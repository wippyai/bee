CREATE TABLE bee_thread_cancel_intents (
  thread_id TEXT NOT NULL REFERENCES bee_thread_heads(thread_id),
  attempt_id TEXT NOT NULL,
  idempotency_key TEXT,
  state TEXT NOT NULL CHECK(state IN ('cancelling','ended')),
  outcome TEXT CHECK(outcome IS NULL OR outcome IN ('succeeded','failed','cancelled','uncertain')),
  recorded_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY(thread_id, attempt_id),
  FOREIGN KEY(thread_id, attempt_id)
    REFERENCES bee_thread_attempts(thread_id, attempt_id),
  CHECK((state = 'cancelling' AND outcome IS NULL)
     OR (state = 'ended' AND outcome = 'cancelled'))
);
