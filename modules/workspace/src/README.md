# Workspace component

`bee/workspace` owns the node workspace catalog, workspace checkpoints, display
assignments, transfer receipts and application/thread binding rows. Workspace
Manager remains a separate application. The root host owns database resources,
permissions, workspace leases, process lifetime and recovery orchestration.
Workspace decoders import primitive bounds directly from `bee.values`.

`bee.workspace.catalog:contract`, `:extension` and `:local` retain their durable
identities. The local binding calls the authorized `bee.workspace.binding`
operations directly. Each operation decodes its request and checks the caller
before entering the host-selected execution scope. The private
`bee.workspace.binding:catalog` checks execution authority, fences archive
against a running workspace host and queries only workspace-owned tables.

SQL repositories live in `bee.workspace.persist`; checkpoint decoding and
selection values live in `bee.workspace.types`. `bee.workspace.persist:checkpoint`
combines the repositories for the host without owning a process or resource.
`bee.workspace.migrations:migrations` carries migrations 1–12 unchanged;
`bee.persist.persist:ledger` applies them with the original batch transaction and
connection-local freshness semantics. No row, topic or schema migration occurs.

The host supplies `target_db`, `target_roots`, `target_scope` and
`target_facade_policy`. The component creates no database or second resource
record. Requirements link database configuration onto the existing store entry
and catalog configuration onto its implementation. Explicit store opens also
accept host-selected reserved database IDs under the caller's database grant.
`target_application_protocol`, `target_decode` and `target_model` link the
existing host value codecs until their owning components are extracted. Linked
metadata selects dependencies and resources; it grants no authority.

See [storage](../../../docs/reference/storage.md),
[workspace state](../../../docs/reference/workspace-state.md) and
[workspace catalog](../../../docs/reference/workspace-catalog.md) for the
implemented operations and persistence contracts. Function publication refreshes
future calls; running hosts use their existing handoff or restart lifecycle.

## Host lease client

`bee.workspace.client:host_leases` acquires and releases leases on node-managed
workspace hosts. The holder registers a lease name and asks the existing node
host manager for the workspace's host. The manager answers only that holder;
`bee.security.desktop:workspace_host_lease_policy` selects who may name leases.
A timed-out acquire releases its lease and leaves attachment status unknown.
The client opens no store and selects no host permissions. Existing lease names,
`bee.workspace.hosts.*` topics and host lifecycle remain unchanged.
