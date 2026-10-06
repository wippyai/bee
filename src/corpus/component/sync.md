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

The store keeps its feeds, replicas and distribution cursors in the node
database `bee:db`. Feed adapters own their payload decoder and authorization.
The `bee.sync.service:service` process follows committed feed events through
`bee:changes`, runs the distributor and hosts the replica receiver.
A component publishes feeds to the hive with a `registry.entry` of
`meta.type: bee.sync.exports` whose `data.exports` lists `feed` and
`content_kinds`; receivers are Hive routes with `meta.sync: receiver`
(route prefix `sync`, name `bee.sync`).

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

| Namespace | Responsibility |
|---|---|
| `bee.sync` | `protocol` (transport envelopes, cursors, snapshots) and `replica_protocol` (replica transfer envelopes) |
| `bee.sync.values` | `limits` (bounded capacities) and `version` (replica version descriptors) |
| `bee.sync.persist` | `store` (feeds and projections), `replicas` (immutable replicas and source cursors), `distribution_store` (destination cursors) |
| `bee.sync.binding` | `replica_receive`, the authenticated immutable replica receiver |
| `bee.sync.service` | `sender` (`send(destination, descriptor, content, options)`), `distributor`, and the `sync` process run as `service` |
| `bee.sync.migrations` | Immutable SQLite migrations for feeds and replicas |
