-- MIT. Host-selected client database; no workspace checkpoint or registry publication.
local sql = require("sql")
local json = require("json")
local hash = require("hash")
local state = require("state")
local contract = require("contract")
local binding = require("binding")
type Row = {client_id: string, generation: integer, value: state.State?, workspace_id: string, receipt: string}
type Store = {
    db: sql.DB, closed: boolean, client_id: string, generation: integer,
}
local M = {}
type Migration = {id: integer, name: string, sql: string}
local SCHEMA = [[
CREATE TABLE client_state (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    client_id TEXT NOT NULL CHECK (length(client_id) = 32 AND client_id NOT GLOB '*[^0-9a-f]*'),
    generation INTEGER NOT NULL CHECK (generation >= 0),
    value TEXT CHECK (value IS NULL OR length(CAST(value AS BLOB)) <= 2097152),
    import_workspace TEXT NOT NULL DEFAULT '',
    import_receipt TEXT NOT NULL DEFAULT ''
);
INSERT INTO client_state (singleton, client_id, generation)
VALUES (1, lower(hex(randomblob(16))), 0)
]]
local migrations: {Migration} = {{id = 1, name = "client_layout_v1", sql = SCHEMA}}
local LEDGER = [[
CREATE TABLE IF NOT EXISTS client_schema_migrations (
    id INTEGER PRIMARY KEY CHECK (id > 0),
    name TEXT NOT NULL UNIQUE,
    checksum TEXT NOT NULL
)
]]
local function migrate(db: sql.DB): (boolean, string?)
    local tx, begin_error = db:begin()
    if not tx then return false, tostring(begin_error) end
    local function fail(message: string): (boolean, string?)
        tx:rollback()
        return false, message
    end
    local _, create_error = tx:execute(LEDGER)
    if create_error then return fail(tostring(create_error)) end
    local rows, read_error = tx:query("SELECT id, name, checksum FROM client_schema_migrations ORDER BY id")
    if not rows then return fail(tostring(read_error)) end
    if #rows > #migrations then return fail("Client database schema is newer than this Bee build") end
    for index, migration in ipairs(migrations) do
        local checksum, hash_error = hash.sha256(migration.name .. "\n" .. migration.sql)
        if not checksum then return fail(tostring(hash_error)) end
        if index <= #rows then
            local applied = rows[index]
            if applied.id ~= migration.id or applied.name ~= migration.name or applied.checksum ~= checksum then
                return fail("Client migration ledger is newer or has changed")
            end
        else
            local _, apply_error = tx:execute(migration.sql)
            if apply_error then return fail(tostring(apply_error)) end
            local _, record_error = tx:execute("INSERT INTO client_schema_migrations (id, name, checksum) VALUES (?, ?, ?)", {migration.id, migration.name, checksum})
            if record_error then return fail(tostring(record_error)) end
        end
    end
    local _, commit_error = tx:commit()
    if commit_error then return fail(tostring(commit_error)) end
    return true, nil
end
local function row(db: sql.DB): (Row?, string?)
    local rows, err = db:query("SELECT singleton, client_id, generation, value, import_workspace, import_receipt FROM client_state")
    if not rows then return nil, tostring(err) end
    if #rows ~= 1 then return nil, "Client identity row is corrupt" end
    local value = rows[1]
    local identity = contract.workspace_id(value.client_id)
    local generation: unknown = value.generation
    local workspace_id, receipt = contract.text(value.import_workspace, 32), contract.text(value.import_receipt, 32)
    if not identity then return nil, "Client identity is corrupt" end
    if not workspace_id or not receipt then return nil, "Client import fields are corrupt" end
    if value.singleton ~= 1 or type(generation) ~= "number" or generation < 0
        or generation > 9007199254740990 or generation ~= math.floor(generation) then return nil, "Client state row is corrupt" end
    local result: Row = {client_id = identity, generation = math.floor(generation), value = nil, workspace_id = workspace_id, receipt = receipt}
    if (workspace_id == "") ~= (receipt == "") then return nil, "Client import receipt is corrupt" end
    if workspace_id ~= "" and (not contract.workspace_id(workspace_id) or not contract.workspace_id(receipt)) then return nil, "Client import identity is corrupt" end
    local saved: state.State? = nil
    if value.value ~= nil then
        local encoded: unknown = value.value
        if type(encoded) ~= "string" or #encoded > 2097152 or generation < 1 then return nil, "Client layout is corrupt" end
        saved = state.decode(json.decode(encoded))
        if not saved then return nil, "Unsupported or corrupt client layout" end
    elseif generation ~= 0 or receipt ~= "" then return nil, "Client layout disappeared" end
    result.value = saved
    return result, nil
