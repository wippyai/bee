-- MIT. Rows of the node workspace catalog: insert, read, ordered pages and
-- state changes. Callers pass an open transaction on the node workspace
-- database; request decoding and authorization belong to the owner operations.
local sql = require("sql")
local contract = require("contract")

type Summary = {workspace_id: string, label: string, root_ref: string, subpath: string, state: string,
    created_at: string, last_used_at: string}
type Definition = {label: string, root_ref: string, subpath: string}
type Cursor = {key: string, workspace_id: string}
type Query = {state: string, order: string, prefix: string, root_ref: string?, after: Cursor?, limit: integer}
type Statement = {sql: string, params: {unknown}}
type Page = {items: {Summary}, next_after: string?}
type Fault = {code: string, message: string}

local M = {}
M.MAX_LABEL_BYTES = 240
M.MAX_PAGE = 100
M.MAX_KEY_BYTES = 1024
M.STATES = {"active", "archived"}

local COLUMNS = "workspace_id, label, root_ref, subpath, state, created_at, last_used_at"
local NOW = "strftime('%Y-%m-%dT%H:%M:%fZ', 'now')"

local function fault(code: string, message: string): Fault
    return {code = code, message = message}
end

local function summary(row: unknown): Summary?
    if type(row) ~= "table" then return nil end
    local id = contract.workspace_id(row.workspace_id)
    local label, root_ref, subpath, state = row.label, row.root_ref, row.subpath, row.state
    local created_at, last_used_at = row.created_at, row.last_used_at
    if not id or type(label) ~= "string" or type(root_ref) ~= "string" or type(subpath) ~= "string"
        or (state ~= "active" and state ~= "archived") or type(created_at) ~= "string" or type(last_used_at) ~= "string" then
        return nil
    end
    return {workspace_id = id, label = label, root_ref = root_ref, subpath = subpath, state = state,
        created_at = created_at, last_used_at = last_used_at}
end

local function one(rows: {unknown}): (Summary?, Fault?)
    if #rows == 0 then return nil, nil end
    if #rows ~= 1 then return nil, fault("STORAGE", "workspace catalog row is corrupt") end
    local value = summary(rows[1])
    if not value then return nil, fault("STORAGE", "workspace catalog row is corrupt") end
    return value, nil
end

-- SQLite's lower() folds ASCII letters only; the keys the index stores and
-- the bounds a query compares must fold the same way.
function M.fold(value: string): string
    return (value:gsub("[A-Z]", function(letter: string): string return string.char(letter:byte() + 32) end))
end

