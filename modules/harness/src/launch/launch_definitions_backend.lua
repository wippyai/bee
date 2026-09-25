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
local function definition_summary(ref: string): ({[string]: unknown}?, string?)
    local definition, definition_error = definitions.load(ref)
    if not definition then return nil, definition_error or ("launch definition " .. ref .. " is unavailable") end
    return {definition_ref = definition.ref, title = definition.title, digest = definition.digest,
        default_mode = definition.default_mode, profile_id = definition.profile_id,
        policy_ref = definition.policy_ref, allowed_overrides = definition.allowed_overrides,
        workdir_policy = definition.workdir_policy, thread_policy = definition.thread_policy,
        placements = {"native", "docker"}}, nil
end
local function saved_profiles(workspace_id: string, admitted: {[string]: boolean}): ({unknown}?, string?)
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
        if item and item.tombstone ~= true and profile_id and revision and definition_ref and admitted[definition_ref] then
            profiles[#profiles + 1] = {profile_id = profile_id, revision = revision,
                title = tostring(profile.title), definition_ref = definition_ref}
        end
    end
    return profiles, nil
end
local function handle(raw: unknown): Reply
    local bound, binding_error = attribution()
    if not bound then return fail(binding_error.code, binding_error.message) end
    local policy_ref = bounds.id(bound.policy_ref)
    local object = bounds.object(raw or {})
    local workspace_id = (object and bounds.id(object.workspace_id)) or bounds.id(bound.workspace_id)
    if not policy_ref or not workspace_id then
        return fail("UNAUTHENTICATED", "the binding does not identify an agent launch context")
    end
    local caller_policy, policy_error = policy.load(policy_ref)
    if not caller_policy then return fail("UNAVAILABLE", policy_error or "the caller's launch policy is unavailable") end
    local admitted: {[string]: boolean} = {}
    local found: {unknown} = {}
    for _, ref in ipairs(caller_policy.agent_launch) do
        if not admitted[ref] then
            admitted[ref] = true
            local summary, summary_error = definition_summary(ref)
            if not summary then return fail("UNAVAILABLE", summary_error or ("launch definition " .. ref .. " is unavailable")) end
            found[#found + 1] = summary
        end
    end
    local profiles, profiles_error = saved_profiles(workspace_id, admitted)
    if not profiles then
        return {ok = true, value = {workspace_id = workspace_id, policy_ref = policy_ref,
            definitions = found, saved_profiles = {}, profiles_complete = false,
            profiles_unavailable = profiles_error or "saved profiles are unavailable"}, error = nil}
    end
    return {ok = true, value = {workspace_id = workspace_id, policy_ref = policy_ref,
        definitions = found, saved_profiles = profiles, profiles_complete = true}, error = nil}
end
return {handle = handle}
