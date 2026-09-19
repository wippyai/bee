-- MIT. The owner operation behind the gateway's thread_launch: the caller's
-- own launch policy admits a definition or refuses it by name, and nothing
-- the launching policy did not permit is reachable. The tests drive the same
-- public facade the gateway endpoint calls, under the facade's host-named
-- policy, with the authenticated binding supplied as call context.
local test = require("test")
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local agent_launch = require("agent_launch")
local CALL = "bee.harness.launch:agent_launch_call"
local BINDING_KEY = "bee.gateway.binding"
local FACADE_POLICY = "bee.harness.launch:agent_launch_facade_policy"
local AGENT = "bee.test.agent_launch"
local WORKSPACE = "agent-launch-workspace"
local ACTION = "action-agent-launch"
local ATTEMPT = "attempt-agent-launch"
local THREAD = "thread-agent-launch"
local PERMITTED = "bee.harness.catalog:fixture_definition"
local WINDOW_DEFINITION = "bee.harness.catalog:agent_launch_window_definition"
local ALLOWING_POLICY = "bee.harness.catalog:agent_launch_policy"
local DENYING_POLICY = "bee.harness.catalog:agent_launch_denied_policy"
local WINDOW_POLICY = "bee.harness.catalog:agent_launch_window_policy"
type Object = {[string]: unknown}
local function facade_scope(): security.Scope
    local policy, err = security.policy(FACADE_POLICY)
    if err or not policy then error("facade policy: " .. tostring(err)) end
    return security.new_scope({policy})
end
local function launch(binding: {[string]: unknown}?, request: Object): Object
    local executor = funcs.new():with_actor(security.new_actor(AGENT)):with_scope(facade_scope())
    if binding then executor = assert(executor:with_context({[BINDING_KEY] = binding})) end
    local reply, err = executor:call(CALL, request)
    if err then error("agent launch call: " .. tostring(err)) end
    if type(reply) ~= "table" then error("agent launch returned a non-table") end
    return reply :: Object
end
local function fault(reply: Object): string
    test.eq(reply.ok, false)
    return tostring((reply.error :: Object).code)
end
local function binding(policy_ref: string): {[string]: unknown}
    return {binding_id = "binding-1", thread_id = THREAD, action_id = ACTION, attempt_id = ATTEMPT, policy_ref = policy_ref, workspace_id = WORKSPACE}
end
local function define_tests()
    test.describe("Agent launch owner operation", function()
        test.it("decodes only a bounded definition, brief and retry key", function()
            local request = agent_launch.decode_request({definition_ref = PERMITTED, brief = "do the work", idempotency_key = "key-1"})
            test.eq(request and request.definition_ref, PERMITTED)
            test.eq(request and request.brief, "do the work")
            local _, no_brief = agent_launch.decode_request({definition_ref = PERMITTED, brief = "", idempotency_key = "key-1"})
            test.eq(no_brief, "brief must be nonempty bounded text")
            local _, no_key = agent_launch.decode_request({definition_ref = PERMITTED, brief = "x"})
            test.eq(no_key, "idempotency_key is not a bounded identifier")
            local _, smuggled = agent_launch.decode_request({definition_ref = PERMITTED, brief = "x", idempotency_key = "k", workspace_id = "other"})
            test.eq(smuggled, "unknown field workspace_id")
            local _, oversized = agent_launch.decode_request({definition_ref = PERMITTED, brief = string.rep("x", agent_launch.MAX_BRIEF_BYTES + 1), idempotency_key = "k"})
            test.eq(oversized, "brief must be nonempty bounded text")
            local _, no_definition = agent_launch.decode_request({brief = "x", idempotency_key = "k"})
            test.eq(no_definition, "definition_ref is not an identifier")
        end)
        test.it("reads the caller's own launch policy allow-list and nothing else", function()
            local allowing = assert(registry.get(ALLOWING_POLICY))
            local denying = assert(registry.get(DENYING_POLICY))
            local listed = ((allowing.data :: Object).agent_launch :: {string})
            test.eq(#listed, 1)
            test.eq(listed[1], PERMITTED)
            test.eq(#((denying.data :: Object).agent_launch :: {string}), 0)
        end)
        test.it("derives one durable request identity per caller action and retry key", function()
            local first, err = agent_launch.request_id(ACTION, "key-1")
            if not first then error(tostring(err)) end
            test.eq(first, agent_launch.request_id(ACTION, "key-1"))
            test.is_true(first ~= agent_launch.request_id(ACTION, "key-2"))
            test.is_true(first ~= agent_launch.request_id("another-action", "key-1"))
        end)
        test.it("refuses an unbound call before any work exists", function()
            local reply = launch(nil, {definition_ref = PERMITTED, brief = "do the work", idempotency_key = "unbound-key"})
            test.eq(fault(reply), "UNAUTHENTICATED")
        end)
        test.it("refuses a binding that names no launch policy or workspace", function()
            local reply = launch({binding_id = "b", thread_id = THREAD, action_id = ACTION, attempt_id = ATTEMPT},
                {definition_ref = PERMITTED, brief = "do the work", idempotency_key = "context-key"})
            test.eq(fault(reply), "UNAUTHENTICATED")
        end)
        test.it("refuses a definition the caller's own policy does not list, by name", function()
            local reply = launch(binding(DENYING_POLICY), {definition_ref = PERMITTED, brief = "do the work", idempotency_key = "refused-key"})
            test.eq(fault(reply), "LAUNCH_NOT_PERMITTED")
            test.is_true(tostring((reply.error :: Object).message):find(PERMITTED, 1, true) ~= nil)
        end)
        test.it("refuses a definition declaring a window mode, which has no agent carrier", function()
            local reply = launch(binding(WINDOW_POLICY), {definition_ref = WINDOW_DEFINITION, brief = "do the work", idempotency_key = "window-key"})
            test.eq(fault(reply), "LAUNCH_MODE_UNSUPPORTED")
        end)
    end)
end
return test.run_cases(define_tests)
