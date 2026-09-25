-- MIT. Read-only launch discovery behind the gateway's launch_definitions
-- tool: the caller's own launch policy allow-list names exactly the returned
-- definitions, each with the placements a launch accepts, the overrides its
-- definition admits and the saved profiles held for it. The tests drive the
-- same public facade the gateway endpoint calls, under the facade's
-- host-named policy, with the authenticated binding supplied as call context.
local test = require("test")
local funcs = require("funcs")
local security = require("security")
local CALL = "bee.harness.launch:launch_definitions_call"
local BINDING_KEY = "bee.gateway.binding"
local FACADE_POLICY = "bee.harness.launch:launch_definitions_facade_policy"
local AGENT = "bee.test.agent_launch"
local WORKSPACE = "agent-launch-workspace"
local ALLOWING_POLICY = "bee.harness.catalog:agent_launch_policy"
local DENYING_POLICY = "bee.harness.catalog:agent_launch_denied_policy"
local PERMITTED = "bee.harness.catalog:fixture_definition"
type Object = {[string]: unknown}
local function facade_scope(): security.Scope
    local policy, err = security.policy(FACADE_POLICY)
    if err or not policy then error("facade policy: " .. tostring(err)) end
    return security.new_scope({policy})
end
local function discover(policy_ref: string, request: Object): Object
    local executor = funcs.new():with_actor(security.new_actor(AGENT)):with_scope(facade_scope())
    executor = assert(executor:with_context({[BINDING_KEY] = {binding_id = "binding-definitions",
        thread_id = "thread-definitions", action_id = "action-definitions", attempt_id = "attempt-definitions",
        policy_ref = policy_ref, workspace_id = WORKSPACE}}))
    local reply, err = executor:call(CALL, request)
    if err then error("launch definitions call: " .. tostring(err)) end
    if type(reply) ~= "table" then error("launch definitions returned a non-table") end
    return reply :: Object
end
local function define_tests()
    test.describe("Launch definitions discovery", function()
        test.it("returns exactly the definitions the caller's launch policy admits", function()
            local reply = discover(ALLOWING_POLICY, {})
            test.eq(reply.ok, true)
            local value = reply.value :: Object
            test.eq(value.workspace_id, WORKSPACE)
            test.eq(value.policy_ref, ALLOWING_POLICY)
            local definitions = value.definitions :: {Object}
            test.eq(#definitions, 1)
            local definition = definitions[1]
            test.eq(definition.definition_ref, PERMITTED)
            test.eq(definition.title, "Claude protocol fixture")
            test.eq(definition.default_mode, "batch")
            test.eq(definition.profile_id, "batch")
            local placements = definition.placements :: {string}
            test.eq(#placements, 2)
            local overrides = definition.allowed_overrides :: {string}
            local briefed = false
            for _, override in ipairs(overrides) do if override == "brief" then briefed = true end end
            test.is_true(briefed)
            test.not_nil(definition.workdir_policy)
            test.not_nil(definition.thread_policy)
            test.eq(type(value.saved_profiles), "table")
            test.eq(type(value.profiles_complete), "boolean")
        end)
        test.it("returns no definitions for an empty allow-list and refuses unknown fields", function()
            local reply = discover(DENYING_POLICY, {})
            test.eq(reply.ok, true)
            test.eq(#((reply.value :: Object).definitions :: {unknown}), 0)
            local refused = discover(ALLOWING_POLICY, {definition_ref = PERMITTED})
            test.eq(refused.ok, false)
            test.eq(tostring((refused.error :: Object).code), "INVALID")
        end)
    end)
end
return test.run_cases(define_tests)
