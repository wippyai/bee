-- MIT. Captured migration functions receive only the selected owner scope.
local test = require("test")
local migration_runner = require("migration_runner")
local migrations = require("migrations")

local DB = "bee.hub:migration_runner_db"
local DEFAULT = "bee.hub:test_default_migration"
local CUSTOM = "bee.hub:test_custom_migration"

local entries = {
    {id = DEFAULT, meta = {type = "migration", target_db = DB, timestamp = "2026-09-19T10:00:00Z"}, registry = {owner = "bee/hub"}},
    {id = CUSTOM, meta = {type = "migration", target_db = DB, timestamp = "2026-09-19T11:00:00Z"}, registry = {owner = "bee/hub"}},
}

local function run_next(source: migrations.Source, id: string): migrations.RunnerResult
    local runner, setup_error = source.runner.setup(DB)
    if not runner then error(tostring(setup_error)) end
    return runner:run_next({allowed_ids = {id}})
end

local function define_tests()
    test.describe("Hub migration runner policy selection", function()
        test.it("keeps Hub defaults and accepts a different owner policy set", function()
            local default_result = run_next(migration_runner.source(entries), DEFAULT)
            test.not_nil(default_result.migrations)
            if default_result.migrations then test.eq(default_result.migrations[1].status, "applied") end
            local custom_result = run_next(migration_runner.source(entries, {
                "bee:governance_destination_service_policy", "bee:governance_destination_execution_policy",
            }), CUSTOM)
            test.not_nil(custom_result.migrations)
            if custom_result.migrations then test.eq(custom_result.migrations[1].status, "applied") end
        end)
    end)
end

return test.run_cases(define_tests)
