CREATE TABLE bee_governance_leases (
  owner_node TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  lease_id TEXT NOT NULL,
  target TEXT NOT NULL,
  envelope_bytes BLOB NOT NULL CHECK(length(CAST(envelope_bytes AS BLOB)) BETWEEN 1 AND 65536),
  envelope_digest TEXT NOT NULL CHECK(length(envelope_digest) = 64),
  source_approval_id TEXT NOT NULL,
  source_approval_proposal_digest TEXT NOT NULL CHECK(length(source_approval_proposal_digest) = 64),
  source_approval_owner_incarnation INTEGER NOT NULL CHECK(source_approval_owner_incarnation >= 1),
  granted_by TEXT NOT NULL,
  created_at TEXT NOT NULL,
  expires_at TEXT,
  max_applies INTEGER CHECK(max_applies IS NULL OR max_applies >= 1),
  applies_used INTEGER NOT NULL DEFAULT 0 CHECK(applies_used >= 0),
  revision INTEGER NOT NULL CHECK(revision >= 1),
  state TEXT NOT NULL CHECK(state IN ('active', 'revoked')),
  revoked_by TEXT,
  revoked_at TEXT,
  PRIMARY KEY(owner_node, workspace_id, lease_id),
  UNIQUE(owner_node, workspace_id, source_approval_id),
  CHECK(expires_at IS NOT NULL OR max_applies IS NOT NULL)
);
CREATE INDEX bee_governance_leases_target ON bee_governance_leases (owner_node, workspace_id, target, state);
CREATE TABLE bee_governance_lease_uses (
  owner_node TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  lease_id TEXT NOT NULL,
  intent_id TEXT NOT NULL,
  proposal_snapshot_bytes BLOB NOT NULL CHECK(length(CAST(proposal_snapshot_bytes AS BLOB)) BETWEEN 1 AND 65536),
  proposal_snapshot_digest TEXT NOT NULL CHECK(length(proposal_snapshot_digest) = 64),
  applied_at TEXT NOT NULL,
  PRIMARY KEY(owner_node, workspace_id, lease_id, intent_id),
  FOREIGN KEY(owner_node, workspace_id, lease_id)
    REFERENCES bee_governance_leases(owner_node, workspace_id, lease_id)
);
CREATE TABLE bee_governance_lease_receipts (
  owner_node TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  actor_id TEXT NOT NULL,
  operation TEXT NOT NULL CHECK(operation IN ('grant', 'use', 'revoke')),
  request_digest TEXT NOT NULL CHECK(length(request_digest) = 64),
  lease_id TEXT NOT NULL,
  result_revision INTEGER NOT NULL CHECK(result_revision >= 1),
  PRIMARY KEY(owner_node, workspace_id, idempotency_key)
);
