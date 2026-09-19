# "Building Components"

_Path: en/guides/components_

> "Declare reusable module requirements with ns.requirement and supply them from a host through dependency parameters."

## Table of Contents

- Building Components

## Content

# Building Components


A **component** is a reusable Wippy module published to the Hub and mounted into a host application. A component can depend on a database, process host, or router without knowing the host's entry IDs. It declares these dependencies through a **requirement interface**, and the host supplies their values.

This guide covers the author side: declaring that interface and understanding how values flow into your entries. For the consumer side (lock files, version constraints, `wippy add`/`update`) see [Dependency Management](guides/dependency-management.md). For how a component is structured internally see [Application Architecture](concepts/architecture.md).



## The Three Entry Kinds


| Kind | Side | Role |
|------|------|------|
| `ns.definition` | component | Module metadata; required to publish. |
| `ns.requirement` | component | A hole the host must fill, and where to inject the value. |
| `ns.dependency` | host | Mounts a component and supplies values for its requirements. |



## ns.definition


Each published module must have exactly one definition. The definition can carry module metadata, a README reference, and wiki page references.

```yaml
- name: definition
  kind: ns.definition
  module: jobs                # optional module metadata
  readme: file://README.md    # path to the module's documentation
  meta:
    title: Durable Jobs
    description: Leased job queue with retry and dead-lettering.
```

`module`, `readme`, and `wiki` are definition data; all are optional. `meta` is ordinary entry metadata for management UIs. Release notes are supplied at publish time, not here.



## ns.requirement


A requirement is a **named value with a list of injection targets**. The host supplies the value, and the runtime writes it into each target entry at the specified path.

```yaml
- name: target_db
  kind: ns.requirement
  meta:
    description: SQL database backing every table in this module.
  default: app:db
  targets:
    - entry: app.jobs.migrations:schema
      path: .meta.target_db
    - entry: app.jobs.persist:lifecycle
      path: .db
```



### `default`: Mandatory or Optional


The `default` field decides whether the host *must* supply a value:

- **`default` present with a non-null value** (including an empty string) → the requirement is **optional**. If the host supplies nothing, the default is used.
- **`default` absent** → the requirement is **mandatory**. With nothing supplied, linking fails under strict mode (and warns otherwise).

<note>
An explicitly empty default (<code>default: ""</code>) is distinct from an
absent or null default. Empty-string means "optional, falls back to nothing";
absent and <code>default: null</code> both mean "the host must provide this."
Use a non-null default for infrastructure that has a sane in-app convention
(<code>app:db</code>, <code>app:processes</code>); omit it for values only the
host can know.
</note>



### `targets`: Injection Locations


Each target is an `{entry, path}` pair:

- **`entry`** — the entry the value is injected into. A bare name (`schema`) resolves within the requirement's own namespace; a fully-qualified id (`app.jobs.migrations:schema`) targets that entry exactly, across namespaces.
- **`path`** — a dot path into the target entry, e.g. `.meta.target_db`, `.host`, `.database.url`. The leading dot is conventional.

A requirement must declare at least one target.

Append instead of set with the `+=` suffix on the path — useful when several requirements contribute to one list (e.g. middleware):

```yaml
targets:
  - entry: app.api:router
    path: .middleware+=     # appends the value to the list at .middleware
```



### One Requirement, Multiple Targets


Group targets that need the same value under one requirement. For example, `target_db` can supply every migration's `.meta.target_db` and persistence library's `.db`; `process_host` can supply each supervised service's `.host`; and `api_router` can supply each endpoint's `.meta.router`:

```yaml
- name: process_host
  kind: ns.requirement
  default: app:processes
  targets:
    - { entry: app.jobs.service:worker.service, path: .host }
    - { entry: app.jobs.service:sweeper.service, path: .host }
```

The host supplies one value, and the runtime writes it to every declared target. The requirement entry contains this wiring directly.



## Consuming a Component


The host mounts a component with `ns.dependency` and fills its requirements through `parameters`:

```yaml
version: "1.0"
namespace: app
entries:
  - name: dep.jobs
    kind: ns.dependency
    component: acme/jobs
    version: "^1.0.0"
    parameters:
      - name: target_db
        value: app:db
      - name: process_host
        value: app:processes
      - name: api_router
        value: app:api
```

Each `parameter.name` matches a requirement; its `value` is what gets injected into that requirement's targets. Requirements with a default may be omitted; mandatory ones must be supplied.



### Parameter Name Matching


How a parameter name binds to a requirement:

- **Bare name** (`target_db`) matches a requirement of that name belonging to the component being mounted. It does not cross into a different module's requirements.
- **Qualified name** (`acme.jobs:target_db`) matches that requirement id exactly. Use this to disambiguate when wiring transitive dependencies.

If two dependencies supply **different** values for the same requirement, that is a conflict and is reported (identical values are fine).



## When Values Resolve


Injection happens at the **Link stage** of the build pipeline — at publish, during dependency expansion, and at boot — not at runtime. The stage:

1. Collects every `ns.requirement` and every `ns.dependency` with its parameters.
2. For each requirement, resolves a value: a matching parameter wins; otherwise the default; otherwise (no default) it is unresolved.
3. Writes the resolved value into each target entry at its path (set, or append for `+=`).

Under **strict requirements** an unresolved mandatory requirement fails the build; otherwise it logs a warning and proceeds. By the time entries reach the runtime, every filled requirement has already been baked into its targets.



## Verify Integration with a Mount Test


Unit tests do not verify the assembled module's registry relationships. Add a packaging or mount test against the requirement-injected registry to verify that:

- every supervised `service` points at a process entry that exists,
- every spawned or scheduled id resolves to a real entry,
- every `env.variable`'s storage is registered.

This catches unresolved relationships such as a supervisor referencing an unregistered worker or a test fixture using a harness-only storage ID. See [Supervision](guides/supervision.md) and the [Testing](framework/testing.md) framework.



## See Also


- [Application Architecture](concepts/architecture.md) — how a component is structured internally
- [Dependency Management](guides/dependency-management.md) — lock files, versions, the consumer workflow
- [Publishing Modules](guides/publishing.md) — putting a component on the hub
- [Entry Kinds Guide](guides/entry-kinds.md) — `ns.definition`, `ns.requirement`, `ns.dependency` reference



## Navigation

Previous: "Build-time artifacts" (guides/artifacts)
Next: "Entry Kinds Reference" (guides/entry-kinds)
