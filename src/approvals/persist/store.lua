-- MIT. SQL access for approval requests, their history and workspace feed.
local sql = require("sql")
local bounds = require("bounds")
local windows = require("windows")
local canonical = require("canonical")
local lifecycle = require("lifecycle")
local M = {}
type NewRequest = {
    approval_id: string, owner_node: string, owner_incarnation: integer, workspace_id: string,
    requester_id: string, requester_key: string, request_digest: string, request_kind: string,
    policy: string, proposal_json: string, proposal_digest: string, prompt_json: string,
    response_schema_json: string, thread_id: string?, binding_json: string?, expires_ms: integer,
    expires_at: string, created_at: string,
}

local function query(tx: sql.Transaction, statement: string, params: {unknown}): ({unknown}?, string?)
    local rows, err = tx:query(statement, params)
    if err or not rows then return nil, "approval store query failed: " .. tostring(err) end
    return rows, nil
end

local function execute(tx: sql.Transaction, statement: string, params: {unknown}, detail: string): string?
    local _, err = tx:execute(statement, params)
    if err then return detail .. ": " .. tostring(err) end
    return nil
end

function M.request(tx: sql.Transaction, approval_id: string): (unknown?, string?)
    local found, err = query(tx, "SELECT * FROM bee_approval_requests WHERE approval_id = ?", {approval_id})
    if err then return nil, err end
    if not found or #found == 0 then return nil, nil end
    return found[1], nil
end

function M.request_by_key(tx: sql.Transaction, requester_id: string, requester_key: string): ({unknown}?, string?)
    return query(tx, "SELECT * FROM bee_approval_requests WHERE requester_id = ? AND requester_key = ?", {requester_id, requester_key})
end

function M.pending_count(tx: sql.Transaction, requester_id: string): (unknown?, string?)
    local found, err = query(tx, "SELECT COUNT(*) AS count FROM bee_approval_requests WHERE requester_id = ? AND state = 'pending'", {requester_id})
    if err then return nil, err end
    local values = found and bounds.object(found[1]) or nil
    if not values then return nil, nil end
    return values.count, nil
end

function M.authority(tx: sql.Transaction, owner_node: string): (unknown?, boolean, string?)
    local found, err = query(tx, "SELECT incarnation FROM bee_approval_authority WHERE owner_node = ?", {owner_node})
    if err then return nil, false, err end
    if not found or #found == 0 then return nil, false, nil end
    local values = found and bounds.object(found[1]) or nil
    if not values then return nil, true, nil end
    return values.incarnation, true, nil
end

function M.write_authority(tx: sql.Transaction, owner_node: string, incarnation: integer, established_at: string): string?
    return execute(tx, "INSERT INTO bee_approval_authority (owner_node, incarnation, established_at) VALUES (?, ?, ?) ON CONFLICT(owner_node) DO UPDATE SET incarnation = excluded.incarnation, established_at = excluded.established_at",
        {owner_node, incarnation, established_at}, "establish authority incarnation")
end

function M.insert_request(tx: sql.Transaction, value: NewRequest): string?
    return execute(tx, "INSERT INTO bee_approval_requests (approval_id, owner_node, owner_incarnation, workspace_id, requester_id, requester_key, request_digest, request_kind, policy, proposal_json, proposal_digest, prompt_json, response_schema_json, thread_id, binding_json, revision, state, expires_ms, expires_at, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, 'pending', ?, ?, ?, ?)",
        {value.approval_id, value.owner_node, value.owner_incarnation, value.workspace_id, value.requester_id, value.requester_key,
            value.request_digest, value.request_kind, value.policy, value.proposal_json, value.proposal_digest, value.prompt_json,
            value.response_schema_json, value.thread_id, value.binding_json, value.expires_ms, value.expires_at,
            value.created_at, value.created_at}, "record approval request")
end

function M.insert_history(tx: sql.Transaction, approval_id: string, revision: integer, state: string, decision: string?,
    actor_id: string, reason: string, at: string): string?
    return execute(tx, "INSERT INTO bee_approval_history (approval_id, revision, state, decision, actor_id, reason, at) VALUES (?, ?, ?, ?, ?, ?, ?)",
        {approval_id, revision, state, decision, actor_id, reason, at}, "record approval history")
end

function M.insert_inbox(tx: sql.Transaction, workspace_id: string, approval_id: string, revision: integer, at: string): string?
    return execute(tx, "INSERT INTO bee_approval_inbox (workspace_id, approval_id, revision, at) VALUES (?, ?, ?, ?)",
        {workspace_id, approval_id, revision, at}, "record inbox change")
