-- MIT. SQL access for approval requests, their history and workspace feed.
local sql = require("sql")
local bounds = require("bounds")
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
    if err or not rows then return nil, "approval store query failed" end
    return rows, nil
end

local function execute(tx: sql.Transaction, statement: string, params: {unknown}, detail: string): string?
    local _, err = tx:execute(statement, params)
    if err then return detail end
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

function M.installation_effects(tx: sql.Transaction, now: integer, limit: integer): ({unknown}?, string?)
    return query(tx, [[SELECT * FROM bee_approval_requests
        WHERE state = 'decided' AND decision = 'approved' AND effect_completed_at IS NULL
        AND ((consumed_effect IS NULL AND expires_ms > ?)
            OR (consumer_id = requester_id AND consumed_effect = 'hub-install:' || approval_id))
        AND proposal_json LIKE '%"ref":"bee.hub:apply"%'
        ORDER BY approval_id LIMIT ?]], {now, limit})
end

function M.publication_effects(tx: sql.Transaction, now: integer, limit: integer): ({unknown}?, string?)
    return query(tx, [[SELECT * FROM bee_approval_requests
        WHERE state = 'decided' AND decision = 'approved' AND effect_completed_at IS NULL
        AND ((consumed_effect IS NULL AND expires_ms > ?)
            OR (consumer_id = requester_id AND consumed_effect = 'hub-publish:' || approval_id))
        AND proposal_json LIKE '%"ref":"bee.hub:publish"%'
        ORDER BY approval_id LIMIT ?]], {now, limit})
end

function M.complete_effect(tx: sql.Transaction, approval_id: string, completed_at: string, result_json: string, updated_at: string): string?
    return execute(tx, "UPDATE bee_approval_requests SET effect_completed_at = ?, effect_result_json = ?, updated_at = ? WHERE approval_id = ? AND effect_completed_at IS NULL",
        {completed_at, result_json, updated_at, approval_id}, "complete installation effect")
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

function M.retained(tx: sql.Transaction, horizon: integer, limit: integer): ({unknown}?, string?)
    return query(tx, "SELECT approval_id FROM bee_approval_requests WHERE state <> 'pending' AND expires_ms < ? AND NOT EXISTS (SELECT 1 FROM bee_approval_outbox o WHERE o.approval_id = bee_approval_requests.approval_id AND o.acknowledged_at IS NULL) LIMIT ?",
        {horizon, limit})
end

function M.forget(tx: sql.Transaction, approval_id: string): string?
    for _, statement in ipairs({"DELETE FROM bee_approval_outbox WHERE approval_id = ?", "DELETE FROM bee_approval_inbox WHERE approval_id = ?",
        "DELETE FROM bee_approval_history WHERE approval_id = ?", "DELETE FROM bee_approval_requests WHERE approval_id = ?"}) do
        local err = execute(tx, statement, {approval_id}, "forget retained request")
        if err then return err end
    end
    return nil
end

return M
