-- MIT. Host-selected client database; no workspace checkpoint or registry publication.
-- Desktop identities belong to the client node. A desktop keeps one layout per
-- workspace it shows, keyed by (desktop_id, workspace_id); the layout columns of
-- the identity tables hold only a pre-keyed layout that the first workspace it
-- belongs to adopts.
local sql = require("sql")
local json = require("json")
local hash = require("hash")
local state = require("state")
local contract = require("contract")
local binding = require("binding")
type DesktopIdentity = {desktop_id: string, is_default: boolean}
type Row = {client_id: string, generation: integer, value: state.State?, workspace_id: string, receipt: string}
type Layout = {generation: integer, value: state.State?, receipt: string}
type Store = {
    db: sql.DB, closed: boolean, client_id: string, workspace_id: string, generation: integer, desktop_id: string?,
}
-- The node's desktop identities, independent of any workspace layout.
type Desktops = {db: sql.DB, closed: boolean, client_id: string}
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
local DESKTOPS = [[
CREATE TABLE client_desktops (
    client_id TEXT NOT NULL PRIMARY KEY CHECK (length(client_id) = 32 AND client_id NOT GLOB '*[^0-9a-f]*'),
    generation INTEGER NOT NULL DEFAULT 0 CHECK (generation >= 0),
    value TEXT CHECK (value IS NULL OR length(CAST(value AS BLOB)) <= 2097152),
    import_workspace TEXT NOT NULL DEFAULT '',
    import_receipt TEXT NOT NULL DEFAULT ''
)
]]
local LAYOUTS = [[
CREATE TABLE client_layouts (
    desktop_id TEXT NOT NULL CHECK (length(desktop_id) = 32 AND desktop_id NOT GLOB '*[^0-9a-f]*'),
    workspace_id TEXT NOT NULL CHECK (length(workspace_id) = 32 AND workspace_id NOT GLOB '*[^0-9a-f]*'),
    generation INTEGER NOT NULL CHECK (generation >= 1 AND generation <= 9007199254740990),
    value TEXT NOT NULL CHECK (length(CAST(value AS BLOB)) <= 2097152),
    import_receipt TEXT NOT NULL CHECK (import_receipt = '' OR (length(import_receipt) = 32 AND import_receipt NOT GLOB '*[^0-9a-f]*')),
    PRIMARY KEY (desktop_id, workspace_id)
)
]]
local migrations: {Migration} = {
    {id = 1, name = "client_layout_v1", sql = SCHEMA},
    {id = 2, name = "independent_desktops_v1", sql = DESKTOPS},
    {id = 3, name = "workspace_layouts_v1", sql = LAYOUTS},
}
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
local function row(db: sql.DB, desktop_id: string?): (Row?, string?)
    local query = "SELECT singleton, client_id, generation, value, import_workspace, import_receipt FROM client_state"
    local params: {string} = {}
    if desktop_id then
        query = "SELECT 1 AS singleton, client_id, generation, value, import_workspace, import_receipt FROM client_desktops WHERE client_id = ?"
        params = {desktop_id}
    end
    local rows, err = db:query(query, params)
    if not rows then return nil, tostring(err) end
    if #rows == 0 and desktop_id then return nil, "Desktop identity not found" end
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
local function layout(db: sql.DB, desktop_id: string, workspace_id: string): (Layout?, string?)
    local rows, err = db:query("SELECT generation, value, import_receipt FROM client_layouts WHERE desktop_id = ? AND workspace_id = ?",
        {desktop_id, workspace_id})
    if not rows then return nil, tostring(err) end
    if #rows == 0 then return {generation = 0, value = nil, receipt = ""}, nil end
    if #rows ~= 1 then return nil, "Client layout row is corrupt" end
    local generation: unknown, encoded: unknown = rows[1].generation, rows[1].value
    local receipt: unknown = rows[1].import_receipt
    if type(generation) ~= "number" or generation < 1 or generation > 9007199254740990 or generation ~= math.floor(generation)
        or type(encoded) ~= "string" or #encoded > 2097152 or type(receipt) ~= "string"
        or (receipt ~= "" and not contract.workspace_id(receipt)) then
        return nil, "Client layout row is corrupt"
    end
    local saved = state.decode(json.decode(encoded))
    if not saved then return nil, "Unsupported or corrupt client layout" end
    local result: Layout = {generation = math.floor(generation), value = saved, receipt = tostring(receipt)}
    return result, nil