end

function M.transition(tx: sql.Transaction, approval_id: string, revision: integer, state: string, decision: string?,
    decider_id: string?, decided_at: string?, response_json: string?, updated_at: string): string?
    return execute(tx, "UPDATE bee_approval_requests SET revision = ?, state = ?, decision = ?, decider_id = ?, decided_at = ?, response_json = ?, updated_at = ? WHERE approval_id = ? AND state = 'pending'",
        {revision, state, decision, decider_id, decided_at, response_json, updated_at, approval_id}, "settle approval request")
end

function M.validate_effect(tx: sql.Transaction, approval_id: string, incarnation: integer, actor: string, at: string): string?
    return execute(tx, "UPDATE bee_approval_requests SET validated_incarnation = ?, validated_by = ?, validated_at = ?, updated_at = ? WHERE approval_id = ?",
        {incarnation, actor, at, at, approval_id}, "record approval validation")
end

function M.consume(tx: sql.Transaction, approval_id: string, actor: string, effect_key: string, at: string): string?
    return execute(tx, "UPDATE bee_approval_requests SET consumer_id = ?, consumed_effect = ?, consumed_at = ?, updated_at = ? WHERE approval_id = ? AND consumed_effect IS NULL",
        {actor, effect_key, at, at, approval_id}, "consume approval")
end

function M.complete_effect(tx: sql.Transaction, approval_id: string, completed_at: string, result_json: string, updated_at: string, state: string?): string?
    local effect, read_error = lifecycle.read(tx, approval_id)
    if not effect then return read_error end
    local lifecycle_error = lifecycle.complete(tx, approval_id, state or (effect.state == "canceled" and "canceled" or "succeeded"), result_json, updated_at)
    if lifecycle_error then return lifecycle_error end
    local ack_error = lifecycle.ack_effect(tx, approval_id, updated_at)
    if ack_error then return ack_error end
    return execute(tx, "UPDATE bee_approval_requests SET effect_completed_at = ?, effect_result_json = ?, updated_at = ? WHERE approval_id = ? AND effect_completed_at IS NULL",
        {completed_at, result_json, updated_at, approval_id}, "complete approval effect")
end

function M.oldest_inbox(tx: sql.Transaction, workspace_id: string): (unknown?, string?)
    local found, err = query(tx, "SELECT MIN(seq) AS seq FROM bee_approval_inbox WHERE workspace_id = ?", {workspace_id})
    if err then return nil, err end
    local values = found and bounds.object(found[1]) or nil
    if not values then return nil, nil end
    return values.seq, nil
end

function M.inbox_after(tx: sql.Transaction, workspace_id: string, after: integer, limit: integer): ({unknown}?, string?)
    return query(tx, "SELECT seq, approval_id, revision, at FROM bee_approval_inbox WHERE workspace_id = ? AND seq > ? ORDER BY seq LIMIT ?",
        {workspace_id, after, limit})
end

function M.inbox_head(tx: sql.Transaction): (unknown?, boolean, string?)
    local found, err = query(tx, "SELECT seq FROM sqlite_sequence WHERE name = 'bee_approval_inbox'", {})
    if err then return nil, false, err end
    if not found or #found == 0 then return nil, false, nil end
    local values = bounds.object(found[1])
    if not values then return nil, true, nil end
    return values.seq, true, nil
end

function M.snapshot(tx: sql.Transaction, workspace_id: string, after_key: string, limit: integer): ({unknown}?, string?)
    return query(tx, [[SELECT r.*, (SELECT MAX(i.seq) FROM bee_approval_inbox i WHERE i.approval_id = r.approval_id) AS last_sequence
        FROM bee_approval_requests r WHERE r.workspace_id = ? AND r.approval_id > ? ORDER BY r.approval_id LIMIT ?]],
        {workspace_id, after_key, limit})
end

function M.list(tx: sql.Transaction, requester_id: string, workspace_id: string?, limit: integer): ({unknown}?, string?)
    if workspace_id then
        return query(tx, "SELECT * FROM bee_approval_requests WHERE requester_id = ? AND workspace_id = ? ORDER BY created_at DESC LIMIT ?",
            {requester_id, workspace_id, limit})
    end
    return query(tx, "SELECT * FROM bee_approval_requests WHERE requester_id = ? ORDER BY created_at DESC LIMIT ?", {requester_id, limit})
end

function M.due(tx: sql.Transaction, now: integer, limit: integer): ({unknown}?, string?)
    return query(tx, "SELECT * FROM bee_approval_requests WHERE state = 'pending' AND expires_ms <= ? ORDER BY expires_ms LIMIT ?", {now, limit})
