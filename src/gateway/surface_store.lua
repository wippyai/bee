-- MIT. Transaction-local storage of an admitted MCP surface and its selection.
-- The caller owns authorization, decoding and transaction commit/rollback.
local bounds = require("bounds")
local M = {}
type State = {surface_json: string, active_json: string, context_json: string, revision: integer}
type Fault = {code: string, message: string}
local function fault(code: string, message: string): Fault return {code = code, message = message} end
local function text(value: string, limit: integer): boolean return #value > 0 and #value <= limit end
function M.read(tx: sql.Transaction, binding_id: string): (State?, Fault?)
    local rows, err = tx:query("SELECT surface_json, active_json, context_json, revision FROM bee_gateway_surfaces WHERE binding_id = ?", {binding_id})
    if err or not rows then return nil, fault("STORAGE", "read binding surface") end
    if #rows == 0 then return nil, fault("NOT_FOUND", "binding surface is absent") end
    local row = bounds.object(rows[1])
    if not row then return nil, fault("STORAGE", "invalid binding surface row") end
    local revision = bounds.count(row.revision)
    local surface, active, context = bounds.text(row.surface_json, 131072), bounds.text(row.active_json, 8192), bounds.text(row.context_json, 16384)
    if surface == nil then return nil, fault("STORAGE", "invalid surface JSON") end
    if active == nil then return nil, fault("STORAGE", "invalid active JSON") end
    if context == nil then return nil, fault("STORAGE", "invalid context JSON") end
    if revision == nil then return nil, fault("STORAGE", "invalid surface revision") end
    if revision < 1 or not text(surface, 131072) or not text(active, 8192) or not text(context, 16384) then
        return nil, fault("STORAGE", "invalid binding surface state")
    end
    return {surface_json = surface, active_json = active, context_json = context, revision = revision}, nil
end
function M.initialize(tx: sql.Transaction, binding_id: string, surface: string, active: string, context: string): (State?, Fault?)
    if not bounds.id(binding_id) or not text(surface, 131072) or not text(active, 8192) or not text(context, 16384) then
        return nil, fault("INVALID", "binding surface exceeds storage bounds")
    end
    local inserted, err = tx:execute("INSERT INTO bee_gateway_surfaces (binding_id, surface_json, active_json, context_json, revision) VALUES (?, ?, ?, ?, 1) ON CONFLICT(binding_id) DO NOTHING",
        {binding_id, surface, active, context})
    if err or not inserted then return nil, fault("STORAGE", "initialize binding surface") end
    if inserted.rows_affected ~= 1 then return nil, fault("CONFLICT", "binding surface already exists") end
    return {surface_json = surface, active_json = active, context_json = context, revision = 1}, nil
end
function M.replace(tx: sql.Transaction, binding_id: string, expected_revision: integer, active: string, context: string): (State?, Fault?)
    if not bounds.id(binding_id) or expected_revision < 1 or expected_revision >= 9007199254740991
        or not text(active, 8192) or not text(context, 16384) then return nil, fault("INVALID", "invalid surface replacement") end
    local updated, err = tx:execute("UPDATE bee_gateway_surfaces SET active_json = ?, context_json = ?, revision = revision + 1 WHERE binding_id = ? AND revision = ?",
        {active, context, binding_id, expected_revision})
    if err or not updated then return nil, fault("STORAGE", "update binding surface") end
    if updated.rows_affected ~= 1 then return nil, fault("CONFLICT", "binding surface changed or is absent") end
    return M.read(tx, binding_id)
end
return M
