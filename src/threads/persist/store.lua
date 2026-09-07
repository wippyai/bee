-- Durable thread and run storage.  The caller supplies the actor selected by
-- the host's authenticated security context; this library does not infer it
-- from a payload, process ID, or registry metadata.
local sql = require("sql")
local json = require("json")
local hash = require("hash")

type Event = {
    seq: integer,
    run: string,
    key: string,
    kind: string,
    body: string,
}

type Store = {
    db: sql.DB,
    closed: boolean,
    claim: (Store, string, string, string) -> (boolean?, string?),
    append: (Store, string, string, string, string, string, string) -> (integer?, string?),
    read: (Store, string, string, integer) -> ({Event}?, string?),
    close: (Store) -> (boolean, string?),
}

type Migration = {id: integer, name: string, sql: string}

local M = {}

local DATABASE_ID = "bee.threads:db"

local MAX_TEXT_BYTES = 160
local MAX_BODY_BYTES = 16384
local MAX_EVENTS_PER_THREAD = 10000
local MAX_RUNS_PER_THREAD = 128
local MAX_READ_ROWS = 64

-- The migration text is part of its checksum.  All owned tables are created
-- together so the first production open cannot expose a partial thread schema.
local THREAD_SCHEMA_SQL = [[
CREATE TABLE IF NOT EXISTS bee_threads (
    thread_id TEXT PRIMARY KEY,
    actor TEXT NOT NULL,
    created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS bee_thread_runs (
    thread_id TEXT NOT NULL,
    run_id TEXT NOT NULL,
    actor TEXT NOT NULL,
    claimed_at TEXT NOT NULL,
    PRIMARY KEY (thread_id, run_id),
    FOREIGN KEY (thread_id) REFERENCES bee_threads(thread_id)
);
CREATE TABLE IF NOT EXISTS bee_thread_events (
    thread_id TEXT NOT NULL,
    sequence INTEGER NOT NULL CHECK (sequence > 0),
    run_id TEXT NOT NULL,
    idempotency_key TEXT NOT NULL,
    event_type TEXT NOT NULL,
    body_json TEXT NOT NULL,
    committed_at TEXT NOT NULL,
    PRIMARY KEY (thread_id, sequence),
    UNIQUE (thread_id, run_id, idempotency_key),
    FOREIGN KEY (thread_id, run_id) REFERENCES bee_thread_runs(thread_id, run_id)
)
]]

local migrations: {Migration} = {
    {id = 1, name = "bee_thread_schema_v1", sql = THREAD_SCHEMA_SQL},
}

local function database_error(prefix: string, _err: unknown): string
    -- Driver errors may include SQL, paths, or caller-controlled values.  Keep
    -- the storage boundary's failures short and independent of those details.
    return prefix
end

local function integer(value: unknown): integer?
    if type(value) ~= "number" then return nil end
    local result = math.floor(value)
    if value ~= result then return nil end
    return result
end

local function rollback(tx: sql.Transaction)
    tx:rollback()
end

local function commit(tx: sql.Transaction, prefix: string): (boolean, string?)
    local committed, commit_err = tx:commit()
    if commit_err or committed ~= true then
        rollback(tx)
        return false, database_error(prefix, commit_err)
    end
    return true, nil
end

local function migration_checksum(migration: Migration): (string?, string?)
    local digest, err = hash.sha256(migration.name .. "\n" .. migration.sql)
    if err or not digest then
        return nil, database_error("calculate thread migration checksum", err)
    end
    return digest, nil
end

local function migration_map(): {[integer]: Migration}
    local result: {[integer]: Migration} = {}
    for _, migration in ipairs(migrations) do result[migration.id] = migration end
    return result
end

local function migrate(db: sql.DB): (boolean, string?)
    local tx, begin_err = db:begin({isolation = sql.isolation.SERIALIZABLE})
    if not tx then return false, database_error("begin thread migration", begin_err) end

    local _, create_err = tx:execute([[
CREATE TABLE IF NOT EXISTS bee_thread_schema_migrations (
    id INTEGER PRIMARY KEY CHECK (id > 0),
    name TEXT NOT NULL,
    checksum TEXT NOT NULL,
    applied_at TEXT NOT NULL,
    UNIQUE (name)
)
]])
    if create_err then
        rollback(tx)
        return false, database_error("create thread migration ledger", create_err)
    end

    local rows, query_err = tx:query(
        "SELECT id, name, checksum FROM bee_thread_schema_migrations ORDER BY id")
    if query_err or not rows then
        rollback(tx)
        return false, database_error("read thread migration ledger", query_err)
    end

    local known: {[integer]: boolean} = {}
    local by_id = migration_map()
    local expected_id = 1
    for _, row in ipairs(rows) do
        local id = integer(row.id)
        local name: unknown = row.name
        local checksum: unknown = row.checksum
        if not id or id < 1 then
            rollback(tx)
            return false, "thread migration ledger is invalid"
        end
        if id ~= expected_id then
            rollback(tx)
            if id > #migrations then
                return false, "thread database schema is newer"
            end
            return false, "thread migration ledger has a gap"
        end
        if id > #migrations then
            rollback(tx)
            return false, "thread database schema is newer"
        end

        local migration = by_id[id]
        if not migration or type(name) ~= "string" or type(checksum) ~= "string" then
            rollback(tx)
            return false, "thread migration ledger is invalid"
        end
        local expected_checksum, checksum_err = migration_checksum(migration)
        if checksum_err or not expected_checksum then
            rollback(tx)
            return false, checksum_err or "thread migration checksum unavailable"
        end
        if name ~= migration.name then
            rollback(tx)
            return false, "thread migration name changed"
        end
        if checksum ~= expected_checksum then
            rollback(tx)
            return false, "thread migration checksum changed"
        end
        known[id] = true
        expected_id = expected_id + 1
    end

    for _, migration in ipairs(migrations) do
        if not known[migration.id] then
            local checksum, checksum_err = migration_checksum(migration)
            if checksum_err or not checksum then
                rollback(tx)
                return false, checksum_err or "thread migration checksum unavailable"
            end
            local _, apply_err = tx:execute(migration.sql)
            if apply_err then
                rollback(tx)
                return false, database_error("apply thread migration", apply_err)
            end
            local _, record_err = tx:execute(
                "INSERT INTO bee_thread_schema_migrations (id, name, checksum, applied_at) " ..
                "VALUES (?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))",
                {migration.id, migration.name, checksum})
            if record_err then
                rollback(tx)
                return false, database_error("record thread migration", record_err)
            end
        end
    end

    return commit(tx, "commit thread migration")
end

local function ensure_open(store: Store): string?
    if store.closed then return "thread store is closed" end
    return nil
end

local function valid_text(value: unknown, field: string): (boolean, string?)
    if type(value) ~= "string" then return false, "invalid " .. field end
    if #value == 0 then return false, field .. " must not be empty" end
    if #value > MAX_TEXT_BYTES then
        return false, field .. " exceeds " .. tostring(MAX_TEXT_BYTES) .. " bytes"
    end
    if value:find("%c") then return false, field .. " contains a control character" end
    return true, nil
end

local function valid_body(value: unknown): (boolean, string?)
    if type(value) ~= "string" then return false, "invalid event body" end
    if #value == 0 then return false, "event body must not be empty" end
    if #value > MAX_BODY_BYTES then
        return false, "event body exceeds " .. tostring(MAX_BODY_BYTES) .. " bytes"
    end
    local _, decode_err = json.decode(value)
    if decode_err then return false, "event body is not valid JSON" end
    return true, nil
end

local function validate_claim(actor: string, thread: string, run: string): (boolean, string?)
    local fields: {{value: unknown, name: string}} = {
        {value = actor, name = "actor"},
        {value = thread, name = "thread"},
        {value = run, name = "run"},
    }
    for _, field in ipairs(fields) do
        local valid, err = valid_text(field.value, field.name)
        if not valid then return false, err end
    end
    return true, nil
end

local function validate_append(
    actor: string, thread: string, run: string, key: string, kind: string, body_json: string
): (boolean, string?)
    local valid_claim, claim_err = validate_claim(actor, thread, run)
    if not valid_claim then return false, claim_err end
    local text_fields: {{value: unknown, name: string}} = {
        {value = key, name = "event key"},
        {value = kind, name = "event kind"},
    }
    for _, field in ipairs(text_fields) do
        local valid, err = valid_text(field.value, field.name)
        if not valid then return false, err end
    end
    return valid_body(body_json)
end

local function claim_run(store: Store, actor: string, thread: string, run: string): (boolean?, string?)
    local closed_err = ensure_open(store)
    if closed_err then return nil, closed_err end
    local valid, validation_err = validate_claim(actor, thread, run)
    if not valid then return nil, validation_err or "invalid thread claim" end

    local tx, begin_err = store.db:begin({isolation = sql.isolation.SERIALIZABLE})
    if not tx then return nil, database_error("begin thread claim", begin_err) end

    local threads, thread_err = tx:query(
        "SELECT actor FROM bee_threads WHERE thread_id = ?", {thread})
    if thread_err or not threads then
        rollback(tx)
        return nil, database_error("read thread owner", thread_err)
    end
    if #threads > 1 then
        rollback(tx)
        return nil, "thread owner row is corrupt"
    end
    if #threads == 1 then
        local owner: unknown = threads[1].actor
        if type(owner) ~= "string" then
            rollback(tx)
            return nil, "thread owner row is corrupt"
        end
        if owner ~= actor then
            rollback(tx)
            return nil, "thread access denied"
        end
    else
        local _, insert_thread_err = tx:execute(
            "INSERT INTO bee_threads (thread_id, actor, created_at) " ..
            "VALUES (?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))",
            {thread, actor})
        if insert_thread_err then
            rollback(tx)
            return nil, database_error("create thread", insert_thread_err)
        end
    end

    local runs, run_err = tx:query(
        "SELECT actor FROM bee_thread_runs WHERE thread_id = ? AND run_id = ?",
        {thread, run})
    if run_err or not runs then
        rollback(tx)
        return nil, database_error("read thread run", run_err)
    end
    if #runs > 1 then
        rollback(tx)
        return nil, "thread run rows are corrupt"
    end
    if #runs == 1 then
        local run_actor: unknown = runs[1].actor
        if type(run_actor) ~= "string" then
            rollback(tx)
            return nil, "thread run row is corrupt"
        end
        if run_actor ~= actor then
            rollback(tx)
            return nil, "thread run access denied"
        end
        local committed, commit_err = commit(tx, "commit duplicate thread claim")
        if not committed then return nil, commit_err end
        return false, nil
    end

    local counts, count_err = tx:query(
        "SELECT COUNT(*) AS count FROM bee_thread_runs WHERE thread_id = ?", {thread})
    if count_err or not counts or #counts ~= 1 then
        rollback(tx)
        return nil, database_error("count thread runs", count_err)
    end
    local count = integer(counts[1].count)
    if not count then
        rollback(tx)
        return nil, "thread run count is corrupt"
    end
    if count >= MAX_RUNS_PER_THREAD then
        rollback(tx)
        return nil, "thread run limit reached"
    end

    local _, insert_run_err = tx:execute(
        "INSERT INTO bee_thread_runs (thread_id, run_id, actor, claimed_at) " ..
        "VALUES (?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))",
        {thread, run, actor})
    if insert_run_err then
        rollback(tx)
        return nil, database_error("claim thread run", insert_run_err)
    end

    local committed, commit_err = commit(tx, "commit thread claim")
    if not committed then return nil, commit_err end
    return true, nil
end

local function append_event(
    store: Store, actor: string, thread: string, run: string, key: string, kind: string, body_json: string
): (integer?, string?)
    local closed_err = ensure_open(store)
    if closed_err then return nil, closed_err end
    local valid, validation_err = validate_append(actor, thread, run, key, kind, body_json)
    if not valid then return nil, validation_err or "invalid thread event" end

    local tx, begin_err = store.db:begin({isolation = sql.isolation.SERIALIZABLE})
    if not tx then return nil, database_error("begin event append", begin_err) end

    local threads, thread_err = tx:query(
        "SELECT actor FROM bee_threads WHERE thread_id = ?", {thread})
    if thread_err or not threads then
        rollback(tx)
        return nil, database_error("read thread owner", thread_err)
    end
    if #threads ~= 1 then
        rollback(tx)
        if #threads == 0 then return nil, "thread access denied" end
        return nil, "thread owner rows are corrupt"
    end
    local owner: unknown = threads[1].actor
    if type(owner) ~= "string" then
        rollback(tx)
        return nil, "thread owner row is corrupt"
    end
    if owner ~= actor then
        rollback(tx)
        return nil, "thread access denied"
    end

    local runs, run_err = tx:query(
        "SELECT actor FROM bee_thread_runs WHERE thread_id = ? AND run_id = ?",
        {thread, run})
    if run_err or not runs then
        rollback(tx)
        return nil, database_error("read thread run", run_err)
    end
    if #runs ~= 1 then
        rollback(tx)
        if #runs == 0 then return nil, "thread run is not claimed" end
        return nil, "thread run rows are corrupt"
    end
    local run_actor: unknown = runs[1].actor
    if type(run_actor) ~= "string" then
        rollback(tx)
        return nil, "thread run row is corrupt"
    end
    if run_actor ~= actor then
        rollback(tx)
        return nil, "thread run access denied"
    end

    local existing, existing_err = tx:query(
        "SELECT sequence, event_type, body_json FROM bee_thread_events " ..
        "WHERE thread_id = ? AND run_id = ? AND idempotency_key = ?",
        {thread, run, key})
    if existing_err or not existing then
        rollback(tx)
        return nil, database_error("read event dedupe key", existing_err)
    end
    if #existing > 1 then
        rollback(tx)
        return nil, "thread event dedupe rows are corrupt"
    end
    if #existing == 1 then
        local row = existing[1]
        local old_seq = integer(row.sequence)
        local old_kind: unknown = row.event_type
        local old_body: unknown = row.body_json
        if not old_seq or old_seq < 1 or type(old_kind) ~= "string" or type(old_body) ~= "string" then
            rollback(tx)
            return nil, "thread event row is corrupt"
        end
        if old_kind ~= kind or old_body ~= body_json then
            rollback(tx)
            return nil, "event key conflicts with existing body"
        end
        local committed, commit_err = commit(tx, "commit duplicate event lookup")
        if not committed then return nil, commit_err end
        return old_seq, nil
    end

    local counts, count_err = tx:query(
        "SELECT COUNT(*) AS count FROM bee_thread_events WHERE thread_id = ?", {thread})
    if count_err or not counts or #counts ~= 1 then
        rollback(tx)
        return nil, database_error("count thread events", count_err)
    end
    local count = integer(counts[1].count)
    if not count then
        rollback(tx)
        return nil, "thread event count is corrupt"
    end
    if count >= MAX_EVENTS_PER_THREAD then
        rollback(tx)
        return nil, "thread event limit reached"
    end

    local next_rows, next_err = tx:query(
        "SELECT COALESCE(MAX(sequence), 0) + 1 AS next_sequence " ..
        "FROM bee_thread_events WHERE thread_id = ?", {thread})
    if next_err or not next_rows or #next_rows ~= 1 then
        rollback(tx)
        return nil, database_error("allocate thread sequence", next_err)
    end
    local next_sequence = integer(next_rows[1].next_sequence)
    if not next_sequence or next_sequence < 1 then
        rollback(tx)
        return nil, "thread sequence is corrupt"
    end

    local _, insert_err = tx:execute(
        "INSERT INTO bee_thread_events " ..
        "(thread_id, sequence, run_id, idempotency_key, event_type, body_json, committed_at) " ..
        "VALUES (?, ?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))",
        {thread, next_sequence, run, key, kind, body_json})
    if insert_err then
        rollback(tx)
        return nil, database_error("append thread event", insert_err)
    end

    local committed, commit_err = commit(tx, "commit thread event")
    if not committed then return nil, commit_err end
    return next_sequence, nil
end

local function read_events(store: Store, actor: string, thread: string, after: integer): ({Event}?, string?)
    local closed_err = ensure_open(store)
    if closed_err then return nil, closed_err end
    local valid_claim_fields, validation_err = validate_claim(actor, thread, "read")
    if not valid_claim_fields then return nil, validation_err or "invalid thread read" end
    if after < 0 or after ~= math.floor(after) then
        return nil, "after cursor must be a nonnegative integer"
    end

    local threads, thread_err = store.db:query(
        "SELECT actor FROM bee_threads WHERE thread_id = ?", {thread})
    if thread_err or not threads then
        return nil, database_error("read thread owner", thread_err)
    end
    if #threads ~= 1 then
        if #threads == 0 then return nil, "thread access denied" end
        return nil, "thread owner rows are corrupt"
    end
    local owner: unknown = threads[1].actor
    if type(owner) ~= "string" then return nil, "thread owner row is corrupt" end
    if owner ~= actor then return nil, "thread access denied" end

    local rows, query_err = store.db:query(
        "SELECT sequence, run_id, idempotency_key, event_type, body_json " ..
        "FROM bee_thread_events WHERE thread_id = ? AND sequence > ? " ..
        "ORDER BY sequence LIMIT ?", {thread, after, MAX_READ_ROWS})
    if query_err or not rows then
        return nil, database_error("read thread events", query_err)
    end

    local result: {Event} = {}
    for _, row in ipairs(rows) do
        local sequence = integer(row.sequence)
        local run: unknown = row.run_id
        local key: unknown = row.idempotency_key
        local kind: unknown = row.event_type
        local body: unknown = row.body_json
        if not sequence or sequence < 1 or type(run) ~= "string" or type(key) ~= "string"
            or type(kind) ~= "string" or type(body) ~= "string" then
            return nil, "thread event row is corrupt"
        end
        result[#result + 1] = {
            seq = sequence,
            run = run,
            key = key,
            kind = kind,
            body = body,
        }
    end
    return result, nil
end

local function close_store(store: Store): (boolean, string?)
    if store.closed then return true, nil end
    store.closed = true
    local released, release_err = store.db:release()
    if release_err or released ~= true then
        return false, database_error("close thread database", release_err)
    end
    return true, nil
end

function M.open(): (Store?, string?)
    local db, acquire_err = sql.get(DATABASE_ID)
    if not db then return nil, database_error("open thread database", acquire_err) end

    local db_type, type_err = db:type()
    if type_err or not db_type then
        db:release()
        return nil, database_error("inspect thread database", type_err)
    end
    if db_type ~= sql.type.SQLITE then
        db:release()
        return nil, "thread database must be SQLite"
    end

    local _, wal_err = db:execute("PRAGMA journal_mode = WAL")
    if wal_err then
        db:release()
        return nil, database_error("enable thread WAL mode", wal_err)
    end
    local migrated, migration_err = migrate(db)
    if not migrated then
        db:release()
        return nil, migration_err or "thread migration failed"
    end

    local store: Store = {
        db = db,
        closed = false,
        claim = claim_run,
        append = append_event,
        read = read_events,
        close = close_store,
    }
    return store, nil
end

return M
