-- SPDX-License-Identifier: MIT
local exec = require("exec")
local env = require("env")
local fs = require("fs")
local json = require("json")
local hash = require("hash")
local registry = require("registry")
local process = require("process")
local bounds = require("bounds")
local canonical = require("canonical")
local profiles = require("profiles")
local resources = require("resources")
local homes = require("homes")
local quote = require("quote")
local docker_client = require("docker_client")
local spec = require("spec")
local channel = require("channel")
local uuid = require("uuid")
local security = require("security")
local time = require("time")
local M = {}
M.TOPIC = "bee.placement.image_progress"
type Channel = channel.Channel
type Reader = {read: (Reader, integer) -> (unknown, unknown)}
type Artifact = {name: string, executable_ref: string, candidates: {string}, sibling_prefix: string?}
type Recipe = {base: string, artifacts: {Artifact}}
type Input = {name: string, source: string, digest: string}
type Discovery = {recipe: Recipe, inputs: {Input}, tag: string, digest: string, arch: string}
local function command(argv: {string}, progress: ((string) -> ())?, cancel: Channel<boolean>?): (string?, string?)
    local ref, ref_error = resources.executor()
    local executor = ref and exec.get(ref) or nil
    if not executor then return nil, ref_error or "host executor unavailable" end
    local child, child_error = executor:exec(quote.line(argv), {process_group = true})
    if not child then executor:release(); return nil, tostring(child_error) end
    local stdout, stdout_error = child:stdout_stream()
    local stderr, stderr_error = child:stderr_stream()
    if not stdout or not stderr then child:close(true); executor:release(); return nil, tostring(stdout_error or stderr_error) end
    local output: {string} = {}
    local errors: {string} = {}
    local total = 0
    local function drain(stream: Reader, buffer: {string})
        while true do
            local chunk, read_error = stream:read(4096)
            if chunk == nil or chunk == "" then break end
            if type(chunk) ~= "string" then child:close(true); break end
            total = total + #chunk
            if total > 1048576 then child:close(true); break end
            buffer[#buffer + 1] = chunk
            if progress then progress(chunk) end
        end
    end
    local stdout_reader: Reader = {read = function(_self: Reader, size: integer): (unknown, unknown) return stdout:read(size) end}
    local stderr_reader: Reader = {read = function(_self: Reader, size: integer): (unknown, unknown) return stderr:read(size) end}
    local started, start_error = child:start()
    if not started then child:close(true); executor:release(); return nil, tostring(start_error) end
    local finished = channel.new(2)
    coroutine.spawn(function() drain(stderr_reader, errors); finished:send(true) end)
    coroutine.spawn(function() drain(stdout_reader, output); finished:send(true) end)
    for _ = 1, 2 do
        local cases = {finished:case_receive()}
        if cancel then cases[#cases + 1] = cancel:case_receive() end
        local selected = channel.select(cases)
        if not selected.ok or selected.channel == cancel then
            child:close(true); executor:release()
            return nil, "runtime image build cancelled; inspect its recorded result before another launch"
        end
    end
    local code, wait_error = child:wait()
    stdout:close(); stderr:close(); executor:release()
    if code ~= 0 or wait_error then return nil, "image command failed: " .. argv[1] end
    return table.concat(output), nil
end
function M.decode(value: unknown): (Recipe?, string?)
    local object = bounds.object(value)
    if not object or bounds.fields(object, {"schema_revision", "base", "artifacts"}) or object.schema_revision ~= "bee.runtime-recipe@1" then return nil, "invalid runtime recipe" end
    local base = bounds.line(object.base, 512)
    local digest = base and base:match("^[A-Za-z0-9_.:/%-]+@sha256:([0-9a-f]+)$") or nil
    if not base or not digest or #digest ~= 64 then return nil, "runtime recipe base must be digest-pinned" end
    local rows = bounds.array(object.artifacts, 6)
    if not rows or #rows == 0 then return nil, "runtime recipe requires installed artifacts" end
    local artifacts: {Artifact} = {}
    local names: {[string]: boolean} = {}
    for _, row in ipairs(rows) do
        local item = bounds.object(row)
        if not item or bounds.fields(item, {"name", "executable_ref", "candidates", "sibling_prefix"}) then return nil, "invalid runtime artifact" end
        local name, ref = bounds.id(item.name), bounds.id(item.executable_ref)
        local candidates = bounds.array(item.candidates or {}, 8)
        local prefix = item.sibling_prefix == nil and nil or bounds.line(item.sibling_prefix, 64)
        if not name or not name:match("^[a-z][a-z0-9_-]*$") or names[name] or not ref or not candidates then return nil, "invalid runtime artifact identity" end
        if item.sibling_prefix ~= nil and (not prefix or not prefix:match("^[A-Za-z0-9_-]+$")) then return nil, "invalid artifact sibling prefix" end
        local checked: {string} = {}
        for _, raw in ipairs(candidates) do
            local candidate = bounds.line(raw, 512)
            if not candidate or not candidate:match("^[A-Za-z0-9_@./%-]+$") or candidate:sub(1, 1) == "/" then return nil, "artifact candidate must be relative to its executable" end
            checked[#checked + 1] = candidate
        end
        names[name] = true
        artifacts[#artifacts + 1] = {name = name, executable_ref = ref, candidates = checked, sibling_prefix = prefix}
    end
    return {base = base, artifacts = artifacts}, nil
end
local function real_file(path: string, cancel: Channel<boolean>?): string?
    if path:sub(1, 1) ~= "/" or path:find("[%z%c]") then return nil end
    local resolved = command({"/usr/bin/readlink", "-f", "--", path}, nil, cancel)
    local value = resolved and resolved:gsub("\n$", "") or nil
    if not value or value:sub(1, 1) ~= "/" or value:find("[%z%c]") then return nil end
    return value
end
function M.artifact_arch(header: string): string?
    if #header < 20 or header:sub(1, 4) ~= "\127ELF" or header:byte(5) ~= 2 or header:byte(6) ~= 1 then return nil end
    local machine = assert(header:byte(19)) + assert(header:byte(20)) * 256
    if machine == 62 then return "amd64" end
    if machine == 183 then return "arm64" end
    return nil
end
local function elf(volume: fs.FS, path: string): string?
    local file = volume:open(path, "r")
    if not file then return nil end
    local header = file:read(20)
    file:close()
    return type(header) == "string" and M.artifact_arch(header) or nil
end
function M.discover(ref: string, cancel: Channel<boolean>?): (Discovery?, string?)
    local entry = registry.get(ref)
    local meta = entry and bounds.object(entry.meta) or nil
    if not entry or entry.kind ~= "registry.entry" or not meta or meta.type ~= "bee.runtime_recipe" then return nil, "runtime recipe is unavailable" end
    local recipe, recipe_error = M.decode(entry.data)
    if not recipe then return nil, recipe_error end
    local host_ref = resources.host_files()
    local volume = host_ref and fs.get(host_ref) or nil
    local executor_ref = resources.executor()
    if not volume or not executor_ref then return nil, "runtime artifact discovery has no host files or executor" end
    local inputs: {Input} = {}
    local architecture: string? = nil
    for _, artifact in ipairs(recipe.artifacts) do
        local executable = env.get(artifact.executable_ref)
        if type(executable) == "string" and executable ~= "" then
            local resolved = real_file(executable, cancel)
            if not resolved then return nil, "installed runtime path cannot be resolved: " .. artifact.name end
            local parent = resolved:match("^(.*)/[^/]+$")
            if not parent then return nil, "installed runtime has no parent directory" end
            local source: string? = elf(volume, resolved) and resolved or nil
            for _, candidate in ipairs(artifact.candidates) do
                if not source then
                    local selected = real_file(parent .. "/" .. candidate, cancel)
                    if selected and elf(volume, selected) then source = selected end
                end
            end
            if not source and artifact.sibling_prefix then
                local iterator, state = volume:readdir(parent)
                if iterator then
                    local candidates: {string} = {}
                    for item in iterator, state do
                        if item.name:sub(1, #artifact.sibling_prefix) == artifact.sibling_prefix then candidates[#candidates + 1] = parent .. "/" .. item.name end
                    end
                    table.sort(candidates)
                    for _, candidate in ipairs(candidates) do if elf(volume, candidate) then source = candidate end end
                end
            end
            if not source then return nil, "installed runtime has no Linux executable artifact: " .. artifact.name end
            local arch = elf(volume, source)
            if not arch or (architecture and architecture ~= arch) then return nil, "installed CLI artifacts have incompatible architectures" end
            architecture = arch
            local measured, measure_error = command({"/usr/bin/sha256sum", source}, nil, cancel)
            local digest = measured and measured:match("^([0-9a-f]+)") or nil
            if not digest or #digest ~= 64 then return nil, measure_error or "runtime artifact digest failed" end
            inputs[#inputs + 1] = {name = artifact.name, source = source, digest = digest}
        end
    end
    if #inputs == 0 then return nil, "no installed Linux CLI artifacts were discovered" end
    local identity = canonical.encode({recipe = recipe, inputs = inputs, arch = architecture})
    local digest = identity and hash.sha256(identity) or nil
    if not digest then return nil, "runtime recipe digest failed" end
    return {recipe = recipe, inputs = inputs, digest = digest, tag = "bee-runtime:" .. digest, arch = assert(architecture)}, nil
end
local function image_id(value: unknown): string?
    local object = bounds.object(value)
    local id = object and bounds.line(object.Id, 71) or nil
    if not id or not id:match("^sha256:[0-9a-f]+$") or #id ~= 71 then return nil end
    return id
end
function M.verified_image(value: unknown, digest: string, inputs: {Input}, arch: string): string?
    local object = bounds.object(value)
    local config = object and bounds.object(object.Config) or nil
    local labels = config and bounds.object(config.Labels) or nil
    if not object or object.Os ~= "linux" or object.Architecture ~= arch or not labels
        or labels["bee.actor_ref"] ~= "bee.runtime-image" or labels["bee.attempt_id"] ~= digest then return nil end
    for _, input in ipairs(inputs) do if labels["bee.runtime." .. input.name] ~= input.digest then return nil end end
    return image_id(value)
end
function M.readiness(ref: string, runtime: string): ({[string]: unknown}?, string?)
    local discovered, discover_error = M.discover(ref)
    if not discovered then return nil, discover_error end
    local client = docker_client.new("/var/run/docker.sock")
    if not client then return nil, "Docker connection unavailable" end
    local installed = client:inspect_image(discovered.tag)
    local available = false
    for _, input in ipairs(discovered.inputs) do if input.name == runtime then available = true end end
    local verified = M.verified_image(installed, discovered.digest, discovered.inputs, discovered.arch)
    if image_id(installed) and not verified then
        return {present = false, buildable = false, runtime_present = available, os = "linux", arch = discovered.arch,
            reason = "cached runtime image differs from the installed artifact recipe"}, nil
    end
    return {image_ref = verified, image_digest = verified or discovered.digest, present = verified ~= nil, buildable = available, runtime_present = available,
        os = "linux", arch = discovered.arch, reason = verified and "cached runtime image is ready" or (available and "runtime image is not cached; launch once to build it, then refresh runtime options" or "this CLI has no installed artifact")}, nil
end
function M.build(profile: profiles.Resolved, recipient: string?, cancel: Channel<boolean>?): (string?, string?, string?)
    local recipe_ref = profile.profile.image_recipe_ref
    if not recipe_ref then return profile.profile.image_ref, profile.profile.interactive_route_ref, nil end
    process.send(recipient or process.pid(), M.TOPIC, {version = 1, profile_ref = profile.ref, detail = "Discovering installed CLI artifacts"})
    local discovered, discover_error = M.discover(recipe_ref, cancel)
    if not discovered then return nil, nil, discover_error end
    local client = docker_client.new("/var/run/docker.sock")
    if not client then return nil, nil, "Docker connection unavailable" end
    local installed = client:inspect_image(discovered.tag)
    local image = M.verified_image(installed, discovered.digest, discovered.inputs, discovered.arch)
    if image_id(installed) and not image then return nil, nil, "cached runtime image differs from the installed artifact recipe" end
    local root_ref = resources.root()
    local volume = root_ref and fs.get(root_ref) or nil
    if not volume then return nil, nil, "image build root unavailable" end
    local receipt_directory = homes.os_path("/images/receipts")
    if not receipt_directory then return nil, nil, "image receipt path unavailable" end
    local made, mkdir_error = command({"/bin/mkdir", "-p", receipt_directory}, nil, cancel)
    if not made then return nil, nil, mkdir_error end
    local steps: {string} = {}
    local function progress(detail: string)
        local bounded = detail:sub(1, 4096)
        if #steps == 128 then table.remove(steps, 1) end
        steps[#steps + 1] = bounded
        local receipt = json.encode({version = 1, recipe_ref = recipe_ref, recipe_digest = discovered.digest,
            profile_ref = profile.ref, image = image, detail = bounded, arch = discovered.arch, steps = steps})
        if receipt then volume:writefile("/images/receipts/" .. discovered.digest .. ".json", receipt, {atomic = true}) end
        process.send(recipient or process.pid(), M.TOPIC, {version = 1, profile_ref = profile.ref, detail = bounded})
    end
    if not image then
        local directory = "/images/" .. discovered.digest
        local absolute = homes.os_path(directory)
        if not absolute then return nil, nil, "image build path unavailable" end
        local made, mkdir_error = command({"/bin/mkdir", "-p", absolute .. "/bin"}, nil, cancel)
        if not made then return nil, nil, mkdir_error end
        progress("Discovering installed CLI artifacts")
        local labels: {string} = {'bee.actor_ref="bee.runtime-image"', 'bee.attempt_id="' .. discovered.digest .. '"'}
        for _, input in ipairs(discovered.inputs) do
            progress("Copying " .. input.name .. " runtime artifact")
            local copied, copy_error = command({"/bin/cp", "--", input.source, absolute .. "/bin/" .. input.name}, nil, cancel)
            if not copied then homes.remove_tree(volume, directory); return nil, nil, copy_error end
            local measured = command({"/usr/bin/sha256sum", absolute .. "/bin/" .. input.name}, nil, cancel)
            if not measured or measured:match("^([0-9a-f]+)") ~= input.digest then
                homes.remove_tree(volume, directory); return nil, nil, "installed artifact changed during image preparation: " .. input.name
            end
            labels[#labels + 1] = 'bee.runtime.' .. input.name .. '="' .. input.digest .. '"'
        end
        local dockerfile = "FROM " .. discovered.recipe.base .. "\nLABEL " .. table.concat(labels, " ")
            .. '\nCOPY bin/ /usr/local/bin/\nENV PATH="/usr/local/bin:/usr/bin:/bin" HOME="/home/bee"\nUSER 1000:1000\nWORKDIR /home/bee\n'
        local written = volume:writefile(directory .. "/Dockerfile", dockerfile)
        if not written then homes.remove_tree(volume, directory); return nil, nil, "runtime Dockerfile could not be written" end
        progress("Building the digest-pinned runtime image")
        local built, build_error = command({"docker", "build", "--platform", "linux/" .. discovered.arch, "--rm", "--force-rm", "-t", discovered.tag, absolute}, progress, cancel)
        homes.remove_tree(volume, directory)
        if not built then progress(build_error or "runtime image build failed"); return nil, nil, build_error end
        installed = client:inspect_image(discovered.tag)
        image = M.verified_image(installed, discovered.digest, discovered.inputs, discovered.arch)
        if not image then return nil, nil, "built runtime image has no immutable digest" end
    end
    progress("Runtime image ready: " .. image)
    local identity = hash.sha256(assert(canonical.encode({profile = profile, image = image, ownership_labels = spec.LABEL_ENV})))
    if not identity then return nil, nil, "runtime executor identity failed" end
    local name = "runtime-" .. identity
    local executor_id = "bee.placement.docker:" .. name .. "-executor"
    local route_id = "bee.placement.docker:" .. name .. "-route"
    local overlay, overlay_error = registry.overlay("bee.placement.docker:runtime")
    if not overlay then return nil, nil, tostring(overlay_error) end
    if not overlay:get(executor_id) then
        local selected = profile.profile
        local limits = selected.limits
        if not limits then return nil, nil, "runtime profile has no limits" end
        local changes = overlay:changes()
        changes:create({id = executor_id, kind = "exec.docker", data = {host = "unix:///var/run/docker.sock", image = image,
            user = selected.user, network_mode = selected.network, memory_limit = limits.memory, cpu_quota = limits.cpu, pids_limit = limits.pids,
            labels_from_env = spec.LABEL_ENV,
            read_only_rootfs = true, no_new_privileges = true, auto_remove = false, cap_drop = {"ALL"}, tmpfs = {["/tmp"] = "rw,nosuid,nodev,size=128m"}}})
        changes:create({id = route_id, kind = "registry.entry", meta = {type = "docker.interactive_executor"}, data = {image_ref = image, executor_ref = executor_id}})
        local _, apply_error = changes:apply()
        if apply_error then return nil, nil, tostring(apply_error) end
    end
    return image, route_id, nil
end
M.OWNER = "bee.placement.docker/image"
M.REQUEST = "bee.placement.image_request"
M.REPLY = "bee.placement.image_reply"
M.command = command
function M.resolve(profile: profiles.Resolved, progress_recipient: string?, operation: string?, workspace: string?): (string?, string?, string?)
    if not operation and not profile.profile.image_recipe_ref then return profile.profile.image_ref, profile.profile.interactive_route_ref, nil end
    if not security.can("bee.placement.image", profile.ref) then return nil, nil, "runtime image preparation is not authorized" end
    local owner = process.registry.lookup(M.OWNER)
    if not owner then return nil, nil, "runtime image owner is unavailable" end
    local root_ref = resources.root()
    local volume = root_ref and fs.get(root_ref) or nil
    if not volume then return nil, nil, "image request root unavailable" end
    local parent = "/images/requests"
    local absolute = homes.os_path(parent)
    if not absolute then return nil, nil, "image request path unavailable" end
    local made, mkdir_error = command({"/bin/mkdir", "-p", absolute})
    if not made then return nil, nil, mkdir_error end
    local id = uuid.v7()
    local path = parent .. "/" .. id .. ".json"
    local encoded = json.encode({version = 1, request_id = id, profile_ref = profile.ref, profile_digest = profile.digest,
        sender = tostring(process.pid()), progress_recipient = progress_recipient, operation = operation, workspace = workspace})
    if not encoded then return nil, nil, "image request encoding failed" end
    local written, write_error = volume:writefile(path, encoded, {atomic = true})
    if not written then return nil, nil, tostring(write_error) end
    local replies = process.listen(M.REPLY, {message = true})
    if not replies then volume:remove(path); return nil, nil, "image reply listener unavailable" end
    local events = assert(process.events())
    local monitored = process.monitor(owner)
    if not monitored then process.unlisten(replies); volume:remove(path); return nil, nil, "runtime image owner could not be monitored" end
    local sent = process.send(owner, M.REQUEST, {version = 1, request_id = id})
    if not sent then process.unmonitor(owner); process.unlisten(replies); volume:remove(path); return nil, nil, "image request was not queued" end
    local deadline = time.after("10m")
    local result: {[string]: unknown}? = nil
    while not result do
        local selected = channel.select({replies:case_receive(), events:case_receive(), deadline:case_receive()})
        if not selected.ok or selected.channel == deadline then break end
        if selected.channel == events then
            local event = selected.value
            if event.kind == process.event.CANCEL or (event.kind == process.event.EXIT and tostring(event.from) == tostring(owner)) then break end
        else
            local message = selected.value
            local value = bounds.object(message:payload():data())
            if tostring(message:from()) == tostring(owner) and value and value.version == 1 and value.request_id == id
                and not bounds.fields(value, {"version", "request_id", "image", "route", "error"}) then result = value end
        end
    end
    process.unmonitor(owner)
    process.unlisten(replies)
    volume:remove(path)
    if not result then return nil, nil, "image preparation outcome is unknown; inspect image readiness and its receipt before another launch" end
    if operation then return bounds.line(result.image,128), nil, bounds.line(result.error,4096) end
    if result.error == nil and not image_id({Id = result.image}) then return nil, nil, "image owner returned no immutable image ID" end
    if result.error == nil and not bounds.id(result.route) then return nil, nil, "image owner returned no interactive route" end
    return bounds.line(result.image, 512), bounds.id(result.route), bounds.line(result.error, 4096)
end
function M.authorized_request(id: string, sender: string): (profiles.Resolved?, string?, string?, string?, string?)
    local root_ref = resources.root()
    local volume = root_ref and fs.get(root_ref) or nil
    if not volume then return nil, "image request root unavailable" end
    local content = volume:readfile("/images/requests/" .. id .. ".json")
    if not content or #content > 4096 then return nil, "image request is not recorded" end
    local decoded = json.decode(content)
    local request = bounds.object(decoded)
    if not request or bounds.fields(request, {"version", "request_id", "profile_ref", "profile_digest", "sender", "progress_recipient", "operation", "workspace"})
        or request.version ~= 1 or request.request_id ~= id or request.sender ~= sender then return nil, "image request belongs to another sender" end
    local ref = bounds.id(request.profile_ref)
    if not ref then return nil, "image request profile is invalid" end
    local pinned = registry.snapshot()
    local profile = pinned and profiles.resolve(pinned, ref) or nil
    if not profile or profile.digest ~= request.profile_digest then return nil, "image request profile changed" end
    local recipient = request.progress_recipient == nil and sender or bounds.line(request.progress_recipient, 512)
    if not recipient then return nil, "image progress recipient is invalid" end
    local operation = request.operation == nil and nil or bounds.member(request.operation, {"environment", "revoke"})
    local workspace = request.workspace == nil and nil or bounds.id(request.workspace)
    if request.operation ~= nil and (not operation or not workspace) then return nil, "environment request is invalid" end
    return profile, nil, recipient, operation, workspace
end
return M
