-- MIT. Transaction-local storage of an admitted MCP surface and its selection.
-- The caller owns authorization, decoding and transaction commit/rollback.
local bounds = require("bounds")
local json = require("json")
local M = {}
type State = {surface_json: string, active_json: string, context_json: string, revision: integer}
type Fault = {code: string, message: string}
type Grant = {approval_id: string, proposal_digest: string, traits: {string}}
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
-- The approval owner has consumed the exact effect before this transaction.
-- Recording the receipt and revision together makes a lost commit reply replayable.
function M.grants(tx: sql.Transaction, binding_id: string): ({string}?, Fault?)
    local rows, err = tx:query("SELECT traits_json FROM bee_gateway_access_grants WHERE binding_id = ?", {binding_id})
    if not rows or err then return nil, fault("STORAGE", "read MCP access grants") end
    if #rows > 64 then return nil, fault("STORAGE", "MCP access receipt capacity exceeded") end
    local result: {string} = {}
    local seen: {[string]: boolean} = {}
    for _, raw in ipairs(rows) do
        local row = bounds.object(raw)
        local encoded = row and bounds.text(row.traits_json, 8192)
        if not encoded then return nil, fault("STORAGE", "invalid grant receipt") end
        local decoded, decode_error = json.decode(encoded)
        local traits, traits_error = bounds.ids(decoded, true)
        if decode_error or not traits then return nil, fault("STORAGE", traits_error or "invalid grant traits") end
        for _, id in ipairs(traits) do
            if not seen[id] then seen[id] = true; result[#result + 1] = id end
        end
    end
    if #result > 64 then return nil, fault("STORAGE", "too many granted traits") end
    table.sort(result)
    return result, nil
end
-- A receipt is durable evidence, not a new authorization mechanism.  When
-- several approved effects carry one trait, the explicit approval-ID order
-- makes the provenance selected for a retried runtime call stable.
function M.runtime_grant(tx: sql.Transaction, binding_id: string, trait_id: string): (Grant?, Fault?)
    if not bounds.id(binding_id) or not bounds.id(trait_id) then return nil, fault("INVALID", "invalid runtime receipt lookup") end
    local rows, err = tx:query("SELECT approval_id, proposal_digest, traits_json FROM bee_gateway_access_grants WHERE binding_id = ? ORDER BY approval_id ASC", {binding_id})
    if not rows or err then return nil, fault("STORAGE", "read application runtime access receipt") end
    if #rows > 64 then return nil, fault("STORAGE", "MCP access receipt capacity exceeded") end
    for _, raw in ipairs(rows) do
        local row = bounds.object(raw)
        local approval_id = row and bounds.id(row.approval_id)
        local proposal_digest = row and bounds.text(row.proposal_digest, 64)
        local encoded = row and bounds.text(row.traits_json, 8192)
        local decoded: unknown = nil
        local decode_error: string? = nil
        if encoded then decoded, decode_error = json.decode(encoded) end
        local traits, traits_error = bounds.ids(decoded, true)
        if not approval_id or not proposal_digest or #proposal_digest ~= 64 or not proposal_digest:match("^[0-9a-f]+$") or decode_error or not traits then
            return nil, fault("STORAGE", traits_error or "invalid application runtime access receipt")
        end
        for _, id in ipairs(traits) do
            if id == trait_id then return {approval_id = approval_id :: string, proposal_digest = proposal_digest :: string, traits = traits}, nil end
        end
    end
    return nil, nil
end
function M.grant(tx: sql.Transaction, binding_id: string, approval_id: string, digest: string, traits_json: string): (State?, Fault?)
    if not bounds.id(binding_id) or not bounds.id(approval_id) or #digest ~= 64 or not digest:match("^%x+$")
        or not text(traits_json, 8192) then return nil, fault("INVALID", "invalid grant receipt") end
    local rows, err = tx:query("SELECT proposal_digest, traits_json FROM bee_gateway_access_grants WHERE binding_id = ? AND approval_id = ?", {binding_id, approval_id})
    if not rows or err then return nil, fault("STORAGE", "read grant receipt") end
    if #rows > 0 then
        local row = bounds.object(rows[1])
        if not row or row.proposal_digest ~= digest or row.traits_json ~= traits_json then return nil, fault("CONFLICT", "grant receipt differs") end
        return M.read(tx, binding_id)
    end
    local count, count_error = tx:query("SELECT COUNT(*) AS n FROM bee_gateway_access_grants WHERE binding_id = ?", {binding_id})
    if not count or count_error then return nil, fault("STORAGE", "count grant receipts") end
    local first = bounds.object(count[1])
    local n = first and bounds.count(first.n)
    if not n then return nil, fault("STORAGE", "invalid grant count") end
    if n >= 64 then return nil, fault("LIMIT_EXCEEDED", "MCP grant receipt capacity reached") end
    local current, current_error = M.read(tx, binding_id)
    if not current then return nil, current_error end
    local old_raw, old_error = json.decode(current.active_json)
    local added_raw, added_error = json.decode(traits_json)
    local active = bounds.ids(old_raw, true)
    local added = bounds.ids(added_raw, true)
    if old_error or added_error or not active or not added then return nil, fault("STORAGE", "invalid active traits") end
    local seen: {[string]: boolean} = {}
    for _, id in ipairs(active) do seen[id] = true end
    for _, id in ipairs(added) do if not seen[id] then active[#active + 1] = id; seen[id] = true end end
    if #active > 64 then return nil, fault("LIMIT_EXCEEDED", "too many active traits") end
    table.sort(active)
    local active_json, encode_error = json.encode(active)
    if not active_json or encode_error then return nil, fault("STORAGE", "encode active traits") end
    local inserted, insert_error = tx:execute("INSERT INTO bee_gateway_access_grants (binding_id, approval_id, proposal_digest, traits_json) VALUES (?, ?, ?, ?)", {binding_id, approval_id, digest, traits_json})
    if not inserted or insert_error then return nil, fault("STORAGE", "record MCP grant receipt") end
    local updated, update_error = tx:execute("UPDATE bee_gateway_surfaces SET active_json = ?, revision = revision + 1 WHERE binding_id = ? AND revision < 9007199254740991", {active_json, binding_id})
    if not updated or update_error or updated.rows_affected ~= 1 then return nil, fault("STORAGE", "advance MCP grant revision") end
    return M.read(tx, binding_id)
end
return M
