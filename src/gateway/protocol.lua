-- MIT. Gateway binding values carried between module owners.
local bounds = require("bounds")
local service_reply = require("service_reply")
local M = {}

type OriginView = {view_id: string, instance_id: string}
type Binding = {
    binding_id: string,
    subject: string,
    action_id: string,
    attempt_id: string,
    thread_id: string,
    owner_incarnation: integer,
    carrier_epoch: integer,
    tools: {string},
    hooks: {string},
    epoch: integer,
    credential_generation: integer,
    expires_at: string,
    revoked: boolean,
    sealed: boolean,
    policy_ref: string?,
    workspace_id: string?,
    workspace_name: string,
    origin_view: OriginView?,
}
type Expected = {attempt_id: string, carrier_epoch: integer, binding_id: string?}
type Materialization = {binding: Binding, token: string, hook_token: string?, generation: integer}
type Generation = {epoch: integer, restarts: integer}
type CheckedBinding = {binding: Binding, valid: boolean, reason: string?, generation: Generation,
    presented_count: integer, last_presented_at: string?}
type Readiness = {generation: Generation, address: string, listening: boolean, binding_valid: boolean?, binding_reason: string?}
type HookClaim = {binding_id: string, carrier_epoch: integer, hooks: {unknown}}

local BASE_FIELDS = {"binding_id", "subject", "action_id", "attempt_id", "thread_id", "owner_incarnation", "carrier_epoch",
    "tools", "hooks", "epoch", "credential_generation", "expires_at", "revoked", "sealed", "policy_ref", "workspace_id",
    "workspace_name", "origin_view"}

local function positive_count(value: unknown): integer?
    local count = bounds.count(value)
    if count == nil or count < 1 then return nil end
    return count
end

local function decode_generation(value: unknown): (Generation?, string?)
    local object = bounds.object(value)
    if not object then return nil, "generation must be an object" end
    local unknown_field = bounds.fields(object, {"epoch", "restarts"})
    if unknown_field then return nil, "generation: " .. unknown_field end
    local epoch, restarts = bounds.count(object.epoch), bounds.count(object.restarts)
    if epoch == nil or restarts == nil then return nil, "generation fields are malformed" end
    return {epoch = epoch, restarts = restarts}, nil
end

local function decode_binding(value: unknown, checked: boolean): (Binding?, string?)
    local object = bounds.object(value)
    if not object then return nil, "binding must be an object" end
    local allowed = BASE_FIELDS
    if checked then
        allowed = {"binding_id", "subject", "action_id", "attempt_id", "thread_id", "owner_incarnation", "carrier_epoch",
            "tools", "hooks", "epoch", "credential_generation", "expires_at", "revoked", "sealed", "policy_ref", "workspace_id",
            "workspace_name", "origin_view", "valid", "reason", "generation", "presented_count", "last_presented_at"}
    end
    local unknown_field = bounds.fields(object, allowed)
    if unknown_field then return nil, "binding: " .. unknown_field end
    local binding_id, subject, action_id = bounds.id(object.binding_id), bounds.id(object.subject), bounds.id(object.action_id)
    local attempt_id, thread_id = bounds.id(object.attempt_id), bounds.id(object.thread_id)
    local owner_incarnation, carrier_epoch = positive_count(object.owner_incarnation), positive_count(object.carrier_epoch)
    local epoch, credential_generation = bounds.count(object.epoch), bounds.count(object.credential_generation)
    local tools, tools_error = bounds.ids(object.tools, true)
    local hooks, hooks_error = bounds.ids(object.hooks, true)
    local expires_at = bounds.timestamp(object.expires_at)
    local workspace_name = bounds.line(object.workspace_name, 80)
    if binding_id == nil then return nil, "binding_id is malformed" end
    if subject == nil then return nil, "binding subject is malformed" end
    if action_id == nil then return nil, "binding action_id is malformed" end
    if attempt_id == nil then return nil, "binding attempt_id is malformed" end
    if thread_id == nil then return nil, "binding thread_id is malformed" end
    if owner_incarnation == nil then return nil, "binding owner incarnation must be positive" end
    if carrier_epoch == nil then return nil, "binding carrier epoch must be positive" end
    if epoch == nil then return nil, "binding epoch is malformed" end
    if credential_generation == nil then return nil, "binding credential generation is malformed" end
    if tools == nil then return nil, "binding tools are malformed" end
    if hooks == nil then return nil, "binding hooks are malformed" end
    if expires_at == nil then return nil, "binding expiry is malformed" end
    if workspace_name == nil or workspace_name:match("^%s*$") then return nil, "binding workspace name is malformed" end
    local revoked, sealed = object.revoked, object.sealed
    if type(revoked) ~= "boolean" or type(sealed) ~= "boolean" then return nil, "binding flags are malformed" end
    local policy_ref, policy_valid = bounds.optional_id(object, "policy_ref")
    local workspace_id, workspace_valid = bounds.optional_id(object, "workspace_id")
    if not policy_valid or not workspace_valid then return nil, "binding references are malformed" end
    local origin_view: OriginView? = nil
    if object.origin_view ~= nil then
        local origin = bounds.object(object.origin_view)
        if not origin then return nil, "binding origin_view must be an object" end
        local origin_field = bounds.fields(origin, {"view_id", "instance_id"})
        local view_id, instance_id = bounds.id(origin.view_id), bounds.id(origin.instance_id)
        if origin_field or view_id == nil or instance_id == nil then return nil, "binding origin_view is malformed" end
        origin_view = {view_id = view_id, instance_id = instance_id}
    end
    local binding: Binding = {binding_id = binding_id, subject = subject, action_id = action_id, attempt_id = attempt_id, thread_id = thread_id,
        owner_incarnation = owner_incarnation, carrier_epoch = carrier_epoch, tools = tools, hooks = hooks, epoch = epoch,
        credential_generation = credential_generation, expires_at = expires_at, revoked = revoked, sealed = sealed,
        policy_ref = policy_ref, workspace_id = workspace_id, workspace_name = workspace_name, origin_view = origin_view}
    return binding, nil
