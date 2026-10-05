-- MIT. Complete the approval owner store to its full schema: requests, the outbox and approval windows take their full definitions, and runtime leases and their uses are added.
-- A table whose definition changes is renamed aside, created again and given
-- its rows back; foreign keys are checked when the migration commits.
local STATEMENTS = {
    [[PRAGMA defer_foreign_keys = ON]],
    [[DROP INDEX bee_approval_requests_pending]],
    [[DROP INDEX bee_approval_requests_workspace]],
    [[DROP INDEX bee_approval_outbox_due]],
    [[DROP INDEX bee_approval_window_match]],
    [[ALTER TABLE bee_approval_history RENAME TO bee_approval_history_prev]],
    [[ALTER TABLE bee_approval_requests RENAME TO bee_approval_requests_prev]],
    [[ALTER TABLE bee_approval_outbox RENAME TO bee_approval_outbox_prev]],
    [[ALTER TABLE bee_approval_window_grants RENAME TO bee_approval_window_grants_prev]],
    [[CREATE TABLE bee_approval_history ( approval_id TEXT NOT NULL REFERENCES bee_approval_requests(approval_id), revision INTEGER NOT NULL, state TEXT NOT NULL, decision TEXT, actor_id TEXT NOT NULL, reason TEXT NOT NULL, at TEXT NOT NULL, PRIMARY KEY (approval_id, revision) )]],
    [[CREATE TABLE "bee_approval_requests" ( approval_id TEXT PRIMARY KEY, owner_node TEXT NOT NULL, owner_incarnation INTEGER NOT NULL, workspace_id TEXT NOT NULL, requester_id TEXT NOT NULL, requester_key TEXT NOT NULL, request_digest TEXT NOT NULL, request_kind TEXT NOT NULL CHECK (request_kind IN ('permission', 'question')), policy TEXT NOT NULL, proposal_json TEXT NOT NULL CHECK (length(CAST(proposal_json AS BLOB)) <= 8192), proposal_digest TEXT NOT NULL, prompt_json TEXT NOT NULL, response_schema_json TEXT NOT NULL CHECK (length(CAST(response_schema_json AS BLOB)) <= 4096), thread_id TEXT, binding_json TEXT, revision INTEGER NOT NULL CHECK (revision > 0), state TEXT NOT NULL CHECK (state IN ('pending', 'decided', 'expired', 'withdrawn')), decision TEXT CHECK (decision IN ('approved', 'denied')), decider_id TEXT, decided_at TEXT, response_json TEXT, validated_incarnation INTEGER, validated_by TEXT, validated_at TEXT, consumer_id TEXT, consumed_effect TEXT, consumed_at TEXT, expires_ms INTEGER NOT NULL, expires_at TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, effect_completed_at TEXT, effect_result_json TEXT, window_grant_id TEXT, allowed_by_grant TEXT, UNIQUE (requester_id, requester_key) )]],
    [[CREATE TABLE "bee_approval_outbox" ( event_id TEXT PRIMARY KEY, approval_id TEXT NOT NULL REFERENCES bee_approval_requests(approval_id), revision INTEGER NOT NULL, thread_id TEXT NOT NULL, kind TEXT NOT NULL CHECK (kind IN ('approval.request', 'approval.transition', 'message')), body_json TEXT NOT NULL CHECK (length(CAST(body_json AS BLOB)) <= 16384), context_json TEXT, attempts INTEGER NOT NULL DEFAULT 0, next_attempt_ms INTEGER NOT NULL, lease_owner TEXT, lease_until_ms INTEGER, acknowledged_at TEXT, exhausted_at TEXT, last_error TEXT, created_at TEXT NOT NULL )]],
    [[CREATE TABLE "bee_approval_window_grants" ( grant_id TEXT PRIMARY KEY, owner_node TEXT NOT NULL, workspace_id TEXT NOT NULL, requester_id TEXT NOT NULL, policy TEXT NOT NULL, scope_digest TEXT NOT NULL, granted_by TEXT NOT NULL, granted_definition TEXT, granted_ms INTEGER NOT NULL, granted_at TEXT NOT NULL, until_ms INTEGER NOT NULL CHECK (until_ms > granted_ms), until_at TEXT NOT NULL, revoked_at TEXT )]],
    [[CREATE TABLE bee_approval_runtime_leases ( lease_ref TEXT PRIMARY KEY, owner_node TEXT NOT NULL, subject TEXT NOT NULL, workspace_id TEXT NOT NULL, tool TEXT NOT NULL, input_digest TEXT NOT NULL, expires_ms INTEGER NOT NULL, max_uses INTEGER NOT NULL CHECK (max_uses > 0), revoked_at TEXT, source_digest TEXT NOT NULL )]],
    [[CREATE TABLE bee_approval_runtime_lease_uses ( lease_ref TEXT NOT NULL REFERENCES bee_approval_runtime_leases(lease_ref), effect_key TEXT NOT NULL, request_digest TEXT NOT NULL, PRIMARY KEY (lease_ref, effect_key) )]],
    [[INSERT INTO bee_approval_requests (approval_id, owner_node, owner_incarnation, workspace_id, requester_id, requester_key, request_digest, request_kind, policy, proposal_json, proposal_digest, prompt_json, response_schema_json, thread_id, binding_json, revision, state, decision, decider_id, decided_at, response_json, validated_incarnation, validated_by, validated_at, consumer_id, consumed_effect, consumed_at, expires_ms, expires_at, created_at, updated_at, window_grant_id, allowed_by_grant) SELECT approval_id, owner_node, owner_incarnation, workspace_id, requester_id, requester_key, request_digest, request_kind, policy, proposal_json, proposal_digest, prompt_json, response_schema_json, thread_id, binding_json, revision, state, decision, decider_id, decided_at, response_json, validated_incarnation, validated_by, validated_at, consumer_id, consumed_effect, consumed_at, expires_ms, expires_at, created_at, updated_at, window_grant_id, allowed_by_grant FROM bee_approval_requests_prev]],
    [[INSERT INTO bee_approval_outbox (event_id, approval_id, revision, thread_id, kind, body_json, context_json, attempts, next_attempt_ms, acknowledged_at, exhausted_at, last_error, created_at) SELECT event_id, approval_id, revision, thread_id, kind, body_json, context_json, attempts, 0, acknowledged_at, exhausted_at, last_error, created_at FROM bee_approval_outbox_prev]],
    [[INSERT INTO bee_approval_window_grants (grant_id, owner_node, workspace_id, requester_id, policy, scope_digest, granted_by, granted_ms, granted_at, until_ms, until_at, revoked_at) SELECT grant_id, owner_node, workspace_id, requester_id, policy, scope_digest, granted_by, granted_ms, granted_at, until_ms, until_at, revoked_at FROM bee_approval_window_grants_prev]],
    [[INSERT INTO bee_approval_history (approval_id, revision, state, decision, actor_id, reason, at) SELECT approval_id, revision, state, decision, actor_id, reason, at FROM bee_approval_history_prev]],
    [[DROP TABLE bee_approval_history_prev]],
    [[DROP TABLE bee_approval_outbox_prev]],
    [[DROP TABLE bee_approval_requests_prev]],
    [[DROP TABLE bee_approval_window_grants_prev]],
    [[CREATE INDEX bee_approval_requests_pending ON bee_approval_requests (state, expires_ms)]],
    [[CREATE INDEX bee_approval_requests_workspace ON bee_approval_requests (workspace_id, state)]],
    [[CREATE INDEX bee_approval_requests_effects ON bee_approval_requests (state, decision, effect_completed_at, approval_id)]],
    [[CREATE INDEX bee_approval_outbox_due ON bee_approval_outbox (acknowledged_at, exhausted_at, next_attempt_ms)]],
    [[CREATE INDEX bee_approval_window_match ON bee_approval_window_grants (owner_node, workspace_id, requester_id, policy, scope_digest, until_ms)]],
}


return require("migration").define(function()
    migration("Complete the approval owner store to its full schema: requests, the outbox and approval windows take their full definitions, and runtime leases and their uses are added", function()
        database("sqlite", function()
            up(function(db)
                for _, statement in ipairs(STATEMENTS) do
                    local _, err = db:execute(statement)
                    if err then error(err) end
                end
            end)
        end)
    end)
end)