end

function M.retained(tx: sql.Transaction, horizon: integer, now: integer, limit: integer): ({unknown}?, string?)
    return query(tx, "SELECT approval_id FROM bee_approval_requests WHERE state <> 'pending' AND expires_ms < ? AND NOT EXISTS (SELECT 1 FROM bee_approval_grants g WHERE g.approval_id = bee_approval_requests.approval_id AND g.domain <> 'decision' AND g.revoked_at IS NULL AND (g.until_ms IS NULL OR g.until_ms > ?)) AND NOT EXISTS (SELECT 1 FROM bee_approval_events e WHERE e.approval_id = bee_approval_requests.approval_id AND e.acknowledged_at IS NULL) AND NOT EXISTS (SELECT 1 FROM bee_approval_effects f WHERE f.approval_id = bee_approval_requests.approval_id AND f.state NOT IN ('succeeded','failed','canceled')) AND NOT EXISTS (SELECT 1 FROM bee_approval_outbox o WHERE o.approval_id = bee_approval_requests.approval_id AND o.acknowledged_at IS NULL) LIMIT ?",
        {horizon, now, limit})
end

function M.forget(tx: sql.Transaction, approval_id: string): string?
    for _, statement in ipairs({"DELETE FROM bee_approval_events WHERE approval_id = ?", "DELETE FROM bee_approval_effects WHERE approval_id = ?", "DELETE FROM bee_approval_grants WHERE approval_id = ? AND NOT EXISTS (SELECT 1 FROM bee_approval_requests r WHERE r.window_grant_id = bee_approval_grants.grant_id AND r.approval_id <> bee_approval_grants.approval_id)", "DELETE FROM bee_approval_decisions WHERE approval_id = ?", "DELETE FROM bee_approval_outbox WHERE approval_id = ?", "DELETE FROM bee_approval_inbox WHERE approval_id = ?",
        "DELETE FROM bee_approval_history WHERE approval_id = ?", "DELETE FROM bee_approval_requests WHERE approval_id = ?"}) do
        local err = execute(tx, statement, {approval_id}, "forget retained request")
        if err then return err end
    end
    return nil
end

function M.forget_grants(tx: sql.Transaction, horizon: integer): string?
    return execute(tx, [[DELETE FROM bee_approval_grants WHERE until_ms < ?
        AND NOT EXISTS (SELECT 1 FROM bee_approval_requests r WHERE r.approval_id = bee_approval_grants.approval_id OR r.window_grant_id = bee_approval_grants.grant_id)]], {horizon}, "forget retained grants")
end
function M.attention_count(tx: sql.Transaction, workspace: string, now: integer): (integer?, string?)
    local rows, err = query(tx, "SELECT COUNT(*) AS count FROM bee_approval_requests WHERE workspace_id = ? AND state = 'pending' AND expires_ms > ?", {workspace, now})
    if err or not rows or #rows ~= 1 then return nil, err or "count attention" end
    local row = rows[1]
    if type(row.count) ~= "number" or row.count < 0 or row.count ~= math.floor(row.count) then return nil, "attention count is corrupt" end
    return math.floor(row.count), nil
end
function M.attention_target(tx: sql.Transaction, workspace: string, now: integer): (unknown?, string?)
    local rows, err = query(tx, "SELECT approval_id, prompt_json FROM bee_approval_requests WHERE workspace_id = ? AND state = 'pending' AND expires_ms > ? ORDER BY created_at DESC, approval_id DESC LIMIT 1", {workspace, now})
    if err or not rows then return nil, err or "read attention target" end
    return rows[1], nil
end
function M.node_pending_count(tx: sql.Transaction, node: string, now: integer): (integer?, string?)
    local rows, err = query(tx, "SELECT COUNT(*) AS count FROM bee_approval_requests WHERE owner_node = ? AND state = 'pending' AND expires_ms > ?", {node, now})
    if err or not rows or #rows ~= 1 then return nil, err or "count node pending approvals" end
    local count = rows[1].count
    if type(count) ~= "number" or count < 0 or count ~= math.floor(count) then return nil, "node pending approval count is corrupt" end
    return math.floor(count), nil
