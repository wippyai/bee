-- MIT. The checked inline migration ledger, owned by no schema. A component
-- hands in its ledger table, a label for its messages and its immutable
-- migration list; every open replays the ledger against that list: a
-- changed name or checksum, a gap, or a newer schema refuses the store
-- before any table is touched.
local sql = require("sql")
local hash = require("hash")
local M = {}
type Migration = {id: integer, name: string, sql: string, rebuild: boolean?}
type Ledger = {
    table: string, label: string,
    transaction: "batch"?, applied_at: boolean?, freshness_table: string?,
}
type Connection = sql.DB | sql.Transaction
local function integer(value: unknown): integer?
    if type(value) ~= "number" or value ~= value then return nil end
    local result = math.floor(value)
    if value ~= result then return nil end
    return result
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
local function create_ledger(db: Connection, ledger: Ledger): string?
    local name = ledger.table
    local timestamp = ledger.applied_at == false and "" or "    applied_at TEXT NOT NULL,\n"
    local _, create_err = db:execute("CREATE TABLE IF NOT EXISTS " .. name .. [[ (
    id INTEGER PRIMARY KEY CHECK (id > 0),
    name TEXT NOT NULL,
    checksum TEXT NOT NULL,
]] .. timestamp .. [[    UNIQUE (name)
)]])
    if create_err then return  "create " .. ledger.label .. " migration ledger: " .. tostring(create_err) end
    return nil
end
local function read_ledger(db: Connection, ledger: Ledger, expected: {Migration}): ({[integer]: boolean}?, string?)
    local name, name_error = table_name(ledger)
    if not name then return nil, name_error end
    local rows, query_err = db:query("SELECT id, name, checksum FROM " .. name .. " ORDER BY id")
    if query_err or not rows then return nil, "read " .. ledger.label .. " migration ledger: " .. tostring(query_err) end
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
local function freshness(tx: sql.Transaction, ledger: Ledger, known: {[integer]: boolean}): string?
    local name = ledger.freshness_table
    if not name then return nil end
    local _, err = tx:execute("CREATE TEMP TABLE IF NOT EXISTS " .. name .. " (fresh INTEGER NOT NULL CHECK (fresh IN (0, 1)))")
    if not err then _, err = tx:execute("DELETE FROM temp." .. name) end
    if not err then _, err = tx:execute("INSERT INTO temp." .. name .. " (fresh) VALUES (?)", {known[1] and 0 or 1}) end
    if err then return "record " .. ledger.label .. " migration run: " .. tostring(err) end
    return nil
end

local function apply_migration(tx: sql.Transaction, ledger: Ledger, migration: Migration): string?
    local checksum, checksum_err = M.checksum(migration)
    if not checksum then return checksum_err end
    local _, apply_err = tx:execute(migration.sql)
    if apply_err then return "apply " .. ledger.label .. " migration " .. migration.name .. ": " .. tostring(apply_err) end
    if migration.rebuild then
        local violations, check_err = tx:query("PRAGMA foreign_key_check")
        if check_err or not violations then return "check foreign keys after rebuild" end
        if #violations > 0 then return ledger.label .. " migration " .. migration.name .. " leaves broken references" end
    end
    local columns, values = "id, name, checksum", "?, ?, ?"
    if ledger.applied_at ~= false then
        columns = columns .. ", applied_at"
        values = values .. ", strftime('%Y-%m-%dT%H:%M:%fZ', 'now')"
    end
    local _, record_err = tx:execute("INSERT INTO " .. ledger.table .. " (" .. columns .. ") VALUES (" .. values .. ")",
        {migration.id, migration.name, checksum})
    if record_err then return "record " .. ledger.label .. " migration: " .. tostring(record_err) end
    return nil
end

-- Batch owners commit their complete upgrade atomically. Other owners commit
-- each step separately; rebuilds disable enforcement outside that transaction.
local function apply_transaction(db: sql.DB, ledger: Ledger, expected: {Migration}, step: Migration?): (boolean, string?)
    local rebuild = step and step.rebuild == true
    if rebuild then
        local _, off_err = db:execute("PRAGMA foreign_keys = OFF")
        if off_err then return false, "disable foreign keys for rebuild" end
    end
    local function finish(ok: boolean, err: string?): (boolean, string?)
        if rebuild then
            local _, on_err = db:execute("PRAGMA foreign_keys = ON")
            if on_err then return false, "restore foreign keys after rebuild: " .. tostring(on_err) end
        end
        return ok, err
    end
    local tx, begin_err = db:begin({isolation = sql.isolation.SERIALIZABLE})
    if not tx then return finish(false, "begin " .. ledger.label .. " migration: " .. tostring(begin_err)) end
    local function fail(err: string?): (boolean, string?)
        tx:rollback()
        return finish(false, err)
    end
    -- Recheck under the writer transaction, including when another opener won.
    local create_err = create_ledger(tx, ledger)
    if create_err then return fail(create_err) end
    local _, writer_err = tx:execute("UPDATE " .. ledger.table .. " SET id = id WHERE 0")
    if writer_err then return fail("lock " .. ledger.label .. " migration ledger: " .. tostring(writer_err)) end
    local known, ledger_err = read_ledger(tx, ledger, expected)
    if not known then return fail(ledger_err) end
    local run_err = freshness(tx, ledger, known)
    if run_err then return fail(run_err) end
    for _, migration in ipairs(expected) do
        if not known[migration.id] and (not step or step.id == migration.id) then
            local apply_err = apply_migration(tx, ledger, migration)
            if apply_err then return fail(apply_err) end
        end
    end
    local committed, commit_err = tx:commit()
    if commit_err or committed ~= true then return fail("commit " .. ledger.label .. " migration: " .. tostring(commit_err)) end
    return finish(true, nil)
end

function M.apply(db: sql.DB, ledger: Ledger, expected: {Migration}): (boolean, string?)
    local shape_error = M.check(expected)
    if shape_error then return false, shape_error end
    local name, name_error = table_name(ledger)
    if not name then return false, name_error end
    if ledger.freshness_table then
        if not ledger.freshness_table:match("^[a-z][a-z0-9_]*$") then return false, "migration freshness table name is invalid" end
        if ledger.transaction ~= "batch" then return false, "migration freshness requires a batch transaction" end
    end
    if ledger.transaction == "batch" then
        for _, migration in ipairs(expected) do
            if migration.rebuild then return false, "rebuild migration requires a separate transaction" end
        end
        return apply_transaction(db, ledger, expected, nil)
    end
    local create_err = create_ledger(db, ledger)
    if create_err then return false, create_err end
    local known, ledger_err = read_ledger(db, ledger, expected)
    if not known then return false, ledger_err end
    for _, migration in ipairs(expected) do
        if not known[migration.id] then
            local applied, apply_err = apply_transaction(db, ledger, expected, migration)
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
        result[index] = {id = id, name = row.name, checksum = row.checksum}
    end
    return result, nil
end
return M
