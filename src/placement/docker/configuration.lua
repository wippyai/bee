-- SPDX-License-Identifier: MIT
-- Pure projection of host-admitted container inputs. These values describe a
-- request; neither paths nor labels establish permission to create or mount.
local bounds = require("bounds")
local M = {}
type Object = {[string]: unknown}
type Mount = {source: string, target: string, access: "read" | "write"}
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
-- The first argument is the admitted specification. Materialized environment
-- values are separate transient input; the resulting daemon request may hold
-- credentials and must never be used as the durable placement specification.
function M.build(value: unknown, delivered_environment: unknown?): (Config?, string?)
    local raw = bounds.object(value)
    if not raw then return nil, "Docker preparation must be an object" end
    local extra = bounds.fields(raw, {"image", "user", "network", "apparmor", "memory", "nano_cpus", "pids_limit",
        "command", "home_source", "home_target", "mounts", "working_directory", "labels"})
    if extra then return nil, extra end
    local selected_image = image(raw.image)
    if not selected_image then return nil, "Docker preparation needs the exact local image ID" end
    local user = bounds.text(raw.user, 32)
    if not user or not user:match("^[1-9][0-9]*:[1-9][0-9]*$") then return nil, "Docker user must be non-root uid:gid" end
    local network = bounds.text(raw.network, 128)
    if not network then return nil, "Docker network is required" end
    if not network:match("^[A-Za-z0-9][A-Za-z0-9_.-]*$") then return nil, "Docker network name is invalid" end
    if network == "host" or network == "default" then
        return nil, "Docker network must be explicitly selected without host sharing or an implicit default"
    end
    local apparmor: string? = nil
    if raw.apparmor ~= nil then
        apparmor = bounds.text(raw.apparmor, 128)
        if not apparmor or not apparmor:match("^[A-Za-z0-9_.-]+$") or apparmor == "unconfined" then
            return nil, "Docker AppArmor requirement must name an enforced profile"
        end
    end
    local memory, cpu, pids = positive(raw.memory), positive(raw.nano_cpus), positive(raw.pids_limit)
    if not memory or not cpu or not pids then return nil, "Docker resource limits must be positive exact integers" end
    local home_source, home_target = path(raw.home_source), path(raw.home_target)
    if not home_source or not home_target then return nil, "Docker mount paths must be absolute and normalized" end
    if home_source:find("docker.sock", 1, true) or home_target:find("docker.sock", 1, true) then return nil, "Docker socket mounts are forbidden" end
    if overlap(home_target, "/tmp") then return nil, "Docker mount targets overlap" end
    if type(raw.mounts) ~= "table" then return nil, "Docker mounts must be an array" end
    local mount_values = raw.mounts :: {unknown}
    local mount_count = 0
    for key in pairs(raw.mounts :: Object) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 or key > 15 then
            return nil, "Docker mounts must be dense and bounded"
        end
        mount_count = mount_count + 1
    end
    if mount_count < 1 or mount_count > 15 then return nil, "Docker mounts must contain 1 to 15 entries" end
    local mounts: {Mount} = {}
    for index = 1, mount_count do
        local declared = bounds.object(mount_values[index])
        if not declared then return nil, "Docker mount " .. tostring(index) .. " must be an object" end
        local extra_mount = bounds.fields(declared, {"source", "target", "access"})
        if extra_mount then return nil, extra_mount end
        local source, target = path(declared.source), path(declared.target)
        if not source or not target then return nil, "Docker mount paths must be absolute and normalized" end
        if source:find("docker.sock", 1, true) or target:find("docker.sock", 1, true) then
            return nil, "Docker socket mounts are forbidden"
        end
        if overlap(home_source, source) then return nil, "mount must not expose the private home" end
        if overlap(home_target, target) or overlap(target, "/tmp") then return nil, "Docker mount targets overlap" end
        for _, prior_mount in ipairs(mounts) do
            if overlap(prior_mount.target, target) then return nil, "Docker mount targets overlap" end
        end
        local access = declared.access
        if access ~= "read" and access ~= "write" then return nil, "mount access must be read or write" end
        mounts[index] = {source = source, target = target, access = access}
    end
    local workdir = path(raw.working_directory)
    local workdir_allowed = workdir and within(workdir, home_target)
    if workdir and not workdir_allowed then
        for _, mount in ipairs(mounts) do
            if within(workdir, mount.target) then workdir_allowed = true; break end
        end
    end
    if not workdir or not workdir_allowed then return nil, "working directory must be within an admitted mount" end
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
        if not argument or argument:find("%z") then return nil, "invalid Docker command argument" end
        command[index] = argument
        bytes = bytes + #argument
        if index > 64 or bytes > 65536 then return nil, "Docker command exceeds its budget" end
    end
    for key in pairs(raw.command :: Object) do
        if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #command then return nil, "Docker command must be dense" end
    end
    if #command == 0 or not path(command[1]) then return nil, "Docker executable must be absolute" end
    -- Values come from the existing materializer after policy, credential and
    -- gateway admission. Do not discover host environment or log these bytes.
    local environment: {[string]: string} = {HOME = home_target, TMPDIR = "/tmp"}
    if delivered_environment ~= nil then
        local supplied = bounds.object(delivered_environment)
        if not supplied then return nil, "Docker environment must be an object" end
        local count, size = 2, #home_target + #"HOME=" + #"TMPDIR=/tmp"
        for name, value in pairs(supplied) do
            local text = bounds.text(value, 16384)
            if #name > 128 or not name:match("^[A-Za-z_][A-Za-z0-9_]*$")
                or not text or text:find("%z") then return nil, "invalid Docker environment entry" end
            if environment[name] == nil then count = count + 1; size = size + #name + #text + 1 end
            if count > 64 or size > 65536 then return nil, "Docker environment exceeds its budget" end
            if (name == "HOME" and text ~= home_target) or (name == "TMPDIR" and text ~= "/tmp") then
                return nil, "Docker environment differs from the admitted home or temporary directory"
            end
            environment[name] = text
        end
    end
    local names: {string} = {}
    for name in pairs(environment) do names[#names + 1] = name end
    table.sort(names)
    local encoded_environment: {string} = {}
    for _, name in ipairs(names) do encoded_environment[#encoded_environment + 1] = name .. "=" .. environment[name] end
    local binds: {string} = {home_source .. ":" .. home_target .. ":rw"}
    for _, mount in ipairs(mounts) do
        binds[#binds + 1] = mount.source .. ":" .. mount.target .. (mount.access == "read" and ":ro" or ":rw")
    end
    local security_options: {string} = {"no-new-privileges:true"}
    if apparmor then security_options[#security_options + 1] = "apparmor=" .. apparmor end
    return {Image = selected_image, User = user, Cmd = command, WorkingDir = workdir,
        Env = encoded_environment, Tty = true, OpenStdin = true,
        AttachStdin = true, AttachStdout = true, AttachStderr = true, Labels = labels,
        HostConfig = {ReadonlyRootfs = true, Privileged = false, AutoRemove = false,
            -- Docker selects its default seccomp profile when no override is
            -- supplied. The admitting owner must verify daemon support.
            CapDrop = {"ALL"}, SecurityOpt = security_options,
            PidsLimit = pids, Memory = memory, NanoCPUs = cpu, NetworkMode = network,
            Binds = binds,
            Tmpfs = {["/tmp"] = "rw,nosuid,nodev,noexec"}, ExtraHosts = {}, Devices = {}}}, nil
end
return M
