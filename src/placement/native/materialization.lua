-- MIT. Native attempt materialization shared by execution transports.
-- Runs only inside the admitted placement owner after its starting transition.
-- File credentials go only to the selected private home; receipts retain no
-- credential bytes. The caller owns gateway retirement even
-- when materialization fails after minting the binding.
local env = require("env")
local funcs = require("funcs")
local sql = require("sql")
local process = require("process")
local hash = require("hash")
local store = require("store")
local resources = require("resources")
local homes = require("homes")
local types = require("types")
local configuration = require("configuration")
local M = {}
type Prepared = {environment: {[string]: string}, working_directory: string, arguments: {string}}
local function evidence(db, attempt_id: string, kind: string, detail: string, update: {[string]: unknown}?): (boolean, string?)
    local result = store.transition(db, attempt_id, {execution = update and update.execution :: types.ExecutionState? or nil,
        fields = update and update.fields :: {[string]: unknown}? or nil, evidence = {kind = kind, detail = detail}})
    if not result.ok then return false, result.message end
    return true, nil
end
-- Native placement selects either its private home or the host's user home.
-- Arbitrary HOME values remain refused; an admitted gateway owns its tokens.
-- Check before intent and again when materializing a retained request.
function M.environment_conflict(request: types.LaunchRequest): string?
    local owners: {[string]: string} = {HOME = "native placement"}
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
            and request.environment_refs[name] == "bee:machine_home"
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
    if request.environment_refs.HOME == "bee:machine_home" then
        local selected = values.HOME
        if not selected or selected:sub(1, 1) ~= "/" or selected:find("[%z\r\n]") then
            return nil, "host user home is unavailable"
        end
    else
        values.HOME = home
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
function M.prepare(db: sql.DB, request: types.LaunchRequest, attempt_id: string, generation: integer, expected_binding: string?, materialization_key: string?): (Prepared?, string?, string?)
    local gateway_binding: string? = nil
    local function finish_stopped_without_child(): boolean
        local current = store.row(db, attempt_id)
        if not current or current.execution_state ~= "stopping" or current.runner_pid ~= process.pid() then return false end
        local finished = store.transition(db, attempt_id, {expected_execution = "stopping", execution = "exited",
            fields = {runner_pid = "", exit_source = "runner"},
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
    if request.session_ref then
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
        local raw, call_error = funcs.call(resources.CREDENTIAL_MATERIALIZE, {projection_id = projection_id, subject = request.owner_id, audience = request.owner_id,
            attempt_id = attempt_id, generation_key = attempt_id .. ":" .. tostring(index)})
        local reply = type(raw) == "table" and raw :: {ok: boolean, error: {code: string}?, value: {destination: string, value: string?, projection_kind: string}?} or nil
        -- Credential materialization reads an external source and can yield
        -- while the owner stops this attempt. Fence the reply before touching
        -- retained login state or recording materialization evidence.
        if not owns_attempt() then
            return refused("attempt no longer owns configuration materialization")
        end
        if call_error or not reply or not reply.ok or not reply.value then
            local code = reply and reply.error and reply.error.code or "UNAVAILABLE"
            evidence(db, attempt_id, "credential.refused", "projection " .. projection_id .. ": " .. code, {execution = "exited"})
            return refused("projection " .. projection_id .. ": " .. code)
        end
        local projected = reply.value :: {destination: string, value: string?, projection_kind: string}
        if projected.projection_kind == "file" then
            if not retained_home or file_projection then
                evidence(db, attempt_id, "credential.refused", "invalid file login projection", {execution = "exited"})
                return refused("invalid file login projection")
            end
            local login = reply.value :: {destination: string, value: string?, projection_kind: string,
                provider: unknown, definition_id: unknown, definition_revision: unknown, optional: unknown, present: unknown, format: unknown}
            local source = homes.decode_login_source({provider = login.provider,
                definition_id = login.definition_id, definition_revision = login.definition_revision, optional = login.optional, format = login.format})
            if not source or projected.destination ~= (source.path:match("[^/]+$") :: string)
                or type(login.optional) ~= "boolean" or type(login.present) ~= "boolean"
                or (login.present == true and type(projected.value) ~= "string")
                or (login.present == false and (login.optional ~= true or projected.value ~= nil)) then
                evidence(db, attempt_id, "credential.refused", "invalid file login projection", {execution = "exited"})
                return refused("invalid file login projection")
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
            local session_ref = request.session_ref
            if not session_ref then return refused("file login session unavailable") end
            local login_value = {provider = source.source.provider, definition_id = source.source.definition_id,
                definition_revision = source.source.definition_revision, optional = source.source.optional, format = source.format}
            local replayed, replay_error = homes.login_replayed(selected_home_path, login_value)
            if replayed == nil then
                evidence(db, attempt_id, "credential.refused", "projection " .. projection_id .. ": file login refused", {execution = "exited"})
                return refused(replay_error or "file login projection refused")
            end
            -- Bind every admitted setup file before retain_login can publish
            -- the ready marker. A crash after the marker must never leave a
            -- reusable session whose immutable composition base has no digest.
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
            file_projection = true
            evidence(db, attempt_id, "credential.materialized", "projection " .. projection_id .. " file login " .. (replayed and "retained" or (login.present == true and "seeded" or "unseeded")))
        else
            local environment_projection = reply.value :: {destination: string, value: string?, projection_kind: string, encoding: unknown, optional: unknown, present: unknown}
            local secret = projected.value
            if projected.projection_kind ~= "environment" or type(projected.destination) ~= "string"
            or #projected.destination > 128 or not projected.destination:match("^[A-Z_][A-Z0-9_]*$")
            or environment_projection.encoding ~= "utf-8" or type(environment_projection.optional) ~= "boolean"
            or type(environment_projection.present) ~= "boolean" then
                evidence(db, attempt_id, "credential.refused", "invalid environment projection", {execution = "exited"})
                return refused("invalid environment projection")
            end
            local absent = secret == nil and environment_projection.optional == true and environment_projection.present == false
            if absent then
                evidence(db, attempt_id, "credential.materialized", "projection " .. projection_id .. " optional environment absent")
            else
                if environment_projection.present ~= true or type(secret) ~= "string" or #secret == 0 or #secret > 8192
                or secret:find("[%z\r\n]") then
                    evidence(db, attempt_id, "credential.refused", "invalid environment projection", {execution = "exited"})
                    return refused("invalid environment projection")
                end
                local gateway = request.gateway
                if environment[projected.destination] ~= nil or (gateway and (projected.destination == gateway.destination or projected.destination == gateway.hook_destination)) then
                    local conflict = "environment destination " .. projected.destination .. " is already assigned"
                    evidence(db, attempt_id, "credential.refused", "projection " .. projection_id .. ": " .. conflict, {execution = "exited"})
                    return refused(conflict)
                end
                environment[projected.destination] = secret :: string
                evidence(db, attempt_id, "credential.materialized", "projection " .. projection_id .. " into " .. projected.destination)
            end
        end
    end
    local arguments: {string} = {}
    for _, argument in ipairs(delivery.arguments) do arguments[#arguments + 1] = argument end
    for _, argument in ipairs(request.launch.argv) do arguments[#arguments + 1] = argument end
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
        local reply = type(raw) == "table" and raw :: {ok: boolean, error: {code: string, message: string}?, value: {token: string, hook_token: string?, generation: number, binding: {binding_id: string}}?} or nil
        if call_error or not reply or not reply.ok or not reply.value then
            local code = reply and reply.error and (reply.error.code .. ": " .. reply.error.message) or tostring(call_error or "UNAVAILABLE")
            evidence(db, attempt_id, "gateway.refused", "materialize under carrier epoch " .. tostring(generation) .. ": " .. code, {execution = "exited"})
            return refused("gateway binding: " .. code)
        end
        local materialized = reply.value :: {token: string, hook_token: string?, generation: number, binding: {binding_id: string}}
        environment[gateway.destination] = materialized.token
        if gateway.hook_destination and materialized.hook_token then environment[gateway.hook_destination] = materialized.hook_token end
        gateway_binding = materialized.binding.binding_id
        evidence(db, attempt_id, "gateway.materialized", "binding " .. materialized.binding.binding_id .. " credential generation " .. tostring(materialized.generation) .. " under carrier epoch " .. tostring(generation) .. " into " .. gateway.destination .. "; driver configuration frozen at admission")
    end
    for _, file in ipairs(delivery.files) do
        local base: string? = nil
        if file.composition then
            if not retained_home then
                evidence(db, attempt_id, "configuration.refused", "configuration composition requires a retained home", {execution = "exited"})
                return refused("configuration composition requires a retained home")
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
    local work_dir, work_dir_error = resolve_work_dir(request, home_os)
    if not work_dir then
        evidence(db, attempt_id, "workdir.failed", work_dir_error or "working directory", {execution = "exited"})
        return refused(work_dir_error or "working directory")
    end
    return {environment = environment, working_directory = work_dir, arguments = arguments}, nil, gateway_binding
end
return M
