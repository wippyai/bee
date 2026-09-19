-- MIT. Governance's adapter drives the shared ledger-verified runner and
-- removes its own private owner policies from called migration code.
local json = require("json")
local test = require("test")
local effect = require("effect")
local migration_runner = require("migration_runner")

local DB = "bee.hub:migration_runner_db"
local ID = "bee.hub:test_governance_migration"

local function define_tests()
    test.describe("Governance migration effect", function()
        test.it("executes captured package ownership and returns a measured receipt", function()
            local receipt, complete, problem = effect.execute({migrations = {{id = ID, target_db = DB,
                ordinal = 12, package = "bee/hub", definition = {id = ID, kind = "function.lua"}}}})
            if not receipt then error(tostring(problem)) end
            if not complete then error("migration execution incomplete: " .. tostring(problem) .. " receipt " .. receipt.bytes) end
            local decoded = assert(json.decode(receipt.bytes))
            test.eq(decoded.schema_revision, "bee.governance-migration-receipt@1")
            test.eq(decoded.rows[1].id, ID)
            test.eq(decoded.rows[1].status, "applied")
            local applied, ledger_error = migration_runner.is_applied(DB, ID)
            if not applied then error("target ledger did not record migration: " .. tostring(ledger_error)) end
        end)
    end)
end

return test.run_cases(define_tests)
