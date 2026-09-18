-- MIT. Focused tests for the pure bounded MCP context decoder and composer.
local test = require("test")
local context = require("context")
type Object = {[string]: unknown}

local function run()
    test.describe("Gateway MCP context values", function()
        test.it("reserves binding attribution and isolates it from caller context", function()
            local identity = {binding_id = "binding-a", thread_id = "thread-a", action_id = "action-a", attempt_id = "attempt-a"}
            local spoof: Object = {}
            spoof[context.BINDING_KEY] = {thread_id = "foreign"}
            test.is_nil(context.decode(spoof))
            test.is_nil(context.compose(spoof, {}, {}))
            test.is_nil(context.compose({}, {}, {context.BINDING_KEY}))
            test.is_nil(context.compose({}, spoof, {context.BINDING_KEY}))
            test.is_nil(context.bind(spoof, identity))
            local values: Object = {}
            for index = 1, 32 do values["value" .. tostring(index)] = index end
            local first, first_error = context.bind(values, identity)
            if not first then error(tostring(first_error)) end
            local second, second_error = context.bind(values, identity)
            if not second then error(tostring(second_error)) end
            (first[context.BINDING_KEY] :: Object).thread_id = "changed"
            first.value1 = 99
            test.eq((second[context.BINDING_KEY] :: Object).thread_id, "thread-a")
            test.eq(identity.thread_id, "thread-a")
            test.eq(values.value1, 1)
            test.eq(second.value32, 32)
            test.is_nil(context.bind({}, {binding_id = "", thread_id = "thread-a", action_id = "action-a", attempt_id = "attempt-a"}))
        end)
        test.it("keeps host values fixed and admits only named dynamic keys", function()
            local fixed: Object = {action_id = "action-host", attempt_id = "attempt-host", host = {node = "node-a"}}
            local dynamic, decode_error = context.decode({trace_id = "trace-1", labels = {phase = "review"}})
            if not dynamic then error(tostring(decode_error)) end
            local composed, compose_error = context.compose(fixed, dynamic, {"trace_id", "labels"})
            if not composed then error(tostring(compose_error)) end
            test.eq(composed.action_id, "action-host")
            test.eq(composed.attempt_id, "attempt-host")
            test.eq((composed.labels :: Object).phase, "review")

            local conflict, conflict_error = context.compose(fixed, {action_id = "caller-action"}, {"action_id"})
            test.is_nil(conflict)
            test.eq(conflict_error, "dynamic context cannot overwrite host context key action_id")
            local unknown, unknown_error = context.compose(fixed, {principal = "caller"}, {"trace_id"})
            test.is_nil(unknown)
            test.eq(unknown_error, "unknown dynamic context key principal")
        end)

        test.it("copies host and request maps for each concurrent call", function()
            local fixed: Object = {host = {tags = {"bee"}}}
            local raw: Object = {metadata = {labels = {"one"}}}
            local decoded, decode_error = context.decode(raw)
            if not decoded then error(tostring(decode_error)) end
            local first, first_error = context.compose(fixed, decoded, {"metadata"})
            local second, second_error = context.compose(fixed, decoded, {"metadata"})
            if not first then error(tostring(first_error)) end
            if not second then error(tostring(second_error)) end

            ((first.host :: Object).tags :: {string})[1] = "first-only"
            ((first.metadata :: Object).labels :: {string})[1] = "first-only"
            test.eq(((second.host :: Object).tags :: {string})[1], "bee")
            test.eq(((second.metadata :: Object).labels :: {string})[1], "one")
            test.eq(((fixed.host :: Object).tags :: {string})[1], "bee")
            test.eq(((raw.metadata :: Object).labels :: {string})[1], "one")
        end)

        test.it("rejects non-finite, nested, sparse, and oversized context values", function()
            local _, nan_error = context.decode({value = 0 / 0})
            test.eq(nan_error, "context numbers must be finite")
            local _, infinity_error = context.decode({value = math.huge})
            test.eq(infinity_error, "context numbers must be finite")
            local _, depth_error = context.decode({a = {b = {c = {d = {e = "deep"}}}}})
            test.eq(depth_error, "context nests deeper than 4")
            local sparse: Object = {items = {[1] = "one", [3] = "three"}}
            local _, sparse_error = context.decode(sparse)
            test.eq(sparse_error, "context array indexes must be dense")
            local too_many: Object = {}
            for index = 1, 33 do too_many["key" .. tostring(index)] = index end
            local _, keys_error = context.decode(too_many)
            test.eq(keys_error, "context has more than 32 keys")
            local _, bytes_error = context.decode({payload = string.rep("x", context.MAX_BYTES)})
            test.eq(bytes_error, "context exceeds 16384 encoded bytes")
        end)

        test.it("applies the byte and key limits to the combined host and dynamic map", function()
            local fixed: Object = {}
            local dynamic: Object = {}
            for index = 1, 16 do fixed["host" .. tostring(index)] = string.rep("h", 500) end
            for index = 1, 16 do dynamic["dynamic" .. tostring(index)] = string.rep("d", 500) end
            local too_large, byte_error = context.compose(fixed, dynamic, {
                "dynamic1", "dynamic2", "dynamic3", "dynamic4", "dynamic5", "dynamic6", "dynamic7", "dynamic8",
                "dynamic9", "dynamic10", "dynamic11", "dynamic12", "dynamic13", "dynamic14", "dynamic15", "dynamic16"})
            test.is_nil(too_large)
            test.eq(byte_error, "context exceeds 16384 encoded bytes")

            local key_fixed: Object = {}
            local key_dynamic: Object = {}
            local allowed: {string} = {}
            for index = 1, 17 do key_fixed["host" .. tostring(index)] = index end
            for index = 1, 16 do
                local key = "dynamic" .. tostring(index)
                key_dynamic[key] = index
                allowed[index] = key
            end
            local too_many, key_error = context.compose(key_fixed, key_dynamic, allowed)
            test.is_nil(too_many)
            test.eq(key_error, "context has more than 32 keys")
        end)
    end)
end

return test.run_cases(run)
