# "Registry"

_Path: en/concepts/registry_

> "How Wippy stores typed entries, initializes runtime resources, and propagates configuration changes."

## Table of Contents

- Registry

## Content

# Registry


The registry is Wippy's versioned store for entry points, services, resources, and other runtime definitions. Most runtime entry kinds are reconciled through event-bus transactions; internal kinds such as `registry.entry` and namespace metadata bypass event dispatch by default.



## Entries


The registry holds **entries**—typed definitions with unique IDs:

```
app.api:get_user          → HTTP handler
app.workers:email_sender  → Background process
app:database              → Database connection
app:templates             → Template set
```

Each entry has an `ID` (namespace:name format), a `kind` that determines its handler, arbitrary `meta` fields, and kind-specific `data`.

Alongside that authored content the registry keeps its own provenance for each entry: the `owner`, meaning the deployment source the entry came from, and `root`, marking a dependency declaration the deployment selected. This state is assigned by the registry, not written by the entry author, and it is kept separate from `meta` so the two can never be confused. It is read through the snapshot state API rather than the ordinary entry APIs—see [Registry module](lua/core/registry.md#snapshot-state).

For how the registry functions as an authorization layer, see the [Security Model](concepts/security-model.md).



## Kind Handlers


When a dispatched entry is submitted, its `kind` selects the registered handler. The handler validates and reconciles the corresponding runtime resource: an `http.service` entry manages an HTTP server, a `function.lua` entry manages a function pool, and a `db.sql.postgres` entry manages a connection pool. See the [Entry Kinds Guide](guides/entry-kinds.md) for available kinds and [Custom Entry Kinds](internals/kinds.md) for handler implementation.



## Live Updates


Entries can be added, updated, or removed while the system runs. For dispatched kinds, a registry transaction asks participating handlers to accept or reject each operation before commit. A rejection discards the transaction and applies the inverse transition. Related topology changes produce one new registry version.

Version history supports backward and forward transitions when history is enabled. Memory history is the default and lasts for the process lifetime; SQLite and PostgreSQL backends persist history across restarts.

YAML and JSON definition files are source manifests that the boot loader converts into entries. They are not serialized registry snapshots. See [Registry module](lua/core/registry.md) for programmatic access.



## See Also


- [YAML & Project Structure](start/structure.md) — Definition files
- [Custom Entry Kinds](internals/kinds.md) — Implement kind handlers
- [Process Model](concepts/process-model.md) — Understand process execution



## Navigation

Previous: "Application Architecture" (concepts/architecture)
Next: Security Model - Process Isolation, Capability Control, and Data Boundaries (concepts/security-model)
