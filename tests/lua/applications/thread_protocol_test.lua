local test = require("test")
local protocol = require("protocol")

local function request(operation: string, arguments: {[string]: unknown}): {[string]: unknown}
    return {version = 1, request_id = "request-1", instance_id = "instance-1", launch_token = "token-1",
        execution_generation = 2, operation = operation, arguments = arguments}
end

local function define_tests()
    test.describe("Application thread facade protocol", function()
        test.it("accepts the bounded operation surface", function()
            if not protocol.request(request("read", {cursor = 0, limit = 64})) then error("read refused") end
            if not protocol.request(request("subscribe", {idempotency_key = "subscribe-1", after_sequence = 0})) then error("subscribe refused") end
            if not protocol.request(request("page", {subscription_id = "subscription-1", limit = 10})) then error("page refused") end
            if not protocol.request(request("ack_page", {idempotency_key = "ack-1", subscription_id = "subscription-1",
                page_id = "page-1", scanned_through = 4})) then error("ack refused") end
            if not protocol.request(request("resume", {idempotency_key = "resume-1", subscription_id = "subscription-1"})) then error("resume refused") end
            if not protocol.request(request("unsubscribe", {idempotency_key = "unsubscribe-1", subscription_id = "subscription-1"})) then error("unsubscribe refused") end
            if not protocol.request(request("post", {idempotency_key = "post-1", message_id = "message-1",
                message_kind = "notification", recipient_ids = {}, content = {text = "running"}})) then error("post refused") end
            if not protocol.request(request("post", {idempotency_key = "post-2", message_id = "message-2",
                message_kind = "reply", recipient_ids = {"agent-1"}, content = {text = "done"},
                in_reply_to_record_id = "record-1", outcome = "succeeded"})) then error("reply refused") end
        end)

        test.it("rejects caller-selected identity and malformed messages", function()
            for _, name in ipairs({"thread_id", "actor_id", "sender_id", "workspace_id", "binding_id",
                "execution_pid", "approval_id", "grant_id"}) do
                local value = request("read", {})
                value.arguments[name] = "forged"
                test.is_nil(protocol.request(value), name)
            end
            local outer = request("read", {})
            outer.thread_id = "forged"
            test.is_nil(protocol.request(outer))
            test.is_nil(protocol.request(request("post", {idempotency_key = "post", message_id = "message",
                message_kind = "reply", recipient_ids = {}, content = {text = "missing reference"}, outcome = "succeeded"})))
            test.is_nil(protocol.request(request("post", {idempotency_key = "post", message_id = "message",
                message_kind = "notification", recipient_ids = {}, content = {text = "unexpected reference"},
                in_reply_to_record_id = "record"})))
            test.is_nil(protocol.request(request("wait", {})))
        end)

        test.it("decodes replies under the execution fence", function()
            local success = protocol.reply({version = 1, request_id = "request-1", instance_id = "instance-1",
                execution_generation = 2, operation = "read", ok = true,
                value = {records = {}, scanned_through = 0, has_more = false}}, "read")
            if not success or not success.ok then error("success refused") end
            local failure = protocol.reply({version = 1, request_id = "request-1", instance_id = "instance-1",
                execution_generation = 2, operation = "read", ok = false, value = nil,
                error = {code = "DENIED", message = "revoked"}}, "read")
            if not failure or failure.ok or not failure.error then error("failure refused") end
            test.eq(failure.error.code, "DENIED")
            test.is_nil(protocol.reply({version = 1, request_id = "request-1", instance_id = "instance-1",
                execution_generation = 2, operation = "read", ok = true, value = {records = {}, scanned_through = 0,
                    has_more = false}, error = {code = "DENIED", message = "mixed"}}, "read"))
        end)

        test.it("binds success values and faults to the requested operation", function()
            local identity = {version = 1, request_id = "request-1", instance_id = "instance-1", execution_generation = 2}
            local read = {version = identity.version, request_id = identity.request_id, instance_id = identity.instance_id,
                execution_generation = identity.execution_generation, operation = "read", ok = true,
                value = {records = {}, scanned_through = 0, has_more = false}}
            test.not_nil(protocol.reply(read, "read"))
            test.is_nil(protocol.reply(read, "post"))

            local post = {version = 1, request_id = "request-1", instance_id = "instance-1", execution_generation = 2,
                operation = "post", ok = true, value = {record_id = "record-1", sequence = 1}}
            test.not_nil(protocol.reply(post, "post"))
            post.value = {record_id = "record-1", sequence = 1, ignored = true}
            test.is_nil(protocol.reply(post, "post"))

            local fault = {version = 1, request_id = "request-1", instance_id = "instance-1", execution_generation = 2,
                operation = "page", ok = false, value = nil, error = {code = "DENIED", message = "revoked"}}
            test.not_nil(protocol.reply(fault, "page"))
            fault.error = {code = "DENIED", message = "revoked", detail = "unexpected"}
            test.is_nil(protocol.reply(fault, "page"))
            fault.error = {code = "", message = "revoked"}
            test.is_nil(protocol.reply(fault, "page"))
            fault.error = {code = "DENIED", message = "revoked"}
            fault.extra = true
            test.is_nil(protocol.reply(fault, "page"))
        end)
    end)
end

return test.run_cases(define_tests)
