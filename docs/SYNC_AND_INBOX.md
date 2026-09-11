# Owner-local sync and inbox

Bee implements a shared typed projection protocol in `bee.sync`, editable node
descriptions in `bee.node`, and an approval-feed adapter consumed by the Approvals
application. These are Bee-owned Lua modules; no Keeper dependency is involved.

## Authority and ledger

This is application-level synchronization, not SQLite replication or a global
consensus log. Each native node remains the authority for its own records.
Clients hold projections keyed by owner and feed; a cursor from one owner/feed
cannot be used for another. Transport connectivity and descriptive metadata
grant no authority.

The sync store commits a projection, ordered event and idempotency receipt in
one SQLite transaction. Expected revisions prevent lost updates. Migration 1
creates the owner/feed, projection, event and receipt tables through Bee's
checked migration ledger. Reopening/updating the module runs that same checked
migration lifecycle without deleting the database or changing applied SQL.
Event retention is bounded; stale readers must resnapshot. Tombstones remain
in snapshots. Retry receipts have a hard capacity: new writes fail rather than
silently forgetting old idempotency keys. This is not an unlimited audit archive.

Approval feeds adapt the approval owner's existing transactional inbox ledger;
they do not copy decisions into another database. Future overlay/app descriptions
can supply another typed adapter, but no overlay activation or generic remote
append API is implemented here.

## Node metadata

`bee.node:describe`, `update_metadata`, `snapshot` and `read_after` operate on
the executing node. The host grants `bee.node.read` / `bee.node.update` on its
exact native node ID and selects the `target_db` resource. `BEE_NODE_DB` selects
the bundled node database path.

An update replaces `{display_name, description, labels}` and requires
`expected_revision` and a stable `idempotency_key`. Omitted description/labels
become empty. Identity, trust, permissions, runtime capabilities and presence
cannot be changed through metadata. `bee.node:metadata_trait` describes the two
agent-facing read/update tools without granting either operation.

## Approval feeds and UI

`bee.approvals:feed_snapshot` accepts `workspace_id`, optional `limit`, and
continuation fields `after_key`, `expected_cursor`, `expected_scope_revision`.
`feed_read_after` accepts `workspace_id`, `cursor`, optional `limit`, and the
snapshot's `expected_scope_revision`. Both retain the approval owner's existing
reply envelope. Node methods retain their flat transaction result envelope.
Hive wraps the complete domain reply rather than losing conflict/replay details.

Snapshots pin both the ledger head and the actor's host approver-policy revision.
Policy changes require a reset; each page checks authority again. Event payloads
carry a typed current approval projection, not an executable callback. Pages are
bounded by count and 192 KiB of encoded items, below the Hive reply limit.

The host may configure `bee.inbox:sources` as
`data: {sources: [{node_id: node-b, workspace_id: workspace-id}]}`. Existing local
workspace configuration still applies. At most 16 sources are accepted. Each
source uses a staged snapshot, incremental catch-up and periodic reconciliation;
the current adapter bounds a snapshot to eight pages and 256 visible requests.
Denied/reset sources lose their cached routes and visible rows. Unavailable
sources are reported as unavailable, not silently empty.

Queries run outside the rendering/input loop. Remote row identities are qualified
by source; decisions route back to the original owner and approval ID. User
confirmation is pinned to the exact viewed owner incarnation, revision and
proposal digest. A lost decision reply is reconciled by reading the owner;
unavailable recovery stays pending and does not resubmit the decision.
A successful read that still reports a pending request also retains uncertainty:
the earlier decision may still be executing. Only a terminal owner record settles
that pending client operation.

## Hive admission and limits

The existing native Hive supervisor admits only the exact reviewed node and
approval operations. The destination host must expose the operation and map the
verified issuer/subject pair to policies. The mapped actor needs both invocation
permission and the owner's domain permission; approver policies must separately
list that actor. Host exposure cannot substitute for caller authorization.

The present transport principal is the authenticated source process identity.
There is no automatic cross-node human enrollment or persistent human identity
linking. A replacement source process requires a host-selected mapping. Native
direct/client-role connectivity is exercised; multi-hop proxy identity delegation,
offline writes, owner failover and cross-owner ordering are not implemented.

Acceptance commands: `make sync-check`, `make sync-unit-check`, `make sync-hive-check`, `make test` and
`make check`, using the candidate runtime required by the shared source.
The two-runtime fixture proves metadata read/update/replay, mapped read-only
denial, revocation, approval snapshot/decision/catch-up and revoked visibility.
The local application test drives the real broker-owned inbox. These checks do
not prove autonomous Hub install/update, governance plugins or overlay activation.
