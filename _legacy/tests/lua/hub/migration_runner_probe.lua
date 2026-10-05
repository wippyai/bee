-- MIT. The runner probe observes the callee scope and records one ledger row.
local sql = require("sql")
local security = require("security")

local DEFAULT = "bee.hub:test_default_migration"
local CUSTOM = "bee.hub:test_custom_migration"
local GOVERNANCE = "bee.hub:test_governance_migration"
local BOUND = "bee.hub:test_bound_migration"
local DB = "bee.hub:migration_runner_db"
local BOUND_DB = "bee.hub:migration_binding_db"

local function expect_policy(id: string, wanted: boolean)
    local scope = assert(security.scope(), "migration execution scope unavailable")
    local actual = scope:contains(id)
    assert(actual == wanted, id .. " membership was " .. tostring(actual))
end

local function run(options: {[string]: unknown}): {[string]: unknown}
    local id = options.id
    assert(type(id) == "string")
    if id == DEFAULT then
        for _, policy in ipairs({"bee.hub.security:execution_policy", "bee.hub.security:publisher_policy",
            "bee.hub.security:worker_policy", "bee.hub.security:worker_host_policy", "bee.hub.security:migration_context_policy"}) do
            expect_policy(policy, false)
        end
        expect_policy("bee.gov.security:destination_service_policy", true)
        expect_policy("bee.gov.security:destination_execution_policy", true)
    elseif id == CUSTOM then
        expect_policy("bee.hub.security:execution_policy", true)
        expect_policy("bee.hub.security:publisher_policy", true)
        expect_policy("bee.gov.security:destination_service_policy", false)
        expect_policy("bee.gov.security:destination_execution_policy", false)
    elseif id == GOVERNANCE then
        expect_policy("bee.hub.security:execution_policy", false)
        expect_policy("bee.hub.security:publisher_policy", false)
        expect_policy("bee.gov.security:destination_service_policy", false)
        expect_policy("bee.gov.security:destination_execution_policy", false)
        expect_policy("bee.hub:governance_migration_grant_policy", true)
        assert(options.target_db == "governance:data")
        assert(options.database_id == DB)
        assert(options.table_prefix == "governance_")
    elseif id == BOUND then
        assert(options.target_db == "demo:data")
        assert(options.database_id == BOUND_DB)
        assert(options.table_prefix == "demo_")
    else
        error("unexpected migration " .. id)
    end
    local target = options.database_id
    assert(type(target) == "string")
    local db, open_error = sql.get(target)
    assert(db, tostring(open_error))
    local _, create_error = db:execute("CREATE TABLE IF NOT EXISTS _migrations (id TEXT PRIMARY KEY, applied_at TEXT NOT NULL)")
    assert(not create_error, tostring(create_error))
    local _, insert_error = db:execute("INSERT INTO _migrations (id, applied_at) VALUES ($1, $2)", {id, id})
    assert(not insert_error, tostring(insert_error))
    db:release()
    return {id = id, status = "applied"}
end

return {run = run}
