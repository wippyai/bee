-- MIT. Governance's adapter drives the shared ledger-verified runner and
-- removes its own private owner policies from called migration code.
local json = require("json")
local test = require("test")
local effect = require("effect")
local migration_runner = require("migration_runner")
local migration_work = require("migration_work")
local canonical = require("canonical")
local hash = require("hash")

local DB = "bee.hub:migration_runner_db"
local TARGET = "governance:data"
local ID = "bee.hub:test_governance_migration"
local POLICY = "bee.hub:governance_migration_grant_policy"
local SHA = string.rep("a", 64)

local function work_fixture(): migration_work.Work
    local definition = {id = ID, kind = "function.lua",
        meta = {type = "migration", target_db = TARGET, ordinal = 12},
        data = {source = "file://migration_runner_probe.lua", method = "run", modules = {"sql", "security"}}}
    local definition_bytes = assert(canonical.encode(definition))
    local checksum = assert(hash.sha256(definition_bytes))
    local bytes = assert(canonical.encode({schema_revision = migration_work.SCHEMA,
        destination_node = "node-hub", source_node = "node-source", base_revision = 0,
        base_digest = SHA, policy_digest = SHA, candidate_digest = SHA,
        artifact_digest = SHA, plan_digest = SHA,
        migrations = {{id = ID, target_db = TARGET, ordinal = 12, checksum = checksum,
            package = "bee/hub", definition = definition}},
        databases = {{target_db = TARGET, database_id = DB, table_prefix = "governance_",
            kind = "db.sql.sqlite", package = "bee/hub", digest = SHA, planned = false}}}, migration_work.MAX_BYTES))
    local digest = assert(hash.sha256(bytes))
    local work, problem = migration_work.decode(bytes, digest)
    if not work then error(tostring(problem)) end
    return work
end

local function define_tests()
    test.describe("Governance migration effect", function()
        test.it("executes captured package ownership and returns a measured receipt", function()
            local binding = {database_id = DB, table_prefix = "governance_"}
            local receipt, complete, problem = effect.execute(work_fixture(), {POLICY})
            if not receipt then error(tostring(problem)) end
            if not complete then error("migration execution incomplete: " .. tostring(problem) .. " receipt " .. receipt.bytes) end
            local decoded = assert(json.decode(receipt.bytes))
            test.eq(decoded.schema_revision, "bee.governance-migration-receipt@1")
            test.eq(decoded.rows[1].id, ID)
            test.eq(decoded.rows[1].status, "applied")
            local applied, ledger_error = migration_runner.is_applied(TARGET, ID, binding)
            if not applied then error("target ledger did not record migration: " .. tostring(ledger_error)) end
        end)
    end)
end

return test.run_cases(define_tests)
