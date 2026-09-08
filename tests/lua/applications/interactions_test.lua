local test = require("test")
local interactions = require("interactions")
local protocol = require("protocol")
local function spec(id: string, request: string): protocol.Spec
    return {request_id = request, id = id, instance_id = "instance", kind = "confirm",
        title = "Stop?", message = "Work will stop", accept = "Stop", initial = ""}
end
local function define_tests()
    test.describe("Pending shell interactions", function()
        test.it("owns one copied request per view and resolves the exact incarnation once", function()
            local state = interactions.new()
            local value = spec("view", "fresh")
            test.is_true(interactions.add(state, value, "client", "pid", false))
            value.title = "Changed outside"
            test.eq(interactions.snapshot(state)[1].title, "Stop?")
            test.is_false(interactions.add(state, spec("view", "other"), "other", "pid", false))
            test.is_nil(interactions.resolve(state, {id = "view", instance_id = "foreign", request_id = "fresh", action = "accept", value = ""}))
            test.is_nil(interactions.resolve(state, {id = "view", instance_id = "instance", request_id = "stale", action = "accept", value = ""}))
            test.is_nil(interactions.resolve(state, {id = "view", instance_id = "instance", request_id = "fresh", action = "accept", value = "unexpected"}))
            local response: protocol.Response = {id = "view", instance_id = "instance", request_id = "fresh", action = "cancel", value = ""}
            local resolved = interactions.resolve(state, response)
            test.not_nil(resolved)
            if resolved then test.eq(resolved.client_request_id, "client"); test.eq(resolved.execution_pid, "pid") end
            test.is_nil(interactions.resolve(state, response))
            test.is_true(interactions.add(state, spec("view", "new"), "client", "pid", false))
            test.is_nil(interactions.resolve(state, response))
        end)
        test.it("bounds pending requests and retires them on owner cleanup", function()
            local state = interactions.new()
            for i = 1, 16 do test.is_true(interactions.add(state, spec(tostring(i), tostring(i)), "c", "p", true)) end
            test.is_false(interactions.add(state, spec("17", "17"), "c", "p", true))
            local snapshot = interactions.snapshot(state)
            test.eq(#snapshot, 16)
            snapshot[1].title = "Mutable projection"
            test.eq(interactions.snapshot(state)[1].title, "Stop?")
            test.not_nil(interactions.remove(state, "1"))
            test.is_nil(interactions.remove(state, "1"))
            test.is_true(interactions.add(state, spec("17", "17"), "c", "p", true))
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
