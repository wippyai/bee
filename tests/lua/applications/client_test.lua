local test = require("test")
local client = require("client")

local function launch()
    local value = client.launch({version = 1, broker_pid = "broker-1", workspace_pid = "workspace-1",
        workspace_id = string.rep("a", 32), instance_id = "instance-1", view_id = "view-1",
        definition_id = "bee.test:app", thread_id = "thread-1", execution_generation = 2,
        definition_revision = "revision-1", registry_revision = "registry-1", launch_token = "token-1",
        resume_schema = "", resume_state = "", arguments = {}})
    if not value then error("valid SDK launch was refused") end
    return value
end

local function subscription_reply()
    return {version = 1, request_id = "request-1", instance_id = "instance-1", execution_generation = 2,
        operation = "subscribe", ok = true, error = nil,
        value = {subscription_id = "subscription-1", consumer_id = "bee.application:instance-1",
            after_sequence = 0, lease_generation = 1, owner_incarnation = 1, owner_authority = "owner-1",
            durability = "durable", filter_digest = string.rep("a", 64), closed = false}}
end

local function define_tests()
    test.describe("Application SDK thread result", function()
        test.it("decodes only the expected operation from the bound broker execution", function()
            local opened = launch()
            local raw = subscription_reply()
            local reply = client.thread_result(opened, "broker-1", "subscribe", raw)
            if not reply or not reply.ok then error("valid broker subscribe reply was refused") end
            test.eq(reply.request_id, "request-1")
            test.eq(reply.operation, "subscribe")
            test.is_nil(client.thread_result(opened, "broker-1", "read", raw))
            test.is_nil(client.thread_result(opened, "other-broker", "subscribe", raw))

            local stale = subscription_reply()
            stale.execution_generation = 1
            test.is_nil(client.thread_result(opened, "broker-1", "subscribe", stale))
        end)
    end)
end

return test.run_cases(define_tests)
