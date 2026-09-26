-- MIT. Host audience table decoding and admission: listed operations admit
-- the owner's own callers and their peers, unlisted ones stay unrestricted.
local test = require("test")
local audiences = require("audiences")

local function define_tests()
    test.describe("Hive exposure audiences", function()
        test.it("decodes the host table and refuses malformed rows", function()
            local decoded = assert(audiences.decode({audiences = {
                {operation_ref = "bee.hive:probe_open", peers = {"node-2", "node-1"}},
                {operation_ref = "bee.hive.telemetry:presence", peers = {"node-1"}},
            }}))
            test.eq(#decoded.list, 2)
            test.is_true(decoded.by_operation["bee.hive:probe_open"].peers["node-1"])
            test.is_true(decoded.by_operation["bee.hive:probe_open"].peers["node-2"])
            local empty = assert(audiences.decode({audiences = {}}))
            test.is_true(audiences.admits(empty, "bee.hive:probe_open", "node-0", "node-2", "node-2"))
            test.is_nil(audiences.decode({audiences = {{operation_ref = "bee.hive:probe_open", peers = {}}}
            }))
            test.is_nil(audiences.decode({audiences = {{operation_ref = "no-colon", peers = {"node-1"}}} }))
            test.is_nil(audiences.decode({audiences = {{operation_ref = "bee.hive:probe_open", peers = {"Bad Peer"}}} }))
            test.is_nil(audiences.decode({audiences = {{operation_ref = "bee.hive:probe_open", peers = {"*"}}} }))
            test.is_nil(audiences.decode({audiences = {
                {operation_ref = "bee.hive:probe_open", peers = {"node-1"}},
                {operation_ref = "bee.hive:probe_open", peers = {"node-2"}},
            }}))
            test.is_nil(audiences.decode({unexpected = true}))
        end)

        test.it("admits local callers and listed peers only", function()
            local decoded = assert(audiences.decode({audiences = {
                {operation_ref = "bee.hive:probe_open", peers = {"node-1"}},
            }}))
            test.is_true(audiences.admits(decoded, "bee.hive:probe_open", "node-0", "node-1", "node-1"))
            test.is_false(audiences.admits(decoded, "bee.hive:probe_open", "node-0", "node-2", "node-2"))
            test.is_true(audiences.admits(decoded, "bee.hive:probe_open", "node-0", "node-9", "node-0"))
            test.is_true(audiences.admits(decoded, "bee.hive:other", "node-0", "node-2", "node-2"))
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
