-- MIT. The approval owner schema as an ordered ledger. Migration text is
-- part of its checksum; a change is a new migration.
local M = {}
type Migration = {id: integer, name: string, sql: string, rebuild: boolean}
local APPROVALS_SQL = [[
CREATE TABLE bee_approval_authority (
    owner_node TEXT PRIMARY KEY,
    incarnation INTEGER NOT NULL CHECK (incarnation > 0),
    established_at TEXT NOT NULL
);
CREATE TABLE bee_approval_requests (
    approval_id TEXT PRIMARY KEY,
    owner_node TEXT NOT NULL,
    owner_incarnation INTEGER NOT NULL,
    workspace_id TEXT NOT NULL,
    requester_id TEXT NOT NULL,
    requester_key TEXT NOT NULL,
    request_digest TEXT NOT NULL,
    request_kind TEXT NOT NULL CHECK (request_kind IN ('permission', 'question')),
    policy TEXT NOT NULL,
    proposal_json TEXT NOT NULL CHECK (length(CAST(proposal_json AS BLOB)) <= 8192),
    proposal_digest TEXT NOT NULL,
    prompt_json TEXT NOT NULL,
    response_schema_json TEXT NOT NULL CHECK (length(CAST(response_schema_json AS BLOB)) <= 4096),
    thread_id TEXT,
    binding_json TEXT,
    revision INTEGER NOT NULL CHECK (revision > 0),
    state TEXT NOT NULL CHECK (state IN ('pending', 'decided', 'expired', 'withdrawn')),
    decision TEXT CHECK (decision IN ('approved', 'denied')),
    decider_id TEXT,
    decided_at TEXT,
    response_json TEXT,
    validated_incarnation INTEGER,
    validated_by TEXT,
    validated_at TEXT,
    consumer_id TEXT,
    consumed_effect TEXT,
    consumed_at TEXT,
    expires_ms INTEGER NOT NULL,
    expires_at TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE (requester_id, requester_key)
);
CREATE INDEX bee_approval_requests_pending
    ON bee_approval_requests (state, expires_ms);
CREATE INDEX bee_approval_requests_workspace
    ON bee_approval_requests (workspace_id, state);
CREATE TABLE bee_approval_history (
    approval_id TEXT NOT NULL REFERENCES bee_approval_requests(approval_id),
    revision INTEGER NOT NULL,
    state TEXT NOT NULL,
    decision TEXT,
    actor_id TEXT NOT NULL,
    reason TEXT NOT NULL,
    at TEXT NOT NULL,
    PRIMARY KEY (approval_id, revision)
);
CREATE TABLE bee_approval_inbox (
    seq INTEGER PRIMARY KEY AUTOINCREMENT,
    workspace_id TEXT NOT NULL,
    approval_id TEXT NOT NULL,
    revision INTEGER NOT NULL,
    at TEXT NOT NULL
);
CREATE INDEX bee_approval_inbox_workspace
    ON bee_approval_inbox (workspace_id, seq);
CREATE TABLE bee_approval_outbox (
    event_id TEXT PRIMARY KEY,
    approval_id TEXT NOT NULL REFERENCES bee_approval_requests(approval_id),
    revision INTEGER NOT NULL,
    thread_id TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('approval.request', 'approval.transition')),
    body_json TEXT NOT NULL CHECK (length(CAST(body_json AS BLOB)) <= 16384),
    context_json TEXT,
    attempts INTEGER NOT NULL DEFAULT 0,
    next_attempt_ms INTEGER NOT NULL,
    lease_owner TEXT,
    lease_until_ms INTEGER,
    acknowledged_at TEXT,
    exhausted_at TEXT,
    last_error TEXT,
    created_at TEXT NOT NULL
);
CREATE INDEX bee_approval_outbox_due
    ON bee_approval_outbox (acknowledged_at, exhausted_at, next_attempt_ms);
]]
-- A decision notice is projected as a `message`, so the outbox carries that
-- family too. SQLite cannot widen a CHECK in place, so the table is rebuilt
-- and its rows are copied unchanged.
local NOTICE_SQL = [[
CREATE TABLE bee_approval_outbox_rebuilt (
    event_id TEXT PRIMARY KEY,
    approval_id TEXT NOT NULL REFERENCES bee_approval_requests(approval_id),
    revision INTEGER NOT NULL,
    thread_id TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('approval.request', 'approval.transition', 'message')),
    body_json TEXT NOT NULL CHECK (length(CAST(body_json AS BLOB)) <= 16384),
    context_json TEXT,
    attempts INTEGER NOT NULL DEFAULT 0,
    next_attempt_ms INTEGER NOT NULL,
    lease_owner TEXT,
    lease_until_ms INTEGER,
    acknowledged_at TEXT,
    exhausted_at TEXT,
    last_error TEXT,
    created_at TEXT NOT NULL
);
INSERT INTO bee_approval_outbox_rebuilt (event_id, approval_id, revision, thread_id, kind, body_json, context_json,
    attempts, next_attempt_ms, lease_owner, lease_until_ms, acknowledged_at, exhausted_at, last_error, created_at)
    SELECT event_id, approval_id, revision, thread_id, kind, body_json, context_json,
    attempts, next_attempt_ms, lease_owner, lease_until_ms, acknowledged_at, exhausted_at, last_error, created_at
    FROM bee_approval_outbox;
DROP TABLE bee_approval_outbox;
ALTER TABLE bee_approval_outbox_rebuilt RENAME TO bee_approval_outbox;
CREATE INDEX bee_approval_outbox_due
    ON bee_approval_outbox (acknowledged_at, exhausted_at, next_attempt_ms);
]]
local list: {Migration} = {
    {id = 1, name = "approvals", sql = APPROVALS_SQL, rebuild = false},
    {id = 2, name = "decision_notice", sql = NOTICE_SQL, rebuild = true},
}
function M.all(): {Migration}
    return list
end
return M
