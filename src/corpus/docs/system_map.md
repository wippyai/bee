# Bee ownership and boundaries

This page records which component of `src/` owns what, and the boundaries
between them. It is not a list of callable APIs; each component has its own
document (`component/<name>`).

Bee is a terminal desktop. A node (`bee.node`) owns the workspaces, desktops and
running application instances of one folder. A display (`bee.shell`) shows one
desktop at a time and owns window placement, so a display can detach or be
replaced without stopping the applications the node runs. Agents run as
sessions; Threads keeps their durable record.

## Identities

A machine, a Bee node, a workspace, a desktop, an application instance, an
execution process, a human or agent principal and a transport session are
separate identities. A process id is an execution address, not a credential. An
attachment grants a recipient observation, input and resize rights over an
existing view. Knowing a process id, holding a mesh membership or reading
metadata authorizes nothing: each operation is authorized by its owner.

## Table ownership

There is no central SQL catalog. Every component owns the `bee_<name>_*` tables
that its migrations create in the node database (see `docs/storage`).
Aggregates and caches are projections an owner can rebuild.

## Components

| Component (`src/`) | Namespace | Owns |
|---|---|---|
| `values` | `bee.values` | Bounded decoders, canonical encoding, the clock and reply values every owner shares |
| `persist` | `bee.persist` | Access to the node database and its transactions |
| `deps`, `env` | `bee.deps`, `bee.env` | Dependencies on Wippy modules; the workspace folder, the machine home and the documentation corpus volume |
| `process` | `bee.process` | The worker loop background services run |
| `node` | `bee.node` | Workspaces, desktops, kept application instances, node settings, the node owner process, the application broker and the workspace catalog operations |
| `app` | `bee.app` | The application SDK: launch values, `client`, arguments, descriptors, interaction; `bee.app.threads` carries thread requests from an app through its broker |
| `shell` | `bee.shell` | The display: windows, Start menu, taskbar, workspace menu, dialogs |
| `ui` | `bee.ui` | The application frame, appearance and themes, visualization (`viz`), diagrams, forms and the folder picker |
| `apps` | `bee.apps.*` | The stock applications: Help, Modules, Overlays, Processes, Settings, Terminal |
| `hive` | `bee.hive` | The call protocol between nodes: one supervisor per node routes an operation by its prefix to the node-local service that serves it |
| `sync` | `bee.sync` | Typed projection feeds and replicas between nodes |
| `threads` | `bee.threads` | Durable thread records, membership, delivery, notices, action inboxes, carrier checkpoints and the Sessions work journal |
| `threads/sessions` | `bee.threads.sessions` | The Sessions contract, client and protocol over the journal |
| `approvals` | `bee.approvals` | Owner-scoped approval requests, decisions, policy, the feed and the Needs you app (`bee.approvals.inbox.app`) |
| `capability` | `bee.capability` | The capability catalog and the model that compares grants |
| `resources` | `bee.resources` | Named resource roots, associations and grants |
| `credentials` | `bee.credentials` | Credential sources and projections |
| `harness` | `bee.harness` | Agent profiles, launch admission, hooks, the carrier of a running attempt and the Sessions app (`bee.harness.app`) |
| `driver` | `bee.driver` | Agent drivers: `claude`, `codex`, `agy`, `grok`, `muse`, `opencode` and the native `wippy` driver, over shared descriptors, profiles, codec, permission and transport |
| `placement` | `bee.placement` | Launch plans and attempts; `native` and `docker` place them |
| `executor/external` | `bee.executor.external` | Running a driver's external process under a placement |
| `git/worktree` | `bee.git.worktree` | The Git worktree a launch can prepare and clean up |
| `gateway` | `bee.gateway` | The scoped MCP gateway agents reach Bee through: sessions, bindings, hooks, tool surfaces and publication |
| `docs` | `bee.docs` | The offline corpus and its read-only `docs` tool |
| `gov` | `bee.gov` | Overlay authoring, freeze, preflight, delivery, approval, activation, revert and recovery; the component authoring guide |
| `hub` | `bee.hub` | Package search, inspection, planning, installation and publication |
| `security` | `bee.security.*` | Policies the approval, documentation and gateway owners hold |
| `corpus` | none | The documentation read by the `docs` tool |

## Boundaries

An application definition describes what it needs; the host-selected admission
record supplies its policy and scopes. A component cannot publish itself, select
an arbitrary database or turn a display attachment into authority. Applications
run as separate processes in a scope that holds only what their process entry and admission
name, and may not start the node's own services; they reach an owner through its contract or through the
application broker.

The node database is opened only by an owner. Applications read workspace data
through `bee.node.binding` and threads through `bee.threads` contracts under the
actor the broker issues.

Metadata is descriptive. Registry entries, route names and `meta` fields never
authorize an operation; the owner of each operation checks the caller.

## Change ownership

Governance and Hub are the two ways installed code changes. A change follows
stage, validate, authorize, apply, activate and verify, and each owner writes
only its own tables and migrations. Intent is persisted before effects, retried
effects use idempotency keys, and an uncertain effect is reconciled after a
crash. An agent-authored overlay is frozen, preflighted and delivered, and the
person approves one request that names the version and the permissions it adds
(see `docs/approvals` and `component/gov`). Installed, visible, activated and
running are separate states. Applied migrations are immutable, and an existing
execution keeps its admitted definition until its lifecycle permits replacement.

## Visibility, approvals and sharing

The Needs you inbox is an owner-qualified projection. A client aggregates the
requests it may read, keeping a separate cursor per owner. The owner rechecks
visibility, deadline, proposal digest and approver rights when it reads or
decides; a stale row cannot authorize a changed proposal, and a notification
wakes a client without deciding anything. See `docs/sync_and_inbox`.

- Sharing a view keeps execution at its owner and grants a new attachment.
- Sharing a definition exports the admitted content for a destination-owned plan.
- Exposing a service publishes an operation on a Hive route, and each invocation
  is authorized at its owner.

Portable content excludes credentials, enrollment secrets, active grants, live
process ids and native handles.