end
local WINDOW_COLUMNS = "grant_id, owner_node, workspace_id, requester_id, policy, scope_digest, granted_by, granted_definition, granted_ms, granted_at, until_ms, until_at, revoked_at"
local WINDOW_SOURCE = "(SELECT grant_id,owner_node,workspace_id,requester_id,json_extract(metadata_json,'$.policy') AS policy,json_extract(metadata_json,'$.scope_digest') AS scope_digest,granted_by,granted_definition,json_extract(metadata_json,'$.granted_ms') AS granted_ms,created_at AS granted_at,until_ms,json_extract(metadata_json,'$.until_at') AS until_at,revoked_at FROM bee_approval_grants WHERE domain = 'approval_window')"
function M.matching_windows(tx: sql.Transaction, owner: string, workspace: string, requester: string, policy: string, digest: string): ({unknown}?, string?)
    return query(tx, "SELECT " .. WINDOW_COLUMNS .. " FROM " .. WINDOW_SOURCE .. " WHERE owner_node = ? AND workspace_id = ? AND requester_id = ? AND policy = ? AND scope_digest = ? ORDER BY granted_ms DESC, grant_id DESC LIMIT 1",
        {owner, workspace, requester, policy, digest})
end
function M.window(tx: sql.Transaction, id: string): (unknown?, string?)
    local rows, err = query(tx, "SELECT " .. WINDOW_COLUMNS .. " FROM " .. WINDOW_SOURCE .. " WHERE grant_id = ?", {id})
    if err then return nil, err end
    return rows and rows[1], nil
end
function M.insert_window(tx: sql.Transaction, grant: windows.Grant): string?
    local metadata = canonical.encode({policy = grant.policy, scope_digest = grant.scope_digest, granted_ms = grant.granted_ms, until_at = grant.until_at})
    return execute(tx, [[INSERT INTO bee_approval_grants(grant_id,approval_id,subject_json,scope_json,terms_json,state,revision,until_ms,max_uses,created_at,domain,owner_node,workspace_id,requester_id,granted_by,granted_definition,metadata_json,provenance_json)
        SELECT ?,approval_id,json_extract(contract_json,'$.subject'),json_extract(contract_json,'$.scope'),?, 'active',1,?,NULL,?,'approval_window',?,?,?,?,?,?,json_object('kind','decision','approval_id',approval_id,'reviewed_digest',reviewed_digest) FROM bee_approval_requests WHERE approval_id = ?]],
        {grant.grant_id, grant.until_ms == windows.PERMANENT_UNTIL_MS and '{"kind":"until_revoked","time_basis":"absolute"}' or '{"kind":"window","time_basis":"absolute"}', grant.until_ms, grant.granted_at, grant.owner_node, grant.workspace_id, grant.requester_id, grant.granted_by, grant.granted_definition, metadata, grant.grant_id}, "record approval window grant")
end
function M.supersede_windows(tx: sql.Transaction, grant: windows.Grant): string?
    return execute(tx, "UPDATE bee_approval_grants SET state = 'revoked', revision = revision + 1, revoked_at = ? WHERE domain = 'approval_window' AND owner_node = ? AND workspace_id = ? AND requester_id = ? AND json_extract(metadata_json,'$.policy') = ? AND json_extract(metadata_json,'$.scope_digest') = ? AND revoked_at IS NULL",
        {grant.granted_at, grant.owner_node, grant.workspace_id, grant.requester_id, grant.policy, grant.scope_digest}, "supersede approval window")
end
function M.attach_window(tx: sql.Transaction, approval_id: string, grant_id: string, automatic: boolean): string?
    return execute(tx, "UPDATE bee_approval_requests SET window_grant_id = ?, allowed_by_grant = ? WHERE approval_id = ?",
        {grant_id, automatic and grant_id or nil, approval_id}, "record approval window settlement")
end
function M.active_windows(tx: sql.Transaction, owner: string, workspace: string, actor: string, definition: string?, now: integer, after: string): ({unknown}?, string?)
    return query(tx, "SELECT " .. WINDOW_COLUMNS .. " FROM " .. WINDOW_SOURCE .. " WHERE owner_node = ? AND workspace_id = ? AND (granted_by = ? OR granted_definition = ?) AND revoked_at IS NULL AND until_ms > ? AND grant_id > ? ORDER BY grant_id LIMIT 65",
        {owner, workspace, actor, definition, now, after})
end
function M.revoke_window(tx: sql.Transaction, id: string, at: string): string?
    local err = execute(tx, "UPDATE bee_approval_grants SET state = 'revoked', revision = revision + 1, revoked_at = ?, revoked_by = granted_by WHERE grant_id = ? AND state <> 'revoked'", {at, id}, "revoke approval window")
    if err then return err end
    return execute(tx, "INSERT OR IGNORE INTO bee_approval_grant_history SELECT grant_id,revision,'grant.revoked',granted_by,'{}',? FROM bee_approval_grants WHERE grant_id = ?", {at,id}, "record window revocation")
end
return M
