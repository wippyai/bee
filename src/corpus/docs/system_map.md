# Bee system map

This records the intended product and its subsystem boundaries. It is a planning
map, not a list of callable APIs or a claim that Hive is ready. Implementation
status lives in [foundation status](FOUNDATION_STATUS.md), module READMEs and
[the build sequence](BUILD_SEQUENCE.md). Existing detailed contracts remain
in force. Keep this map when splitting work between future agents.

The destination is a persistent Bee that can host many workspaces, run standalone
applications and automation, share admitted application views across clients,
and acquire new capabilities through governed packages and edits. A connected
client can present applications from several Bees and aggregate the approval
requests its user may resolve. The services continue without an open window.

## Identities and ownership

A machine may run multiple named Bees; a Bee may own multiple workspaces. A
workspace has its own resources and application state and is not synonymous with
a process, folder, desktop or node. A desktop composes views. An attachment grants
a client specific observation/control rights over an existing application.
Multiple presentations must not create duplicate application execution. Human
and agent principals, process incarnations and transport sessions are separate
identities; a PID is an address, not a credential.

There is no central Hive database. Each owner retains authoritative records and
migrations. Registry definitions/history, workspace application data, approval
records, thread history and client presentation state keep their respective
owners even when stores share a physical database file. Aggregates and caches
must be reconstructible from those owners.

## Subsystems needed

