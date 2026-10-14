-- MIT. Create one-shot notices. A notice is owed once to a watcher on its own thread when a
-- target action or attempt ends a turn or an attempt.
local STATEMENTS = {
    [[CREATE TABLE bee_thread_notices (
  notice_id TEXT PRIMARY KEY,
  watcher_actor TEXT NOT NULL,
  watcher_thread_id TEXT NOT NULL REFERENCES bee_thread_heads(thread_id),
  watcher_action_id TEXT,
  target_thread_id TEXT NOT NULL,
  target_action_id TEXT,
  target_attempt_id TEXT,
  after_sequence INTEGER NOT NULL CHECK(after_sequence >= 0),
  state TEXT NOT NULL CHECK(state IN ('pending','fired','cancelled')),
  fired_record_id TEXT REFERENCES bee_thread_records(record_id),
  created_at TEXT NOT NULL,
  CHECK((target_action_id IS NOT NULL) OR (target_attempt_id IS NOT NULL)),
  CHECK((state = 'fired') = (fired_record_id IS NOT NULL)),
  FOREIGN KEY(target_thread_id, target_action_id) REFERENCES bee_thread_actions(thread_id, action_id)
)]],
    [[CREATE INDEX bee_thread_notices_target ON bee_thread_notices(target_thread_id, state)]],
    [[CREATE INDEX bee_thread_notices_watcher ON bee_thread_notices(watcher_thread_id, state)]],
    [[CREATE INDEX bee_thread_notices_attempt ON bee_thread_notices(target_thread_id, target_attempt_id, state)]],
}

return require("migration").define(function()
    migration("Create one-shot notices", function()
        database("sqlite", function()
            up(function(db)
                for _, statement in ipairs(STATEMENTS) do
                    local _, err = db:execute(statement)
                    if err then error(err) end
                end
            end)
            down(function(db)
                for _, name in ipairs({"bee_thread_notices"}) do
                    local _, err = db:execute("DROP TABLE IF EXISTS " .. name)
                    if err then error(err) end
                end
            end)
        end)
    end)
end)
