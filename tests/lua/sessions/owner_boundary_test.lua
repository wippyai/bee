-- MIT. Public owner operations reject malformed input before touching state.
local test = require("test")
local funcs = require("funcs")
local bounds = require("bounds")
local registry = require("registry")

local function define_tests()
    test.describe("Sessions owner boundary", function()
        test.it("rejects non-object requests through every registered method", function()
            for _, method in ipairs({"open", "run", "send", "await", "join", "get", "list", "history",
                "cancel", "close", "catalog", "attach", "detach", "hook_boundary", "attention_count"}) do
                local raw, problem = funcs.call("bee.threads.sessions.binding:" .. method, "invalid")
                test.is_nil(problem, method)
                local reply = assert(bounds.object(raw))
                test.eq(reply.ok, false, method)
                test.eq(assert(bounds.object(reply.error)).code, "INVALID", method)
            end
        end)
        test.it("forwards every contract operation to its node and preserves uncertain mutation keys", function()
            local original = assert(registry.get("bee.hive.binding:call"))
            local replacement = assert(registry.get("bee.tests.sessions:peer_call_probe"))
            local changes = assert(registry.snapshot()):changes()
            changes:update({id = original.id, kind = replacement.kind, meta = replacement.meta, data = replacement.data})
            assert(changes:apply())
            local ok, failure = pcall(function()
                for _, method in ipairs({"open", "run", "send", "await", "join", "get", "list", "history", "cancel", "close", "catalog"}) do
                    local raw, err = funcs.call("bee.threads.sessions.binding:" .. method, {node = "peer-test", operation_key = "key/" .. method})
                    test.is_nil(err)
                    local reply = assert(bounds.object(raw))
                    test.eq(reply.ok, true)
                    local value = assert(bounds.object(reply.value))
                    test.eq(value.node, "peer-test")
                    test.eq(value.operation, method)
                end
                local raw, err = funcs.call("bee.threads.sessions.binding:send", {node = "lost-peer", operation_key = "durable/send"})
                test.is_nil(err)
                local failure = assert(bounds.object(assert(bounds.object(raw)).error))
                test.eq(failure.code, "UNKNOWN_OUTCOME")
                test.eq(failure.retry, "same_key")
                test.eq(failure.operation_key, "durable/send")
            end)
            local restore = assert(registry.snapshot()):changes()
            restore:update(original)
            assert(restore:apply())
            if not ok then error(tostring(failure)) end
        end)
        test.it("accepts node additively while rejecting invalid targets", function()
            for _, method in ipairs({"open", "run", "send", "await", "join", "get", "list", "history", "cancel", "close", "catalog"}) do
                local raw, err = funcs.call("bee.threads.sessions.binding:" .. method, {node = "", operation_key = "k"})
                test.is_nil(err)
                local reply = assert(bounds.object(raw))
                local fault = assert(bounds.object(reply.error))
                test.eq(fault.code, "INVALID")
                test.contains(tostring(fault.message), "node")
            end
        end)
    end)
end

return test.run_cases(define_tests)
