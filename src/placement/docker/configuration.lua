-- SPDX-License-Identifier: MIT
-- Pure projection of host-admitted container inputs. These values describe a
-- request; neither paths nor labels establish permission to create or mount.
local bounds = require("bounds")
local M = {}
type Object = {[string]: unknown}
type Config = {
    Image: string, User: string, Cmd: {string}, WorkingDir: string, Env: {string},
    Tty: boolean, OpenStdin: boolean, AttachStdin: boolean, AttachStdout: boolean, AttachStderr: boolean,
    Labels: {[string]: string}, HostConfig: {
        ReadonlyRootfs: boolean, Privileged: boolean, AutoRemove: boolean,
        CapDrop: {string}, SecurityOpt: {string}, PidsLimit: integer, Memory: integer,
        NanoCPUs: integer, NetworkMode: string, Binds: {string},
        Tmpfs: {[string]: string}, ExtraHosts: {string}, Devices: {string},
    },
}
local LABELS = {"bee.actor_ref", "bee.revision_digest", "bee.attempt_id", "bee.request_digest", "bee.lease_fence", "bee.image_digest"}
local function path(value: unknown): string?
    local text = bounds.text(value, 4096)
    if not text or text:sub(1, 1) ~= "/" or text == "/" or text:sub(-1) == "/"
        or text:find("[%c:]") or text:find("//", 1, true) then return nil end
    for segment in text:gmatch("[^/]+") do
        if segment == "." or segment == ".." then return nil end
    end
    return text
end
local function within(child: string, parent: string): boolean
    return child == parent or child:sub(1, #parent + 1) == parent .. "/"
end
local function overlap(a: string, b: string): boolean
    return within(a, b) or within(b, a)
end
local function positive(value: unknown): integer?
    local number = bounds.integer(value)
    if not number or number < 1 or number > 9007199254740991 then return nil end
    return number
end
local function image(value: unknown): string?
    local text = bounds.text(value, 71)
    if not text or #text ~= 71 or not text:match("^sha256:[0-9a-f]+$") then return nil end
    return text
end
function M.build(value: unknown): (Config?, string?)
    local raw = bounds.object(value)
    if not raw then return nil, "Docker preparation must be an object" end
    local extra = bounds.fields(raw, {"image", "user", "network", "apparmor", "memory", "nano_cpus", "pids_limit",
        "command", "home_source", "home_target", "workspace_source", "workspace_target", "workspace_access", "working_directory", "labels"})
    if extra then return nil, extra end
    local selected_image = image(raw.image)
    if not selected_image then return nil, "Docker preparation needs the exact local image ID" end
    local user = bounds.text(raw.user, 32)
    if not user or not user:match("^[1-9][0-9]*:[1-9][0-9]*$") then return nil, "Docker user must be non-root uid:gid" end
    local network = bounds.text(raw.network, 128)
    if not network then return nil, "Docker network is required" end
    if not network:match("^[A-Za-z0-9][A-Za-z0-9_.-]*$") then return nil, "Docker network name is invalid" end
    if network == "host" or network == "default" or network == "bridge" then
        return nil, "Docker network must be explicitly selected without host or default sharing"
    end
    local apparmor = bounds.text(raw.apparmor, 128)
    if not apparmor or not apparmor:match("^[A-Za-z0-9_.-]+$") or apparmor == "unconfined" then
        return nil, "Docker preparation needs an enforced AppArmor profile"
    end
    local memory, cpu, pids = positive(raw.memory), positive(raw.nano_cpus), positive(raw.pids_limit)
    if not memory or not cpu or not pids then return nil, "Docker resource limits must be positive exact integers" end
    local home_source, home_target = path(raw.home_source), path(raw.home_target)
    local project_source, project_target = path(raw.workspace_source), path(raw.workspace_target)
    if not home_source or not home_target or not project_source or not project_target then return nil, "Docker mount paths must be absolute and normalized" end
    if home_source:find("docker.sock", 1, true) or project_source:find("docker.sock", 1, true) then return nil, "Docker socket mounts are forbidden" end
    if overlap(home_source, project_source) then return nil, "project mount must not expose the private home" end
    if overlap(home_target, project_target) or overlap(home_target, "/tmp") or overlap(project_target, "/tmp") then
        return nil, "Docker mount targets overlap"
    end
    local access = raw.workspace_access
    if access ~= "read" and access ~= "write" then return nil, "workspace access must be read or write" end
    local workdir = path(raw.working_directory)
    if not workdir or (not within(workdir, home_target) and not within(workdir, project_target)) then return nil, "working directory must be within an admitted mount" end
    local declared = bounds.object(raw.labels)
    if not declared then return nil, "Docker admission labels are required" end
    local extra_label = bounds.fields(declared, LABELS)
    if extra_label then return nil, extra_label end
    local labels: {[string]: string} = {}
    for _, key in ipairs(LABELS) do
        local label = bounds.text(declared[key], 512)
        if not label or label == "" or label:find("%c") then return nil, "invalid Docker admission label " .. key end
        labels[key] = label
    end
    if labels["bee.image_digest"] ~= selected_image then return nil, "image label differs from selected image" end
    if type(raw.command) ~= "table" then return nil, "Docker command must be an array" end
    local command: {string} = {}
    local bytes = 0
    for index, item in ipairs(raw.command :: {unknown}) do
        local argument = bounds.text(item, 16384)
        if not argument or argument == "" or argument:find("%z") then return nil, "invalid Docker command argument" end
        command[index] = argument
        bytes = bytes + #argument
        if index > 64 or bytes > 65536 then return nil, "Docker command exceeds its budget" end
    end
    for key in pairs(raw.command :: Object) do
        if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #command then return nil, "Docker command must be dense" end
    end
    if #command == 0 or not path(command[1]) then return nil, "Docker executable must be absolute" end
    return {Image = selected_image, User = user, Cmd = command, WorkingDir = workdir,
        Env = {"HOME=" .. home_target, "TMPDIR=/tmp"}, Tty = true, OpenStdin = true,
        AttachStdin = true, AttachStdout = true, AttachStderr = true, Labels = labels,
        HostConfig = {ReadonlyRootfs = true, Privileged = false, AutoRemove = false,
            CapDrop = {"ALL"}, SecurityOpt = {"no-new-privileges:true", "seccomp=runtime/default", "apparmor=" .. apparmor},
            PidsLimit = pids, Memory = memory, NanoCPUs = cpu, NetworkMode = network,
            Binds = {home_source .. ":" .. home_target .. ":rw", project_source .. ":" .. project_target .. (access == "read" and ":ro" or ":rw")},
            Tmpfs = {["/tmp"] = "rw,nosuid,nodev,noexec"}, ExtraHosts = {}, Devices = {}}}, nil
end
return M
