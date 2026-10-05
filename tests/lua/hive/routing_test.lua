-- MIT. The supervisor routes an operation by its prefix to the service a
-- route entry names and refuses operations no route covers.
local test = require("test")
local system = require("system")
local channel = require("channel")
local process = require("process")
local protocol = require("protocol")

local function call(op: string): protocol.Reply
    local reply, err = protocol.call(assert(system.node.id()), op, {}, "5s")
    if not reply then error(op .. ": " .. tostring(err)) end
    return reply
end

local function define_tests()
    test.describe("routing", function()
        test.it("refuses an operation without a route", function()
            local reply = call("nowhere.list")
            test.is_false(reply.ok)
            test.contains(tostring(reply.error), "unknown operation")
        end)

        test.it("refuses an operation without a prefix", function()
            test.is_false(call("list").ok)
        end)

        test.it("answers concurrent calls from one process", function()
            local done = channel.new(4)
            for _ = 1, 3 do
                coroutine.spawn(function()
                    local reply, err = protocol.call(assert(system.node.id()), "node.list", {}, "5s")
                    done:send(reply ~= nil and reply.ok == true or tostring(err))
                end)
            end
            for _ = 1, 3 do
                local result = done:receive()
                test.eq(result, true)
            end
        end)

        test.it("holds a request for a service that is not running until it is ready", function()
            local done = channel.new(1)
            coroutine.spawn(function()
                local reply, err = protocol.call(assert(system.node.id()), "parked.ping", {}, "5s")
                done:send(reply ~= nil and reply.ok == true and (reply.value or {}).op == "ping" or tostring(err))
            end)
            assert(process.spawn("bee.tests.hive:parked_service", "bee:workers"))
            test.eq(done:receive(), true)
        end)

        test.it("drops a held request its caller stopped waiting for", function()
            local late, late_error = protocol.call(assert(system.node.id()), "parked.ping", {label = "late"}, "200ms")
            test.is_nil(late)
            test.contains(tostring(late_error), "no reply")
            local done = channel.new(1)
            coroutine.spawn(function()
                local reply = protocol.call(assert(system.node.id()), "parked.ping", {label = "current"}, "5s")
                done:send(reply ~= nil and reply.ok == true and (reply.value or {}).label or "none")
            end)
            assert(process.spawn("bee.tests.hive:parked_service", "bee:workers"))
            test.eq(done:receive(), "current")
        end)

        test.it("hands a routed operation to the service the route names", function()
            test.is_true(call("node.list").ok)
            local reply = call("node.frobnicate")
            test.is_false(reply.ok)
            test.contains(tostring(reply.error), "unknown node operation")
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
