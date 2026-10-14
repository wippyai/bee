-- MIT. Create the placement receipt store: attempts with their recorded
-- execution and cleanup state, append-only evidence, workdir preparer plans
-- and runner control authorities.
local STATEMENTS = {
    [[CREATE TABLE bee_placement_attempts (
  attempt_id TEXT PRIMARY KEY,
  owner_id TEXT NOT NULL,
  owner_incarnation INTEGER NOT NULL CHECK (owner_incarnation > 0),
  action_id TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  request_digest TEXT NOT NULL,
  request_json TEXT NOT NULL,
  placement_kind TEXT NOT NULL CHECK (placement_kind IN ('native', 'docker')),
  placement_spec_json TEXT,
  placement_identity_json TEXT,
  execution_state TEXT NOT NULL CHECK (execution_state IN ('intended', 'starting', 'running', 'stopping', 'exited', 'start_failed', 'uncertain')),
  cleanup_state TEXT NOT NULL CHECK (cleanup_state IN ('pending', 'complete', 'uncertain')),
  capability TEXT NOT NULL CHECK (capability IN ('direct_process', 'process_group', 'contained_tree')),
  required_cleanup TEXT NOT NULL CHECK (required_cleanup IN ('direct_process', 'process_group', 'contained_tree')),
  exit_observation TEXT NOT NULL CHECK (exit_observation IN ('independent', 'eof_gated')),
  exit_source TEXT CHECK (exit_source IN ('runner', 'reconcile', 'terminal')),
  attachment_generation INTEGER NOT NULL DEFAULT 0 CHECK (attachment_generation >= 0),
  recipient TEXT,
  supervisor_pid TEXT,
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
)]],
    [[CREATE INDEX bee_placement_attempts_action ON bee_placement_attempts (owner_id, action_id)]],
    [[CREATE INDEX bee_placement_attempts_state ON bee_placement_attempts (execution_state, cleanup_state)]],
    [[CREATE TABLE bee_placement_evidence (
  attempt_id TEXT NOT NULL REFERENCES bee_placement_attempts (attempt_id),
  sequence INTEGER NOT NULL CHECK (sequence > 0),
  at TEXT NOT NULL,
  kind TEXT NOT NULL,
  detail TEXT NOT NULL,
  PRIMARY KEY (attempt_id, sequence)
)]],
    [[CREATE TABLE bee_placement_preparer_states (
  attempt_id TEXT NOT NULL REFERENCES bee_placement_attempts (attempt_id),
  binding_id TEXT NOT NULL,
  position INTEGER NOT NULL CHECK (position > 0),
  record_json TEXT NOT NULL CHECK (length(record_json) <= 65536),
  created_at TEXT NOT NULL,
  PRIMARY KEY (attempt_id, binding_id)
)]],
    [[CREATE TABLE bee_placement_runner_authorities (
  attempt_id TEXT PRIMARY KEY REFERENCES bee_placement_attempts (attempt_id),
  control_token TEXT NOT NULL UNIQUE
)]],
}

return require("migration").define(function()
    migration("Create the placement receipt store", function()
        database("sqlite", function()
            up(function(db)
                for _, statement in ipairs(STATEMENTS) do
                    local _, err = db:execute(statement)
                    if err then error(err) end
                end
            end)
            down(function(db)
                for _, name in ipairs({"bee_placement_runner_authorities", "bee_placement_preparer_states",
                    "bee_placement_evidence", "bee_placement_attempts"}) do
                    local _, err = db:execute("DROP TABLE IF EXISTS " .. name)
                    if err then error(err) end
                end
            end)
        end)
    end)
end)
