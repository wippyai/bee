-- MIT.
local bounds = require("bounds")
local canonical = require("canonical")
local hash = require("hash")
local M = {}
M.PERMANENT_UNTIL_MS = 253402300799000
type Grant = {grant_id: string, owner_node: string, workspace_id: string, requester_id: string, policy: string,
    scope_digest: string, granted_by: string, granted_definition: string?, granted_ms: integer, granted_at: string,
    until_ms: integer, until_at: string, revoked_at: string?}
type Choice = {ttl_ms: integer, label: string}
function M.decode(value: unknown): (Grant?, string?)
    local row = bounds.object(value)
    if not row or bounds.fields(row, {"grant_id", "owner_node", "workspace_id", "requester_id", "policy", "scope_digest",
        "granted_by", "granted_definition", "granted_ms", "granted_at", "until_ms", "until_at", "revoked_at"}) then return nil, "window grant has invalid fields" end
    local id, owner, workspace = bounds.id(row.grant_id), bounds.id(row.owner_node), bounds.id(row.workspace_id)
    local requester, policy, person = bounds.id(row.requester_id), bounds.id(row.policy), bounds.id(row.granted_by)
    local definition = row.granted_definition == nil and nil or bounds.id(row.granted_definition)
    local from, until_ms = bounds.integer(row.granted_ms), bounds.integer(row.until_ms)
    local at, until_at = bounds.timestamp(row.granted_at), bounds.timestamp(row.until_at)
    local revoked = row.revoked_at == nil and nil or bounds.timestamp(row.revoked_at)
    local digest = row.scope_digest
    if not id or not owner or not workspace or not requester or not policy or not person or not from or not until_ms
        or until_ms <= from or not at or not until_at or (row.revoked_at ~= nil and not revoked)
        or (row.granted_definition ~= nil and not definition) or type(digest) ~= "string" or #digest ~= 64
        or not digest:match("^[0-9a-f]+$") then return nil, "window grant is corrupt" end
    return {grant_id = id, owner_node = owner, workspace_id = workspace, requester_id = requester, policy = policy,
        scope_digest = digest, granted_by = person, granted_definition = definition, granted_ms = from, granted_at = at,
        until_ms = until_ms, until_at = until_at, revoked_at = revoked}, nil
end
function M.scope_digest(proposal: {[string]: unknown}): (string?, string?)
    local scope: {[string]: unknown} = {}
    for key, value in pairs(proposal) do scope[key] = value end
    local payload = bounds.object(proposal.payload)
    if payload and not bounds.fields(payload, {"adapter_ref", "adapter_digest", "permission_request_id", "correlation_id", "tool_name", "action_id", "session_ref"})
        and bounds.id(payload.adapter_ref) and bounds.id(payload.permission_request_id) and bounds.id(payload.correlation_id)
        and bounds.id(payload.tool_name) and type(payload.adapter_digest) == "string" and #payload.adapter_digest == 64
        and payload.adapter_digest:match("^[0-9a-f]+$") and type(proposal.input_digest) == "string" and #proposal.input_digest == 64
        and proposal.input_digest:match("^[0-9a-f]+$") then
        local stable: {[string]: unknown} = {}
        for key, value in pairs(payload) do
            if key ~= "permission_request_id" and key ~= "correlation_id" then stable[key] = value end
        end
        scope.payload = stable
    end
    local encoded, encode_error = canonical.encode(scope, 8192)
    if not encoded then return nil, encode_error end
    local digest, hash_error = hash.sha256(encoded)
    if not digest or hash_error then return nil, tostring(hash_error or "window scope digest unavailable") end
    return digest, nil
end
function M.duration(ttl_ms: integer): string
    if ttl_ms % 3600000 == 0 then return tostring(ttl_ms // 3600000) .. " hours" end
    if ttl_ms % 60000 == 0 then return tostring(ttl_ms // 60000) .. " min" end
    return tostring(ttl_ms // 1000) .. " sec"
end
function M.choices(cap: integer, now: integer): {Choice}
    local choices: {Choice} = {}
    local end_day = 86400000 - now % 86400000
    for _, choice in ipairs({{ttl_ms = 1800000, label = "30 minutes"}, {ttl_ms = 14400000, label = "4 hours"},
        {ttl_ms = end_day, label = "end of day (UTC)"}, {ttl_ms = 86400000, label = "24 hours"}}) do
        if choice.ttl_ms <= cap then choices[#choices + 1] = choice end
    end
    return choices
end
return M
