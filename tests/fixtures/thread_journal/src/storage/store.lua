-- Bee thread prototype storage.  This library owns only the fixture database;
-- authentication and participant admission belong to its coordinator.
local sql = require("sql")
local json = require("json")
local hash = require("hash")

type Event = {
    seq: integer,
    source: string,
    key: string,
    kind: string,
    body: string,
}

type Store = {
    db: sql.DB,
    closed: boolean,
    append: (Store, string, string, string, string, string) -> (integer?, string?),
    read: (Store, string, integer) -> ({Event}?, string?),
    close: (Store) -> (boolean, string?),
}

type Migration = {id: integer, name: string, sql: string}

local M = {}

local DATABASE_ID = "bee.thread.demo:db"
local MIGRATION_TABLE = "thread_demo_schema_migrations"
local MAX_TEXT_BYTES = 256
local MAX_BODY_BYTES = 16384
local MAX_EVENTS_PER_THREAD = 10000
local MAX_READ_ROWS = 64

-- The migration text is part of the checksum.  Applied entries are checked on
-- every open so a local database cannot silently acquire a different schema.
local EVENTS_TABLE_SQL = [[
CREATE TABLE IF NOT EXISTS thread_demo_events (
    thread_id TEXT NOT NULL,
    sequence INTEGER NOT NULL CHECK (sequence > 0),
    source TEXT NOT NULL,
    idempotency_key TEXT NOT NULL,
    event_type TEXT NOT NULL,
    body_json TEXT NOT NULL,
    committed_at TEXT NOT NULL,
    PRIMARY KEY (thread_id, sequence),
    UNIQUE (thread_id, source, idempotency_key)
)
]]

local migrations: {Migration} = {
    {
        id = 1,
        name = "thread_demo_events_v1",
        sql = EVENTS_TABLE_SQL,
    },
}

local function error_text(prefix: string, err: unknown): string
    if err == nil then return prefix end
    return prefix .. ": " .. tostring(err)
end

local function integer(value: unknown): integer?
    if type(value) ~= "number" or value ~= value or value ~= math.floor(value) then return nil end
    return math.floor(value)
end

local function rollback(tx: sql.Transaction)
    tx:rollback()
end

local function migration_checksum(migration: Migration): (string?, string?)
    local digest, err = hash.sha256(migration.name .. "\n" .. migration.sql)
    if err or not digest then
        return nil, error_text("calculate migration checksum", err)
    end
    return digest, nil
end

local function migrate(db: sql.DB): (boolean, string?)
    local tx, begin_err = db:begin({isolation = sql.isolation.SERIALIZABLE})
    if not tx then return false, error_text("begin thread migration", begin_err) end

    local _, create_err = tx:execute([[
CREATE TABLE IF NOT EXISTS thread_demo_schema_migrations (
    id INTEGER PRIMARY KEY CHECK (id > 0),
    name TEXT NOT NULL,
    checksum TEXT NOT NULL,
    applied_at TEXT NOT NULL,
    UNIQUE (name)
)
]])
    if create_err then
        rollback(tx)
        return false, error_text("create thread migration ledger", create_err)
    end

    local rows, query_err = tx:query(
        "SELECT id, name, checksum FROM thread_demo_schema_migrations ORDER BY id")
    if query_err or not rows then
        rollback(tx)
        return false, error_text("read thread migration ledger", query_err)
    end

    local known: {[integer]: boolean} = {}
    local by_id: {[integer]: Migration} = {}
    for _, migration in ipairs(migrations) do by_id[migration.id] = migration end

    local expected_id = 1
    for _, row in ipairs(rows) do
        local id = integer(row.id)
        local name: unknown = row.name
        local checksum: unknown = row.checksum
        if not id or id < 1 then
            rollback(tx)
            return false, "thread migration ledger contains an invalid id"
        end
        if id ~= expected_id then
            rollback(tx)
            if id > #migrations then
                return false, "thread database schema is newer than this prototype"
            end
            return false, "thread migration ledger has a missing migration"
        end
        if id > #migrations then
            rollback(tx)
            return false, "thread database schema is newer than this prototype"
        end

        local migration = by_id[id]
        if not migration or type(name) ~= "string" or type(checksum) ~= "string" then
            rollback(tx)
            return false, "thread migration ledger is invalid"
        end
        local expected_checksum, checksum_err = migration_checksum(migration)
        if checksum_err or not expected_checksum then
            rollback(tx)
            return false, checksum_err or "thread migration checksum is unavailable"
        end
        if name ~= migration.name then
            rollback(tx)
            return false, "thread migration name changed for id " .. tostring(id)
        end
        if checksum ~= expected_checksum then
            rollback(tx)
            return false, "thread migration checksum changed for id " .. tostring(id)
        end
        known[id] = true
        expected_id = expected_id + 1
    end

    for _, migration in ipairs(migrations) do
        if not known[migration.id] then
            local checksum, checksum_err = migration_checksum(migration)
            if checksum_err or not checksum then
                rollback(tx)
                return false, checksum_err or "thread migration checksum is unavailable"
            end
            local _, apply_err = tx:execute(migration.sql)
            if apply_err then
                rollback(tx)
                return false, error_text("apply thread migration " .. migration.name, apply_err)
            end
            local _, record_err = tx:execute(
                "INSERT INTO thread_demo_schema_migrations (id, name, checksum, applied_at) " ..
                "VALUES (?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))",
                {migration.id, migration.name, checksum})
            if record_err then
                rollback(tx)
                return false, error_text("record thread migration " .. migration.name, record_err)
            end
        end
    end

    local committed, commit_err = tx:commit()
    if commit_err or not committed then
        rollback(tx)
        return false, error_text("commit thread migration", commit_err)
    end
    return true, nil