end
-- A pre-keyed layout belongs to the workspace its import receipt and every
-- target name. Adoption moves it under that workspace in one transaction and
-- keeps the desktop identity, which workspaces record as the display ID.
local function adopt(db: sql.DB, current: Row, desktop_id: string?, workspace_id: string): string?
    local saved = current.value
    if not saved then return nil end
    if current.workspace_id ~= "" and current.workspace_id ~= workspace_id then return nil end
    for _, target in ipairs(saved.targets) do
        if target.workspace_id ~= workspace_id then return nil end
    end
    local table_name = desktop_id and "client_desktops" or "client_state"
    local tx, begin_error = db:begin()
    if not tx then return tostring(begin_error) end
    local _, insert_error = tx:execute("INSERT INTO client_layouts (desktop_id, workspace_id, generation, value, import_receipt) " ..
        "SELECT client_id, ?, generation, value, import_receipt FROM " .. table_name .. " WHERE client_id = ? AND generation = ? AND value IS NOT NULL",
        {workspace_id, current.client_id, current.generation})
    if insert_error then tx:rollback(); return tostring(insert_error) end
    local cleared, clear_error = tx:execute("UPDATE " .. table_name .. " SET value = NULL, generation = 0, import_workspace = '', import_receipt = '' " ..
        "WHERE client_id = ? AND generation = ? AND value IS NOT NULL", {current.client_id, current.generation})
    if not cleared then tx:rollback(); return tostring(clear_error) end
    if cleared.rows_affected ~= 1 then tx:rollback(); return "Client layout changed during adoption; read before retrying" end
    local _, commit_error = tx:commit()
    if commit_error then tx:rollback(); return tostring(commit_error) end
    return nil
end
function M.read(store: Store): (state.State?, string?)
    if store.closed then return nil, "Client store is closed" end
    local current, err = row(store.db, store.desktop_id)
    if not current then return nil, err end
    if current.client_id ~= store.client_id then return nil, "Client identity changed" end
    local saved, layout_error = layout(store.db, store.client_id, store.workspace_id)
    if not saved then return nil, layout_error end
    store.generation = saved.generation
    return saved.value, nil
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
    local current, read_error = row(store.db, store.desktop_id)
    if not current then return false, read_error end
    if current.client_id ~= store.client_id then return false, "Client identity changed" end
    if store.generation >= 9007199254740990 then return false, "Client generation exhausted" end
    local result, err
    if store.generation == 0 then
        result, err = store.db:execute("INSERT INTO client_layouts (desktop_id, workspace_id, generation, value, import_receipt) " ..
            "VALUES (?, ?, 1, ?, '') ON CONFLICT(desktop_id, workspace_id) DO NOTHING", {store.client_id, store.workspace_id, encoded})
    else
        result, err = store.db:execute("UPDATE client_layouts SET value = ?, generation = generation + 1 " ..
            "WHERE desktop_id = ? AND workspace_id = ? AND generation = ?", {encoded, store.client_id, store.workspace_id, store.generation})
    end
    if not result then return false, tostring(err) end
    if result.rows_affected ~= 1 then return false, "Client state changed since it was read" end
    store.generation = store.generation + 1
    return true, nil
end
function M.import_legacy(store: Store, workspace_id: string, desktop: unknown, appearance_mode: state.AppearanceMode?): (string?, string?)
    if store.desktop_id then return nil, "Only the default desktop imports legacy layout" end
    if store.closed then return nil, "Client store is closed" end
    if workspace_id ~= store.workspace_id then return nil, "Invalid import workspace" end
    local current, read_error = row(store.db, store.desktop_id)
    if not current then return nil, read_error end
    if current.client_id ~= store.client_id then return nil, "Client identity changed" end
    local saved, layout_error = layout(store.db, store.client_id, store.workspace_id)
    if not saved then return nil, layout_error end
    if saved.receipt ~= "" then return saved.receipt, nil end
    if saved.value then return nil, "Existing client layout cannot be replaced by legacy import" end
    local decoded, import_error = state.import_desktop(workspace_id, desktop)
    if not decoded then return nil, import_error end
    local imported: state.State = decoded
    if appearance_mode then imported.appearance_mode = appearance_mode end
    local encoded, encode_error = encode(imported)
    if not encoded then return nil, encode_error end
    -- The layout and receipt become durable in the same SQLite statement.
    -- A racing importer loses the insert and retries by reading the winner's
    -- receipt; a retry never resets later user layout edits.
    local result, err = store.db:execute("INSERT INTO client_layouts (desktop_id, workspace_id, generation, value, import_receipt) " ..
        "VALUES (?, ?, 1, ?, lower(hex(randomblob(16)))) ON CONFLICT(desktop_id, workspace_id) DO NOTHING",
        {store.client_id, store.workspace_id, encoded})
    if not result then return nil, tostring(err) end
    if result.rows_affected ~= 1 then return nil, "Client state changed during import; read before retrying" end
    local committed, commit_error = layout(store.db, store.client_id, store.workspace_id)
    if not committed then return nil, commit_error end
    if committed.receipt == "" then return nil, "Client import receipt missing after commit" end
    -- Do not adopt another writer's generation if it edited after our commit.
    store.generation = 1
    return committed.receipt, nil
end
function M.close(store: Store): (boolean, string?)
    if store.closed then return true, nil end
    store.closed = true
    local released, err = store.db:release()
    return released == true, err and tostring(err) or nil
