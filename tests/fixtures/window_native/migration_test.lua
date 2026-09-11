-- The terminal exit-source rebuild carries existing placement rows and the
-- evidence foreign key without losing references.
local test = require("test")
local sql = require("sql")
local persist = require("persist")
local migrations = require("migrations")
local RESOURCE = "bee.window_native:upgrade_db"
local LEDGER = {table = "bee_window_native_schema_migrations", label = "window native"}
type Row = {[string]: unknown}

local function reset()
    local db, err = sql.get(RESOURCE)
    if not db then error(tostring(err)) end
    for _, statement in ipairs({"DROP TABLE IF EXISTS bee_placement_evidence", "DROP TABLE IF EXISTS bee_placement_attempts",
        "DROP TABLE IF EXISTS bee_placement_attempts_next", "DROP TABLE IF EXISTS " .. LEDGER.table}) do
        local _, drop_error = db:execute(statement)
        if drop_error then db:release(); error(statement .. ": " .. tostring(drop_error)) end
    end
    db:release()
end

local function open_with(count: integer): sql.DB
    local expected = migrations.all()
    local selected: {migrations.Migration} = {}
    for index = 1, count do selected[index] = expected[index] end
    local db, err = persist.open({resource = RESOURCE, ledger = LEDGER, migrations = selected})
    if not db then error("open with " .. tostring(count) .. ": " .. tostring(err)) end
    return db
end

local function one(db: sql.DB, statement: string): Row
    local rows, err = db:query(statement)
    if err or not rows or #rows ~= 1 then error(statement .. ": " .. tostring(err or "wrong row count")) end
    return rows[1] :: Row
end

local function run()
    reset()
    local v1 = open_with(1)
    local _, attempt_error = v1:execute([[INSERT INTO bee_placement_attempts
        (attempt_id, owner_id, owner_incarnation, action_id, idempotency_key, request_digest, request_json,
         execution_state, cleanup_state, capability, required_cleanup, exit_observation, evidence_count, created_at, updated_at)
        VALUES ('migration-attempt', 'migration-owner', 1, 'migration-action', 'migration-key', 'digest', '{}',
         'running', 'pending', 'direct_process', 'direct_process', 'eof_gated', 1, 'before', 'before')]])
    if attempt_error then v1:release(); error(tostring(attempt_error)) end
    local _, evidence_error = v1:execute([[INSERT INTO bee_placement_evidence (attempt_id, sequence, at, kind, detail)
        VALUES ('migration-attempt', 1, 'before', 'migration.before', 'retained evidence')]])
    if evidence_error then v1:release(); error(tostring(evidence_error)) end
    v1:release()

    local upgraded = open_with(2)
    local attempt = one(upgraded, "SELECT attempt_id, execution_state, evidence_count FROM bee_placement_attempts WHERE attempt_id = 'migration-attempt'")
    test.eq(attempt.attempt_id, "migration-attempt")
    test.eq(attempt.execution_state, "running")
    test.eq(attempt.evidence_count, 1)
    local evidence = one(upgraded, "SELECT e.attempt_id, e.sequence, e.detail FROM bee_placement_evidence e JOIN bee_placement_attempts a ON a.attempt_id = e.attempt_id WHERE e.attempt_id = 'migration-attempt'")
    test.eq(evidence.attempt_id, "migration-attempt")
    test.eq(evidence.sequence, 1)
    test.eq(evidence.detail, "retained evidence")
    test.eq(#(upgraded:query("PRAGMA foreign_key_check") :: {{[string]: unknown}}), 0)
    local _, terminal_error = upgraded:execute("UPDATE bee_placement_attempts SET exit_source = 'terminal' WHERE attempt_id = 'migration-attempt'")
    test.is_nil(terminal_error)
    upgraded:release()
end

return {run = run}