end

local function ensure_open(store: Store): string?
    if store.closed then return "thread store is closed" end
    return nil
end

local function valid_text(value: string, field: string): (boolean, string?)
    if #value == 0 then return false, field .. " must not be empty" end
    if #value > MAX_TEXT_BYTES then
        return false, field .. " exceeds " .. tostring(MAX_TEXT_BYTES) .. " bytes"
    end
    return true, nil
end

local function validate_append(
    thread_id: string, source: string, key: string, event_type: string, body_json: string
): (boolean, string?)
    local fields: {{value: string, name: string}} = {
        {value = thread_id, name = "thread_id"},
        {value = source, name = "source"},
        {value = key, name = "idempotency key"},
        {value = event_type, name = "event type"},
    }
    for _, field in ipairs(fields) do
        local valid, err = valid_text(field.value, field.name)
        if not valid then return false, err end
    end
    if #body_json == 0 then return false, "event body must not be empty" end
    if #body_json > MAX_BODY_BYTES then
        return false, "event body exceeds " .. tostring(MAX_BODY_BYTES) .. " bytes"
    end
    local _, decode_err = json.decode(body_json)
    if decode_err then return false, error_text("decode event body", decode_err) end
    return true, nil
end

local function append_event(
    store: Store, thread_id: string, source: string, key: string, event_type: string, body_json: string
): (integer?, string?)
    local closed_err = ensure_open(store)
    if closed_err then return nil, closed_err end
    local valid, validation_err = validate_append(thread_id, source, key, event_type, body_json)
    if not valid then return nil, validation_err or "invalid event" end

    -- SQLite serializable transactions serialize the MAX(sequence)+1 read with
    -- the insert.  The unique idempotency key handles retries atomically.
    local tx, begin_err = store.db:begin({isolation = sql.isolation.SERIALIZABLE})
    if not tx then return nil, error_text("begin event append", begin_err) end

    local existing, existing_err = tx:query(
        "SELECT sequence, event_type, body_json FROM thread_demo_events " ..
        "WHERE thread_id = ? AND source = ? AND idempotency_key = ?",
        {thread_id, source, key})
    if existing_err or not existing then
        rollback(tx)
        return nil, error_text("read event dedupe key", existing_err)
    end
    if #existing > 1 then
        rollback(tx)
        return nil, "thread event dedupe key is corrupt"
    end
    if #existing == 1 then
        local row = existing[1]
        local old_seq = integer(row.sequence)
        local old_type: unknown = row.event_type
        local old_body: unknown = row.body_json
        if not old_seq or type(old_type) ~= "string" or type(old_body) ~= "string" then
            rollback(tx)
            return nil, "thread event row is corrupt"
        end
        if old_type ~= event_type or old_body ~= body_json then
            rollback(tx)
            return nil, "event idempotency key conflicts with an existing body"
        end
        local committed, commit_err = tx:commit()
        if commit_err or not committed then
            rollback(tx)
            return nil, error_text("commit duplicate event lookup", commit_err)
        end
        return old_seq, nil
    end

    local counts, count_err = tx:query(
        "SELECT COUNT(*) AS count FROM thread_demo_events WHERE thread_id = ?", {thread_id})
    if count_err or not counts or #counts ~= 1 then
        rollback(tx)
        return nil, error_text("count thread events", count_err)
    end
    local count = integer(counts[1].count)
    if not count then
        rollback(tx)
        return nil, "thread event count is corrupt"
    end
    if count >= MAX_EVENTS_PER_THREAD then
        rollback(tx)
        return nil, "thread event limit of " .. tostring(MAX_EVENTS_PER_THREAD) .. " reached"
    end

    local next_rows, next_err = tx:query(
        "SELECT COALESCE(MAX(sequence), 0) + 1 AS next_sequence " ..
        "FROM thread_demo_events WHERE thread_id = ?",
        {thread_id})
    if next_err or not next_rows or #next_rows ~= 1 then
        rollback(tx)
        return nil, error_text("allocate thread sequence", next_err)
    end
    local next_sequence = integer(next_rows[1].next_sequence)
    if not next_sequence or next_sequence < 1 then
        rollback(tx)
        return nil, "thread sequence is corrupt"
    end

    local _, insert_err = tx:execute(
        "INSERT INTO thread_demo_events " ..
        "(thread_id, sequence, source, idempotency_key, event_type, body_json, committed_at) " ..
        "VALUES (?, ?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))",
        {thread_id, next_sequence, source, key, event_type, body_json})
    if insert_err then
        rollback(tx)
        return nil, error_text("append thread event", insert_err)
    end

    local committed, commit_err = tx:commit()
    if commit_err or not committed then
        rollback(tx)
        return nil, error_text("commit thread event", commit_err)
    end
    return next_sequence, nil