-- The smallest string above every string that starts with prefix. UTF-8
-- text never contains byte 0xFF, so the last byte always has a successor.
local function successor(prefix: string): string
    return prefix:sub(1, #prefix - 1) .. string.char(prefix:byte(#prefix) + 1)
end

local function hex(value: string): string
    return (value:gsub(".", function(byte: string): string return string.format("%02x", byte:byte()) end))
end

local function unhex(value: string): string?
    if #value % 2 ~= 0 or value:find("[^0-9a-f]") then return nil end
    return (value:gsub("%x%x", function(pair: string): string return string.char(math.floor(tonumber(pair, 16) or 0)) end))
end

-- A cursor is the exact keyset position of the last row of a page: the
-- workspace identity and the order key it was listed under.
function M.encode_cursor(position: Cursor): string
    return position.workspace_id .. ":" .. hex(position.key)
end

function M.decode_cursor(value: unknown): Cursor?
    if type(value) ~= "string" or #value > 33 + 2 * M.MAX_KEY_BYTES then return nil end
    local id, encoded = value:match("^([0-9a-f]+):([0-9a-f]*)$")
    local workspace_id = contract.workspace_id(id)
    if not workspace_id or not encoded then return nil end
    local key = unhex(encoded)
    if not key then return nil end
    return {key = key, workspace_id = workspace_id}
end

-- The statements that read one page, in order. Label order walks
-- (state, lower(label), workspace_id); a nonempty prefix bounds the same
-- range. Path order walks (state, root_ref, subpath) and is segment-aware:
-- the folder named by the prefix first, then everything below "prefix/".
function M.statements(query: Query): {Statement}
    local fetch = query.limit + 1
    local after = query.after
    if query.order == "label" then
        local clauses = "state = ?"
        local params: {unknown} = {query.state}
        if query.prefix ~= "" then
            local folded = M.fold(query.prefix)
            clauses = clauses .. " AND lower(label) >= ? AND lower(label) < ?"
            params[#params + 1] = folded
            params[#params + 1] = successor(folded)
        end
        if after then
            clauses = clauses .. " AND (lower(label) > ? OR (lower(label) = ? AND workspace_id > ?))"
            params[#params + 1] = after.key
            params[#params + 1] = after.key
            params[#params + 1] = after.workspace_id
        end
        params[#params + 1] = fetch
        return {{sql = "SELECT " .. COLUMNS .. ", lower(label) AS sort_key FROM workspaces WHERE " .. clauses ..
            " ORDER BY lower(label), workspace_id LIMIT ?", params = params}}
    end
    local root_ref = query.root_ref or ""
    local select = "SELECT " .. COLUMNS .. ", subpath AS sort_key FROM workspaces WHERE state = ? AND root_ref = ?"
    local statements: {Statement} = {}
    if query.prefix == "" then
        local params: {unknown} = {query.state, root_ref}
        local clauses = ""
        if after then
            clauses = " AND subpath > ?"
            params[#params + 1] = after.key
        end
        params[#params + 1] = fetch
        statements[1] = {sql = select .. clauses .. " ORDER BY subpath LIMIT ?", params = params}
        return statements
    end
    if not after then
        statements[#statements + 1] = {sql = select .. " AND subpath = ? LIMIT 1", params = {query.state, root_ref, query.prefix}}
    end
    local params: {unknown} = {query.state, root_ref, query.prefix .. "/", query.prefix .. "0"}
    local clauses = " AND subpath >= ? AND subpath < ?"
    if after then
        clauses = clauses .. " AND subpath > ?"
        params[#params + 1] = after.key
    end
    params[#params + 1] = fetch
    statements[#statements + 1] = {sql = select .. clauses .. " ORDER BY subpath LIMIT ?", params = params}
    return statements
end

function M.page(tx: sql.Transaction, query: Query): (Page?, Fault?)
    local items: {Summary} = {}
    local keys: {string} = {}
    local more = false
    for _, statement in ipairs(M.statements(query)) do
        if more then break end
        local rows, err = tx:query(statement.sql, statement.params)
        if err or not rows then return nil, fault("STORAGE", "read workspace catalog") end
        for _, row in ipairs(rows) do
            if #items == query.limit then more = true; break end
            local value = summary(row)
            local key: unknown = type(row) == "table" and row.sort_key or nil
            if not value or type(key) ~= "string" then return nil, fault("STORAGE", "workspace catalog row is corrupt") end
            items[#items + 1] = value
            keys[#keys + 1] = key
        end
    end
    local next_after: string? = nil
    if more then next_after = M.encode_cursor({key = keys[#keys], workspace_id = items[#items].workspace_id}) end
    return {items = items, next_after = next_after}, nil
end

function M.get(tx: sql.Transaction, workspace_id: string): (Summary?, Fault?)
    local rows, err = tx:query("SELECT " .. COLUMNS .. " FROM workspaces WHERE workspace_id = ?", {workspace_id})
    if err or not rows then return nil, fault("STORAGE", "read workspace catalog") end
    return one(rows)
end

-- A new active row with a fresh identity. One folder is one workspace: a
-- second row for the same root and subpath is a conflict.
function M.insert(tx: sql.Transaction, definition: Definition): (Summary?, Fault?)
    local rows, err = tx:query("INSERT INTO workspaces (" .. COLUMNS .. ") VALUES (lower(hex(randomblob(16))), ?, ?, ?, 'active', " ..
        NOW .. ", " .. NOW .. ") ON CONFLICT (root_ref, subpath) DO NOTHING RETURNING " .. COLUMNS,
        {definition.label, definition.root_ref, definition.subpath})
    if err or not rows then return nil, fault("STORAGE", "create workspace") end
    if #rows == 0 then return nil, fault("CONFLICT", "a workspace already holds this folder") end
    local value, corrupt = one(rows)
    if not value then return nil, corrupt or fault("STORAGE", "created workspace row is missing") end
    return value, nil
end

function M.rename(tx: sql.Transaction, workspace_id: string, label: string): (Summary?, Fault?)
    local rows, err = tx:query("UPDATE workspaces SET label = ? WHERE workspace_id = ? RETURNING " .. COLUMNS, {label, workspace_id})
    if err or not rows then return nil, fault("STORAGE", "rename workspace") end
    local value, corrupt = one(rows)
    if corrupt then return nil, corrupt end
    if not value then return nil, fault("NOT_FOUND", "workspace is not in the node catalog") end
    return value, nil
end

-- Move a row from one lifecycle state to the other. A row already in the
-- target state is returned unchanged, so a repeated request replays.
function M.transition(tx: sql.Transaction, workspace_id: string, from: string, to: string): (Summary?, Fault?)
    local rows, err = tx:query("UPDATE workspaces SET state = ? WHERE workspace_id = ? AND state = ? RETURNING " .. COLUMNS,
        {to, workspace_id, from})
    if err or not rows then return nil, fault("STORAGE", "change workspace state") end
    local value, corrupt = one(rows)
    if corrupt then return nil, corrupt end
    if value then return value, nil end
    local current, read_fault = M.get(tx, workspace_id)
    if read_fault then return nil, read_fault end
    if not current then return nil, fault("NOT_FOUND", "workspace is not in the node catalog") end
    if current.state == to then return current, nil end
    return nil, fault("CONFLICT", "workspace changed state concurrently")
end

return M
