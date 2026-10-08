# Owner-local sync and inbox

`bee.sync` is a typed projection protocol shared by nodes. The Needs you app
(`bee.approvals.inbox.app`) reads approval feeds through it. See
`component/sync` for the module reference.

## Authority and ledger

This is application-level synchronization, not SQLite replication or a global
consensus log. Each node is the authority for its own records. Clients hold
projections keyed by owner and feed; a cursor from one owner and feed cannot be
used for another. Transport connectivity and descriptive metadata grant no
authority.

The sync store commits a projection, an ordered event and an idempotency
receipt in one SQLite transaction in `bee:db`. Expected revisions prevent lost
updates. Event retention is bounded: a reader behind the window gets
`RESET_REQUIRED` and takes a new snapshot. Tombstones remain in snapshots.
Retry receipts have a hard capacity: new writes fail with `CAPACITY_EXHAUSTED`
rather than forgetting idempotency keys.

Approval feeds adapt the approval owner's transactional inbox ledger; they do
not copy decisions into another database. The distributor in
`bee.sync.service` pages locally exported feeds to hive destinations and
keeps a durable cursor for each. A component exports a feed with a
`registry.entry` of `meta.type: bee.sync.exports` whose `data.exports` lists
`feed` and `content_kinds`; Gov exports `governance.application_versions` as
`bee.governance-application-version@2`. Sync transfers those bytes without
decoding them. Governance owns activation. There is no generic remote append
API.

## Component-owned distributed stores

A component that shares data over `bee.sync` owns its schema and migrations;
Sync supplies owner-qualified projections, revisions, ordered events, retry
receipts, snapshot and catch-up envelopes and an opaque durable replica cache.
The component supplies the payload decoder and decides what a receiver may do
with it. It never exposes the low-level store's append or open operations, and
never takes database ids or owner identities from remote callers.

Each feed has one authoritative owner and read replicas on admitted nodes.
Mutations route to the owner with expected revisions and caller-scoped retry
identities. A replica shows its last confirmed state with its cursor, and
reports no locally queued edit as committed. A receiver validates the payload
schema, owner and feed identity, scope and cursor before it stores a replica;
snapshot replacement, tombstones and cursor advancement commit together.

Sharing content does not authorize running or installing it. The destination's
governance plans against the immutable content and local policy, and the
approval owner commits the decision through the same owner-qualified inbox.

## Approval feeds

`bee.approvals.binding:feed_snapshot` takes `workspace_id`, optional `limit`
(1 to 64) and the continuation fields `after_key`, `expected_cursor` and
`expected_scope_revision`. `bee.approvals.binding:feed_read_after` takes
`workspace_id`, `cursor`, optional `limit` and `expected_scope_revision`.
Replies keep the approval owner's envelope; Hive wraps the complete domain
reply.

A snapshot pins the ledger head and the actor's approver-policy revision. A
policy change requires a reset and each page checks authority again. Event
payloads carry a typed current approval projection, not an executable callback.

## Needs you

The app reads the launch workspace and the workspaces named by the registry
entry `bee.approvals.inbox.app:workspaces` (`meta.type:
bee.approvals.inbox.workspaces`). Remote sources are listed by
`bee.approvals.inbox.app:sources`:

```yaml
- name: sources
  kind: registry.entry
  meta:
    type: bee.approvals.inbox.sources
  data:
    sources:
    - {node_id: node-b, workspace_id: workspace-id}
```

At most 16 sources are accepted. Each source uses a staged snapshot, incremental
catch-up and periodic reconciliation; a snapshot is bounded to eight pages and
256 visible requests, beyond which the source fails with `CAPACITY_EXHAUSTED`.
A denied or reset source loses its cached rows. An unavailable source is shown
as unavailable, not empty.

Row identities are qualified by source. A decision routes to the original owner
and approval id, and the person's confirmation is pinned to the exact owner
incarnation, revision and proposal digest the person viewed. A lost reply is
reconciled by reading the owner; a still-pending request keeps the decision
uncertain, and only a terminal owner record settles it. Recovery never
resubmits a decision.

## Hive admission

Feed operations carry `meta.hive: policy`. The `approvals` route accepts only
messages forwarded by this node's Hive supervisor and uses the authenticated
sender PID's node as `bee.approvals.peer.<node>`. Its explicit operation map
covers snapshots, catch-up, reads, decisions, batches, withdrawals and grant
windows. The peer scope reaches only those bindings and the approval decision
gate; destination approver policies must separately name the peer actor for
request reads and decisions. The owner checks revision and proposal digest on
decisions and retains requester-only withdrawal and issuer-only window
revocation.

The supervisor enforces live admission, operation exposure, approved peer-node
audiences and application scope for `application.call`. Policy-mode application
operations remain fail-closed until trusted remote-subject mappings exist.
The approvals route keeps its explicit operation map and destination approver
authorization; an application exposure grant does not grant approval decision
authority. See `docs/hive_test_sdk` for application peer calls and agent discovery.