end

local function read_events(store: Store, thread_id: string, after: integer): ({Event}?, string?)
    local closed_err = ensure_open(store)
    if closed_err then return nil, closed_err end
    local valid, validation_err = valid_text(thread_id, "thread_id")
    if not valid then return nil, validation_err or "invalid thread_id" end
    if after < 0 or after ~= math.floor(after) then return nil, "after cursor must be a nonnegative integer" end

    local rows, query_err = store.db:query(
        "SELECT sequence, source, idempotency_key, event_type, body_json " ..
        "FROM thread_demo_events WHERE thread_id = ? AND sequence > ? " ..
        "ORDER BY sequence LIMIT ?",
        {thread_id, after, MAX_READ_ROWS})
    if query_err or not rows then
        return nil, error_text("read thread events", query_err)
    end

    local result: {Event} = {}
    for _, row in ipairs(rows) do
        local sequence = integer(row.sequence)
        local source: unknown = row.source
        local key: unknown = row.idempotency_key
        local event_type: unknown = row.event_type
        local body: unknown = row.body_json
        if not sequence or type(source) ~= "string" or type(key) ~= "string"
            or type(event_type) ~= "string" or type(body) ~= "string" then
            return nil, "thread event row is corrupt"
        end
        result[#result + 1] = {
            seq = sequence,
            source = source,
            key = key,
            kind = event_type,
            body = body,
        }
    end
    return result, nil
end

local function close_store(store: Store): (boolean, string?)
    if store.closed then return true, nil end
    store.closed = true
    local released, release_err = store.db:release()
    if release_err then return false, error_text("close thread database", release_err) end
    return released == true, nil
end

function M.open(): (Store?, string?)
    local db, acquire_err = sql.get(DATABASE_ID)
    if not db then return nil, error_text("open thread database", acquire_err) end

    local db_type, type_err = db:type()
    if type_err or not db_type then
        db:release()
        return nil, error_text("inspect thread database", type_err)
    end
    if db_type ~= sql.type.SQLITE then
        db:release()
        return nil, "thread database must be SQLite"
    end

    local _, wal_err = db:execute("PRAGMA journal_mode = WAL")
    if wal_err then
        db:release()
        return nil, error_text("enable thread WAL mode", wal_err)
    end
    local migrated, migration_err = migrate(db)
    if not migrated then
        db:release()
        return nil, migration_err or "thread migration failed"
    end

    local store: Store = {
        db = db,
        closed = false,
        append = append_event,
        read = read_events,
        close = close_store,
    }
    return store, nil
end

return M
