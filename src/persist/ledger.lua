-- MIT. The checked inline migration ledger, owned by no schema. A component
-- hands in its ledger table, a label for its messages and its immutable
-- migration list; every open replays the ledger against that list: a
-- changed name or checksum, a gap, or a newer schema refuses the store
-- before any table is touched.
local sql = require("sql")
local hash = require("hash")
local M = {}
type Migration = {id: integer, name: string, sql: string, rebuild: boolean}
type Ledger = {table: string, label: string}
local function integer(value: unknown): integer?
    if type(value) ~= "number" then return nil end
    local result = math.floor(value)
    if value ~= result then return nil end
    return result
end
local function rollback(tx: sql.Transaction)
    tx:rollback()
end
local function table_name(ledger: Ledger): (string?, string?)
    if not ledger.table:match("^[a-z][a-z0-9_]*$") then return nil, ledger.label .. " migration ledger table name is invalid" end
    return ledger.table, nil
end
-- The checksum covers the name and the text; a migration is immutable once
-- it is in any ledger.
function M.checksum(migration: Migration): (string?, string?)
    local digest, err = hash.sha256(migration.name .. "\n" .. migration.sql)
    if err or not digest then return nil, "calculate migration checksum" end
    return digest, nil
end
-- Every migration list is dense from 1 and each entry carries its text.
function M.check(expected: {Migration}): string?
    for index, migration in ipairs(expected) do
        if migration.id ~= index then return "migration list is not dense from 1" end
        if migration.name == "" or migration.sql == "" then return "migration " .. tostring(index) .. " is empty" end
    end
    return nil
end
local function read_ledger(db: sql.DB, ledger: Ledger, expected: {Migration}): ({[integer]: boolean}?, string?)
    local name, name_error = table_name(ledger)
    if not name then return nil, name_error end
    local _, create_err = db:execute("CREATE TABLE IF NOT EXISTS " .. name .. [[ (
    id INTEGER PRIMARY KEY CHECK (id > 0),
    name TEXT NOT NULL,
    checksum TEXT NOT NULL,
    applied_at TEXT NOT NULL,
    UNIQUE (name)
)]])
    if create_err then return nil, "create " .. ledger.label .. " migration ledger" end
    local rows, query_err = db:query("SELECT id, name, checksum FROM " .. name .. " ORDER BY id")
    if query_err or not rows then return nil, "read " .. ledger.label .. " migration ledger" end
    local by_id: {[integer]: Migration} = {}
    for _, migration in ipairs(expected) do by_id[migration.id] = migration end
    local known: {[integer]: boolean} = {}
    local expected_id = 1
    for _, row in ipairs(rows) do
        local id = integer(row.id)
        local row_name: unknown = row.name
        local checksum: unknown = row.checksum
        if not id or id < 1 then return nil, ledger.label .. " migration ledger is invalid" end
        if id > #expected then return nil, ledger.label .. " database schema is newer" end
        if id ~= expected_id then return nil, ledger.label .. " migration ledger has a gap" end
        local migration = by_id[id]
        if not migration or type(row_name) ~= "string" or type(checksum) ~= "string" then return nil, ledger.label .. " migration ledger is invalid" end
        local expected_checksum, checksum_err = M.checksum(migration)
        if not expected_checksum then return nil, checksum_err end
        if row_name ~= migration.name then return nil, ledger.label .. " migration name changed" end
        if checksum ~= expected_checksum then return nil, ledger.label .. " migration checksum changed" end
        known[id] = true
        expected_id = expected_id + 1
    end
    return known, nil