end
function M.read(store: Store): (state.State?, string?)
    if store.closed then return nil, "Client store is closed" end
    local current, err = row(store.db)
    if not current then return nil, err end
    if current.client_id ~= store.client_id then return nil, "Client identity changed" end
    store.generation = current.generation
    return current.value, nil
end
local function encode(value: state.State): (string?, string?)
    local checked = state.decode(value)
    if not checked then return nil, "Invalid client layout" end
    local encoded, err = json.encode(checked)
    if not encoded then return nil, tostring(err) end
    if #encoded > 2097152 then return nil, "Client layout exceeds 2097152 bytes" end
    return encoded, nil
end
function M.write(store: Store, value: state.State): (boolean, string?)
    if store.closed then return false, "Client store is closed" end
    local encoded, validation_error = encode(value)
    if not encoded then return false, validation_error end
    local current, read_error = row(store.db)
    if not current then return false, read_error end
    if current.client_id ~= store.client_id or current.generation ~= store.generation then return false, "Client state changed since it was read" end
    if store.generation >= 9007199254740990 then return false, "Client generation exhausted" end
    local result, err = store.db:execute("UPDATE client_state SET value = ?, generation = generation + 1 WHERE singleton = 1 AND client_id = ? AND generation = ?",
        {encoded, store.client_id, store.generation})
    if not result then return false, tostring(err) end
    if result.rows_affected ~= 1 then return false, "Client state changed since it was read" end
    store.generation = store.generation + 1
    return true, nil
end
function M.import_legacy(store: Store, workspace_id: string, desktop: unknown): (string?, string?)
    if store.closed then return nil, "Client store is closed" end
    if not contract.workspace_id(workspace_id) then return nil, "Invalid import workspace" end
    local current, read_error = row(store.db)
    if not current then return nil, read_error end
    if current.client_id ~= store.client_id then return nil, "Client identity changed" end
    if current.receipt ~= "" then
        if current.workspace_id ~= workspace_id then return nil, "Client already imported a different workspace" end
        return current.receipt, nil
    end
    if current.value then return nil, "Existing client layout cannot be replaced by legacy import" end
    local imported, import_error = state.import_desktop(workspace_id, desktop)
    if not imported then return nil, import_error end
    local encoded, encode_error = encode(imported)
    if not encoded then return nil, encode_error end
    -- The layout and receipt become durable in the same SQLite statement.
    -- A racing importer loses the generation check and retries by reading the
    -- winner's receipt; a retry never resets later user layout edits.
    local result, err = store.db:execute("UPDATE client_state SET value = ?, generation = generation + 1, import_workspace = ?, import_receipt = lower(hex(randomblob(16))) " ..
        "WHERE singleton = 1 AND client_id = ? AND generation = ? AND value IS NULL AND import_receipt = ''",
        {encoded, workspace_id, store.client_id, store.generation})
    if not result then return nil, tostring(err) end
    if result.rows_affected ~= 1 then return nil, "Client state changed during import; read before retrying" end
    local committed, commit_error = row(store.db)
    if not committed then return nil, commit_error end
    if committed.client_id ~= store.client_id or committed.workspace_id ~= workspace_id or committed.receipt == "" then return nil, "Client import receipt missing after commit" end
    -- Do not adopt another writer's generation if it edited after our commit.
    store.generation = store.generation + 1
    return committed.receipt, nil
end
function M.close(store: Store): (boolean, string?)
    if store.closed then return true, nil end
    store.closed = true
    local released, err = store.db:release()
    return released == true, err and tostring(err) or nil
end
function M.open(resource: string?): (Store?, string?)
    local database_id = binding.database("client", resource)
    if not database_id then return nil, "Invalid client database binding" end
    local db, err = sql.get(database_id)
    if not db then return nil, tostring(err) end
    local function fail(message: string): (Store?, string?)
        db:release()
        return nil, message
    end
    if db:type() ~= sql.type.SQLITE then return fail("Client database must be SQLite") end
    local _, wal_error = db:execute("PRAGMA journal_mode = WAL")
    if wal_error then return fail(tostring(wal_error)) end
    local migrated, migration_error = migrate(db)
    if not migrated then return fail(migration_error or "Client migration failed") end
    local current, read_error = row(db)
    if not current then return fail(read_error or "Client state read failed") end
    local store: Store = {db = db, closed = false, client_id = current.client_id, generation = current.generation}
    return store, nil
end
return M
