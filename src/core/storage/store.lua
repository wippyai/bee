-- Durable workspace state owned by the workspace/session core.
--
-- The database resource is deliberately fixed here.  Its SQLite file and
-- lifecycle are configured by the root registry entry; callers cannot select
-- another database or table. Applications receive no import to this library;
-- the host's database policy also denies them access to the workspace store.
local sql = require("sql")
local json = require("json")
local hash = require("hash")

type Migration = {id: integer, name: string, sql: string}
type Store = {
    db: sql.DB,
    closed: boolean,
    generation: integer?,
    read: (Store) -> (string?, string?),
    write: (Store, string) -> (boolean, string?),
    close: (Store) -> (boolean, string?),
}

local M = {}

local DATABASE_ID = "bee:workspace_db"
local STATE_VERSION = 1
local MAX_STATE_BYTES = 2097152
local MIGRATION_TABLE = "workspace_schema_migrations"
local STATE_TABLE = "workspace_state"

-- This table is an append-only ledger from the library's point of view.  The
-- name and checksum are checked on every open, so editing an applied
-- migration cannot silently reinterpret an existing workspace.
local MIGRATION_TABLE_SQL = [[
CREATE TABLE IF NOT EXISTS workspace_schema_migrations (
    id INTEGER PRIMARY KEY CHECK (id > 0),
    name TEXT NOT NULL,
    checksum TEXT NOT NULL,
    applied_at TEXT NOT NULL,
    UNIQUE (name)
)
]]

local STATE_TABLE_SQL = [[
CREATE TABLE IF NOT EXISTS workspace_state (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    schema_version INTEGER NOT NULL CHECK (schema_version = 1),
    generation INTEGER NOT NULL CHECK (generation >= 0),
    value TEXT NOT NULL CHECK (length(CAST(value AS BLOB)) <= 2097152),
    updated_at TEXT NOT NULL
)
]]

local migrations: {Migration} = {
    {id = 1, name = "workspace_state_v1", sql = STATE_TABLE_SQL},
}

local function error_text(prefix: string, err: unknown): string
    if err == nil then return prefix end
    return prefix .. ": " .. tostring(err)
end

local function integer(value: unknown): integer?
    if type(value) ~= "number" or value ~= value or value ~= math.floor(value) then return nil end
    return math.floor(value)
end

local function increment_generation(value: integer?): integer
    if not value then return 1 end
    return value + 1
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

local function validate_state(encoded: string): (boolean, string?)
    if #encoded == 0 then return false, "workspace state must not be empty" end
    if #encoded > MAX_STATE_BYTES then
        return false, "workspace state exceeds 2097152 bytes"
    end

    local value: unknown, decode_err = json.decode(encoded)
    if decode_err then return false, error_text("decode workspace state", decode_err) end
    if type(value) ~= "table" then return false, "workspace state must be a JSON object" end
    if value.version ~= STATE_VERSION then
        return false, "unsupported workspace state version"
    end
    return true, nil
end

local function migration_map(): {[integer]: Migration}
    local result: {[integer]: Migration} = {}
    for _, migration in ipairs(migrations) do result[migration.id] = migration end
    return result
end

local function migrate(db: sql.DB): (boolean, string?)
    local tx, begin_err = db:begin()
    if not tx then return false, error_text("begin workspace migration", begin_err) end

    local _, create_err = tx:execute(MIGRATION_TABLE_SQL)
    if create_err then
        rollback(tx)
        return false, error_text("create workspace migration ledger", create_err)
    end

    local rows, query_err = tx:query(
        "SELECT id, name, checksum FROM workspace_schema_migrations ORDER BY id")
    if query_err or not rows then
        rollback(tx)
        return false, error_text("read workspace migration ledger", query_err)
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
            return false, "workspace migration ledger contains an invalid id"
        end
        if id ~= expected_id then
            rollback(tx)
            if id > #migrations then
                return false, "workspace database schema is newer than this Bee build"
            end
            return false, "workspace migration ledger has a missing migration"
        end
        if id > #migrations then
            rollback(tx)
            return false, "workspace database schema is newer than this Bee build"
        end
        local migration = by_id[id]
        if not migration or type(name) ~= "string" or type(checksum) ~= "string" then
            rollback(tx)
            return false, "workspace migration ledger is invalid"
        end
        local expected_checksum, checksum_err = migration_checksum(migration)
        if checksum_err or not expected_checksum then
            rollback(tx)
            return false, checksum_err or "workspace migration checksum is unavailable"
        end
        if name ~= migration.name then
            rollback(tx)
            return false, "workspace migration name changed for id " .. tostring(id)
        end
        if checksum ~= expected_checksum then
            rollback(tx)
            return false, "workspace migration checksum changed for id " .. tostring(id)
        end
        known[id] = true
        expected_id = expected_id + 1
    end

    for _, migration in ipairs(migrations) do
        if not known[migration.id] then
            local checksum, checksum_err = migration_checksum(migration)
            if checksum_err or not checksum then
                rollback(tx)
                return false, checksum_err or "workspace migration checksum is unavailable"
            end
            local _, apply_err = tx:execute(migration.sql)
            if apply_err then
                rollback(tx)
                return false, error_text("apply workspace migration " .. migration.name, apply_err)
            end
            local _, record_err = tx:execute(
                "INSERT INTO workspace_schema_migrations (id, name, checksum, applied_at) " ..
                "VALUES (?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))",
                {migration.id, migration.name, checksum})
            if record_err then
                rollback(tx)
                return false, error_text("record workspace migration " .. migration.name, record_err)
            end
        end
    end

    local _, commit_err = tx:commit()
    if commit_err then
        rollback(tx)
        return false, error_text("commit workspace migration", commit_err)
    end
    return true, nil
