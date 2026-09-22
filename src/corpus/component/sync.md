# Bee sync

`bee.sync` is the owner-local, durable change feed used to share typed
descriptions between connected Bee nodes and clients. It is not SQLite
replication and it grants no authority: the owner-facing adapter authenticates
reads and writes before calling this store.

An append changes one named projection and records one ordered event in the
same SQLite transaction. Each feed has its own cursor and bounded event
window. A cursor older than that window receives `RESET_REQUIRED` and must
take a projection snapshot, which includes tombstones. A multi-page snapshot
pins its first cursor; a continuation whose expected cursor no longer matches
restarts rather than merging different revisions. Stable event and idempotency
identifiers replay their original receipt. Receipts are retained until the feed
reaches its configured hard receipt ceiling; at that point new writes fail with
`CAPACITY_EXHAUSTED` rather than forgetting deduplication.

The host links `target_db`; this module does not select a workspace database
or expose a public mutation binding. Feed adapters own their payload decoder
and authorization. The distributor has no transport default or independent
auto-start: a host links `target_sender`, selects `target_exports`, and starts
the worker with its own process host and policy.

`bee.sync:protocol` decodes the common transport envelopes and tracks cursors
and snapshots without interpreting a feed payload. An adapter supplies a typed
payload decoder and, for event catch-up, its own reducer; event payloads and
projection values are intentionally separate. Adapters may include an
authorization `scope_revision` in page and snapshot envelopes. Consumers pin
it through a snapshot/catch-up stream and reset their cached projection when it
changes.

Immutable replica blobs and source discovery cursors have separate lifecycles.
Finishing a version transfer only makes that version available; its descriptor's
`source_cursor` is provenance and never advances the source checkpoint. A
catch-up owner reads `replicas.cursor` and calls `replicas.advance_cursor` with
the expected and completed cursor only after it has handled every descriptor in
the discovered range. The compare-and-set rejects a stale concurrent checkpoint.
The replica receiver cannot infer whether a discovery page contained additional
descriptors, so transfer completion alone must never be treated as catch-up.

| Slice | Responsibility |
|---|---|
| `bee.sync` | Shared bounded values, descriptors, protocol, and the `Sender.send(destination, descriptor, content, options)` obligation |
| `bee.sync.migrations` | Immutable SQLite migrations for the Sync owner |
| `bee.sync.persist` | SQLite database, projections, immutable replicas, and distribution cursors |
| `bee.sync.registry` | Linked SQL and host export references |
| `bee.sync.binding` | Authenticated immutable replica receiver |
| `bee.sync.service` | Distributor and worker, wired and started only by a host |
