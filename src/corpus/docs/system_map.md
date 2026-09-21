# Bee system map

This page records current ownership and explicit future boundaries. It is not a
list of callable APIs. Use module READMEs and the linked contracts for
implementation details.

Bee is a persistent terminal workspace. One Bee can own multiple workspaces;
each workspace owns its application state and recovery. A client presents
views from a workspace, while the host owns execution and attachments. The
desktop can be replaced or detached without stopping admitted applications.

## Identities and ownership

Machine, Bee node, workspace, desktop client, application instance, execution
process, human/agent principal and transport session are separate identities.
A PID is an execution address, not a credential. An attachment grants a
recipient explicit observation, input and resize rights over an existing view;
multiple presentations must not duplicate execution.

There is no central Bee SQL catalog. Registry definitions and configuration
history, workspace application state, approval records, thread records,
resources, credentials and client presentation state retain their respective
owners. A shared physical database does not change table authority. Aggregates
and caches are projections that owners can rebuild.

## Current subsystem boundaries

| Subsystem | Owns | Status |
|---|---|---|
| Native runtime | Processes, supervision, transport, storage, terminal surfaces, filesystem events and lifecycle | Implemented platform foundation; Bee policy remains above runtime primitives |
| Workspace owner | Workspace identity, application data, resources, instances and recovery | Implemented locally; public workspace selection across nodes is a proposal |
| Host and attachments | Application admission, producer lifetime, view sharing, control/observation and retained execution | Implemented for local host/client attachment |
| Client shell | Start, windows, layout, presenter replacement, Timeline, Inbox and local commands | Presentation consumes owner data; it does not own execution or authorization |
| Registry/catalog | Stable definitions, dependency closure, versions and discovery projections | Metadata is descriptive; admission and policy are separate |
| Application definition service | Service-owned editable application records projected into admitted runtime definitions | Proposal; these records are not registry overlays or workspace tables |
| Hub | Search, provenance, local planning, host-authorized apply and receipts | Local path implemented; destination transfer/install is a proposal |
| Governance | Durable overlay authoring, immutable candidates, review, activation and restart recovery | Implemented for host-selected local overlays; durable public registry publication is a proposal |
| Approvals | Owner-scoped requests, decisions, policy, inbox feed, consumption and delivery outbox | Local owner and Inbox projection implemented; federation is a proposal |
| Threads and delivery | Durable records, memberships, actions, attempts, subscriptions, obligations, waits, projections and carriers | Local owner implemented; cross-node forwarding remains a proposal |
| Resources and credentials | Named roots, containment, audience-bound grants and credential materialization | Owner contracts implemented; portable authority transfer remains a proposal |
| Placement and harnesses | Launch plans, attempts, native placement, carrier, hooks, permissions and cleanup | Local managed launch path implemented; managed Docker/headless launch is a proposal |
| Hive | Authenticated operation contracts and configured policy routing | Generic policy route implemented; public enrollment, discovery and remote workspace composition are proposals |
| Operation/interface catalog | Filtered descriptions shared by contracts, tools, traits, UI and remote adapters | Visibility is descriptive; each invocation is authorized at its owner |

An application definition describes capabilities, but the host-selected
admission record supplies policy and scopes. A component cannot publish itself,
select an arbitrary database, or turn a client attachment into authority.
Native Terminal retains OS-user authority. Core remains independent of default
application implementations; all applications are standalone processes.

## Installation and change ownership

Use one reviewable plan for local Hub changes, governed overlays and
service-owned application changes. The plan names the authenticated requester,
target owner/workspace, expected revisions, exact candidate and dependency
digests, effective capability/resource changes, dependency order, migration and
lifecycle effects, recovery steps and rollback limits.

The owner sequence is stage, resolve, validate, authorize, apply, activate,
verify and receipt. Each owner writes its own tables and migration ledger.
Persist intent before effects, use idempotent operation keys, recheck revisions
and policy ceilings, and reconcile an uncertain effect after a crash. Publishing
a definition and activating it are separate outcomes. Installed, visible,
compatible, activated and running are separate states; Hub search and artifact
caching confer none of the later states.

Applied migrations are immutable. Plans must identify whether a change supports
live application replacement, checkpoint/restore, presenter rejoin, owner
restart or native rebuild. Existing executions keep their admitted closure until
their lifecycle contract permits replacement. A recoverable baseline is
required for runtime editing.

## Visibility, approvals and sharing

The Inbox is an owner-qualified projection. A client may aggregate requests it
is authorized to discover and read, keeping a separate cursor per owner. The
authoritative owner rechecks visibility, deadline, proposal digest and approver
rights when reading or deciding. A stale row cannot authorize a changed
proposal. Notifications wake a client; they are not decisions. There is no
invented global order across approval owners.

Keep these operations separate:

- Sharing a view keeps execution at its owner and grants a new attachment.
- Sharing a definition exports admitted content and dependencies for a new
  destination-owned plan.
- Transferring supported state uses an owner-defined schema and resolves
  destination resources and authority explicitly.
- Exposing a service publishes a host-selected interface description, then
  authorizes each invocation and resulting session at its owner.

Portable content excludes credentials, enrollment secrets, active grants, live
PIDs, native handles and unsupported process memory. Client layouts are not
portable execution snapshots. Registry publication is not a workspace database
export. Knowing a PID, holding a mesh membership or reading metadata does not
authorize an operation.

## Explicit proposals

The following remain proposals until their owners, permissions, migration and
acceptance contracts are implemented:

- public Hive enrollment, named-node discovery, headless launch and remote
  workspace composition;
- destination-owned Hub package transfer/install and durable/federated registry
  publication;
- independent package releases and alternate overlay lifecycles;
- cross-node approval/inbox federation and remote view/state sharing;
- managed Docker launch, portable harness execution and generic durable
  continuation/wakeup workflows.

Each proposal must preserve destination-owned permissions, explicit identities,
typed boundaries, append-only migrations and recoverable receipts. No desktop,
agent, registry description or mesh membership may bypass those owners.
