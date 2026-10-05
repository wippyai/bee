-- MIT. Create the action inboxes: acceptance epochs and rules, ordered items and the cross-node outbox.
local STATEMENTS = {
    [[CREATE TABLE bee_thread_inbox_epochs (
  thread_id TEXT NOT NULL,
  action_id TEXT NOT NULL,
  grant_epoch INTEGER NOT NULL CHECK(grant_epoch > 0),
  next_sequence INTEGER NOT NULL DEFAULT 1 CHECK(next_sequence > 0),
  PRIMARY KEY(thread_id, action_id),
  FOREIGN KEY(thread_id, action_id) REFERENCES bee_thread_actions(thread_id, action_id)
)]],
    [[CREATE TABLE bee_thread_inbox_rules (
  thread_id TEXT NOT NULL,
  action_id TEXT NOT NULL,
  sender_kind TEXT NOT NULL CHECK(sender_kind IN ('actor','class')),
  sender_value TEXT NOT NULL,
  PRIMARY KEY(thread_id, action_id, sender_kind, sender_value),
  FOREIGN KEY(thread_id, action_id) REFERENCES bee_thread_inbox_epochs(thread_id, action_id)
)]],
    [[CREATE TABLE bee_thread_inbox_items (
  thread_id TEXT NOT NULL,
  action_id TEXT NOT NULL,
  inbox_sequence INTEGER NOT NULL CHECK(inbox_sequence > 0),
  record_id TEXT NOT NULL UNIQUE REFERENCES bee_thread_records(record_id),
  payload_digest TEXT NOT NULL CHECK(length(payload_digest) = 64),
  sender_actor TEXT NOT NULL,
  sender_action_id TEXT NOT NULL,
  sender_node_id TEXT NOT NULL,
  sender_thread_id TEXT NOT NULL,
  message_id TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('committed','offered','transport_accepted','acknowledged','replied')),
  in_reply_to_thread_id TEXT,
  in_reply_to_record_id TEXT,
  reply_thread_id TEXT,
  reply_record_id TEXT, offer_attempt_id TEXT, offer_carrier_epoch INTEGER, offer_count INTEGER NOT NULL DEFAULT 0 CHECK(offer_count >= 0), offered_at TEXT, transport_accepted_at TEXT, delivery_block TEXT CHECK(delivery_block IN ('waiting_for_restart','undeliverable')),
  PRIMARY KEY(thread_id, action_id, inbox_sequence),
  FOREIGN KEY(thread_id, action_id) REFERENCES bee_thread_inbox_epochs(thread_id, action_id),
  CHECK((in_reply_to_thread_id IS NULL) = (in_reply_to_record_id IS NULL)),
  CHECK((reply_thread_id IS NULL) = (reply_record_id IS NULL))
)]],
    [[CREATE INDEX bee_thread_inbox_sender ON bee_thread_inbox_items(sender_actor, sender_action_id, record_id)]],
    [[CREATE TABLE bee_thread_inbox_outbox (
  outbox_id TEXT NOT NULL PRIMARY KEY,
  sender_thread_id TEXT NOT NULL,
  sender_actor TEXT NOT NULL,
  sender_action_id TEXT NOT NULL,
  sender_node_id TEXT NOT NULL,
  dest_node_id TEXT NOT NULL,
  dest_workspace_id TEXT NOT NULL,
  dest_thread_id TEXT NOT NULL,
  dest_action_id TEXT NOT NULL,
  grant_epoch INTEGER NOT NULL CHECK(grant_epoch > 0),
  idempotency_key TEXT NOT NULL,
  message_id TEXT NOT NULL,
  content_json TEXT NOT NULL,
  payload_digest TEXT NOT NULL CHECK(length(payload_digest) = 64),
  state TEXT NOT NULL CHECK(state IN ('queued','delivered','failed','exhausted')) DEFAULT 'queued',
  attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts >= 0),
  next_attempt_ms INTEGER NOT NULL DEFAULT 0,
  lease_owner TEXT,
  lease_until_ms INTEGER,
  last_error TEXT,
  receipt_json TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL, in_reply_to_thread_id TEXT, in_reply_to_record_id TEXT, outcome TEXT CHECK(outcome IN ('succeeded','failed','cancelled','uncertain')),
  UNIQUE(sender_thread_id, sender_actor, idempotency_key)
)]],
    [[CREATE INDEX bee_thread_inbox_outbox_due ON bee_thread_inbox_outbox(state, next_attempt_ms)]],
}

return require("migration").define(function()
    migration("Create the action inboxes: acceptance epochs and rules, ordered items and the cross-node outbox", function()
        database("sqlite", function()
            up(function(db)
                for _, statement in ipairs(STATEMENTS) do
                    local _, err = db:execute(statement)
                    if err then error(err) end
                end
            end)
            down(function(db)
                for _, name in ipairs({"bee_thread_inbox_outbox", "bee_thread_inbox_items", "bee_thread_inbox_rules", "bee_thread_inbox_epochs"}) do
                    local _, err = db:execute("DROP TABLE IF EXISTS " .. name)
                    if err then error(err) end
                end
            end)
        end)
    end)
end)