end

local function ensure_open(store: Store): string?
    if store.closed then return "workspace store is closed" end
    return nil
end

local function read_state(store: Store): (string?, string?)
    local closed_err = ensure_open(store)
    if closed_err then return nil, closed_err end

    local rows, query_err = store.db:query(
        "SELECT schema_version, generation, value FROM workspace_state WHERE singleton = 1")
    if query_err or not rows then
        return nil, error_text("read workspace state", query_err)
    end
    if #rows == 0 then
        store.generation = nil
        return nil, nil
    end
    if #rows ~= 1 then return nil, "workspace state singleton is corrupt" end

    local row = rows[1]
    local schema_version = integer(row.schema_version)
    local generation = integer(row.generation)
    local value: unknown = row.value
    if schema_version ~= STATE_VERSION or not generation or generation < 1 or type(value) ~= "string" then
        return nil, "workspace state row is corrupt"
    end
    local valid, validation_err = validate_state(value)
    if not valid then return nil, validation_err or "workspace state is invalid" end
    store.generation = generation
    return value, nil
end

local function write_state(store: Store, value: string): (boolean, string?)
    local closed_err = ensure_open(store)
    if closed_err then return false, closed_err end
    local valid, validation_err = validate_state(value)
    if not valid then return false, validation_err or "workspace state is invalid" end

    -- Pin the generation observed by this handle.  A writer must first read
    -- (open() performs that initial read) and cannot overwrite a commit made
    -- by another handle in the meantime.
    local expected_generation = store.generation
    local tx, begin_err = store.db:begin()
    if not tx then return false, error_text("begin workspace write", begin_err) end

    local rows, query_err = tx:query(
        "SELECT schema_version, generation, value FROM workspace_state WHERE singleton = 1")
    if query_err or not rows then
        rollback(tx)
        return false, error_text("read workspace state before write", query_err)
    end

    local next_generation = 1
    if #rows > 1 then
        rollback(tx)
        return false, "workspace state singleton is corrupt"
    elseif #rows == 1 then
        local row = rows[1]
        local schema_version = integer(row.schema_version)
        local generation = integer(row.generation)
        local current_value: unknown = row.value
        if schema_version ~= STATE_VERSION or not generation or generation < 1
            or type(current_value) ~= "string" then
            rollback(tx)
            return false, "workspace state row is corrupt"
        end
        if expected_generation == nil or generation ~= expected_generation then
            rollback(tx)
            return false, "workspace state changed since it was read"
        end
        local current_valid, current_err = validate_state(current_value)
        if not current_valid then
            rollback(tx)
            return false, current_err or "workspace state is invalid"
        end
        next_generation = increment_generation(generation)
        local result, update_err = tx:execute(
            "UPDATE workspace_state SET value = ?, generation = ?, updated_at = " ..
            "strftime('%Y-%m-%dT%H:%M:%fZ', 'now') " ..
            "WHERE singleton = 1 AND generation = ?",
            {value, next_generation, generation})
        if update_err or not result then
            rollback(tx)
            return false, error_text("write workspace state", update_err)
        end
        local affected = integer(result.rows_affected)
        if affected ~= 1 then
            rollback(tx)
            return false, "workspace state changed during write"
        end
    else
        if expected_generation ~= nil then
            rollback(tx)
            return false, "workspace state disappeared since it was read"
        end
        local _, insert_err = tx:execute(
            "INSERT INTO workspace_state (singleton, schema_version, generation, value, updated_at) " ..
            "VALUES (1, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))",
            {STATE_VERSION, next_generation, value})
        if insert_err then
            rollback(tx)
            return false, error_text("create workspace state", insert_err)
        end
    end

    local _, commit_err = tx:commit()
    if commit_err then
        rollback(tx)
        return false, error_text("commit workspace state", commit_err)
    end
    store.generation = next_generation
    return true, nil
end

local function close_store(store: Store): (boolean, string?)
    if store.closed then return true, nil end
    store.closed = true
    local ok, release_err = store.db:release()
    if release_err then return false, error_text("close workspace store", release_err) end
    return ok == true, nil
end

function M.open(): (Store?, string?)
    local db, acquire_err = sql.get(DATABASE_ID)
    if not db then return nil, error_text("open workspace database", acquire_err) end

    local db_type, type_err = db:type()
    if type_err or not db_type then
        db:release()
        return nil, error_text("inspect workspace database", type_err)
    end
    if db_type ~= sql.type.SQLITE then
        db:release()
        return nil, "workspace database must be SQLite"
    end

    local _, wal_err = db:execute("PRAGMA journal_mode = WAL")
    if wal_err then
        db:release()
        return nil, error_text("enable workspace WAL mode", wal_err)
    end
    local migrated, migration_err = migrate(db)
    if not migrated then
        db:release()
        return nil, migration_err or "workspace migration failed"
    end

    local store: Store = {
        db = db,
        closed = false,
        generation = nil,
        read = read_state,
        write = write_state,
        close = close_store,
    }
    local _, initial_read_err = read_state(store)
    if initial_read_err then
        store:close()
        return nil, initial_read_err
    end
    return store, nil
end

return M