end

function M.materialization_reply(value: unknown, expected: Expected): (Materialization?, string?)
    local reply, reply_error = service_reply.decode(value)
    if not reply then return nil, reply_error end
    if reply.ok == false then return nil, "gateway refused materialization: " .. reply.error.code .. ": " .. reply.error.message end
    local result = bounds.object(reply.value)
    if not result then return nil, "materialization value must be an object" end
    local unknown_field = bounds.fields(result, {"binding", "token", "hook_token", "generation"})
    if unknown_field then return nil, "materialization: " .. unknown_field end
    local binding, binding_error = decode_binding(result.binding, false)
    if not binding then return nil, "materialization binding: " .. tostring(binding_error) end
    local token = bounds.text(result.token, 128)
    local generation = bounds.count(result.generation)
    local hook_token: string? = nil
    if result.hook_token ~= nil then hook_token = bounds.text(result.hook_token, 128) end
    if token == nil or token == "" or generation == nil or generation < 1
        or (result.hook_token ~= nil and (hook_token == nil or hook_token == "")) then
        return nil, "materialization credentials or generation are malformed"
    end
    if binding.attempt_id ~= expected.attempt_id or binding.carrier_epoch ~= expected.carrier_epoch
        or binding.credential_generation ~= generation or (expected.binding_id ~= nil and binding.binding_id ~= expected.binding_id) then
        return nil, "materialization binding does not match the requested attempt, epoch or generation"
    end
    if #binding.hooks == 0 and hook_token ~= nil then return nil, "materialization returned a hook token for a binding with no hooks" end
    if #binding.hooks > 0 and hook_token == nil then return nil, "materialization omitted the admitted hook token" end
    return {binding = binding, token = token, hook_token = hook_token, generation = generation}, nil
end

function M.checked_binding(value: unknown): (CheckedBinding?, string?)
    local binding, binding_error = decode_binding(value, true)
    if not binding then return nil, binding_error end
    local object = bounds.object(value)
    if not object then return nil, "binding must be an object" end
    local valid = object.valid
    local reason: string? = nil
    if object.reason ~= nil then reason = bounds.text(object.reason, 4096) end
    local generation, generation_error = decode_generation(object.generation)
    local presented_count = bounds.count(object.presented_count)
    local last_presented_at: string? = nil
    if object.last_presented_at ~= nil then last_presented_at = bounds.timestamp(object.last_presented_at) end
    if generation == nil then
        return nil, "checked binding fields are malformed: " .. tostring(generation_error)
    end
    if type(valid) ~= "boolean" or (object.reason ~= nil and reason == nil)
        or presented_count == nil or (object.last_presented_at ~= nil and last_presented_at == nil)
        or (presented_count == 0 and last_presented_at ~= nil) or (presented_count > 0 and last_presented_at == nil) then
        return nil, "checked binding fields are malformed"
    end
    return {binding = binding, valid = valid, reason = reason, generation = generation,
        presented_count = presented_count, last_presented_at = last_presented_at}, nil
end

function M.admitted_binding(value: unknown): (Binding?, string?)
    local result = bounds.object(value)
    if not result then return nil, "admission value must be an object" end
    local unknown_field = bounds.fields(result, {"binding", "replayed"})
    if unknown_field then return nil, "admission: " .. unknown_field end
    if result.replayed ~= nil and type(result.replayed) ~= "boolean" then return nil, "admission replayed flag is malformed" end
    return decode_binding(result.binding, false)
end

