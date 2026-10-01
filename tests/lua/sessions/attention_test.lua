-- MIT. The display summary is workspace-scoped and counts owner evidence.
local test = require("test")
local funcs = require("funcs")
local security = require("security")
local harness = require("harness")
local function object(value: unknown): {[string]: unknown}
    if type(value) ~= "table" then error("expected object") end
    return value
end
local function text(row: {[string]: unknown}, key: string): string
    local value = row[key]
    if type(value) ~= "string" then error("expected " .. key) end
    return value
end
local function define_tests()
    test.describe("Session attention summary", function()
        test.it("counts uncertain sessions and refuses another workspace", function()
            local workspace = string.rep("d", 32)
            local journal = harness.session_owner(workspace)
            local actor = assert(security.new_actor("person", {workspace_id = workspace}))
            local scope = security.new_scope({assert(security.policy("bee.threads:client_test_policy")),
                assert(security.policy("bee.tests.sessions:interactive_lifecycle_policy"))})
            local function summary(home: string): {[string]: unknown}
                local raw, err = funcs.new():with_actor(actor):with_scope(scope):call("bee.sessions.binding:attention_count", {workspace_id = home})
                if err then error(tostring(err)) end
                return object(raw)
            end
            local before = object(summary(workspace).value).count
            if type(before) ~= "number" then error("count unavailable") end
            local opened = object(harness.value(journal:call("session_create", {operation_key = harness.key(), route = {delivery = "hook"}})))
            local session = text(opened, "session")
            harness.value(journal:call("work_send", {session = session, input = "work", operation_key = harness.key()}))
            local reserved = object(harness.value(journal:call("turn_reserve", {session = session, operation_key = harness.key()})))
            local turn, claim = text(reserved, "turn"), text(reserved, "claim")
            local pulled = object(harness.value(journal:call("turn_pull", {turn = turn, claim = claim})))
            harness.value(journal:call("turn_accept", {turn = turn, claim = claim, input_digest = text(pulled, "input_digest"), checkpoint = {}, operation_key = harness.key()}))
            harness.value(journal:call("work_uncertain", {turn = turn, claim = claim, evidence = {summary = "delivery unknown", artifacts = {}}, operation_key = harness.key()}))
            test.eq(object(summary(workspace).value).count, before + 1)
            test.eq(summary(string.rep("e", 32)).ok, false)
        end)
    end)
end
return test.run_cases(define_tests)
