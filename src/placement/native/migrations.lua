-- MIT. The placement receipts schema as an ordered ledger. Migration text is
-- part of its checksum; a change is a new migration.
local M = {}
type Migration = {id: integer, name: string, sql: string, rebuild: boolean}
local ATTEMPTS_SQL = [[
CREATE TABLE bee_placement_attempts (
    attempt_id TEXT PRIMARY KEY,
    owner_id TEXT NOT NULL,
    owner_incarnation INTEGER NOT NULL CHECK (owner_incarnation > 0),
    action_id TEXT NOT NULL,
    idempotency_key TEXT NOT NULL,
    request_digest TEXT NOT NULL,
    request_json TEXT NOT NULL,
    grants_json TEXT,
    execution_state TEXT NOT NULL CHECK (execution_state IN ('intended', 'starting', 'running', 'stopping', 'exited', 'uncertain')),
    cleanup_state TEXT NOT NULL CHECK (cleanup_state IN ('pending', 'complete', 'uncertain')),
    capability TEXT NOT NULL CHECK (capability IN ('direct_process', 'process_group', 'contained_tree')),
    required_cleanup TEXT NOT NULL CHECK (required_cleanup IN ('direct_process', 'process_group', 'contained_tree')),
    exit_observation TEXT NOT NULL CHECK (exit_observation IN ('independent', 'eof_gated')),
    exit_source TEXT CHECK (exit_source IN ('runner', 'reconcile')),
    attachment_generation INTEGER NOT NULL DEFAULT 0 CHECK (attachment_generation >= 0),
    recipient TEXT,
    runner_pid TEXT,
    home_key TEXT,
    session_ref TEXT,
    pid INTEGER,
    pgid INTEGER,
    start_ticks INTEGER,
    boot_id TEXT,
    exit_code INTEGER,
    exit_signal INTEGER,
    evidence_count INTEGER NOT NULL DEFAULT 0 CHECK (evidence_count >= 0),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE (owner_id, idempotency_key)
);
CREATE INDEX bee_placement_attempts_action ON bee_placement_attempts (owner_id, action_id);
CREATE TABLE bee_placement_evidence (
    attempt_id TEXT NOT NULL REFERENCES bee_placement_attempts (attempt_id),
    sequence INTEGER NOT NULL CHECK (sequence > 0),
    at TEXT NOT NULL,
    kind TEXT NOT NULL,
    detail TEXT NOT NULL,
    PRIMARY KEY (attempt_id, sequence)
);
]]
local list: {Migration} = {
    {id = 1, name = "placement_attempts", sql = ATTEMPTS_SQL, rebuild = false},
}
function M.all(): {Migration}
    return list
end
return M