function M.readiness(value: unknown, expected_binding: string): (Readiness?, string?)
    local result = bounds.object(value)
    if not result then return nil, "readiness value must be an object" end
    local unknown_field = bounds.fields(result, {"generation", "address", "listening", "binding", "binding_valid", "binding_reason"})
    if unknown_field then return nil, "readiness: " .. unknown_field end
    local generation, generation_error = decode_generation(result.generation)
    if not generation then return nil, "readiness " .. tostring(generation_error) end
    local address = bounds.line(result.address, 120)
    if address == nil or type(result.listening) ~= "boolean" then return nil, "readiness fields are malformed" end
    local binding_valid: boolean? = nil
    local binding_reason: string? = nil
    if type(result.binding_valid) ~= "boolean" then return nil, "readiness binding status is malformed" end
    binding_valid = result.binding_valid
    if result.binding_reason ~= nil then
        binding_reason = bounds.text(result.binding_reason, 4096)
        if binding_reason == nil then return nil, "readiness binding reason is malformed" end
    end
    local binding, binding_error = decode_binding(result.binding, false)
    if not binding then return nil, "readiness binding: " .. tostring(binding_error) end
    if binding.binding_id ~= expected_binding then return nil, "readiness names another binding" end
    if binding_valid and result.binding_reason ~= nil then return nil, "valid readiness carries a binding refusal" end
    if not binding_valid and binding_reason == nil then return nil, "invalid readiness has no refusal reason" end
    return {generation = generation, address = address, listening = result.listening, binding_valid = binding_valid, binding_reason = binding_reason}, nil
end

function M.hook_claim(value: unknown, expected_binding: string, expected_epoch: integer): (HookClaim?, string?)
    local result = bounds.object(value)
    if not result then return nil, "hook claim must be an object" end
    local unknown_field = bounds.fields(result, {"binding_id", "carrier_epoch", "hooks"})
    if unknown_field then return nil, "hook claim: " .. unknown_field end
    local binding_id = bounds.id(result.binding_id)
    if not binding_id then return nil, "hook claim binding_id is malformed" end
    local carrier_epoch = positive_count(result.carrier_epoch)
    if not carrier_epoch then return nil, "hook claim carrier_epoch must be positive" end
    if binding_id ~= expected_binding then return nil, "hook claim names another binding" end
    if carrier_epoch ~= expected_epoch then return nil, "hook claim names another carrier epoch" end
    local hooks, hooks_error = bounds.array(result.hooks, 16)
    if not hooks then return nil, "hook claim: " .. tostring(hooks_error) end
    return {binding_id = binding_id, carrier_epoch = carrier_epoch, hooks = hooks}, nil
end

-- The trait a person approves before an agent may use application tools.
M.APPLICATION_TOOLS_TRAIT_ID = "bee.app:tools"
M.HUB_LIBRARY_TRAIT_ID = "bee.hub:library"
-- The trait a person approves before an agent may share an installed
-- application with the hive.
M.APPLICATION_SHARE_TRAIT_ID = "bee.app:share"
-- Tools a launch offers only with the person's consent, by the trait the
-- person approves as requestable access.
M.CONSENT_TOOLS = {app_tools = M.APPLICATION_TOOLS_TRAIT_ID, publish = M.APPLICATION_SHARE_TRAIT_ID,
    components = M.HUB_LIBRARY_TRAIT_ID, install_request = M.HUB_LIBRARY_TRAIT_ID,
    uninstall_request = M.HUB_LIBRARY_TRAIT_ID, install_status = M.HUB_LIBRARY_TRAIT_ID}
-- access_traits names the traits a launch policy's data offers as requestable
-- access: its own gateway_access, or the access of the surface it declares.
function M.access_traits(policy_data: unknown): {string}
    local data = bounds.object(policy_data)
    local declared_surface = data and bounds.object(data.gateway_surface) or nil
    local access = data and bounds.object(data.gateway_access) or nil
    if not access and declared_surface then access = bounds.object(declared_surface.access) end
    return access and bounds.ids(access.traits, true) or {}
end
-- offered_tools is the gateway tool list a launch hands its child. With the
-- person's profile selection it is every declared tool, which the gateway
-- narrows per call; without one it leaves out each consent tool whose trait
-- the launch policy does not offer as requestable access. The planner and
-- placement both derive the list here, so their configuration digests agree.
function M.offered_tools(declared: {string}, policy_data: unknown, selected: boolean): {string}
    if selected then return declared end
    local requestable: {[string]: boolean} = {}
    local traits = M.access_traits(policy_data)
    for _, id in ipairs(traits) do requestable[id] = true end
    local offered: {string} = {}
    for _, name in ipairs(declared) do
        local trait = M.CONSENT_TOOLS[name]
        if not trait or requestable[trait] then offered[#offered + 1] = name end
    end
    return offered
end
return M
