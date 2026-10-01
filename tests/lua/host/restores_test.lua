-- MIT. Automatic restores proceed together and never serialize each other.
local test = require("test")
local restores = require("restores")
local records = require("records")
local function record(id: string, definition: string): records.Record
    return {id = "view-" .. id, instance_id = id, definition_id = definition,
        thread_id = nil, resume_schema = "state.v1", resume_state = '{"count":7}',
        restart_policy = "automatic", window = nil}
end
local function available(definitions: {string}): (string) -> boolean
    local known: {[string]: boolean} = {}
    for _, definition in ipairs(definitions) do known[definition] = true end
    return function(definition: string): boolean return known[definition] == true end
end
local function define_tests()
    test.describe("Host restore scheduling", function()
        test.it("sends every available record together in queue order", function()
            local state = restores.new({record("first", "probe:app"), record("second", "other:app"),
                record("third", "probe:app")})
            local selected = restores.select(state, available({"probe:app", "other:app"}))
            test.eq(#selected, 3)
            test.eq(selected[1].instance_id, "first")
            test.eq(selected[2].instance_id, "second")
            test.eq(selected[3].instance_id, "third")
            test.is_false(restores.opening(state))
            restores.track(state, "request-first")
            test.is_true(restores.opening(state))
            test.is_true(restores.complete(state, "request-first"))
            test.is_false(restores.opening(state))
        end)
        test.it("defers records whose definitions are not published yet", function()
            local state = restores.new({record("first", "probe:app"), record("second", "overlay:app")})
            local selected = restores.select(state, available({"probe:app"}))
            test.eq(#selected, 1)
            test.eq(selected[1].instance_id, "first")
            test.is_false(restores.opening(state), "a deferred record never holds readiness")
            local later = restores.select(state, available({"probe:app", "overlay:app"}))
            test.eq(#later, 1)
            test.eq(later[1].instance_id, "second")
        end)
        test.it("stays pending until every tracked open settles", function()
            local state = restores.new({record("first", "probe:app"), record("second", "probe:app")})
            local selected = restores.select(state, available({"probe:app"}))
            test.eq(#selected, 2)
            restores.track(state, "request-first")
            restores.track(state, "request-second")
            test.is_true(restores.opening(state))
            test.is_true(restores.complete(state, "request-second"))
            test.is_true(restores.opening(state))
            test.is_false(restores.complete(state, "request-unknown"))
            test.is_true(restores.complete(state, "request-first"))
            test.is_false(restores.opening(state))
        end)
        test.it("drops in-flight opens and replaces the queue on broker replacement", function()
            local state = restores.new({record("first", "probe:app")})
            restores.select(state, available({"probe:app"}))
            restores.track(state, "request-first")
            restores.reset(state, {record("second", "probe:app")})
            test.is_false(restores.complete(state, "request-first"))
            test.is_false(restores.opening(state))
            local selected = restores.select(state, available({"probe:app"}))
            test.eq(#selected, 1)
            test.eq(selected[1].instance_id, "second")
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
