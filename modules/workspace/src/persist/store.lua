-- The node workspace catalog and the durable state of each workspace, keyed by workspace_id.
--
-- The host selects a reserved registry resource under an exact database policy.
-- Registry configuration owns its file and lifecycle. Applications cannot import
-- this library and their database boundary denies the reserved store namespaces.
local sql = require("sql")
local registry = require("registry")
local json = require("json")
local ledger = require("ledger")
local migrations = require("migrations")
local binding = require("binding")
local contract = require("contract")

type Store = {
    db: sql.DB,
    closed: boolean,
    workspace_id: string,
    generation: integer?,
    identity: (Store) -> (string?, string?),
    read: (Store) -> (string?, string?),
    write: (Store, string) -> (boolean, string?),
    close: (Store) -> (boolean, string?),
}

local M = {}

local STATE_VERSION = 1
local MAX_STATE_BYTES = 2097152
local MIGRATION_TABLE = "workspace_schema_migrations"

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

local function ensure_open(store: Store): string?
    if store.closed then return "workspace store is closed" end
    return nil
end

local function read_identity(store: Store): (string?, string?)
    local closed_err = ensure_open(store)
    if closed_err then return nil, closed_err end
    return store.workspace_id, nil
end

local function read_state(store: Store): (string?, string?)
    local closed_err = ensure_open(store)
    if closed_err then return nil, closed_err end

    local rows, query_err = store.db:query(
        "SELECT schema_version, generation, value FROM workspace_state WHERE workspace_id = ?", {store.workspace_id})
    if query_err or not rows then
        return nil, error_text("read workspace state", query_err)
    end
    if #rows == 0 then
        store.generation = nil
        return nil, nil
    end
    if #rows ~= 1 then return nil, "workspace state row is corrupt" end

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
        "SELECT schema_version, generation, value FROM workspace_state WHERE workspace_id = ?", {store.workspace_id})
    if query_err or not rows then
        rollback(tx)
        return false, error_text("read workspace state before write", query_err)
    end

    local next_generation = 1
    if #rows > 1 then
        rollback(tx)
        return false, "workspace state row is corrupt"
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
            "WHERE workspace_id = ? AND generation = ?",
            {value, next_generation, store.workspace_id, generation})
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
            "INSERT INTO workspace_state (workspace_id, schema_version, generation, value, updated_at) " ..
            "VALUES (?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))",
            {store.workspace_id, STATE_VERSION, next_generation, value})
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

-- Acquire and migrate the node workspace database. Every open verifies the
-- ledger, so a handle never runs against an unknown schema.
local function acquire(resource: string?): (sql.DB?, string?)
    local selected: unknown = resource
    if selected == nil then
        local entry = registry.get("bee.workspace.persist:store")
        local data = entry and entry.data
        selected = type(data) == "table" and data.database or nil
        if selected == nil then return nil, "Workspace database is not linked" end
    end
    local database_id, selection_error = binding.database("workspace", selected)
    if not database_id then return nil, selection_error end
    local db, acquire_err = sql.get(database_id)
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
    local _, busy_error = db:execute("PRAGMA busy_timeout = 5000")
    if busy_error then
        db:release()
        return nil, "configure migration busy timeout: " .. tostring(busy_error)
    end
    local migrated, migration_err = ledger.apply(db, {
        table = MIGRATION_TABLE, label = "workspace", transaction = "batch",
        freshness_table = "workspace_migration_run",
    }, migrations)
    if not migrated then
        db:release()
        return nil, migration_err or "workspace migration failed"
    end
    return db, nil
end

-- The folder workspace's catalog row: an unnamed, active row at the node's
-- workspace root, created with a fresh identity the first time the classic
-- launch path opens the folder, and only while workspace_folder records it as
-- not yet created.
local function create_folder(db: sql.DB): string?
    local tx, begin_err = db:begin()
    if not tx then return error_text("begin folder workspace creation", begin_err) end
    local claimed, claim_err = tx:execute("UPDATE workspace_folder SET created = 1 WHERE singleton = 1 AND created = 0")
    if claim_err or not claimed then
        rollback(tx)
        return error_text("claim the folder workspace", claim_err)
    end
    if integer(claimed.rows_affected) == 1 then
        local _, insert_err = tx:execute(
            "INSERT INTO workspaces (workspace_id, label, root_ref, subpath, state, created_at, last_used_at) " ..
            "VALUES (lower(hex(randomblob(16))), '', ?, '', 'active', strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), " ..
            "strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))",
            {binding.CLASSIC_ROOT})
        if insert_err then
            rollback(tx)
            return error_text("create the folder workspace", insert_err)
        end
    end
    local _, commit_err = tx:commit()
    if commit_err then
        rollback(tx)
        return error_text("commit folder workspace creation", commit_err)
    end
    return nil
end

-- Resolve a selection to exactly one active catalog row. Both forms are
-- unique-key probes and record that a host now uses the workspace. The folder
-- selection creates its row on first use.
local function resolve(db: sql.DB, selection: binding.Selection): (string?, string?)
    local rows: {{[string]: unknown}}?
    local query_err: unknown
    local function probe()
        if selection.workspace_id then
            rows, query_err = db:query("SELECT workspace_id, state FROM workspaces WHERE workspace_id = ?",
                {selection.workspace_id})
        else
            rows, query_err = db:query("SELECT workspace_id, state FROM workspaces WHERE root_ref = ? AND subpath = ?",
                {selection.root_ref, selection.subpath})
        end
    end
    probe()
    if not query_err and rows and #rows == 0 and binding.is_classic(selection) then
        local create_err = create_folder(db)
        if create_err then return nil, create_err end
        probe()
    end
    if query_err or not rows then return nil, error_text("read workspace catalog", query_err) end
    if #rows == 0 then return nil, "workspace is not in the node catalog" end
    if #rows ~= 1 then return nil, "workspace catalog row is corrupt" end
    local id = contract.workspace_id(rows[1].workspace_id)
    if not id then return nil, "workspace identity is invalid" end
    if rows[1].state ~= "active" then return nil, "workspace is not active" end
    local result, update_err = db:execute(
        "UPDATE workspaces SET last_used_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE workspace_id = ? AND state = 'active'",
        {id})
    if update_err or not result then return nil, error_text("record workspace use", update_err) end
    if integer(result.rows_affected) ~= 1 then return nil, "workspace changed while opening" end
    return id, nil
end

-- Open the workspace a host serves. The handle is bound to one catalog row;
-- every read and write it issues carries that workspace_id.
function M.open(resource: string?, value: unknown): (Store?, string?)
    local selection = binding.selection(value)
    if not selection then return nil, "Invalid workspace selection" end
    local db, acquire_err = acquire(resource)
    if not db then return nil, acquire_err end
    local workspace_id, resolve_err = resolve(db, selection)
    if not workspace_id then
        db:release()
        return nil, resolve_err
    end

    local store: Store = {
        db = db,
        closed = false,
        workspace_id = workspace_id,
        generation = nil,
        identity = read_identity,
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

-- The migrated node workspace database, for the catalog owner operations.
-- Callers release the handle.
function M.database(resource: string?): (sql.DB?, string?)
    return acquire(resource)
end

return M