end
-- A durable catalog, not live availability or an admission grant. One bounded
-- query supplies a coherent snapshot without reading any desktop's layout.
function M.catalog(store: Desktops): ({DesktopIdentity}?, string?)
    if store.closed then return nil, "Client store is closed" end
    local rows, err = store.db:query([[SELECT client_id, 1 AS is_default FROM client_state
        UNION ALL SELECT client_id, 0 AS is_default FROM client_desktops
        ORDER BY is_default DESC, client_id LIMIT 34]])
    if not rows then return nil, tostring(err) end
    if #rows < 1 or #rows > 33 then return nil, "Desktop catalog is corrupt" end
    local result: {DesktopIdentity} = {}
    local seen: {[string]: boolean} = {}
    for index, value in ipairs(rows) do
        local id = contract.workspace_id(value.client_id)
        if not id or seen[id] then return nil, "Desktop catalog identity is corrupt" end
        if (index == 1 and (value.is_default ~= 1 or id ~= store.client_id))
            or (index > 1 and value.is_default ~= 0) then return nil, "Desktop catalog default is corrupt" end
        seen[id] = true
        result[#result + 1] = {desktop_id = id, is_default = index == 1}
    end
    return result, nil
end
-- The supervisor allocates opaque identities explicitly; opening a missing
-- identity never silently creates a replacement for a lost desktop.
function M.allocate(store: Desktops, desktop_id: string): (boolean, string?)
    if store.closed then return false, "Client store is closed" end
    if not contract.workspace_id(desktop_id) then return false, "Invalid desktop identity" end
    if desktop_id == store.client_id then return false, "Desktop identity already selected" end
    local existing, read_error = store.db:query("SELECT client_id FROM client_desktops WHERE client_id = ?", {desktop_id})
    if not existing then return false, tostring(read_error) end
    if #existing == 1 then return true, nil end
    local result, err = store.db:execute("INSERT INTO client_desktops (client_id) SELECT ? WHERE (SELECT count(*) FROM client_desktops) < 32 ON CONFLICT(client_id) DO NOTHING", {desktop_id})
    if not result then return false, tostring(err) end
    if result.rows_affected == 1 then return true, nil end
    local raced, race_error = store.db:query("SELECT client_id FROM client_desktops WHERE client_id = ?", {desktop_id})
    if not raced then return false, tostring(race_error) end
    if #raced == 1 then return true, nil end
    return false, "Desktop capacity reached"
end
local function acquire(resource: string?): (sql.DB?, string?)
    local database_id = binding.database("client", resource)
    if not database_id then return nil, "Invalid client database binding" end
    local db, err = sql.get(database_id)
    if not db then return nil, tostring(err) end
    local function fail(message: string): (sql.DB?, string?)
        db:release()
        return nil, message
    end
    if db:type() ~= sql.type.SQLITE then return fail("Client database must be SQLite") end
    local _, wal_error = db:execute("PRAGMA journal_mode = WAL")
    if wal_error then return fail(tostring(wal_error)) end
    local migrated, migration_error = migrate(db)
    if not migrated then return fail(migration_error or "Client migration failed") end
    return db, nil
end
-- A client opens one desktop for one workspace; the layout it reads and writes
-- is that pair's row.
function M.open(resource: string?, workspace_id: string, desktop_id: string?): (Store?, string?)
    if not contract.workspace_id(workspace_id) then return nil, "Invalid workspace identity" end
    if desktop_id ~= nil and not contract.workspace_id(desktop_id) then return nil, "Invalid desktop identity" end
    local db, acquire_error = acquire(resource)
    if not db then return nil, acquire_error end
    local function fail(message: string): (Store?, string?)
        db:release()
        return nil, message
    end
    local current, read_error = row(db, desktop_id)
    if not current then return fail(read_error or "Client state read failed") end
    local adoption_error = adopt(db, current, desktop_id, workspace_id)
    if adoption_error then return fail(adoption_error) end
    local saved, layout_error = layout(db, current.client_id, workspace_id)
    if not saved then return fail(layout_error or "Client layout read failed") end
    local store: Store = {db = db, closed = false, client_id = current.client_id, workspace_id = workspace_id,
        generation = saved.generation, desktop_id = desktop_id}
    return store, nil
end
-- Open the node's desktop identity catalog for listing and allocation.
function M.desktops(resource: string?): (Desktops?, string?)
    local db, acquire_error = acquire(resource)
    if not db then return nil, acquire_error end
    local current, read_error = row(db, nil)
    if not current then
        db:release()
        return nil, read_error or "Client state read failed"
    end
    local desktops: Desktops = {db = db, closed = false, client_id = current.client_id}
    return desktops, nil
end
function M.release(desktops: Desktops): (boolean, string?)
    if desktops.closed then return true, nil end
    desktops.closed = true
    local released, err = desktops.db:release()
    return released == true, err and tostring(err) or nil
end
return M
