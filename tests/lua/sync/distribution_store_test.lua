-- MIT. Distribution progress is independent for every destination and CAS
-- fenced so concurrent workers cannot skip an ordered range.
local test = require("test")
local bounds = require("bounds")
local uuid = require("uuid")
local store = require("store")

local function define_tests()
    test.describe("Sync distribution cursors", function()
        test.it("advances destinations independently with expected-value fencing", function()
            local suffix = assert(uuid.v7())
            local opened = assert(store.open())
            local source, feed = "source-" .. suffix, "application-versions"
            local left = store.cursor(opened, source, feed, "node-left")
            local right = store.cursor(opened, source, feed, "node-right")
            test.eq((assert(bounds.object(left.value))).cursor, 0)
            test.eq((assert(bounds.object(right.value))).cursor, 0)
            test.is_true(store.advance(opened, source, feed, "node-left", 0, 4).ok)
            test.eq(store.advance(opened, source, feed, "node-left", 0, 5).code, "CONFLICT")
            test.eq((assert(bounds.object(store.cursor(opened, source, feed, "node-left").value))).cursor, 4)
            test.eq((assert(bounds.object(store.cursor(opened, source, feed, "node-right").value))).cursor, 0)
            test.is_true(store.close(opened))
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
