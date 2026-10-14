-- MIT. Read the bounded activation revision token without loading activation writers.
local sql = require("sql")
local bounds = require("bounds")
local transaction = require("transaction")
local M = {}
type Result = transaction.Result
local MAX_DESIRED_SLOTS = 1024
local MAX_REVISION = 9007199254740991
local function failure(code: string, message: string): Result
    return transaction.failure(code, message)
end
local function id(value: unknown): string?
    return bounds.id(value)
end
local function count(value: unknown, positive: boolean): integer?
    if type(value) ~= "number" or value ~= math.floor(value) or value < 0 or value > MAX_REVISION then return nil end
    if positive and value < 1 then return nil end
    return math.floor(value)
end
function M.read(resource: string, node_raw: unknown, workspace_raw: unknown): Result
    if type(resource) ~= "string" or resource == "" then
        return failure("UNAVAILABLE", "governance activation database is not linked")
    end
    local node, workspace = id(node_raw), id(workspace_raw)
    if not node or not workspace then return failure("INVALID", "governance activation identity is invalid") end
    local db, err = sql.get(resource)
    if not db then return failure("UNAVAILABLE", transaction.error_message("open governance activation database", err)) end
    local function close_failure(code: string, message: string): Result
        return transaction.release(db, "governance activation", failure(code, message))
    end
    local revisions: {string} = {}
    local overlay_owners: {string} = {}
    local rows, query_error = db:query("SELECT overlay_owner, revision FROM bee_governance_activation_slots WHERE owner_node = ? AND workspace_id = ? ORDER BY overlay_owner LIMIT ?",
        {node, workspace, MAX_DESIRED_SLOTS + 1})
    if query_error or not rows then return close_failure("INTERNAL", transaction.error_message("read governance activation revisions", query_error)) end
    if #rows > MAX_DESIRED_SLOTS then return close_failure("CAPACITY", "governance activation slots exceed their bound") end
    for _, row in ipairs(rows) do
        local overlay_owner, revision = id(row.overlay_owner), count(row.revision, false)
        if not overlay_owner or revision == nil then return close_failure("INTERNAL", "governance activation revision is malformed") end
        revisions[#revisions + 1] = overlay_owner .. "=" .. tostring(revision)
        overlay_owners[#overlay_owners + 1] = overlay_owner
    end
    local released, release_error = db:release()
    if released ~= true or release_error then return failure("UNAVAILABLE", transaction.error_message("close governance activation database", release_error)) end
    return transaction.success({revision = table.concat(revisions, ";"), overlay_owners = overlay_owners}, false)
end
return M
