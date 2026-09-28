-- MIT. Native attempt materialization shared by execution transports.
-- Runs only inside the admitted placement owner after its starting transition.
-- File credentials go only to the selected private home; receipts retain no
-- credential bytes. The caller owns gateway retirement even
-- when materialization fails after minting the binding.
local env = require("env")
local fs = require("fs")
local funcs = require("funcs")
local sql = require("sql")
local process = require("process")
local hash = require("hash")
local bounds = require("bounds")
local store = require("store")
local resources = require("resources")
local homes = require("homes")
local types = require("types")
local paths = require("paths")
local gateway_protocol = require("gateway_protocol")
local credential_protocol = require("credential_protocol")
local service_reply = require("service_reply")
local formats = require("formats")
local configuration = require("configuration")
local workdir_preparers = require("workdir_preparers")
local writable_roots_adapter = require("writable_roots_adapter")
local M = {}
type WriteBack = {projection_id: string, generation: integer, source_digest: string, path: string}
type WriteBackResult = {projection_id: string, ok: boolean, code: string?, message: string?, written: boolean?}
type Prepared = {environment: {[string]: string}, working_directory: string, arguments: {string}, home_path: string, writebacks: {WriteBack}}
local function provider_home_matches(home: types.ProviderHome, source_path: string, format: formats.Format, source_write_back: boolean): boolean
    local file = format.file
    if not file then return false end
    local projected: {[string]: {source_path: string?, kind: string, write_back: boolean}} = {}
    projected[file.path] = {source_path = source_path, kind = "login", write_back = source_write_back}
    for _, item in ipairs(file.initialize) do
        if projected[item.path] ~= nil then return false end
        projected[item.path] = {source_path = item.source_path, kind = item.source_path and "config" or "state", write_back = false}
    end
    for path, actual in pairs(projected) do
        local found = false
        for _, declared in ipairs(home.files) do
            if declared.path == path then
                if actual.source_path ~= declared.source_path or actual.kind ~= declared.kind or actual.write_back ~= declared.write_back then return false end
                found = true
                break
            end
        end
        if not found then return false end
    end
    for _, expected in ipairs(home.files) do
        if projected[expected.path] == nil and not expected.optional then return false end
    end
    return true
end
function M.write_back(home_path: string, writebacks: {WriteBack}, owner_id: string, attempt_id: string): {WriteBackResult}
    local results: {WriteBackResult} = {}
    for index, candidate in ipairs(writebacks) do
        local content, read_error = homes.read_provider_file(home_path, candidate.path)
        if not content then
            results[index] = {projection_id = candidate.projection_id, ok = false, code = read_error and "UNAVAILABLE" or "NOT_FOUND", message = read_error}
        else
            local raw, call_error = funcs.call(resources.CREDENTIAL_WRITE_BACK, {projection_id = candidate.projection_id, subject = owner_id,
                audience = owner_id, attempt_id = attempt_id, generation = candidate.generation, source_digest = candidate.source_digest, value = content})
            local reply: service_reply.Reply? = nil
            local reply_error: string? = nil
            if not call_error then reply, reply_error = service_reply.decode(raw) end
            if call_error or not reply or not reply.ok then
                results[index] = {projection_id = candidate.projection_id, ok = false,
                    code = call_error and "UNAVAILABLE" or reply and not reply.ok and reply.error.code or "UNAVAILABLE",
                    message = call_error and tostring(call_error) or reply_error}
            else
                local result = bounds.object(reply.value)
                if not result then
                    results[index] = {projection_id = candidate.projection_id, ok = false, code = "UNAVAILABLE", message = "credential write-back returned malformed data"}
                else
                    local unknown_field = bounds.fields(result, {"written"})
                    if unknown_field or type(result.written) ~= "boolean" then
                        results[index] = {projection_id = candidate.projection_id, ok = false, code = "UNAVAILABLE", message = "credential write-back returned malformed data"}
                    else
                        results[index] = {projection_id = candidate.projection_id, ok = true, written = result.written}
                    end
                end
            end
        end
    end
    return results
