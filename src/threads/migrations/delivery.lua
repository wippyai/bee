-- MIT. Create recipient obligations, claims, dispatch intents and subscriptions. The owner
-- row holds the incarnation every claim and subscription carries.
local STATEMENTS = {
    [[CREATE TABLE bee_thread_owner (
  singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
  incarnation INTEGER NOT NULL CHECK(incarnation > 0),
  started_at TEXT NOT NULL,
  authority_id TEXT
)]],
    [[CREATE TABLE bee_thread_obligations (
  thread_id TEXT NOT NULL REFERENCES bee_thread_heads(thread_id),
  message_id TEXT NOT NULL,
  recipient_id TEXT NOT NULL,
  message_record_id TEXT NOT NULL REFERENCES bee_thread_records(record_id),
  kind TEXT NOT NULL CHECK(kind IN ('request','progress','reply','notification')),
  state TEXT NOT NULL CHECK(state IN ('pending','claimed','delivered','answered','uncertain','abandoned')),
  delivery_id TEXT,
  reply_record_id TEXT REFERENCES bee_thread_records(record_id),
  answered_mark_record_id TEXT REFERENCES bee_thread_records(record_id),
  created_sequence INTEGER NOT NULL CHECK(created_sequence > 0),
  PRIMARY KEY(thread_id, message_id, recipient_id)
)]],
    [[CREATE INDEX bee_thread_obligations_recipient ON bee_thread_obligations(thread_id, recipient_id, state, created_sequence)]],
    [[CREATE TABLE bee_thread_claim_batches (
  batch_id TEXT PRIMARY KEY,
  thread_id TEXT NOT NULL REFERENCES bee_thread_heads(thread_id),
  claimant_actor TEXT NOT NULL,
  consumer_id TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  request_digest TEXT NOT NULL,
  turn_id TEXT,
  attempt_id TEXT,
  created_at TEXT NOT NULL,
  UNIQUE(thread_id, claimant_actor, consumer_id, idempotency_key)
)]],
    [[CREATE TABLE bee_thread_deliveries (
  delivery_id TEXT PRIMARY KEY,
  thread_id TEXT NOT NULL,
  message_id TEXT NOT NULL,
  recipient_id TEXT NOT NULL,
  batch_id TEXT NOT NULL REFERENCES bee_thread_claim_batches(batch_id),
  consumer_id TEXT NOT NULL,
  channel TEXT NOT NULL,
  owner_incarnation INTEGER NOT NULL CHECK(owner_incarnation > 0),
  state TEXT NOT NULL CHECK(state IN ('claimed','delivered','released','uncertain')),
  claimed_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  evidence_ref TEXT,
  mark_record_id TEXT NOT NULL REFERENCES bee_thread_records(record_id),
  UNIQUE(batch_id, thread_id, message_id, recipient_id),
  FOREIGN KEY(thread_id, message_id, recipient_id) REFERENCES bee_thread_obligations(thread_id, message_id, recipient_id)
)]],
    [[CREATE UNIQUE INDEX bee_thread_live_delivery ON bee_thread_deliveries(thread_id, message_id, recipient_id) WHERE state='claimed']],
    [[CREATE TABLE bee_thread_dispatches (
  delivery_id TEXT PRIMARY KEY REFERENCES bee_thread_deliveries(delivery_id),
  intent_at TEXT NOT NULL,
  accepted INTEGER NOT NULL CHECK(accepted IN (0,1)),
  evidence_ref TEXT
)]],
    [[CREATE TABLE bee_thread_subscriptions (
  subscription_id TEXT PRIMARY KEY,
  thread_id TEXT NOT NULL REFERENCES bee_thread_heads(thread_id),
  actor TEXT NOT NULL,
  consumer_id TEXT NOT NULL,
  filter_digest TEXT NOT NULL,
  filter_json TEXT NOT NULL,
  durability TEXT NOT NULL CHECK(durability IN ('durable','reconstructible')),
  after_sequence INTEGER NOT NULL CHECK(after_sequence >= 0),
  lease_generation INTEGER NOT NULL CHECK(lease_generation > 0),
  owner_incarnation INTEGER NOT NULL CHECK(owner_incarnation > 0),
  created_at TEXT NOT NULL,
  closed_at TEXT
)]],
    [[CREATE UNIQUE INDEX bee_thread_subscription_identity ON bee_thread_subscriptions(thread_id, actor, consumer_id, filter_digest) WHERE closed_at IS NULL]],
    [[CREATE TABLE bee_thread_subscription_pages (
  page_id TEXT PRIMARY KEY,
  subscription_id TEXT NOT NULL REFERENCES bee_thread_subscriptions(subscription_id),
  lease_generation INTEGER NOT NULL CHECK(lease_generation > 0),
  from_sequence INTEGER NOT NULL CHECK(from_sequence >= 0),
  scanned_through INTEGER NOT NULL CHECK(scanned_through >= 0),
  filter_digest TEXT NOT NULL,
  acknowledged INTEGER NOT NULL CHECK(acknowledged IN (0,1)),
  handed_at TEXT NOT NULL
)]],
    [[CREATE UNIQUE INDEX bee_thread_outstanding_page ON bee_thread_subscription_pages(subscription_id) WHERE acknowledged=0]],
}

return require("migration").define(function()
    migration("Create recipient obligations, claims, dispatch intents and subscriptions", function()
        database("sqlite", function()
            up(function(db)
                for _, statement in ipairs(STATEMENTS) do
                    local _, err = db:execute(statement)
                    if err then error(err) end
                end
            end)
            down(function(db)
                for _, name in ipairs({"bee_thread_subscription_pages", "bee_thread_subscriptions", "bee_thread_dispatches", "bee_thread_deliveries", "bee_thread_claim_batches", "bee_thread_obligations", "bee_thread_owner"}) do
                    local _, err = db:execute("DROP TABLE IF EXISTS " .. name)
                    if err then error(err) end
                end
            end)
        end)
    end)
end)
