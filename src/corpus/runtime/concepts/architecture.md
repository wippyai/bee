# "Application Architecture"

_Path: en/concepts/architecture_

> "How to carve a Wippy application into namespaces, slices, and layers so the registry graph stays composable, testable, and bootable as it grows."

## Table of Contents

- Application Architecture

## Content

# Application Architecture


A Wippy application is a **graph of registry entries** represented by source files. Code lives in entries such as `function.lua` and `process.lua`; `_index.yaml` files declare how functions, routes, services, and libraries connect. Application structure determines how that graph is divided into namespaces so it remains composable, testable, and bootable as it grows.

This page explains one way to organize that graph. For file format, naming, and `_index.yaml` placement, see [YAML & Project Structure](start/structure.md). For entry definitions, see the [Entry Kinds Guide](guides/entry-kinds.md).



## Feature Slices


A useful default is to organize by **feature** rather than file type. A slice owns one capability end to end—its database access, long-running processes, HTTP surface, and shared vocabulary—and lives under one namespace prefix:

```
src/app/jobs/          namespace: app.jobs
src/app/auth/          namespace: app.auth
src/app/billing/       namespace: app.billing
```

Feature slices keep related behavior within one folder, making a capability easier to read, test, change, or remove without tracing it across top-level `handlers/`, `models/`, and `services/` directories.



## Layers within a slice


For larger slices, separate code by **what touches the outside world**. This applies ports-and-adapters (hexagonal) architecture through **sub-namespaces**:

```
src/app/jobs/                  namespace: app.jobs          ← shared vocabulary
  consts.lua  config.lua  types.lua
  persist/                     namespace: app.jobs.persist  ← database adapters (sql)
  service/                     namespace: app.jobs.service  ← processes, workers
  api/                         namespace: app.jobs.api      ← http.endpoints
```

Keep imports flowing from outer layers toward inner layers:

```
api  →  service  →  persist  →  { consts, config, types }
```

The slice root contains shared vocabulary and does not import its own children. Children may import the root. Avoid direct imports between slices; place shared definitions in a common parent namespace such as `app.core:types`.

<note>
Namespaces organize entry IDs but do not create dependencies or injection seams by themselves. Explicit <code>imports</code>, kind-specific references, and <code>ns.requirement</code> targets create those relationships. A consistent direction keeps the resulting graph explicit. See <a href="#why-this-shape">Why this shape</a>.
</note>

A small slice can use one `_index.yaml` for its libraries and endpoint. The important property is the **import direction**, not the number of folders.



## Shared Vocabulary


Three files commonly appear at the root of a slice. They contain definitions shared by the slice's layers:

| File | Holds | Capabilities |
|------|-------|--------------|
| `consts.lua` | State machines, enums, queue tiers, registry IDs of processes. The values that mirror your database `CHECK` constraints. | none |
| `config.lua` | Env-tunable knobs with a helper that applies a code default only when `env.get(KEY)` returns `errors.NOT_FOUND` and propagates permission or backend errors. No `env.variable` entry is required for a value to be optional. | `env` |
| `types.lua` | Entity shapes (`type Job = { ... }`) — the rows the persistence layer returns. | none |

`consts` and `types` declare **no host capabilities**; they are pure `library.lua` entries that return a table. Keeping domain vocabulary free of I/O also makes it testable without a database or process host.

Keep this vocabulary **slice-private**. Place constants and types shared across slices in a common parent namespace and import them rather than copying them.



## Capabilities by Layer


Lua entries declare non-ambient modules in `modules:` and registry-backed dependencies in `imports:`. A layered slice can keep those dependencies aligned with responsibility:

- `persist/*` declares `sql`, keeping database access in the persistence layer.
- `service/*` keeps process orchestration and service dependencies in the service layer. The `process` and `channel` globals are ambient and do not need `modules:` declarations.
- `api/*` declares modules such as `http` and imports the functions or libraries it calls.
- The root vocabulary needs no non-ambient modules or infrastructure imports.

This limits module visibility to a known layer. It is not an authorization grant: ABAC policies independently decide whether guarded operations such as `db.get` are allowed at runtime. To review code that can request a database handle, inspect `persist/`, its declared modules, and the policies attached to its execution context.



## Applications and Components


The same shape can support a single application or a published library; the difference is **who supplies its dependencies**.

An **application** is the top-level, deployable graph. It owns the concrete infrastructure — the `http.service`, the `process.host`, the database connection — under a root namespace (conventionally `app`), and wires everything together itself.

A **component** is a publishable module mounted into a host. Because it does not know the host's database or router IDs, it declares an interface of `ns.requirement` entries that the host supplies. Internally, a component can use the same layers, vocabulary, and import direction as an application slice.

These are two points on a spectrum:

- **Single app, internal slices** — slices live under `src/app/`, share the app's infrastructure directly by referencing `app:db`, `app:processes`. No requirement interface is needed because nothing external mounts them.
- **Multi-component composition** — each component is its own publishable module with an `ns.definition` and an `ns.requirement` interface, composed by a host through `ns.dependency`. The host fills each requirement (database, process host, router) once.

Choose based on whether the slice will be **consumed by a host you do not control**. Reusable components need a requirement interface; internal slices can reference application infrastructure directly. The packaging changes with reuse, while the internal layering can remain the same.

See [Building Components](guides/components.md) for the requirement/dependency mechanism, and [Dependency Management](guides/dependency-management.md) for the lock-file side.



## Why Use This Shape :id=why-this-shape


This structure supports composition, capability review, and boot-order analysis:

**Requirement targets are the injection seam.** Distinct namespaces make target IDs legible, but `ns.requirement.targets` performs the injection. A host can supply a database ID to persistence entries and a process-host ID to service entries. Directly referencing `app:db` instead couples the component to that host convention.

**One-way references keep registry transitions resolvable.** The registry extracts declared dependency paths and topologically orders changes so dependencies are created before their dependents and deleted after them. The direction `api → service → persist → root` helps keep that graph acyclic. A parent namespace is only an organizational convention; the shared entries still need explicit references.

**Modules scoped by layer have a clear boundary.** Each Lua chunk can resolve its declared imports and non-ambient modules; undeclared registry modules fail closed at module resolution. Runtime policy checks remain a separate boundary. When persistence entries alone declare `sql`, the code that can request a database handle is easier to identify and audit.

**The layering supports different test scopes.** Vocabulary can be tested without infrastructure. Persistence tests can use a database without starting workers. A whole-module **mount test** then checks the integration seams: every supervised service points to a process, every spawned ID resolves, and every requirement is filled.



## See Also


- [YAML & Project Structure](start/structure.md) — file format, naming, namespaces
- [Building Components](guides/components.md) — `ns.definition`, `ns.requirement`, mounting
- [Dependency Management](guides/dependency-management.md) — lock files, consuming modules
- [Registry](concepts/registry.md) — how entries are stored and resolved
- [Entry Kinds Guide](guides/entry-kinds.md) — every entry kind
- [Process Model](concepts/process-model.md) — services, supervision, hosts



## Navigation

Previous: "Compute Units" (concepts/compute-units)
Next: "Registry" (concepts/registry)
