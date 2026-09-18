-- Disposable acceptance probe.  Captured registry metadata is supplied by the
-- Hub side while the execution runner and SQLite ledger are real 0.3.17 code.
local sql = require("sql")
local logger = require("logger")
local adapter = require("adapter")
local migration_runner = require("migration_runner")
local migration_binding = require("migration_binding")

local DB = "probe:db"
local FIRST = "acme.app:10_first"
local SECOND = "acme.app:20_second"
local EXCLUDED = "acme.app:99_excluded"

local captured = {
    {id = FIRST, meta = {type = "migration", target_db = DB, timestamp = "2026-09-12T10:00:00Z"}, registry = {owner = "acme/app"}},
    {id = SECOND, meta = {type = "migration", target_db = DB, timestamp = "2026-09-12T11:00:00Z"}, registry = {owner = "acme/app"}},
    {id = EXCLUDED, meta = {type = "migration", target_db = DB, timestamp = "2026-09-12T12:00:00Z"}, registry = {owner = "acme/app"}},
}

local function ledger_has(target_db, id)
    local db, err = sql.get(target_db)
    assert(not err and db, tostring(err))
    local rows, query_err = db:query("SELECT COUNT(*) AS count FROM _migrations WHERE id = $1", {id})
    db:release()
    assert(not query_err and rows, tostring(query_err))
    return rows[1] and rows[1].count > 0
end

local function table_exists(name)
    local db, err = sql.get(DB)
    assert(not err and db, tostring(err))
    local rows, query_err = db:query("SELECT COUNT(*) AS count FROM sqlite_master WHERE type='table' AND name = $1", {name})
    db:release()
    assert(not query_err and rows, tostring(query_err))
    return rows[1] and rows[1].count > 0
end

local function source()
    return {
        entries = captured,
        runner = migration_runner,
        is_applied = ledger_has,
    }
end

local function ensure_ledger()
    local db, err = sql.get(DB)
    assert(not err and db, tostring(err))
    local _, create_err = db:execute("CREATE TABLE IF NOT EXISTS _migrations (id VARCHAR(512) PRIMARY KEY, applied_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')), description TEXT)")
    db:release()
    assert(not create_err, tostring(create_err))
end

local function record(phase)
    local db, err = sql.get(DB)
    assert(not err and db, tostring(err))
    local _, create_err = db:execute("CREATE TABLE IF NOT EXISTS probe_acceptance_evidence (phase TEXT PRIMARY KEY, users_table INTEGER NOT NULL, audit_table INTEGER NOT NULL, excluded_table INTEGER NOT NULL, first_ledger INTEGER NOT NULL, second_ledger INTEGER NOT NULL, excluded_ledger INTEGER NOT NULL)")
    assert(not create_err, tostring(create_err))
    local _, insert_err = db:execute("INSERT INTO probe_acceptance_evidence (phase, users_table, audit_table, excluded_table, first_ledger, second_ledger, excluded_ledger) VALUES ($1, $2, $3, $4, $5, $6, $7)", {
        phase,
        table_exists("probe_users") and 1 or 0,
        table_exists("probe_audit") and 1 or 0,
        table_exists("probe_excluded") and 1 or 0,
        ledger_has(DB, FIRST) and 1 or 0,
        ledger_has(DB, SECOND) and 1 or 0,
        ledger_has(DB, EXCLUDED) and 1 or 0,
    })
    db:release()
    assert(not insert_err, tostring(insert_err))
end

local function execute(operation, ids)
    local result, problem = adapter.execute(source(), {
        operation = operation,
        entry_ids = ids,
        components = {"acme/app"},
    })
    assert(not problem, tostring(problem))
    assert(result and result.operation == operation, "adapter returned no result")
    return result
end

local function assert_row(result, id, status)
    for _, row in ipairs(result.rows) do
        if row.id == id then
            assert(row.status == status, id .. " status was " .. tostring(row.status))
            return
        end
    end
    error("missing adapter row for " .. id)
end

local function main()
    ensure_ledger()
    local up = execute("up", {SECOND, FIRST})
    assert_row(up, FIRST, "applied")
    assert_row(up, SECOND, "applied")
    assert(ledger_has(DB, FIRST) and ledger_has(DB, SECOND), "up ledger rows missing")
    assert(table_exists("probe_users") and table_exists("probe_audit"), "up SQL tables missing")
    assert(not ledger_has(DB, EXCLUDED), "excluded migration entered ledger")
    assert(not table_exists("probe_excluded"), "excluded migration changed SQL")
    record("public_up")

    local repeated = execute("up", {FIRST})
    assert_row(repeated, FIRST, "skipped")
    record("public_repeat")

    local down = execute("down", {EXCLUDED, FIRST, SECOND})
    assert_row(down, FIRST, "reverted")
    assert_row(down, SECOND, "reverted")
    assert_row(down, EXCLUDED, "skipped")
    assert(not ledger_has(DB, FIRST) and not ledger_has(DB, SECOND), "down ledger rows remain")
    assert(not table_exists("probe_users") and not table_exists("probe_audit"), "down SQL tables remain")
    assert(not ledger_has(DB, EXCLUDED) and not table_exists("probe_excluded"), "excluded migration ran")
    record("public_down")

    local binding_source = migration_binding.source(captured)
    local binding_up, binding_up_problem = adapter.execute(binding_source, {
        operation = "up", entry_ids = {FIRST, SECOND}, components = {"acme/app"},
    })
    assert(not binding_up_problem and binding_up, tostring(binding_up_problem))
    assert_row(binding_up, FIRST, "applied")
    assert_row(binding_up, SECOND, "applied")
    record("binding_up")
    local binding_down, binding_down_problem = adapter.execute(binding_source, {
        operation = "down", entry_ids = {FIRST, SECOND}, components = {"acme/app"},
    })
    assert(not binding_down_problem and binding_down, tostring(binding_down_problem))
    assert_row(binding_down, FIRST, "reverted")
    assert_row(binding_down, SECOND, "reverted")
    record("binding_down")

    logger:info("REAL_MIGRATION_PROBE_PASS", {
        runner = "wippy/migration 0.3.17",
        up = "probe_users,probe_audit",
        down = "probe_users,probe_audit",
        excluded = EXCLUDED,
        ledger = "_migrations",
    })
end

return {main = main}
