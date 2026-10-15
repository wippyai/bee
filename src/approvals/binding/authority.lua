-- MIT. Authority for the approvals authority.
local sql = require("sql")
local security = require("security")
local bounds = require("bounds")
local transaction = require("transaction")
local resources = require("resources")
local store = require("store")
local part_model = require("part_model")
local part_values = require("part_values")
local M = {}
type Result = part_model.Result
type Row = part_model.Row
local failure = part_values.failure
local storage = part_values.storage
local success = part_values.success
local now_ms = part_values.now_ms
local stamp = part_values.stamp
local node = part_values.node
local text = part_values.text
local integer = part_values.integer
local advance_incarnation = part_values.advance_incarnation
-- The authority incarnation is established by the authority process before
-- any request is served; a missing row means no authority on this node.
local function incarnation(tx: sql.Transaction, owner: string): (integer?, Result?)
    local raw, exists, err = store.authority(tx, owner)
    if err then return nil, storage("read authority incarnation") end
    if not exists then return nil, failure("UNAVAILABLE", "approval authority is not established on this node") end
    local value = integer(raw)
    if not value or value < 1 then return nil, storage("authority incarnation is corrupt") end
    return value, nil
end
local function authenticated_definition(actor: string): string?
    local definition: string? = nil
    local current = security.actor()
    if current and current:id() == actor then
        local metadata = current:meta()
        if type(metadata) == "table" then definition = bounds.id(metadata.definition_id) end
    end
    return definition
end
local function eligible(actor: string, row: Row): (boolean, string?)
    local workspace_id = text(row.workspace_id) or ""
    if not security.can(part_model.DECIDE, workspace_id) then return false, nil end
    local policies, policies_error = resources.policies()
    if not policies then return false, policies_error end
    local policy = policies[text(row.policy) or ""]
    if not policy then return false, nil end
    local definition = authenticated_definition(actor)
    for _, approver in ipairs(policy.approvers) do
        if type(approver) == "string" and approver == actor then return true, nil end
        if type(approver) == "table" and definition and approver.definition_id == definition then return true, nil end
    end
    return false, nil
end
-- establish: the authority process advances the incarnation once per start,
-- before any request is served under it. Delivery ownership is separate.
function M.establish(db: sql.DB): (integer?, string?)
    local owner, node_error = node()
    if not owner then return nil, node_error or "native node identity unavailable" end
    local result = transaction.write(db, part_model.LABEL, function(tx: sql.Transaction): Result
        local raw_current, exists, err = store.authority(tx, owner)
        if err then return storage("read authority incarnation") end
        local next_incarnation = 1
        if exists then
            local advanced, advance_error = advance_incarnation(raw_current)
            if advanced == nil then return storage(advance_error or "authority incarnation is corrupt") end
            next_incarnation = advanced
        end
        local write_error = store.write_authority(tx, owner, next_incarnation, stamp(now_ms()))
        if write_error then return storage("establish authority incarnation") end
        return success(next_incarnation, false)
    end)
    if not result.ok then return nil, result.message end
    return integer(result.value), nil
end
function M.node(): (string?, string?)
    return node()
end
M.authenticated_definition = authenticated_definition
M.eligible = eligible
M.incarnation = incarnation
return M