end
local function evidence(db, attempt_id: string, kind: string, detail: string, update: {[string]: unknown}?): (boolean, string?)
    local result = store.transition(db, attempt_id, {execution = update and update.execution :: types.ExecutionState? or nil,
        fields = update and update.fields :: {[string]: unknown}? or nil, evidence = {kind = kind, detail = detail}})
    if not result.ok then return false, result.message end
    return true, nil
end
-- A launch may declare a host file it needs before it starts, named by the
-- environment variable that locates its directory plus a safe relative path,
-- or by the host home and a default directory. Placement checks existence
-- only through the read-only host volume: it never reads contents and never
-- copies the file into a private home. A missing file refuses before intent.
function M.required_file_missing(request: types.LaunchRequest): string?
    local required = request.launch.required_files
    if not required or #required == 0 then return nil end
    local host_files, host_files_error = resources.host_files()
    local volume = host_files and fs.get(host_files) or nil
    if not volume and host_files_error then return "host files are unavailable: " .. host_files_error end
    if not volume then return "host files are unavailable for " .. request.launch.executable .. "'s required file" end
    for _, file in ipairs(required) do
        local directory = request.environment[file.variable]
        if directory ~= nil and directory == "" then directory = nil end
        local variable_ref = request.environment_refs[file.variable]
        if directory == nil and variable_ref ~= nil then
            local resolved, resolve_error = env.get(variable_ref)
            if not resolve_error and type(resolved) == "string" and resolved ~= "" then directory = resolved end
        end
        if directory == nil then
            local home = request.environment.HOME
            if home ~= nil and home == "" then home = nil end
            if home == nil and request.environment_refs.HOME == "bee.env:machine_home" then
                local resolved, resolve_error = env.get("bee.env:machine_home")
                if not resolve_error and type(resolved) == "string" and resolved ~= "" then home = resolved end
            end
            if home == nil then return "the launch requires " .. file.path .. " and its host home is unavailable" end
            if file.default_directory then directory = home .. "/" .. file.default_directory else directory = home end
        end
        if volume:exists(directory .. "/" .. file.path) ~= true then
            return "the required host file " .. file.path .. " is not installed in " .. directory
        end
    end
    return nil
end
-- The warning is advisory. An evidence file may be created by the provider's
-- sign-in flow after prepare, so this examines existence only at prepare time.
-- All declared paths are already decoded as safe relative paths.
function M.login_notice(request: types.LaunchRequest, selected_home: string,
    is_file: (string) -> boolean?, projected_login_path: string?): types.LoginNotice?
    local login = request.launch.login
    if request.profile_id ~= "window" or not login then return nil end
    if selected_home:sub(1, 1) ~= "/" then return nil end
    for _, file in ipairs(login.files) do
        local directory = request.environment[file.variable]
        if directory == "" then directory = nil end
        if file.variable == "HOME" then directory = selected_home end
        if not directory then
            directory = selected_home
            if file.default_directory then directory = directory .. "/" .. file.default_directory end
        end
        -- A relative override depends on the eventual working directory and
        -- cannot be diagnosed from this home without guessing.
        if directory:sub(1, 1) ~= "/" or directory:find("[%z\r\n]") then return nil end
        local path = directory .. "/" .. file.path
        if path == projected_login_path then return nil end
        local present = is_file(path)
        if present == nil or present == true then return nil end
    end
    return {code = "LOGIN_REQUIRED", provider = login.provider, command = login.command}
end
function M.prepare_login_notice(request: types.LaunchRequest, private_home: string,
    projected_login_path: string?): types.LoginNotice?
    if request.profile_id ~= "window" or not request.launch.login then return nil end
    local selected_home = private_home
    if request.environment_refs.HOME == "bee.env:machine_home" then
        local resolved, err = env.get("bee.env:machine_home")
        if err or type(resolved) ~= "string" then return nil end
        selected_home = resolved
    end
    local host_files = resources.host_files()
    local volume = host_files and fs.get(host_files) or nil
    if not volume then return nil end
    return M.login_notice(request, selected_home, function(path: string): boolean?
        local info, stat_error = volume:stat(path)
        if info then return info.type == "file" and info.is_dir ~= true end
        if stat_error and stat_error:kind() == errors.NOT_FOUND then return false end
        return nil
    end, projected_login_path)
