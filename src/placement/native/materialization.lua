-- MIT. Native attempt materialization shared by execution transports.
-- Runs only inside the admitted placement owner after its starting transition.
-- Credential bytes remain in memory; the caller owns gateway retirement even
-- when materialization fails after minting the binding.
local env = require("env")
local funcs = require("funcs")
local sql = require("sql")
local store = require("store")
local resources = require("resources")
local homes = require("homes")
local types = require("types")
local M = {}
type Prepared = {environment: {[string]: string}, working_directory: string, arguments: {string}}
local function evidence(db, attempt_id: string, kind: string, detail: string, update: {[string]: unknown}?): (boolean, string?)
    local result = store.transition(db, attempt_id, {execution = update and update.execution :: types.ExecutionState? or nil,
        fields = update and update.fields :: {[string]: unknown}? or nil, evidence = {kind = kind, detail = detail}})
    if not result.ok then return false, result.message end
    return true, nil
end
-- Native placement owns HOME; an admitted gateway owns its token names.
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
        if request.environment[name] ~= nil or request.environment_refs[name] ~= nil then
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
    values.HOME = home
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
    local function refused(reason: string): (Prepared?, string?, string?)
        return nil, reason, gateway_binding
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
    -- cleanup. A retained file can only replay exact host-approved content.
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
    local delivery = request.delivery
    if not delivery then return refused("attempt has no owner-recorded configuration delivery") end
    for _, file in ipairs(delivery.files) do
        local written, write_error, replayed = homes.write_protected(selected_home_path, file.path, file.content, created_parents, retained_home)
        if not written then
            evidence(db, attempt_id, "configuration.refused", tostring(write_error), {execution = "exited"})
            return refused(write_error or "configuration")
        end
        evidence(db, attempt_id, "configuration.materialized", file.revision .. " " .. file.path .. " digest " .. file.digest .. (replayed and " replayed" or " created"))
    end
    local arguments: {string} = {}
    for _, argument in ipairs(delivery.arguments) do arguments[#arguments + 1] = argument end
    for _, argument in ipairs(request.launch.argv) do arguments[#arguments + 1] = argument end
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
    -- Credential projections arrive as bytes in a reply nothing persists;
    -- only the projection id and the outcome reach evidence.
    for index, projection_id in ipairs(request.projections) do
        local raw, call_error = funcs.call(resources.CREDENTIAL_MATERIALIZE, {projection_id = projection_id, subject = request.owner_id, audience = request.owner_id,
            attempt_id = attempt_id, generation_key = attempt_id .. ":" .. tostring(index)})
        local reply = type(raw) == "table" and raw :: {ok: boolean, error: {code: string}?, value: {destination: string, value: string}?} or nil
        if call_error or not reply or not reply.ok or not reply.value then
            local code = reply and reply.error and reply.error.code or "UNAVAILABLE"
            evidence(db, attempt_id, "credential.refused", "projection " .. projection_id .. ": " .. code, {execution = "exited"})
            return refused("projection " .. projection_id .. ": " .. code)
        end
        local projected = reply.value :: {destination: string, value: string}
        local gateway = request.gateway
        if environment[projected.destination] ~= nil or (gateway and (projected.destination == gateway.destination or projected.destination == gateway.hook_destination)) then
            local conflict = "environment destination " .. projected.destination .. " is already assigned"
            evidence(db, attempt_id, "credential.refused", "projection " .. projection_id .. ": " .. conflict, {execution = "exited"})
            return refused(conflict)
        end
        environment[projected.destination] = projected.value
        evidence(db, attempt_id, "credential.materialized", "projection " .. projection_id .. " into " .. projected.destination)
    end
    -- The gateway token is minted at delivery for the binding this attempt
    -- holds under the attached carrier epoch, written nowhere: the
    -- driver configuration already names the selected environment
    -- destination the bytes fill. Evidence carries the generation, never the bytes.
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
    local work_dir, work_dir_error = resolve_work_dir(request, home_os)
    if not work_dir then
        evidence(db, attempt_id, "workdir.failed", work_dir_error or "working directory", {execution = "exited"})
        return refused(work_dir_error or "working directory")
    end
    return {environment = environment, working_directory = work_dir, arguments = arguments}, nil, gateway_binding
end
return M
