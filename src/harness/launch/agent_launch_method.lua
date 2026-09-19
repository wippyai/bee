-- MIT. The thread_launch owner operation behind the gateway tool. It reads the
-- caller's authenticated gateway attribution, checks the caller's own launch
-- policy allow-list, resolves and fences the child's measured plan, and starts
-- it through the ordinary launch admission and carrier path. It mints no
-- grant, credential, trait or overlay authority of its own: every acquisition
-- underneath keys on the launching agent's own actor and workspace, and the
-- child receives exactly its own launch policy's gateway tools.
local ctx = require("ctx")
local funcs = require("funcs")
local bounds = require("bounds")
local agent_launch = require("agent_launch")
local policy = require("policy")
local definitions = require("definitions")
local BINDING_KEY = "bee.gateway.binding"
local START = "bee.harness.launch:start"
local RESOLVE = "bee.harness.launch:resolve"
local SETUP = "bee.harness.launch:setup"
type Reply = {ok: boolean, error: {code: string, message: string}?, value: unknown}
type Fault = {code: string, message: string}
local function fail(code: string, message: string): Reply
    return {ok = false, error = {code = code, message = message}, value = nil}
end
-- The endpoint supplies the authenticated attribution in the call context and
-- never in the arguments, so a caller cannot name its own action, thread,
-- launch policy or workspace.
local function attribution(): ({[string]: unknown}?, Fault?)
    local values, value_error = ctx.get(BINDING_KEY)
    if value_error then return nil, {code = "UNAUTHENTICATED", message = "the call context is unavailable"} end
    local object = bounds.object(values)
    if not object then return nil, {code = "UNAUTHENTICATED", message = "the call is not bound to a gateway attempt"} end
    return object, nil
end
local function reply_of(value: unknown): ({[string]: unknown}?, Fault?)
    local object = bounds.object(value)
    if not object then return nil, {code = "INTERNAL", message = "the launch did not answer"} end
    if object.ok ~= true then
        local fault = bounds.object(object.error)
        return nil, {code = tostring(fault and fault.code or "REFUSED"), message = tostring(fault and fault.message or "the launch was refused")}
    end
    local admitted = bounds.object(object.value)
    if not admitted then return nil, {code = "INTERNAL", message = "the launch admission returned no value"} end
    return admitted, nil
end
local function handle(raw: unknown): Reply
    local bound, binding_error = attribution()
    if not bound then return fail(binding_error.code, binding_error.message) end
    local action_id = bounds.id(bound.action_id)
    local thread_id = bounds.id(bound.thread_id)
    local policy_ref = bounds.id(bound.policy_ref)
    local workspace_id = bounds.id(bound.workspace_id)
    if not action_id or not thread_id or not policy_ref or not workspace_id then
        return fail("UNAUTHENTICATED", "the binding does not identify an agent launch context")
    end
    local request, invalid = agent_launch.decode_request(raw)
    if not request then return fail("INVALID", invalid or "invalid launch request") end
    -- The allow-list is the host-selected launch policy the caller's own
    -- attempt was admitted under. A definition it does not name is refused by
    -- a named code and no work is created.
    local caller_policy, policy_error = policy.load(policy_ref)
    if not caller_policy then return fail("UNAVAILABLE", policy_error or "the caller's launch policy is unavailable") end
    local permitted, permit_error = agent_launch.permitted(caller_policy, request.definition_ref)
    if permit_error then return fail("UNAVAILABLE", permit_error) end
    if not permitted then return fail("LAUNCH_NOT_PERMITTED", "this agent may not launch " .. request.definition_ref) end
    -- A definition decides on which thread its action runs. A caller-thread
    -- definition runs on the launching agent's own thread; a new-thread one
    -- gets a thread of its own, in which the launching agent is the owner.
    local definition, definition_error = definitions.load(request.definition_ref)
    if not definition then return fail("NOT_FOUND", definition_error or "the launch definition is unavailable") end
    if definition.default_mode == "window" then
        return fail("LAUNCH_MODE_UNSUPPORTED", "a window definition has no agent-launch carrier; launch a session or batch definition")
    end
    local on_caller_thread = definition.thread_policy.kind == "caller" and thread_id or nil
    -- Resolve and fence the measured plan once, so the child starts under the
    -- exact plan the allow-list admitted and not one that changed underneath.
    local resolved, resolve_error = funcs.call(RESOLVE, {definition_ref = request.definition_ref, mode = definition.default_mode, workspace_id = workspace_id})
    if resolve_error then return fail("UNAVAILABLE", tostring(resolve_error)) end
    local plan, resolve_fault = reply_of(resolved)
    if not plan then return fail(resolve_fault.code, resolve_fault.message) end
    local plan_digest = bounds.text(plan.plan_digest, 64)
    if not plan_digest or #plan_digest ~= 64 then return fail("INTERNAL", "the launch plan has no digest") end
    -- First-use setup associates the definition's resource roots in the
    -- caller's own workspace, exactly as a human launch does before admission;
    -- it foresees no wider workspace management and grants nothing by itself.
    local setup, setup_error = funcs.call(SETUP, {workspace_id = workspace_id, definition_ref = request.definition_ref, expected_plan_digest = plan_digest})
    if setup_error then return fail("UNAVAILABLE", tostring(setup_error)) end
    local prepared = bounds.object(setup)
    if not prepared or prepared.ok ~= true then
        return fail("UNAVAILABLE", tostring(prepared and prepared.error or "the launch resource setup failed"))
    end
    -- The child request identity is the caller's action plus the retry key:
    -- the same call replays one child action and attempt, and a changed brief
    -- under the same key conflicts instead of starting a second child.
    local request_id, identity_error = agent_launch.request_id(action_id, request.idempotency_key)
    if not request_id then return fail("INVALID", identity_error or "the request identity failed") end
    local started, start_error = funcs.call(START, {request_id = request_id, definition_ref = request.definition_ref, workspace_id = workspace_id,
        brief = request.brief, thread_id = on_caller_thread, parent_action_id = action_id, expected_plan_digest = plan_digest})
    if start_error then return fail("UNAVAILABLE", tostring(start_error)) end
    local admitted, start_fault = reply_of(started)
    if not admitted then return fail(start_fault.code, start_fault.message) end
    local child_thread, child_action, child_attempt = bounds.id(admitted.thread_id), bounds.id(admitted.action_id), bounds.id(admitted.attempt_id)
    if not child_thread or not child_action or not child_attempt then return fail("INTERNAL", "the launch admission is incomplete") end
    return {ok = true, error = nil, value = {thread_id = child_thread, action_id = child_action, attempt_id = child_attempt}}
end
return {handle = handle}