end
-- Native placement selects either its private home or the host's user home.
-- Arbitrary HOME values remain refused; an admitted gateway owns its tokens.
-- Check before intent and again when materializing a retained request.
function M.environment_conflict(request: types.LaunchRequest): string?
    local owners: {[string]: string} = {HOME = "native placement"}
    local provider_home = request.launch.provider_home
    if provider_home and provider_home.private and provider_home.variable then
        if owners[provider_home.variable] then return "provider-home variable " .. provider_home.variable .. " is already assigned" end
        owners[provider_home.variable] = "native provider home"
    end
    if provider_home and provider_home.private then
        for _, item in ipairs(provider_home.extra_variables or {}) do
            if owners[item.variable] then return "provider-home variable " .. item.variable .. " is already assigned" end
            owners[item.variable] = "native provider home"
        end
    end
    if request.gateway then
        local gateway = request.gateway
        if owners[gateway.destination] then return "gateway destination " .. gateway.destination .. " is owned by native placement" end
        owners[gateway.destination] = "gateway"
        if gateway.hook_destination then
            if owners[gateway.hook_destination] then return "hook destination " .. gateway.hook_destination .. " is already assigned" end
            owners[gateway.hook_destination] = "gateway hooks"
        end
    end
    for name, owner in pairs(owners) do
        local inherited_home = name == "HOME" and request.environment[name] == nil
            and request.environment_refs[name] == "bee.env:machine_home"
        if not inherited_home and (request.environment[name] ~= nil or request.environment_refs[name] ~= nil) then
            return "environment destination " .. name .. " is owned by " .. owner
        end
    end
    return nil
end
local function resolve_environment(request: types.LaunchRequest, home: string): ({[string]: string}?, string?)
    local values: {[string]: string} = {}
    for name, value in pairs(request.environment) do values[name] = value end
    for name, ref in pairs(request.environment_refs) do
        local value, err = env.get(ref)
        if err or type(value) ~= "string" then return nil, "environment " .. name .. " unavailable from " .. ref end
        values[name] = value
    end
    if request.environment_refs.HOME == "bee.env:machine_home" then
        local selected = values.HOME
        if not selected or selected:sub(1, 1) ~= "/" or selected:find("[%z\r\n]") then
            return nil, "host user home is unavailable"
        end
    else
        values.HOME = home
    end
    local provider_home = request.launch.provider_home
    if provider_home and provider_home.private and provider_home.variable and provider_home.directory then
        values[provider_home.variable] = home .. "/" .. provider_home.directory
    end
    if provider_home and provider_home.private then
        for _, item in ipairs(provider_home.extra_variables or {}) do values[item.variable] = home .. "/" .. item.directory end
    end
    return values, nil
end
local function resolve_work_dir(request: types.LaunchRequest, home: string): (string?, string?)
    local ref = request.launch.working_directory_ref
    if not ref then return home, nil end
    for _, grant in ipairs(request.resources) do
        if grant.name == ref then
            local directory, err = resources.directory(grant.root_ref)
            if not directory then return nil, err end
            if grant.subpath == "" then return directory, nil end
            return directory .. "/" .. grant.subpath, nil
        end
    end
    return nil, "working directory grant is missing"
