-- MIT. Captured migration functions receive only the selected owner scope.
local test = require("test")
local migration_runner = require("migration_runner")
local migrations = require("migrations")

local DB = "bee.hub:migration_runner_db"
local DEFAULT = "bee.hub:test_default_migration"
local CUSTOM = "bee.hub:test_custom_migration"
local BOUND = "bee.hub:test_bound_migration"
local BOUND_DB = "bee.hub:migration_binding_db"

local entries = {
    {id = DEFAULT, meta = {type = "migration", target_db = DB, timestamp = "2026-09-19T10:00:00Z"}, registry = {owner = "bee/hub"}},
    {id = CUSTOM, meta = {type = "migration", target_db = DB, timestamp = "2026-09-19T11:00:00Z"}, registry = {owner = "bee/hub"}},
}
local bound_entries: {migrations.Entry} = {
    {id = BOUND, meta = {type = "migration", target_db = "demo:data", timestamp = "2026-09-19T12:00:00Z"}, registry = {owner = "demo/app"}},
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
        test.it("resolves a logical target through the host database binding", function()
            local bindings = {['demo:data'] = {database_id = BOUND_DB, table_prefix = "demo_"}}
            local source = migration_runner.source(bound_entries, nil, bindings)
            local runner, setup_error = source.runner.setup("demo:data")
            if not runner then error(tostring(setup_error)) end
            local result = runner:run_next({allowed_ids = {BOUND}})
            test.not_nil(result.migrations)
            local applied, applied_error = source.is_applied("demo:data", BOUND)
            if applied == nil then error(tostring(applied_error)) end
            test.is_true(applied)
        end)
        test.it("refuses missing, malformed and ungranted physical bindings", function()
            local source = migration_runner.source(bound_entries, nil, {})
            local runner, missing = source.runner.setup("demo:data")
            test.is_nil(runner)
            test.eq(missing, "migration database binding is missing for demo:data")
            local malformed = migration_runner.source(bound_entries, nil,
                {['demo:data'] = {database_id = BOUND_DB, table_prefix = "bad-prefix"}})
            local malformed_runner, malformed_error = malformed.runner.setup("demo:data")
            test.is_nil(malformed_runner)
            test.eq(malformed_error, "migration database binding is invalid for demo:data")
            local allowed, denied = migration_runner.allowed(bound_entries,
                {['demo:data'] = {database_id = "demo:ungranted"}})
            test.is_false(allowed)
            test.eq(denied, "host database grant required for migration " .. BOUND)
        end)
    end)
end

return test.run_cases(define_tests)
