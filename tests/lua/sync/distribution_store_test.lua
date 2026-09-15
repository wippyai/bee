-- MIT. Distribution progress is independent for every destination and CAS
-- fenced so concurrent workers cannot skip an ordered range.
local test = require("test")
local uuid = require("uuid")
local store = require("store")

local function define_tests()
    test.describe("Sync distribution cursors", function()
        test.it("advances destinations independently with expected-value fencing", function()
            local suffix = assert(uuid.v7())
            local opened = assert(store.open("bee.sync:sync_test_db"))
            local source, feed = "source-" .. suffix, "application-versions"
            local left = store.cursor(opened, source, feed, "node-left")
            local right = store.cursor(opened, source, feed, "node-right")
            test.eq((left.value :: {[string]: unknown}).cursor, 0)
            test.eq((right.value :: {[string]: unknown}).cursor, 0)
            test.is_true(store.advance(opened, source, feed, "node-left", 0, 4).ok)
            test.eq(store.advance(opened, source, feed, "node-left", 0, 5).code, "CONFLICT")
            test.eq((store.cursor(opened, source, feed, "node-left").value :: {[string]: unknown}).cursor, 4)
            test.eq((store.cursor(opened, source, feed, "node-right").value :: {[string]: unknown}).cursor, 0)
            test.is_true(store.close(opened))
        end)
    end)
end

return test.run_cases(define_tests)