end
-- Each write grant admits its granted subpath, physically contained in the
-- resource root the host resolved for the grant.
function M.write_roots(request: types.LaunchRequest, executor: string): ({string}?, string?)
    local write_roots: {string} = {}
    for _, grant in ipairs(request.resources) do
        if grant.access == "write" then
            local root, root_error = resources.directory(grant.root_ref)
            if not root then return nil, root_error or "write-granted root unavailable" end
            if grant.subpath == "" then
                write_roots[#write_roots + 1] = root
            else
                local granted, granted_error = paths.admit(root .. "/" .. grant.subpath, {root}, executor)
                if not granted then return nil, "write grant " .. grant.name .. ": " .. tostring(granted_error) end
                write_roots[#write_roots + 1] = granted
            end
        end
    end
    return write_roots, nil
end
local function prepare_workdir_and_arguments(db: sql.DB, request: types.LaunchRequest, attempt_id: string, initial_work_dir: string): (string?, {string}?, string?)
    local executor, executor_error = resources.executor()
    if not executor then return nil, nil, executor_error or "placement executor unavailable" end
    local write_roots, roots_error = M.write_roots(request, executor)
    if not write_roots then return nil, nil, roots_error or "write-granted root unavailable" end
    local work_dir, extra_roots, preparer_error = workdir_preparers.setup(db, request, attempt_id, initial_work_dir, write_roots)
    if not work_dir or not extra_roots or preparer_error then
        return nil, nil, preparer_error or "workdir preparation failed"
    end
    local delivery = request.delivery
    local adapter = delivery and delivery.git_writable_roots_adapter or nil
    if not adapter or #extra_roots == 0 then
        return work_dir, {}, nil
    end
    local writable_workdir = false
    for _, grant in ipairs(request.resources) do
        if grant.name == request.launch.working_directory_ref and grant.access == "write" then writable_workdir = true end
    end
    if not writable_workdir or not writable_roots_adapter.enabled(adapter, request.launch.argv) then
        return work_dir, {}, nil
    end
    local sandbox_args, args_error = writable_roots_adapter.arguments(adapter, extra_roots)
    if not sandbox_args then
        return nil, nil, args_error or "render writable roots arguments"
    end
    return work_dir, sandbox_args, nil
end
function M.prepare(db: sql.DB, request: types.LaunchRequest, attempt_id: string, generation: integer, expected_binding: string?, materialization_key: string?): (Prepared?, string?, string?)
    local gateway_binding: string? = nil
    local writebacks: {WriteBack} = {}
    local function finish_stopped_without_child(): boolean
        local current = store.row(db, attempt_id)
        if not current or current.execution_state ~= "stopping" or current.runner_pid ~= process.pid() then return false end
        local finished = store.transition(db, attempt_id, {expected_execution = "stopping", execution = "exited",
            fields = {runner_pid = sql.NULL, exit_source = "runner"},
            evidence = {kind = "child.not_started", detail = "stopped during materialization before child creation"}})
        return finished.ok
    end
    local function refused(reason: string): (Prepared?, string?, string?)
        finish_stopped_without_child()
        return nil, reason, gateway_binding
    end
    local function owns_attempt(): boolean
        local current = store.row(db, attempt_id)
        return current ~= nil and current.execution_state == "starting" and current.runner_pid == process.pid()
    end
    if not owns_attempt() then return refused("attempt no longer owns configuration materialization") end
    local delivery = request.delivery
    if not delivery then return refused("attempt has no owner-recorded configuration delivery") end
    if configuration.overlaps(delivery.files, {".bee-retained-login-ready.json"}) then
        evidence(db, attempt_id, "configuration.refused", "configuration overlaps retained login identity", {execution = "exited"})
        return refused("configuration overlaps retained login identity")
    end
    local conflict = M.environment_conflict(request)
    if conflict then
        evidence(db, attempt_id, "environment.refused", conflict, {execution = "exited"})
        return refused(conflict)
    end
    local home_key, key_error = homes.attempt_key(request.owner_id, attempt_id)
    if not home_key then
        evidence(db, attempt_id, "home.failed", key_error or "key", {execution = "uncertain"})
        return refused(key_error or "home key")
    end
    local home_path, home_error = homes.create_attempt(home_key)
    if not home_path then
        evidence(db, attempt_id, "home.failed", home_error or "home", {execution = "exited"})
        return refused(home_error or "attempt home")
    end
    evidence(db, attempt_id, "home.created", "attempt home under derived key", {fields = {home_key = home_key}})
    -- A retained session is an explicit writable session resource. Select its
    -- private /home before any provider, gateway, hook or trust file is
    -- materialized; the attempt directory remains separate for evidence and
    -- cleanup. Only the persisted host-generated delivery files are replaced.
    local selected_home_path = home_path
    local retained_home = false
    local provider_home = request.launch.provider_home
    if request.session_ref and (not provider_home or provider_home.private ~= true) then
        local session_key, session_key_error = homes.session_key(request.owner_id, request.session_ref)
        local session_path = session_key and homes.ensure_session(session_key) or nil
        if not session_path then
            evidence(db, attempt_id, "session.failed", session_key_error or "session directory", {execution = "exited"})
            return refused("session directory")
        end
        if request.launch.home_ref then
            selected_home_path = session_path
            retained_home = true
        end
        evidence(db, attempt_id, "session.attached", retained_home and "retained session home selected" or "retained session directory")
    end
    -- Parents this runner creates in the home for its configuration files.
    local created_parents: {[string]: boolean} = {}
    local home_os, home_os_error = homes.os_path(selected_home_path .. "/home")
    if not home_os then
        evidence(db, attempt_id, "home.failed", home_os_error or "home path", {execution = "exited"})
        return refused(home_os_error or "home path")
    end
    local environment, environment_error = resolve_environment(request, home_os)
    if not environment then
        evidence(db, attempt_id, "environment.failed", environment_error or "environment", {execution = "exited"})
        return refused(environment_error or "environment")
    end
    -- Credential replies carry bytes only to their selected destination.
    -- File logins run before immutable driver configuration so their provider
    -- parent remains runner-owned for this materialization.
    local file_projection = false
    local composition_bases: {[string]: string} = {}
    for index, projection_id in ipairs(request.projections) do
        local generation_key = attempt_id .. ":" .. tostring(index)
        local credential_request: {[string]: unknown} = {projection_id = projection_id, subject = request.owner_id, audience = request.owner_id,
            attempt_id = attempt_id, generation_key = generation_key}
        local provider_home = request.launch.provider_home
        local checked_projection: credential_protocol.CheckedProjection? = nil
        if provider_home and provider_home.private then
            local checked_raw, check_error = funcs.call(resources.CREDENTIAL_CHECK, {projection_id = projection_id,
                subject = request.owner_id, audience = request.owner_id, attempt_id = attempt_id})
            if not owns_attempt() then
                return refused("attempt no longer owns configuration materialization")
            end
            local checked_reply: service_reply.Reply? = nil
            local checked_error: string? = nil
            if not check_error then checked_reply, checked_error = service_reply.decode(checked_raw) end
            if check_error or not checked_reply then
                local code = "UNAVAILABLE"
                evidence(db, attempt_id, "credential.refused", "projection " .. projection_id .. ": " .. code, {execution = "exited"})
                return refused("projection " .. projection_id .. ": " .. code)
            end
            if checked_reply.ok == false then
                local code = checked_reply.error.code
                evidence(db, attempt_id, "credential.refused", "projection " .. projection_id .. ": " .. code, {execution = "exited"})
                return refused("projection " .. projection_id .. ": " .. code)
            end
            local projection, projection_error = credential_protocol.checked_projection(checked_reply.value, projection_id)
            if not projection then
                evidence(db, attempt_id, "credential.refused", "projection " .. projection_id .. ": INVALID", {execution = "exited"})
                return refused("projection " .. projection_id .. ": " .. tostring(projection_error))
            end
            if projection.subject ~= request.owner_id or projection.audience ~= request.owner_id or projection.attempt_id ~= attempt_id
                or projection.profile_id ~= request.profile_id or projection.profile_digest ~= request.profile_digest
                or projection.binding_digest ~= request.binding_digest then
                evidence(db, attempt_id, "credential.refused", "projection " .. projection_id .. ": DENIED", {execution = "exited"})
                return refused("projection " .. projection_id .. ": DENIED")
            end
            checked_projection = projection
            if projection.projection_kind == "file" and projection.provider == provider_home.provider then
                local provider_files: {{source_path: string, path: string, optional: boolean}} = {}
                for _, file in ipairs(provider_home.files) do
                    if file.kind == "config" and file.source_path then
                        provider_files[#provider_files + 1] = {source_path = file.source_path, path = file.path, optional = file.optional}
                    end
                end
                if #provider_files > 0 then credential_request.provider_files = provider_files end
            end
        end
        local raw, call_error = funcs.call(resources.CREDENTIAL_MATERIALIZE, credential_request)
        -- Credential materialization reads an external source and can yield
        -- while the owner stops this attempt. Fence the reply before touching
        -- retained login state or recording materialization evidence.
        if not owns_attempt() then
            return refused("attempt no longer owns configuration materialization")
        end
        local reply: service_reply.Reply? = nil
        local reply_error: string? = nil
        if not call_error then reply, reply_error = service_reply.decode(raw) end
        if call_error or not reply then
            local code = "UNAVAILABLE"
            evidence(db, attempt_id, "credential.refused", "projection " .. projection_id .. ": " .. code, {execution = "exited"})
            return refused("projection " .. projection_id .. ": " .. code)
        end
        if reply.ok == false then
            local code = reply.error.code
            evidence(db, attempt_id, "credential.refused", "projection " .. projection_id .. ": " .. code, {execution = "exited"})
            return refused("projection " .. projection_id .. ": " .. code)
        end
        local expected: credential_protocol.Expected = {projection_id = projection_id, generation_key = generation_key}
        if checked_projection then
            expected.projection_kind = checked_projection.projection_kind
            expected.destination = checked_projection.destination
        end
        local projected, projection_error = credential_protocol.materialization(reply.value, expected)
        if not projected then
            evidence(db, attempt_id, "credential.refused", "projection " .. projection_id .. ": INVALID", {execution = "exited"})
            return refused("projection " .. projection_id .. ": " .. tostring(projection_error))
        end
        if projected.projection_kind == "file" then
            local provider_home = request.launch.provider_home
            if file_projection or (not retained_home and (not provider_home or not provider_home.private)) then
                evidence(db, attempt_id, "credential.refused", "invalid file login projection", {execution = "exited"})
                return refused("invalid file login projection")
            end
            local source = homes.decode_login_source({provider = projected.provider,
                definition_id = projected.definition_id, definition_revision = projected.definition_revision,
                optional = projected.optional, format = projected.format})
            local destination_name = source and source.path:match("[^/]+$") or nil
            if not source or not destination_name or projected.destination ~= destination_name then
                evidence(db, attempt_id, "credential.refused", "invalid file login projection", {execution = "exited"})
                return refused("invalid file login projection")
            end
            if provider_home and (provider_home.provider ~= source.source.provider
                or not provider_home_matches(provider_home, projected.source_path, projected.format, projected.write_back)) then
                evidence(db, attempt_id, "credential.refused", "provider login files do not match the driver declaration", {execution = "exited"})
                return refused("provider login files do not match the driver declaration")
            end
            local login_path = source.path
            if not login_path then return refused("file login path unavailable") end
            local protected: {string} = {login_path}
            local login_file = source.format.file
            if not login_file then return refused("file login format unavailable") end
            for _, item in ipairs(login_file.initialize) do
                protected[#protected + 1] = item.path
            end
            if configuration.overlaps(delivery.files, protected) then
                evidence(db, attempt_id, "configuration.refused", "configuration overlaps provider login state", {execution = "exited"})
                return refused("configuration overlaps provider login state")
            end
            local login_value = {provider = source.source.provider, definition_id = source.source.definition_id,
                definition_revision = source.source.definition_revision, optional = source.source.optional, format = source.format}
            local replayed = false
            if retained_home then
                local session_ref = request.session_ref
                if not session_ref then return refused("file login session unavailable") end
                local replay_value, replay_error = homes.login_replayed(selected_home_path, login_value)
                if replay_value == nil then
                    evidence(db, attempt_id, "credential.refused", "projection " .. projection_id .. ": file login refused", {execution = "exited"})
                    return refused(replay_error or "file login projection refused")
                end
                replayed = replay_value
                for _, item in ipairs(login_file.initialize) do
                    local expected: string? = nil
                    local binding_error: string? = nil
                    if replayed then
                        expected, binding_error = store.session_file_digest(db, request.owner_id, session_ref, item.path)
                        if not expected and not binding_error then binding_error = "retained configuration binding is missing" end
                    else
                        expected, binding_error = hash.sha256(item.content)
                        if expected then binding_error = store.bind_session_file(db, request.owner_id, session_ref, item.path, expected) end
                    end
                    if not expected or binding_error then
                        evidence(db, attempt_id, "configuration.refused", binding_error or "retained configuration binding", {execution = "exited"})
                        return refused(binding_error or "retained configuration binding")
                    end
                    composition_bases[item.path] = expected
                end
            local _, login_error, retained_replay = homes.retain_login(selected_home_path, login_value, projected.value, created_parents)
                if login_error or retained_replay ~= replayed then
                    evidence(db, attempt_id, "credential.refused", "projection " .. projection_id .. ": file login refused", {execution = "exited"})
                    return refused("file login projection refused")
                end
            else
                for _, item in ipairs(login_file.initialize) do
                    local expected, digest_error = hash.sha256(item.content)
                    if not expected or digest_error then return refused("provider setup digest failed") end
                    composition_bases[item.path] = expected
                end
                local _, login_error = homes.project_attempt_login(selected_home_path, login_value, projected.value, created_parents)
                if login_error then
                    evidence(db, attempt_id, "credential.refused", "projection " .. projection_id .. ": file login refused", {execution = "exited"})
                    return refused("file login projection refused")
                end
                if projected.present and provider_home then
                    local declared_generation = projected.generation
                    for _, item in ipairs(provider_home.files) do
                        if item.path == source.path and item.kind == "login" and item.write_back then
                            if not projected.write_back or declared_generation < 1 then
                                return refused("provider token write-back metadata is invalid")
                            end
                            writebacks[#writebacks + 1] = {projection_id = projection_id, generation = declared_generation,
                                source_digest = projected.source_digest, path = item.path}
                        end
                    end
                end
            end
            file_projection = true
            evidence(db, attempt_id, "credential.materialized", "projection " .. projection_id .. " file login " .. (replayed and "retained" or (projected.present and "seeded" or "unseeded")))
        else
            if not projected.present then
                evidence(db, attempt_id, "credential.materialized", "projection " .. projection_id .. " optional environment absent")
            else
                local secret = projected.value
                if #secret == 0 or secret:find("[%z\r\n]") then
                    evidence(db, attempt_id, "credential.refused", "invalid environment projection", {execution = "exited"})
                    return refused("invalid environment projection")
                end
                local gateway = request.gateway
                if environment[projected.destination] ~= nil or (gateway and (projected.destination == gateway.destination or projected.destination == gateway.hook_destination)) then
                    local conflict = "environment destination " .. projected.destination .. " is already assigned"
                    evidence(db, attempt_id, "credential.refused", "projection " .. projection_id .. ": " .. conflict, {execution = "exited"})
                    return refused(conflict)
                end
                environment[projected.destination] = secret
                evidence(db, attempt_id, "credential.materialized", "projection " .. projection_id .. " into " .. projected.destination)
            end
        end
    end
    local arguments: {string} = {}
    for _, argument in ipairs(delivery.arguments) do arguments[#arguments + 1] = argument end
    -- The gateway token is minted at delivery for the binding this attempt
    -- holds under the attached carrier epoch. Bytes fill only the admitted
    -- environment and declared private configuration fields. The stored template
    -- and evidence retain no bytes.
    if request.gateway then
        local gateway = request.gateway
        if generation < 1 then
            evidence(db, attempt_id, "gateway.refused", "the attempt is not attached to a carrier", {execution = "exited"})
            return refused("gateway binding: the attempt is not attached to a carrier")
        end
        local raw, call_error = funcs.call(resources.GATEWAY_MATERIALIZE, {attempt_id = attempt_id, carrier_epoch = generation, binding_id = expected_binding, materialization_key = materialization_key})
        local materialized: gateway_protocol.Materialization? = nil
        local materialization_error: string? = nil
        if call_error then
            materialization_error = tostring(call_error)
        else
            materialized, materialization_error = gateway_protocol.materialization_reply(raw,
                {attempt_id = attempt_id, carrier_epoch = generation, binding_id = expected_binding})
        end
        if not materialized then
            local code = materialization_error or "gateway returned no materialization"
            evidence(db, attempt_id, "gateway.refused", "materialize under carrier epoch " .. tostring(generation) .. ": " .. code, {execution = "exited"})
            return refused("gateway binding: " .. code)
        end
        environment[gateway.destination] = materialized.token
        if gateway.hook_destination and materialized.hook_token then environment[gateway.hook_destination] = materialized.hook_token end
        gateway_binding = materialized.binding.binding_id
        evidence(db, attempt_id, "gateway.materialized", "binding " .. materialized.binding.binding_id .. " credential generation " .. tostring(materialized.generation) .. " under carrier epoch " .. tostring(generation) .. " into " .. gateway.destination .. "; driver configuration frozen at admission")
    end
    for _, file in ipairs(delivery.files) do
        local base: string? = nil
        if file.composition then
            local provider_home = request.launch.provider_home
            if not retained_home and (not provider_home or not provider_home.private) then
                evidence(db, attempt_id, "configuration.refused", "configuration composition requires an admitted provider home", {execution = "exited"})
                return refused("configuration composition requires an admitted provider home")
            end
            local admitted_digest = composition_bases[file.composition.base_path]
            if not admitted_digest then
                evidence(db, attempt_id, "configuration.refused", "configuration base is not admitted by credential setup", {execution = "exited"})
                return refused("configuration base is not admitted by credential setup")
            end
            local base_error: string? = nil
            base, base_error = homes.read_configuration(selected_home_path, file.composition.base_path, admitted_digest)
            if base == nil then
                evidence(db, attempt_id, "configuration.refused", base_error or "configuration base", {execution = "exited"})
                return refused(base_error or "configuration base")
            end
        end
        local content, content_error = configuration.render(file, environment, request.gateway, base)
        if not content then
            evidence(db, attempt_id, "configuration.refused", content_error or "configuration", {execution = "exited"})
            return refused(content_error or "configuration")
        end
        if file.secret_fields then
            local privacy_error = homes.check_private_root()
            if privacy_error then return refused(privacy_error) end
        end
        -- A session intent excludes other attempts; the runner's starting claim
        -- excludes duplicate starts of this attempt. Recheck after asynchronous
        -- credential/gateway calls and before each publication.
        if not owns_attempt() then
            return refused("attempt no longer owns configuration materialization")
        end
        local written: string? = nil
        local write_error: string? = nil
        local published_uncertain: boolean? = nil
        if retained_home then
            written, write_error, published_uncertain = homes.publish_configuration(selected_home_path, file.path, content, created_parents)
        else
            written, write_error = homes.write_protected(selected_home_path, file.path, content, created_parents)
        end
        if not written then
            evidence(db, attempt_id, published_uncertain and "configuration.uncertain" or "configuration.refused", tostring(write_error),
                {execution = published_uncertain and "uncertain" or "exited"})
            return refused(write_error or "configuration")
        end
        evidence(db, attempt_id, "configuration.materialized", file.revision .. " " .. file.path .. " digest " .. file.digest .. (retained_home and " published" or " created"))
    end
    local initial_work_dir, initial_work_dir_error = resolve_work_dir(request, home_os)
    if not initial_work_dir then
        evidence(db, attempt_id, "workdir.failed", initial_work_dir_error or "working directory", {execution = "exited"})
        return refused(initial_work_dir_error or "working directory")
    end
    local work_dir, sandbox_arguments, prepare_error = prepare_workdir_and_arguments(db, request, attempt_id, initial_work_dir)
    if not work_dir or not sandbox_arguments then
        evidence(db, attempt_id, "workdir.failed", prepare_error or "workdir preparation failed", {execution = "exited"})
        return refused(prepare_error or "workdir preparation failed")
    end
    for _, argument in ipairs(sandbox_arguments) do arguments[#arguments + 1] = argument end
    for _, argument in ipairs(request.launch.argv) do arguments[#arguments + 1] = argument end
    return {environment = environment, working_directory = work_dir, arguments = arguments,
        home_path = selected_home_path, writebacks = writebacks}, nil, gateway_binding
end
return M
