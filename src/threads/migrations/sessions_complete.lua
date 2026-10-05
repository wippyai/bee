-- MIT. Complete the session journal to its full schema: sessions, work, turns and operations take their full definitions.
-- A table whose definition changes is renamed aside, created again and given
-- its rows back; foreign keys are checked when the migration commits.
local STATEMENTS = {
    [[PRAGMA defer_foreign_keys = ON]],
    [[DROP INDEX bee_sessions_workspace]],
    [[DROP INDEX bee_session_work_queue]],
    [[DROP INDEX bee_session_live_turn]],
    [[ALTER TABLE bee_session_work_cancellations RENAME TO bee_session_work_cancellations_prev]],
    [[ALTER TABLE bee_sessions RENAME TO bee_sessions_prev]],
    [[ALTER TABLE bee_session_work RENAME TO bee_session_work_prev]],
    [[ALTER TABLE bee_session_turns RENAME TO bee_session_turns_prev]],
    [[ALTER TABLE bee_session_operations RENAME TO bee_session_operations_prev]],
    [[CREATE TABLE bee_session_work_cancellations ( work_ref TEXT PRIMARY KEY REFERENCES bee_session_work(work_ref), operation_ref TEXT NOT NULL UNIQUE, reason TEXT, requested_at TEXT NOT NULL )]],
    [[CREATE TABLE "bee_sessions" ( session_ref TEXT PRIMARY KEY, thread_id TEXT NOT NULL UNIQUE REFERENCES bee_thread_heads(thread_id), workspace_id TEXT NOT NULL CHECK(length(workspace_id)=32 AND workspace_id NOT GLOB '*[^0-9a-f]*'), owner_actor TEXT NOT NULL, title TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('active','suspended','closing','closed')), revision INTEGER NOT NULL CHECK(revision > 0), created_at TEXT NOT NULL, updated_at TEXT NOT NULL, route_json TEXT NOT NULL DEFAULT '{}', context_json TEXT NOT NULL DEFAULT '{}', budget_started_at_ms INTEGER NOT NULL DEFAULT 0 CHECK(budget_started_at_ms >= 0), provider_steps INTEGER NOT NULL DEFAULT 0 CHECK(provider_steps >= 0), tool_calls INTEGER NOT NULL DEFAULT 0 CHECK(tool_calls >= 0), tokens INTEGER NOT NULL DEFAULT 0 CHECK(tokens >= 0), UNIQUE(session_ref, workspace_id) )]],
    [[CREATE TABLE "bee_session_work" ( work_ref TEXT PRIMARY KEY, session_ref TEXT NOT NULL, workspace_id TEXT NOT NULL CHECK(length(workspace_id)=32 AND workspace_id NOT GLOB '*[^0-9a-f]*'), sequence INTEGER NOT NULL CHECK(sequence > 0), revision INTEGER NOT NULL CHECK(revision > 0), phase TEXT NOT NULL CHECK(phase IN ('queued','reserved','accepted','settled')), input_json TEXT NOT NULL, input_digest TEXT NOT NULL, output_schema TEXT NOT NULL, result_json TEXT, operation_ref TEXT NOT NULL, created_at TEXT NOT NULL, sender_kind TEXT NOT NULL DEFAULT 'principal' CHECK(sender_kind IN ('session','principal')), sender_id TEXT NOT NULL DEFAULT '', uncertainty_json TEXT, budget_json TEXT NOT NULL DEFAULT '{}', UNIQUE(session_ref, sequence), UNIQUE(work_ref, session_ref), FOREIGN KEY(session_ref, workspace_id) REFERENCES bee_sessions(session_ref, workspace_id), CHECK((phase='settled') = (result_json IS NOT NULL)) )]],
    [[CREATE TABLE "bee_session_turns" ( turn_ref TEXT PRIMARY KEY, session_ref TEXT NOT NULL REFERENCES bee_sessions(session_ref), work_ref TEXT NOT NULL UNIQUE, claim_token TEXT NOT NULL UNIQUE, owner_epoch INTEGER NOT NULL CHECK(owner_epoch > 0), input_digest TEXT NOT NULL, phase TEXT NOT NULL CHECK(phase IN ('reserved','accepted','settled')), checkpoint_json TEXT, reserve_record_id TEXT NOT NULL UNIQUE REFERENCES bee_thread_records(record_id), accept_record_id TEXT UNIQUE REFERENCES bee_thread_records(record_id), settle_record_id TEXT UNIQUE REFERENCES bee_thread_records(record_id), created_at TEXT NOT NULL, last_progress_at_ms INTEGER NOT NULL DEFAULT 0 CHECK(last_progress_at_ms >= 0), FOREIGN KEY(work_ref, session_ref) REFERENCES bee_session_work(work_ref, session_ref), CHECK((phase='reserved' AND accept_record_id IS NULL AND settle_record_id IS NULL) OR (phase='accepted' AND accept_record_id IS NOT NULL AND settle_record_id IS NULL) OR (phase='settled' AND accept_record_id IS NOT NULL AND settle_record_id IS NOT NULL)) )]],
    [[CREATE TABLE "bee_session_operations" ( workspace_id TEXT NOT NULL CHECK(length(workspace_id)=32 AND workspace_id NOT GLOB '*[^0-9a-f]*'), owner_actor TEXT NOT NULL, operation_key TEXT NOT NULL, operation_ref TEXT NOT NULL UNIQUE, operation TEXT NOT NULL, request_digest TEXT NOT NULL, target_ref TEXT, receipt_json TEXT NOT NULL, committed_at TEXT NOT NULL, PRIMARY KEY(workspace_id, owner_actor, operation_key) )]],
    [[INSERT INTO bee_sessions (session_ref, thread_id, workspace_id, owner_actor, title, state, revision, created_at, updated_at, route_json, context_json) SELECT session_ref, thread_id, workspace_id, owner_actor, title, state, revision, created_at, updated_at, route_json, context_json FROM bee_sessions_prev]],
    [[INSERT INTO bee_session_work (work_ref, session_ref, workspace_id, sequence, revision, phase, input_json, input_digest, output_schema, result_json, operation_ref, created_at, sender_kind, sender_id, uncertainty_json) SELECT work_ref, session_ref, workspace_id, sequence, revision, phase, input_json, input_digest, output_schema, result_json, operation_ref, created_at, sender_kind, sender_id, uncertainty_json FROM bee_session_work_prev]],
    [[INSERT INTO bee_session_turns (turn_ref, session_ref, work_ref, claim_token, owner_epoch, input_digest, phase, checkpoint_json, reserve_record_id, accept_record_id, settle_record_id, created_at) SELECT turn_ref, session_ref, work_ref, claim_token, owner_epoch, input_digest, phase, checkpoint_json, reserve_record_id, accept_record_id, settle_record_id, created_at FROM bee_session_turns_prev]],
    [[INSERT INTO bee_session_operations (workspace_id, owner_actor, operation_key, operation_ref, operation, request_digest, target_ref, receipt_json, committed_at) SELECT workspace_id, owner_actor, operation_key, operation_ref, operation, request_digest, target_ref, receipt_json, committed_at FROM bee_session_operations_prev]],
    [[INSERT INTO bee_session_work_cancellations (work_ref, operation_ref, reason, requested_at) SELECT work_ref, operation_ref, reason, requested_at FROM bee_session_work_cancellations_prev]],
    [[DROP TABLE bee_session_work_cancellations_prev]],
    [[DROP TABLE bee_session_operations_prev]],
    [[DROP TABLE bee_session_turns_prev]],
    [[DROP TABLE bee_session_work_prev]],
    [[DROP TABLE bee_sessions_prev]],
    [[CREATE INDEX bee_sessions_workspace ON bee_sessions(workspace_id, state, created_at)]],
    [[CREATE INDEX bee_session_work_queue ON bee_session_work(session_ref, phase, sequence)]],
    [[CREATE UNIQUE INDEX bee_session_live_turn ON bee_session_turns(session_ref) WHERE phase IN ('reserved','accepted')]],
    [[CREATE INDEX bee_session_operations_ref ON bee_session_operations(operation_ref)]],
}


return require("migration").define(function()
    migration("Complete the session journal to its full schema: sessions, work, turns and operations take their full definitions", function()
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
