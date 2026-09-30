-- SPDX-License-Identifier: MIT
local exec = require("exec")
local registry = require("registry")
local json = require("json")
local sql = require("sql")
local bounds = require("bounds")
local types = require("types")
local materialization = require("materialization")
local process_backend = require("process_backend")
local resources = require("resources")
local homes = require("homes")
local service = require("service")
local spec_codec = require("spec")
local paths = require("paths")
local quote = require("quote")
local M = {}
local function path_under(path: string, root: string): string?
    if path == root then return "" end
    if path:sub(1, #root + 1) == root .. "/" then return path:sub(#root + 1) end
    return nil
end
function M.route(spec: spec_codec.Spec): (string?, string?)
    if not spec.interactive_route_ref then return nil, "placement profile has no interactive executor route" end
    local route, route_error = registry.get(spec.interactive_route_ref)
    if not route then return nil, "interactive route unavailable: " .. tostring(route_error) end
    local meta, data = bounds.object(route.meta), bounds.object(route.data)
    if route.kind ~= "registry.entry" or not meta or meta.type ~= "docker.interactive_executor" or not data then return nil, "interactive route has the wrong type" end
    local ref = bounds.id(data.executor_ref)
    if not ref or data.image_ref ~= spec.image then return nil, "interactive route does not bind the admitted image" end
    local executor, executor_error = registry.get(ref)
    local config = executor and bounds.object(executor.data) or nil
    if not executor or executor.kind ~= "exec.docker" or not config then return nil, "interactive executor unavailable: " .. tostring(executor_error) end
    if config.host ~= "unix:///var/run/docker.sock" or config.image ~= spec.image or config.user ~= spec.user or config.network_mode ~= spec.network
        or config.memory_limit ~= spec.limits.memory or config.cpu_quota ~= spec.limits.cpu or config.pids_limit ~= spec.limits.pids
        or config.read_only_rootfs ~= true or config.no_new_privileges ~= true or config.auto_remove ~= false then
        return nil, "interactive executor differs from the admitted isolation specification"
    end
    local ambient = bounds.object(config.default_env or {})
    if not ambient or next(ambient) ~= nil then return nil, "interactive executor has an ambient environment" end
    local drops = bounds.array(config.cap_drop, 1)
    local volumes = bounds.array(config.volumes or {}, 0)
    local additions = bounds.array(config.cap_add or {}, 0)
    if not drops or #drops ~= 1 or drops[1] ~= "ALL" or not volumes or not additions then return nil, "interactive executor has ambient capabilities or mounts" end
    local tmpfs = bounds.object(config.tmpfs)
    if not tmpfs or tmpfs["/tmp"] ~= "rw,nosuid,nodev,size=128m" then return nil, "interactive executor requires bounded tmpfs" end
    for key in pairs(tmpfs) do if key ~= "/tmp" then return nil, "interactive executor has an unadmitted tmpfs" end end
    return ref, nil
end
function M.prepare(_db: sql.DB, request: types.LaunchRequest, prepared: materialization.Prepared): (exec.Executor?, {string}?, process_backend.Options?, string?)
    local loaded, load_error = service.load({attempt_id = request.attempt_id})
    if not loaded then return nil, nil, nil, load_error end
    local ref, route_error = M.route(loaded.spec)
    if not ref then return nil, nil, nil, route_error end
    local available, image_error = service.ensure_image(loaded.spec)
    if not available then return nil, nil, nil, image_error end
    local mounts: {process_backend.Mount} = {}
    local mappings: {{host: string, guest: string}} = {}
    local host_executor, host_error = resources.executor()
    if not host_executor then return nil, nil, nil, host_error end
    for _, mount in ipairs(loaded.spec.mounts) do
        local grant: types.ResourceGrant? = nil
        for _, item in ipairs(request.resources) do if item.name == mount.resource then grant = item end end
        if not grant then return nil, nil, nil, "mount grant is unavailable" end
        local directory, directory_error = resources.directory(grant.root_ref)
        if not directory then return nil, nil, nil, directory_error end
        local source, source_error = paths.admit(directory .. (grant.subpath == "" and "" or "/" .. grant.subpath), {directory}, host_executor)
        if not source then return nil, nil, nil, source_error end
        mounts[#mounts + 1] = {source = source, target = mount.target, read_only = mount.access == "read"}
        mappings[#mappings + 1] = {host = source, guest = mount.target}
    end
    local raw_home, raw_home_error = homes.os_path(prepared.home_path .. "/home")
    if not raw_home then return nil, nil, nil, raw_home_error end
    local home, home_error = paths.resolve(raw_home, host_executor)
    if not home then return nil, nil, nil, home_error end
    mounts[#mounts + 1] = {source = home, target = spec_codec.HOME, read_only = false}
    mappings[#mappings + 1] = {host = home, guest = spec_codec.HOME}
    local function translate(path: string): string?
        for _, mapping in ipairs(mappings) do
            local suffix = path_under(path, mapping.host)
            if suffix then return mapping.guest .. suffix end
        end
        return nil
    end
    local physical_workdir, workdir_error = paths.resolve(prepared.working_directory, host_executor)
    if not physical_workdir then return nil, nil, nil, workdir_error end
    local workdir = translate(physical_workdir)
    if not workdir then return nil, nil, nil, "RESOURCE_NOT_LOCAL: working directory has no admitted container mount" end
    local argv: {string} = {request.launch.executable}
    for _, argument in ipairs(prepared.arguments) do argv[#argv + 1] = translate(argument) or argument end
    local stdin_materialized = request.launch.stdin ~= nil and request.launch.stdin_eof == true
    if stdin_materialized then
        local written, write_error = homes.write_protected(prepared.home_path, ".bee-stdin", request.launch.stdin or "")
        if not written then return nil, nil, nil, write_error end
        argv = {"/bin/sh", "-c", "exec " .. quote.line(argv) .. " < " .. quote.posix(spec_codec.HOME .. "/.bee-stdin")}
    end
    local executor, executor_error = exec.get(ref)
    if not executor then return nil, nil, nil, "Docker executor unavailable: " .. tostring(executor_error) end
    prepared.environment.BEE_ATTEMPT_ID = request.attempt_id
    return executor, argv, {work_dir = workdir, env = prepared.environment, mounts = mounts, stdin_materialized = stdin_materialized}, nil
end
function M.identity(request: types.LaunchRequest): ({[string]: unknown}?, string?)
    local loaded, load_error = service.load({attempt_id = request.attempt_id})
    if not loaded then return nil, load_error end
    local found, find_error = service.find(loaded)
    if not found then return nil, find_error or "container identity was not observed after start" end
    local encoded, encode_error = json.encode(found)
    if not encoded then return nil, tostring(encode_error) end
    return {placement_identity_json = encoded}, nil
end
function M.absent(request: types.LaunchRequest): (boolean, string?)
    local loaded, load_error = service.load({attempt_id = request.attempt_id})
    if not loaded then return false, load_error end
    local found, find_error, absent = service.find(loaded)
    if find_error then return false, find_error end
    return absent == true or (found ~= nil and (found.state == "exited" or found.state == "stopped")), nil
end
function M.backend(): process_backend.Backend
    return {guest_home = spec_codec.HOME, binding = spec_codec.BINDING, prepare = M.prepare, identity = M.identity, absent = M.absent,
        stop = function(attempt: types.Attempt): (boolean, string?)
            local reply = service.stop({attempt_id = attempt.attempt_id, mode = "forced"})
            return reply.ok, reply.error and reply.error.message or nil
        end,
        cleanup = function(attempt: types.Attempt, preparers_only: boolean?): (boolean, string?)
            if preparers_only then
                local reply = service.cleanup_preparers({attempt_id = attempt.attempt_id})
                return reply.ok, reply.error and reply.error.message or nil
            end
            local reply = service.cleanup({attempt_id = attempt.attempt_id})
            return reply.ok, reply.error and reply.error.message or nil
        end}
end
return M
