# Package boundaries

Bee's native executable embeds a full baseline component graph. Its component lock
includes `bee/agents`, a meta-package for the separately composed harness,
credential, placement, resource and driver components. The local Hub can
inspect, plan and apply host-authorized components, and governed overlays can
author, freeze, review, apply and recover a destination-owned runtime overlay.
Host-owned `bee.deps` roots select components and their requirement parameters.
The M6 root conversion uses Hub's existing plan, apply and registry-history
receipt; it changes no SQL schema. Optional Bee components can be managed
individually. Required host roots and the installer dependency closure refuse
independent removal or replacement. Core self-update preserves component
selection and refuses artifacts that declare Bee-component dependencies.
`make native-pack` seals the composed boot root and dependency-free Hub core
together; their distinct release identities keep recovery and publication separate.
Service drain, generation handoff and independent release streams remain proposals.
The bare kernel can omit `bee/agents`; its known agent commands direct the user
to install the package. Public enrollment, managed headless launch,
destination-owned package transfer/install and independent release streams
remain proposals. Their metadata must not be described as a callable API until
the corresponding owner and acceptance contract exists. See [the system
map](ownership.md) for the larger topology and the [generated component
inventory](component-inventory.json) for the current source declarations.

An admitted Wippy component may define services and functions, an owned
database and migrations, drivers, traits, agents, and optional UI. Bee governs
the exact resolved definitions, host-selected permissions and resources,
lifecycle and receipts. Registry metadata describes capabilities; it does not
authorize them. Component services own their domain protocol and state.

| Layer | Owns | Boundary |
|---|---|---|
| Core | Workspace/session lifetime, composition, focus, geometry, admission and application lifecycle | Runtime primitives and shared value contracts; no default-app implementation imports |
| Shared UI values | Frame, semantic appearance, bounded text and the forms, visualization, diagram and folder-picker kits in `bee/ui` | Value contracts only; UI has no application SDK or owner-service dependencies |
| Default apps | Terminal, Settings, Process Manager and other bundled apps | Standalone processes with explicit grants and core protocols |
| Optional packages | Installed applications, coding tools, harnesses, models and services | Published contracts and host admission |
| Independent subsystems | Workspace catalog/checkpoints, Threads, Hub reads/planning/local apply, governed overlay authoring/review/apply/recovery, approvals, sync and scoped MCP | Authenticated operation contracts; each owns its state and migrations |
| Native extensions | Coding-specific I/O, file watching and native adapters | Built into a native release; registry installation cannot add a Go module to a running process |

## Default managed-agent kit

`bee/agents` composes `bee/harness`, `bee/credentials`, `bee/placement`,
`bee/placement-native`, `bee/resources`, the shared driver contracts and Bee's
built-in drivers. The normal Bee lock includes this bundle, so the Agent
application and `bee claude`, `bee codex`, `bee agy`, `bee grok`, `bee muse`,
`bee opencode` and `bee wippy` commands remain available by default.

The harness owns its Agent application, launch setup and activation entries,
gateway hook endpoints and harness policies. Placement, credentials and
resources own their corresponding roots, host requirements and policies.
Driver components own their launch policies and default host requirements.
Requirements use package defaults that an assembly can replace. The Gateway
component owns the MCP listener, tool routes and tool policies; the harness
package adds only the hook endpoints used by managed agents.

The Agent application's public definition ID and driver definition IDs remain
unchanged when their source moves into these packages. Saved workspace state
therefore continues to resolve those definitions. No owned persistence schema
stores the moved host policy IDs, so this extraction does not require a data
migration.

Physical directories do not define registry identity. Moving an implementation
must preserve its stable definition ID. Every application is a standalone
process; a service must not acquire a view-owned lifetime merely to appear in
navigation. A presenter replacement, application replacement, owner restart and
native binary restart are different lifecycle operations. F12 replaces only
the presenter.

## Hub and governed changes

Hub search is discovery only. A local plan resolves exact dependencies and
provenance against a known owner/registry revision, checks host-selected
permissions and resources, applies through the owning service and records a
recoverable receipt. A search result or cached artifact is not installed,
admitted or authorized. A request sent to another Bee is a destination-owned
operation; the destination resolves its own definitions, policies and resources
and records its own plan and receipt.

Governed authoring stages bounded files in a durable overlay, freezes an
immutable candidate, shows its definitions and capability effects, obtains an
exact approval, and applies through the destination owner with restart recovery.
The applied overlay does not make a component a durable registry publication.
Core, shared libraries and default-app changes remain a host maintenance
boundary unless their owner explicitly supports runtime activation. A bundled
baseline stays recoverable. Being an application actor does not imply
publication authority.

Each change distinguishes staging, resolution, validation, authorization,
application, activation, verification and receipt. Persist intent and step
outcomes before external effects. Recheck revisions and permission ceilings at
execution. A changed candidate invalidates its approval. Crash recovery
reconciles uncertain effects; it never promises rollback of an external effect
or applied migration. Multi-owner changes have separate decisions and receipts
rather than an assumed global transaction.

## Native distribution

The native Bee executable embeds the application pack, build/runtime
provenance and a recovery path for its bundled deployment. Hub references keep
their own cache and installation lifecycle. Registry packages can install only
definitions and resources supported by the running executable; they cannot add
a new native module to that process.

The native distribution is self-sufficient. External or domain-specific
components are optional extensions and must retain explicit resource and
authorization boundaries. Credentials, enrollment secrets, active grants,
live PIDs, native handles and unsupported process memory are not portable
package content. Durable publication is a separate authority from discovery,
artifact caching, local apply and Hive membership.
