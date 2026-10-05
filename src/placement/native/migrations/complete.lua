-- MIT. Complete the native placement store to its full schema: attempts take their full definition and session files are added.
-- A table whose definition changes is renamed aside, created again and given
-- its rows back; foreign keys are checked when the migration commits.
local STATEMENTS = {
    [[PRAGMA defer_foreign_keys = ON]],
    [[DROP INDEX bee_placement_attempts_action]],
    [[DROP INDEX bee_placement_attempts_state]],
    [[ALTER TABLE bee_placement_evidence RENAME TO bee_placement_evidence_prev]],
    [[ALTER TABLE bee_placement_preparer_states RENAME TO bee_placement_preparer_states_prev]],
    [[ALTER TABLE bee_placement_runner_authorities RENAME TO bee_placement_runner_authorities_prev]],
    [[ALTER TABLE bee_placement_attempts RENAME TO bee_placement_attempts_prev]],
    [[CREATE TABLE bee_placement_evidence ( attempt_id TEXT NOT NULL REFERENCES bee_placement_attempts (attempt_id), sequence INTEGER NOT NULL CHECK (sequence > 0), at TEXT NOT NULL, kind TEXT NOT NULL, detail TEXT NOT NULL, PRIMARY KEY (attempt_id, sequence) )]],
    [[CREATE TABLE bee_placement_preparer_states ( attempt_id TEXT NOT NULL REFERENCES bee_placement_attempts (attempt_id), binding_id TEXT NOT NULL, position INTEGER NOT NULL CHECK (position > 0), record_json TEXT NOT NULL CHECK (length(record_json) <= 65536), created_at TEXT NOT NULL, PRIMARY KEY (attempt_id, binding_id) )]],
    [[CREATE TABLE bee_placement_runner_authorities ( attempt_id TEXT PRIMARY KEY REFERENCES bee_placement_attempts (attempt_id), control_token TEXT NOT NULL UNIQUE )]],
    [[CREATE TABLE "bee_placement_attempts" ( attempt_id TEXT PRIMARY KEY, owner_id TEXT NOT NULL, owner_incarnation INTEGER NOT NULL CHECK (owner_incarnation > 0), action_id TEXT NOT NULL, idempotency_key TEXT NOT NULL, request_digest TEXT NOT NULL, request_json TEXT NOT NULL, grants_json TEXT, placement_kind TEXT, placement_spec_json TEXT, placement_identity_json TEXT, execution_state TEXT NOT NULL CHECK (execution_state IN ('intended', 'starting', 'running', 'stopping', 'exited', 'start_failed', 'uncertain')), cleanup_state TEXT NOT NULL CHECK (cleanup_state IN ('pending', 'complete', 'uncertain')), capability TEXT NOT NULL CHECK (capability IN ('direct_process', 'process_group', 'contained_tree')), required_cleanup TEXT NOT NULL CHECK (required_cleanup IN ('direct_process', 'process_group', 'contained_tree')), exit_observation TEXT NOT NULL CHECK (exit_observation IN ('independent', 'eof_gated')), exit_source TEXT CHECK (exit_source IN ('runner', 'reconcile', 'terminal')), attachment_generation INTEGER NOT NULL DEFAULT 0 CHECK (attachment_generation >= 0), recipient TEXT, runner_pid TEXT, home_key TEXT, session_ref TEXT, pid INTEGER, pgid INTEGER, start_ticks INTEGER, boot_id TEXT, exit_code INTEGER, exit_signal INTEGER, evidence_count INTEGER NOT NULL DEFAULT 0 CHECK (evidence_count >= 0), created_at TEXT NOT NULL, updated_at TEXT NOT NULL, UNIQUE (owner_id, idempotency_key) )]],
    [[CREATE TABLE bee_placement_session_files ( owner_id TEXT NOT NULL, session_ref TEXT NOT NULL, path TEXT NOT NULL, digest TEXT NOT NULL CHECK (length(digest) = 64), created_at TEXT NOT NULL, PRIMARY KEY (owner_id, session_ref, path) )]],
    [[INSERT INTO bee_placement_attempts (attempt_id, owner_id, owner_incarnation, action_id, idempotency_key, request_digest, request_json, placement_kind, placement_spec_json, placement_identity_json, execution_state, cleanup_state, capability, required_cleanup, exit_observation, exit_source, attachment_generation, recipient, runner_pid, home_key, session_ref, pid, pgid, start_ticks, boot_id, exit_code, exit_signal, evidence_count, created_at, updated_at) SELECT attempt_id, owner_id, owner_incarnation, action_id, idempotency_key, request_digest, request_json, placement_kind, placement_spec_json, placement_identity_json, execution_state, cleanup_state, capability, required_cleanup, exit_observation, exit_source, attachment_generation, recipient, runner_pid, home_key, session_ref, pid, pgid, start_ticks, boot_id, exit_code, exit_signal, evidence_count, created_at, updated_at FROM bee_placement_attempts_prev]],
    [[INSERT INTO bee_placement_evidence (attempt_id, sequence, at, kind, detail) SELECT attempt_id, sequence, at, kind, detail FROM bee_placement_evidence_prev]],
    [[INSERT INTO bee_placement_preparer_states (attempt_id, binding_id, position, record_json, created_at) SELECT attempt_id, binding_id, position, record_json, created_at FROM bee_placement_preparer_states_prev]],
    [[INSERT INTO bee_placement_runner_authorities (attempt_id, control_token) SELECT attempt_id, control_token FROM bee_placement_runner_authorities_prev]],
    [[DROP TABLE bee_placement_runner_authorities_prev]],
    [[DROP TABLE bee_placement_preparer_states_prev]],
    [[DROP TABLE bee_placement_evidence_prev]],
    [[DROP TABLE bee_placement_attempts_prev]],
    [[CREATE INDEX bee_placement_attempts_action ON bee_placement_attempts (owner_id, action_id)]],
}


return require("migration").define(function()
    migration("Complete the native placement store to its full schema: attempts take their full definition and session files are added", function()
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
