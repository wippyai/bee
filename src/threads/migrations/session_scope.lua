local STATEMENTS = {
    [[PRAGMA defer_foreign_keys = ON]],
    [[DROP INDEX bee_sessions_workspace]],
    [[DROP INDEX bee_session_work_queue]],
    [[DROP INDEX bee_session_live_turn]],
    [[DROP INDEX bee_session_trait_live]],
    [[ALTER TABLE bee_session_trait_intervals RENAME TO bee_session_trait_intervals_prev]],
    [[ALTER TABLE bee_session_traits RENAME TO bee_session_traits_prev]],
    [[ALTER TABLE bee_session_work_cancellations RENAME TO bee_session_work_cancellations_prev]],
    [[ALTER TABLE bee_session_turns RENAME TO bee_session_turns_prev]],
    [[ALTER TABLE bee_session_work RENAME TO bee_session_work_prev]],
    [[ALTER TABLE bee_sessions RENAME TO bee_sessions_prev]],
    [[CREATE TABLE "bee_sessions" ( session_ref TEXT PRIMARY KEY, thread_id TEXT NOT NULL REFERENCES bee_thread_heads(thread_id), workspace_id TEXT NOT NULL CHECK(length(workspace_id)=32 AND workspace_id NOT GLOB '*[^0-9a-f]*'), owner_actor TEXT NOT NULL, title TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('active','suspended','closing','closed')), revision INTEGER NOT NULL CHECK(revision > 0), created_at TEXT NOT NULL, updated_at TEXT NOT NULL, route_json TEXT NOT NULL DEFAULT '{}', context_json TEXT NOT NULL DEFAULT '{}', budget_started_at_ms INTEGER NOT NULL DEFAULT 0 CHECK(budget_started_at_ms >= 0), provider_steps INTEGER NOT NULL DEFAULT 0 CHECK(provider_steps >= 0), tool_calls INTEGER NOT NULL DEFAULT 0 CHECK(tool_calls >= 0), tokens INTEGER NOT NULL DEFAULT 0 CHECK(tokens >= 0), UNIQUE(session_ref, workspace_id) )]],
    [[CREATE TABLE "bee_session_work" ( work_ref TEXT PRIMARY KEY, session_ref TEXT NOT NULL, workspace_id TEXT NOT NULL CHECK(length(workspace_id)=32 AND workspace_id NOT GLOB '*[^0-9a-f]*'), sequence INTEGER NOT NULL CHECK(sequence > 0), revision INTEGER NOT NULL CHECK(revision > 0), phase TEXT NOT NULL CHECK(phase IN ('queued','reserved','accepted','settled')), input_json TEXT NOT NULL, input_digest TEXT NOT NULL, output_schema TEXT NOT NULL, result_json TEXT, operation_ref TEXT NOT NULL, created_at TEXT NOT NULL, sender_kind TEXT NOT NULL DEFAULT 'principal' CHECK(sender_kind IN ('session','principal')), sender_id TEXT NOT NULL DEFAULT '', uncertainty_json TEXT, budget_json TEXT NOT NULL DEFAULT '{}', UNIQUE(session_ref, sequence), UNIQUE(work_ref, session_ref), FOREIGN KEY(session_ref, workspace_id) REFERENCES bee_sessions(session_ref, workspace_id), CHECK((phase='settled') = (result_json IS NOT NULL)) )]],
    [[CREATE TABLE "bee_session_turns" ( turn_ref TEXT PRIMARY KEY, session_ref TEXT NOT NULL REFERENCES bee_sessions(session_ref), work_ref TEXT NOT NULL UNIQUE, claim_token TEXT NOT NULL UNIQUE, owner_epoch INTEGER NOT NULL CHECK(owner_epoch > 0), input_digest TEXT NOT NULL, phase TEXT NOT NULL CHECK(phase IN ('reserved','accepted','settled')), checkpoint_json TEXT, reserve_record_id TEXT NOT NULL UNIQUE REFERENCES bee_thread_records(record_id), accept_record_id TEXT UNIQUE REFERENCES bee_thread_records(record_id), settle_record_id TEXT UNIQUE REFERENCES bee_thread_records(record_id), created_at TEXT NOT NULL, last_progress_at_ms INTEGER NOT NULL DEFAULT 0 CHECK(last_progress_at_ms >= 0), FOREIGN KEY(work_ref, session_ref) REFERENCES bee_session_work(work_ref, session_ref), CHECK((phase='reserved' AND accept_record_id IS NULL AND settle_record_id IS NULL) OR (phase='accepted' AND accept_record_id IS NOT NULL AND settle_record_id IS NULL) OR (phase='settled' AND accept_record_id IS NOT NULL AND settle_record_id IS NOT NULL)) )]],
    [[CREATE TABLE bee_session_work_cancellations ( work_ref TEXT PRIMARY KEY REFERENCES bee_session_work(work_ref), operation_ref TEXT NOT NULL UNIQUE, reason TEXT, requested_at TEXT NOT NULL )]],
    [[CREATE TABLE bee_session_traits (session_ref TEXT NOT NULL, trait_id TEXT NOT NULL, thread_id TEXT NOT NULL, workspace_id TEXT NOT NULL, declaration_json TEXT NOT NULL, grant_id TEXT NOT NULL, selected INTEGER NOT NULL CHECK(selected IN (0,1)), revision INTEGER NOT NULL, PRIMARY KEY(session_ref,trait_id), FOREIGN KEY(session_ref) REFERENCES bee_sessions(session_ref), FOREIGN KEY(thread_id) REFERENCES bee_thread_heads(thread_id))]],
    [[CREATE TABLE bee_session_trait_intervals (session_ref TEXT NOT NULL, trait_id TEXT NOT NULL, generation INTEGER NOT NULL, start_sequence INTEGER NOT NULL, declaration_json TEXT NOT NULL, end_sequence INTEGER, PRIMARY KEY(session_ref,trait_id,generation), FOREIGN KEY(session_ref,trait_id) REFERENCES bee_session_traits(session_ref,trait_id), CHECK(end_sequence IS NULL OR end_sequence >= start_sequence))]],
    [[INSERT INTO bee_sessions SELECT * FROM bee_sessions_prev]],
    [[INSERT INTO bee_session_work SELECT * FROM bee_session_work_prev]],
    [[INSERT INTO bee_session_turns SELECT * FROM bee_session_turns_prev]],
    [[INSERT INTO bee_session_work_cancellations SELECT * FROM bee_session_work_cancellations_prev]],
    [[INSERT INTO bee_session_traits SELECT * FROM bee_session_traits_prev]],
    [[INSERT INTO bee_session_trait_intervals SELECT * FROM bee_session_trait_intervals_prev]],
    [[DROP TABLE bee_session_trait_intervals_prev]],
    [[DROP TABLE bee_session_traits_prev]],
    [[DROP TABLE bee_session_work_cancellations_prev]],
    [[DROP TABLE bee_session_turns_prev]],
    [[DROP TABLE bee_session_work_prev]],
    [[DROP TABLE bee_sessions_prev]],
    [[CREATE INDEX bee_sessions_workspace ON bee_sessions(workspace_id,state,created_at)]],
    [[CREATE INDEX bee_sessions_thread ON bee_sessions(thread_id)]],
    [[CREATE INDEX bee_session_work_queue ON bee_session_work(session_ref,phase,sequence)]],
    [[CREATE UNIQUE INDEX bee_session_live_turn ON bee_session_turns(session_ref) WHERE phase IN ('reserved','accepted')]],
    [[CREATE UNIQUE INDEX bee_session_trait_live ON bee_session_trait_intervals(session_ref,trait_id) WHERE end_sequence IS NULL]],
}
return require("migration").define(function()
    migration("Scope multiple session selections on one thread", function()
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
