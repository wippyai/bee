# Package boundaries

Native assembly is now implemented as described in [native distribution](NATIVE_DISTRIBUTION.md).
The package extraction, in-app installation and overlay operations below remain proposals.
[System map](SYSTEM_MAP.md) records their relationship to service-owned editable
applications, governance, portable sharing and the distributed inbox.

The shell is the current delivery boundary. Directories distinguish ownership;
separate Hub releases and dependency manifests will follow once the contracts
are stable. Moving a file must not change an application's registry identity.

| Layer | Owns | Depends on |
|---|---|---|
| Core | Desktop/session lifetime, composition, focus, geometry, admission, app lifecycle and workspace persistence | Runtime primitives and shared UI values |
| Shared UI | Appearance, wallpaper and reusable presentation helpers | Value contracts; no application authority |
| Default apps | Terminal, Settings and local Process Manager | Explicit grants and core protocols |
| Optional packages | Lookout, coding tools, harnesses, models and other future apps | Published capability/trait contracts |
| Independent subsystems | Threads, Hub discovery/install, overlay editing/review, MCP | Runtime services and authenticated operation contracts |
| Native Bee extensions | Future coding-specific I/O, file watching and adapters | Native runtime module registration |

Core does not import a default application's implementation. A launcher can name
an admitted definition; this does not couple the renderer or model to its logic.
Every app is a standalone process. Services are separate from windows and must
not acquire a view-owned lifetime merely to appear in navigation.

## Required future subsystem contracts

Runtime installation and updates, as in Keeper, are requirements for registry
packages. They need dependency resolution, package provenance, capability review,
versioned activation and recovery. Hub search must support keyword discovery
(including `bee`) without treating a search match as admission or authorization.

Authorized self-edit must cover all Bee application source: core shell, default
apps and shared libraries. The edit subsystem should inspect the active source
and dependency graph, stage a workspace overlay against a known revision, lint
and test it, show the source/capability diff, activate the reviewed revision, and
record a receipt with rollback information. A baseline bundled in the binary
must remain recoverable. Core source changes belong to the host-selected maintenance boundary; not every
component permits runtime editing or activation. Being an application actor must
not imply core-publication permission.

Edits to a replaceable presenter can reuse the existing live rejoin boundary.
Apps now have an opt-in checkpoint/restore protocol; coordinated live producer
replacement is still unimplemented. Stable
workspace/session changes need a coordinated restart and recovery contract; F12
alone does not replace those processes. The native binary has its own build and
restart boundary. These distinctions must be visible to the edit subsystem.

Bee may carry native coding modules before they are mature enough to move into
generic Wippy. Such modules are built into a native release; registry package
installation cannot manufacture a new Go module in an already running process.

These subsystems are not implemented by the shell refinement. Their agent-facing
operations, receipts and recovery instructions must ship with their implementation.

## Isolated registry-planner component

`modules/bee-registry-planner` is a private, separately published library and
acceptance fixture for one narrow part of the future package path. Versions
`wolfy-j/bee-registry-planner@0.1.0` and `@0.1.1` demonstrate immutable-snapshot
harness-binding planning, durable candidate staging, an agent trait, and
append-only install/update migrations on SQLite and PostgreSQL. The planner
cannot publish or apply registry entries, grant permissions, activate drivers,
or launch processes. It is outside production `src/`, is not a Bee dependency,
and does not make Hub installation, overlays, self-edit, or activation callable
from Bee.

Migration 1 creates the staged-candidate store. Migration 2 adds a bounded
summary with an empty default and leaves migration 1 unchanged. The standalone
upgrade acceptance installs the published 0.1.0 artifact, writes a candidate,
updates to the published 0.1.1 artifact, applies migration 2, and verifies the
old candidate and migration ledger survive. A governed activation owner must
still re-plan or recheck the exact generation and digests before consuming any
candidate.

## Native distribution feasibility

The current Wippy CLI already supports `.wapp` and Hub references, including cache
and dependency resolution. The pack reader accepts `io.ReaderAt`, so an embedded
pack can be read from bytes. The missing reusable boundary is public boot/pack
execution: the CLI's loader and command execution are currently internal.
A future native runtime change should expose that boundary for a small `cmd/bee`
with an embedded base pack and optional Bee-native module registration. No native
distribution code is part of this shell round.

The next proposed slice is [durable threads and subscriptions](FOUNDATION_NEXT.md),
with transport-neutral authorization and MCP as an adapter. Publication remains
a separate authority even when its requests and receipts are carried on threads.

Bee must remain self-sufficient. Kickside components are optional later extensions,
not a prerequisite or current compatibility milestone. Domain adapters should
preserve explicit resource and authorization boundaries so integration remains
possible without coupling the desktop to a web host or external platform.