| Subsystem | Responsibility and boundary | Current reference / remaining work |
|---|---|---|
| Native runtime | Processes, supervision, topology, authenticated transport, storage, terminal surfaces, filesystem events and lifecycle | Generic Wippy capabilities; reconcile parallel runtime work before integration. No Bee mesh sidecar. |
| Node supervisor and Hive admission | Enrollment, named-node discovery, operation routing, permission checks, remote sessions and revocation | [Hive protocol](HIVE_PROTOCOL.md), [topology](HIVE_TOPOLOGY.md); public multinode acceptance remains required. |
| Workspace owner | Own persistent projects, resource associations, app instances and recovery; many workspaces per Bee | [Workspace attachments](WORKSPACE_ATTACHMENTS.md), [client state](CLIENT_STATE.md); public management/selection must preserve the identity split. |
| Application host and attachments | Standalone app lifetime, instance admission, view sharing, control versus observation, retained execution | [Application contracts](APPLICATION_CONTRACTS.md), [host/client split](CLIENT_HOST_SPLIT.md); remote/multiple-display composition needs acceptance. |
| Client shell and apps | Start, node/workspace selection, windows, multiple presentations, Timeline, Inbox and Hive Manager | Presentation consumes typed owner data. It does not own execution or authorization. |
| Registry and catalogs | Stable definition IDs, measured dependency closures, compatible bindings, versions and authorized discovery | [Registry extension](REGISTRY_EXTENSION.md); metadata describes capabilities and never grants them. |
| Application definition service | Own editable application records stored in an application database and project admitted definitions into runtime entries | Required future contract. Service-owned application records are not interchangeable with registry-owned core/Hub definitions. |
| Package discovery and artifact cache | Hub search, provenance, immutable artifacts, dependency cache and platform/runtime requirements | [Package boundaries](PACKAGE_BOUNDARIES.md), [native distribution](NATIVE_DISTRIBUTION.md); cached is not installed or authorized. |
| Installation/change planner | Resolve a complete proposed change against a known owner/registry revision and explain its effects | Required Keeper-style plan/validate/approve/apply workflow; detail below. Reuse or extend generic runtime planning where available. |
| Governance and publication | Authorize exact candidates, enforce namespace/grant ceilings, apply through the owning service, record receipts | [Registry extension](REGISTRY_EXTENSION.md); no direct agent registry publication or overlay activation. |
| Registry overlay lifecycle | Stage, validate, activate, reconcile, recover and retire registry overlays under governance | Proposal. Reserve “registry overlay” for this mechanism; ordinary application records and view state are not overlays. |
| Durable approvals owner | Own proposal-bound requests, eligible approvers, decisions, deadlines, withdrawal, effect consumption and delivery outbox | [Approvals](APPROVALS.md), `bee.approvals`; local owner/application exist, federation remains separate. |
| Durable waits and continuations | Owner-persisted wait state and typed function/args/context/security bindings; race-safe wakeup, bounded inbox budgets and recovery | [Reusable wait/wakeup contract](APPROVALS.md#required-reusable-wait-and-wakeup-contract); proposal, separate from approval decision authority. |
| Distributed inbox projection | Discover visible approval sources and aggregate owner-qualified requests into one user-facing inbox | Proposal; any connected authorized client can present the aggregate. It never becomes a central approval authority. |
| Operation and interface catalog | One implementation exposed through contracts, tools, traits, UI and remote calls with filtered visibility | [Hive protocol](HIVE_PROTOCOL.md), [registry extension](REGISTRY_EXTENSION.md); adapters cannot widen owner policy. |
| Threads, subscriptions and delivery | Durable records, correlation, waits, replay, status projections and human/agent workflow events | [Threads](THREADS.md), [delivery](THREAD_DELIVERY.md), [sessions](THREAD_SESSIONS.md); local components exist; cross-node forwarding needs proof. |
| Resources and credentials | Named filesystem roots and other provider resources, containment, audience-bound access, credential materialization | [Resources](../src/resources/README.md), [credentials](../src/credentials/README.md); preserve owner boundaries during export and placement. |
| Launch, placement and harnesses | One launch definition from CLI/UI/tools; execution identity, recovery, native/Docker placement, hooks and permissions | [Launch routing](LAUNCH_ROUTING.md), [placement](PLACEMENT_AND_SUBSCRIPTIONS.md), [carrier](CARRIER.md); managed public launch has separate gates. |
| Export, import and sharing | Portable definitions, application content and explicitly supported state with dependency/provenance manifests | Future owner-mediated operations; importing is a new governed plan, not replaying foreign grants. |
| Diagnostics and runtime supervision | Typed errors with operation/owner context, durable outcomes, bounded telemetry and optional automated assistance | Diagnostic views observe owners. Future model-driven corrective hooks submit authorized operations; they do not bypass governance. |

## Installation and change planning

Use one governed change workflow for Hub installation, local authored definitions,
registry overlays and edits to service-owned applications. Each storage owner
keeps its own apply operation; a shared planner does not write all owners' tables.
Keeper is the reference workflow, not a required Bee runtime dependency.

A reviewable plan must include:

- The authenticated requester, target owner/workspace, expected revisions and
  exact candidate/dependency digests; dependencies, conflicts and binding holes.
- Added/changed/removed definitions, effective transitive closure, provenance,
  runtime/platform compatibility, resource needs and capability changes.
- The dependency order for validation, migrations, publication, activation,
  drain/replacement/restart, and recovery if execution stops between steps.
- Required human decisions or existing delegated authority, validation evidence,
  irreversible effects and rollback limits. Do not promise rollback of external
  effects, historical decisions or applied migrations.

The sequence is stage → resolve → validate → authorize → apply → activate →
verify → receipt. Publishing definitions and activating them are distinct
outcomes. Persist the plan and step outcomes before effects, use idempotent
operations and recheck revisions and permission ceilings at execution. A changed
candidate invalidates its prior approval. A crash resumes by reconciliation;
uncertain effects must not be blindly repeated. A multi-owner plan has separate
owner decisions/receipts and compensation rules, not an assumed global transaction.

Installed, visible, compatible, activated and running are distinct states. Hub
search and artifact caching confer none of the later states. Content-addressed
caches may share immutable dependency artifacts; never cache credentials as
portable package content or let cache eviction remove a pinned live closure.

## Governed editing and registry overlays

Most agent-authored applications may be editable records in an application-level
database, projected by an owning service. Editing, export and activation go
through that service's governed contract. Core components and shared/Hub modules
may instead be registry-owned definitions. Do not drive either owner's durable
state by directly manipulating another owner's store or transient overlays.

All programmatic edits and overlay activation use governance, including self-edit.
Host policy classifies what can be edited and when. Some core authorities require
human maintenance approval; some changes cannot be activated at runtime. Native
code requires a build and restart. Registry presence does not imply hot-editability.
Presenter replacement, app replacement, owner restart and native binary restart
are different lifecycle plans. Keep an accepted baseline recoverable.

Durable desired source and activation must survive restart. If the runtime overlay
mechanism is disposable, its owner reconstructs it from admitted durable content;
overlay history alone is not that guarantee. Existing executions retain their
admitted closure until their lifecycle contract permits replacement.

## One inbox across authorized owners

The user should be able to open one Inbox on a connected Bee and resolve requests
from every visible, reachable approval owner. “All inboxes” means those the
principal is allowed to discover/read/decide, not every request on the mesh.

An approval source exposes a versioned typed interface for discovery, bounded
listing, read, subscription/resume and decision submission. Source visibility,
request visibility and decision rights are distinct. The standard presentation
must work without loading owner-supplied rendering code. Optional renderers can
present a request but cannot decide it.

Every projected row carries an owner-qualified request identity, proposal digest,
revision, deadline, operation summary, decision affordances and freshness. The
projection keeps independent bounded cursors per owner and distinguishes an empty
inbox from an unreachable owner. Permissions are rechecked at the owner on reads
and decisions; changed visibility must invalidate cached sensitive content.

A decision routes through supervisor admission to the authoritative owner. The
owner resolves races, enforces the deadline, commits one decision and consumes it
only for the exact approved effect. A stale projection cannot approve a changed
proposal. Reconnect resumes or explicitly rebuilds a projection; it does not replay
an old click as a new authorization. Offline display cannot claim a committed decision.

Outbox notifications may wake a thread, process or subscribed UI after the owner
commit. Retries are deduplicated; notifications are not authority. Per-owner order
is meaningful; there is no invented global ordering of all Hive approvals.

## Sharing, visibility and callable interfaces

Keep these operations distinct:

- Share an existing application view: its execution remains at the owner; each
  observer/controller has its own attachment and revocation boundary.
- Share an application/package definition: export admitted content and dependencies;
  the recipient installs through its own planner and permission policy.
- Transfer supported application state: the owner exports a versioned schema;
  import resolves destination resources and creates local authority explicitly.
- Expose a service operation: publish an interface description under host-selected
  visibility, then authorize each invocation and any resulting session at its owner.

A tool, trait, contract binding or UI action should address the same operation,
not copy its implementation. Discovery may list a descriptive capability without
authorizing execution; permission changes alter the visible callable surface.
Supervisors mediate cross-node admission. Authorized higher-rate direct sessions
may follow, with exact scope, incarnation, limits and revocation. Neither node
membership nor knowing a PID grants access.

Exports exclude credentials, enrollment secrets, active grants, live PIDs, native
handles and unsupported process memory. Registry publication is not an export of
a workspace database. Client display layouts are not portable execution snapshots.

## Sequence and acceptance

This map expands the destination, not the active implementation scope. Continue
[BUILD_SEQUENCE.md](BUILD_SEQUENCE.md); do not start overlays/Hub/MCP just because
this map records them. The runtime monitor/transport ownership reconciliation
remains an explicit prerequisite for the related Hive integration work.

1. Finish the coherent local runtime build and public client/retained-desktop
   foundation, including recovery, strict lint and honest release instructions.
2. Prove native Hive admission and remote attachment. Establish the operation and
   approval-source interfaces early so local components need no authority retrofit.
3. Federate approval sources with per-owner subscriptions and authorization; prove
   two clients racing one decision, disconnect/reconnect and visibility revocation.
4. Implement the governed planner/publication lane locally before distributing
   installation. Prove stale-plan rejection, crash reconciliation, migrations and
   lifecycle-specific recovery with a harmless application change.
5. Add Hub/package installation and registry overlay activation as clients of that
   lane. Prove one extension installs without a core edit and cannot expand its grants.
6. Add export/import and cross-node sharing with destination-owned plans. Prove
   relocation without copied secrets or accidental authority transfer.
7. Only after those gates, demonstrate governed self-modification and publish an
   honest GIF of the actual workflow. GPU-cluster and other domain capabilities
   become optional application plugins consuming the same foundations.

Keep approval federation independently loadable from its UI, and keep the planner
independent of a physical desktop, model or harness. This supports pure automation
and human-in-the-loop work through the same owner contracts.
