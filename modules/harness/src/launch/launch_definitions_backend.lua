-- MIT. Read-only launch discovery behind the gateway tool. It reads the
-- caller's authenticated gateway attribution, loads the host-selected launch
-- policy the caller's own attempt was admitted under, and returns exactly the
-- definitions that policy's agent_launch allow-list names, with the placements
-- each launch accepts, the overrides each definition admits and the saved
-- profile IDs and revisions held for those definitions in the workspace.
-- Nothing is started, granted or published here.
local ctx = require("ctx")
local funcs = require("funcs")
local bounds = require("bounds")
local policy = require("policy")
local definitions = require("definitions")
local admission = require("admission")
local readiness_client = require("readiness")
local PROFILES = "bee.harness.profiles:call"
local BINDING_KEY = "bee.gateway.binding"
type Reply = {ok: boolean, error: {code: string, message: string}?, value: unknown}
type Fault = {code: string, message: string}
local function fail(code: string, message: string): Reply
    return {ok = false, error = {code = code, message = message}, value = nil}
end
local function attribution(): ({[string]: unknown}?, Fault?)
    local values, value_error = ctx.get(BINDING_KEY)
    if value_error then return nil, {code = "UNAUTHENTICATED", message = "the call context is unavailable"} end
    local object = bounds.object(values)
    if not object then return nil, {code = "UNAUTHENTICATED", message = "the call is not bound to a gateway attempt"} end
    return object, nil
end
local function readiness(refused: unknown): (string, string)
    local result = bounds.object(refused)
    local fault = result and bounds.object(result.error) or nil
    local code = fault and bounds.id(fault.code) or nil
    local message = fault and bounds.text(fault.message, 512) or nil
    local status = "unknown"
    if code == "UNAVAILABLE" then status = "unconfigured"
    elseif code == "UNSUPPORTED_CAPABILITY" or code == "INVALID" then status = "incompatible" end
    return status, message or "Launch readiness is unknown"
end
local function definition_summary(ref: string, show_unavailable: boolean, cache: readiness_client.Cache): ({[string]: unknown}?, string?, string?)
    local definition, definition_error = definitions.load(ref)
    if not definition then return nil, "unknown", definition_error or ("launch definition " .. ref .. " is unavailable") end
    local plan, refused = admission.resolve(definition.ref, definition.default_mode)
    local status, reason = "ready", nil
    if not plan then status, reason = readiness(refused) end
    local probe = readiness_client.probe(definition.binding_ref, definition.profile_id, cache)
    if probe.error then
        if plan then status, reason = "unknown", probe.error end
    elseif probe.located and probe.result then
        local located = probe.result
        if located.status ~= "ready" and (located.status ~= "unknown" or plan ~= nil) then
            status, reason = located.status, located.reason or "Driver readiness is unknown"
        end
    end
    if not plan and not show_unavailable then return nil, status, reason end
    local placements: {string} = {}
    if plan then placements[1] = plan.placement_kind end
    local summary: {[string]: unknown} = {definition_ref = definition.ref, title = definition.title, digest = definition.digest,
        default_mode = definition.default_mode, profile_id = definition.profile_id,
        policy_ref = definition.policy_ref, allowed_overrides = definition.allowed_overrides,
        workdir_policy = definition.workdir_policy, thread_policy = definition.thread_policy,
        unconfined = definition.unconfined, placements = placements, status = status}
    if reason then summary.unavailable = reason end
    return summary, status, reason
end
local function saved_profiles(workspace_id: string, admitted: {[string]: string}, show_unavailable: boolean): ({unknown}?, string?)
    local result, call_error = funcs.call(PROFILES, {operation = "list", workspace_id = workspace_id, limit = 16})
    if call_error then return nil, tostring(call_error) end
    local reply = bounds.object(result)
    if not reply or reply.ok ~= true then
        local fault = reply and bounds.object(reply.error) or nil
        return nil, fault and tostring(fault.message) or "saved profiles are unavailable"
    end
    local value = bounds.object(reply.value)
    local items = value and value.items
    if type(items) ~= "table" then return nil, "saved profile list is malformed" end
    local profiles: {unknown} = {}
    for _, raw in ipairs(items :: {unknown}) do
        local item = bounds.object(raw)
        local profile = item and bounds.object(item.profile)
        local profile_id = item and bounds.id(item.profile_id)
        local revision = item and bounds.integer(item.revision)
        local definition_ref = profile and bounds.id(profile.definition_ref)
        local status = definition_ref and admitted[definition_ref] or nil
        if item and item.tombstone ~= true and profile_id and revision and definition_ref and status
            and (status == "ready" or show_unavailable) then
            profiles[#profiles + 1] = {profile_id = profile_id, revision = revision,
                title = tostring(profile.title), definition_ref = definition_ref, status = status}
        end
    end
    return profiles, nil
end
local function handle(raw: unknown): Reply
    local bound, binding_error = attribution()
    if not bound then return fail(binding_error.code, binding_error.message) end
    local policy_ref = bounds.id(bound.policy_ref)
    local object = bounds.object(raw or {})
    local show_unavailable = object and object.show_unavailable == true or false
    local workspace_id = (object and bounds.id(object.workspace_id)) or bounds.id(bound.workspace_id)
    if not policy_ref or not workspace_id then
        return fail("UNAUTHENTICATED", "the binding does not identify an agent launch context")
    end
    local caller_policy, policy_error = policy.load(policy_ref)
    if not caller_policy then return fail("UNAVAILABLE", policy_error or "the caller's launch policy is unavailable") end
    local admitted: {[string]: string} = {}
    local found: {unknown} = {}
    local unavailable_count = 0
    local probe_cache = readiness_client.new_cache()
    for _, ref in ipairs(caller_policy.agent_launch) do
        if admitted[ref] == nil then
            local summary, status = definition_summary(ref, show_unavailable, probe_cache)
            if status ~= "ready" then unavailable_count = unavailable_count + 1 end
            if summary then
                admitted[ref] = status or "unknown"
                found[#found + 1] = summary
            else
                admitted[ref] = status or "unknown"
            end
        end
    end
    local profiles, profiles_error = saved_profiles(workspace_id, admitted, show_unavailable)
    if not profiles then
        return {ok = true, value = {workspace_id = workspace_id, policy_ref = policy_ref,
            definitions = found, saved_profiles = {}, profiles_complete = false,
            unavailable_count = unavailable_count,
            profiles_unavailable = profiles_error or "saved profiles are unavailable"}, error = nil}
    end
    return {ok = true, value = {workspace_id = workspace_id, policy_ref = policy_ref,
        definitions = found, saved_profiles = profiles, profiles_complete = true, unavailable_count = unavailable_count}, error = nil}
end
return {handle = handle}
