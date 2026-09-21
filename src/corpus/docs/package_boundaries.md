# Package boundaries

Bee currently ships one native application pack. The local Hub can inspect,
plan and apply host-authorized components, and governed overlays can author,
freeze, review, apply and recover a destination-owned runtime overlay. Public
enrollment, managed headless launch, destination package transfer/install and
independent package extraction remain proposals. Their metadata must not be
described as a callable API until the corresponding owner and acceptance
contract exists. See [the system map](ownership.md) for the larger topology.

An admitted Wippy component may define services and functions, an owned
database and migrations, drivers, traits, agents, and optional UI. Bee governs
the exact resolved definitions, host-selected permissions and resources,
lifecycle and receipts. Registry metadata describes capabilities; it does not
authorize them. Component services own their domain protocol and state.

| Layer | Owns | Boundary |
|---|---|---|
| Core | Workspace/session lifetime, composition, focus, geometry, admission, application lifecycle and persistence | Runtime primitives and shared value contracts; no default-app implementation imports |
| Shared UI | Appearance, wallpaper and reusable presentation helpers | Value contracts only; no application authority |
| Default apps | Terminal, Settings, Process Manager and other bundled apps | Standalone processes with explicit grants and core protocols |
| Optional packages | Installed applications, coding tools, harnesses, models and services | Published contracts and host admission |
| Independent subsystems | Threads, Hub reads/planning/local apply, governed overlay authoring/review/apply/recovery, approvals, sync and scoped MCP | Authenticated operation contracts; each owns its state and migrations |
| Native extensions | Coding-specific I/O, file watching and native adapters | Built into a native release; registry installation cannot add a Go module to a running process |

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