end
-- Applies one migration with its ledger row in a single transaction. A
-- rebuild runs with foreign keys off on this dedicated connection, outside
-- the transaction, and is checked before commit, so a broken reference rolls
-- the whole step back and enforcement is restored either way.
local function apply_one(db: sql.DB, ledger: Ledger, migration: Migration): (boolean, string?)
    local name, name_error = table_name(ledger)
    if not name then return false, name_error end
    local checksum, checksum_err = M.checksum(migration)
    if not checksum then return false, checksum_err end
    if migration.rebuild then
        local _, off_err = db:execute("PRAGMA foreign_keys = OFF")
        if off_err then return false, "disable foreign keys for rebuild" end
    end
    local function finish(ok: boolean, err: string?): (boolean, string?)
        if migration.rebuild then
            local _, on_err = db:execute("PRAGMA foreign_keys = ON")
            if on_err and ok then return false, "restore foreign keys after rebuild" end
        end
        return ok, err
    end
    local tx, begin_err = db:begin({isolation = sql.isolation.SERIALIZABLE})
    if not tx then return finish(false, "begin " .. ledger.label .. " migration") end
    -- Another opener may have applied this step between the ledger read and
    -- this transaction; the row decides, not the earlier read.
    local existing, existing_err = tx:query("SELECT name, checksum FROM " .. name .. " WHERE id = ?", {migration.id})
    if existing_err or not existing then
        rollback(tx)
        return finish(false, "read " .. ledger.label .. " migration ledger")
    end
    if #existing == 1 then
        rollback(tx)
        if existing[1].name ~= migration.name then return finish(false, ledger.label .. " migration name changed") end
        if existing[1].checksum ~= checksum then return finish(false, ledger.label .. " migration checksum changed") end
        return finish(true, nil)
    end
    local _, apply_err = tx:execute(migration.sql)
    if apply_err then
        rollback(tx)
        return finish(false, "apply " .. ledger.label .. " migration " .. migration.name)
    end
    if migration.rebuild then
        local violations, check_err = tx:query("PRAGMA foreign_key_check")
        if check_err or not violations then
            rollback(tx)
            return finish(false, "check foreign keys after rebuild")
        end
        if #violations > 0 then
            rollback(tx)
            return finish(false, ledger.label .. " migration " .. migration.name .. " leaves broken references")
        end
    end
    local _, record_err = tx:execute(
        "INSERT INTO " .. name .. " (id, name, checksum, applied_at) VALUES (?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))",
        {migration.id, migration.name, checksum})
    if record_err then
        rollback(tx)
        return finish(false, "record " .. ledger.label .. " migration")
    end
    local committed, commit_err = tx:commit()
    if commit_err or committed ~= true then
        rollback(tx)
        return finish(false, "commit " .. ledger.label .. " migration")
    end
    return finish(true, nil)
end
-- Checks the ledger against the expected list and applies what it lacks,
-- one migration and one ledger row per transaction, in order.
function M.apply(db: sql.DB, ledger: Ledger, expected: {Migration}): (boolean, string?)
    local shape_error = M.check(expected)
    if shape_error then return false, shape_error end
    local known, ledger_err = read_ledger(db, ledger, expected)
    if not known then return false, ledger_err end
    for _, migration in ipairs(expected) do
        if not known[migration.id] then
            local applied, apply_err = apply_one(db, ledger, migration)
            if not applied then return false, apply_err end
        end
    end
    return true, nil
end
-- The ledger rows as stored: what a component reports as its schema state.
function M.rows(db: sql.DB, ledger: Ledger): ({{id: integer, name: string, checksum: string}}?, string?)
    local name, name_error = table_name(ledger)
    if not name then return nil, name_error end
    local rows, query_err = db:query("SELECT id, name, checksum FROM " .. name .. " ORDER BY id")
    if query_err or not rows then return nil, "read " .. ledger.label .. " migration ledger" end
    local result: {{id: integer, name: string, checksum: string}} = {}
    for index, row in ipairs(rows) do
        local id = integer(row.id)
        if not id or type(row.name) ~= "string" or type(row.checksum) ~= "string" then return nil, ledger.label .. " migration ledger is invalid" end
        result[index] = {id = id, name = row.name :: string, checksum = row.checksum :: string}
    end
    return result, nil
end
return M
