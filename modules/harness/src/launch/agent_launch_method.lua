-- MIT. The thread_launch owner operation behind the gateway tool. It reads the
-- caller's authenticated gateway attribution, checks the caller's own launch
-- policy allow-list, resolves and fences the child's measured plan, and starts
-- it through the ordinary launch admission and carrier path. It mints no
-- grant, credential, trait or overlay authority of its own: every acquisition
-- underneath keys on the launching agent's own actor and workspace, and the
-- child receives exactly its own launch policy's gateway tools.
local ctx = require("ctx")
local bounds = require("bounds")
local agent_launch = require("agent_launch")
local agent_protocol = require("agent_protocol")
local policy = require("policy")
local definitions = require("definitions")
local caller_launch = require("caller_launch")
local BINDING_KEY = "bee.gateway.binding"
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
local function request_workspace(raw: unknown): string?
    local object = bounds.object(raw)
    return object and bounds.id(object.workspace_id) or nil
end
local function handle(raw: unknown): Reply
    local bound, binding_error = attribution()
    if not bound then return fail(binding_error.code, binding_error.message) end
    local action_id = bounds.id(bound.action_id)
    local thread_id = bounds.id(bound.thread_id)
    local policy_ref = bounds.id(bound.policy_ref)
    -- The facade authorized a workspace other than the binding's before it
    -- bound this call's actor to it.
    local workspace_id = request_workspace(raw) or bounds.id(bound.workspace_id)
    if not action_id or not thread_id or not policy_ref or not workspace_id then
        return fail("UNAUTHENTICATED", "the binding does not identify an agent launch context")
    end
    local origin_view: {view_id: string, instance_id: string}? = nil
    if bound.origin_view ~= nil then
        local origin = bounds.object(bound.origin_view)
        if not origin or bounds.fields(origin, {"view_id", "instance_id"}) then
            return fail("UNAUTHENTICATED", "the binding has an invalid origin view")
        end
        local view_id, instance_id = bounds.id(origin.view_id), bounds.id(origin.instance_id)
        if not view_id or not instance_id then return fail("UNAUTHENTICATED", "the binding has an invalid origin view") end
        origin_view = {view_id = view_id, instance_id = instance_id}
    end
    local request, invalid = agent_protocol.decode(raw)
    if not request then return fail("INVALID", invalid or "invalid launch request") end
    -- The allow-list is the host-selected launch policy the caller's own
    -- attempt was admitted under. A definition it does not name is refused by
    -- a named code and no work is created.
    local caller_policy, policy_error = policy.load(policy_ref)
    if not caller_policy then return fail("UNAVAILABLE", policy_error or "the caller's launch policy is unavailable") end
    local permitted, permit_error = agent_launch.permitted(caller_policy, request.definition_ref)
    if permit_error then return fail("UNAVAILABLE", permit_error) end
    if not permitted then return fail("LAUNCH_NOT_PERMITTED", "this agent may not launch " .. request.definition_ref) end
    local definition, definition_error = definitions.load(request.definition_ref)
    if not definition then return fail("NOT_FOUND", definition_error or "the launch definition is unavailable") end
    -- A child whose CLI runs without a usable workdir confinement starts
    -- only where the host explicitly flagged it on the launching policy's
    -- own allow-list. This is asserted at admission, before any work.
    if definition.unconfined then
        local flagged, flag_error = agent_launch.unconfined_permitted(caller_policy, request.definition_ref)
        if flag_error then return fail("UNAVAILABLE", flag_error) end
        if not flagged then
            return fail("LAUNCH_UNCONFINED",
                "child definition " .. request.definition_ref .. " runs without a usable workdir confinement, which the launching policy does not explicitly permit")
        end
    end
    -- A child may not reach a wider gateway surface than the parent already
    -- holds: the child's own policy supplies its tools, so unless the host
    -- explicitly flagged the definition, they must be a subset of the
    -- launching policy's. This is asserted at admission, before any work.
    if not definition.allow_wider_tools then
        local child_policy, child_error = policy.load(definition.policy_ref)
        if not child_policy then return fail("UNAVAILABLE", child_error or "the child's launch policy is unavailable") end
        local within, wider = agent_launch.tools_within(child_policy.gateway_tools, caller_policy.gateway_tools)
        if not within then
            return fail("LAUNCH_TOOLS_EXCEED_PARENT",
                "child definition " .. request.definition_ref .. " offers gateway tool " .. tostring(wider) .. ", which the launching policy does not hold")
        end
    end
    -- The launching agent reaches a child through the thread tools bound to
    -- its own attempt. Without an explicit thread choice the child joins the
    -- caller's thread, so only a definition naming the caller's thread is
    -- launched that way; a chosen thread is an override its launch admits.
    if not request.thread and definition.default_mode ~= "window" and definition.thread_policy.kind ~= "caller" then
        return fail("LAUNCH_THREAD_UNSUPPORTED", "a definition that opens its own thread needs an explicit thread choice")
    end
    local reply = caller_launch.start({workspace_id = workspace_id, identity = action_id, thread_id = thread_id,
        parent_action_id = action_id, origin_view = origin_view}, request, definition)
    return {ok = reply.ok, error = reply.error, value = reply.value}
end
return {handle = handle}
