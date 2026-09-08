# Workspace identity and client attachments

Status: design, not a callable API. Production currently has one local workspace
owner and one desktop session. [Workspace state](WORKSPACE_STATE.md) documents
the implemented envelope. This design leaves cluster transport and naming to the
runtime work; no remote discovery or network listener is enabled by it.

## Required headless profile

Headless Hive support is a requested built-in Bee profile, not an optional
third-party application. It remains unimplemented. Local launch must keep its
no-network default; selecting Hive explicitly enables authenticated joining and
remote attachment. A headless node must not need a physical TTY or a desktop
process to keep its workspaces alive.

Initially, each workspace has one hosting node that owns its writable database,
resource bindings and execution. One node can host several workspaces. Creating
a workspace on a selected remote node creates its state there; attaching a client
must not copy that state to the client or silently create a local replacement.
The workspace keeps its durable ID independently of that node's address.
Node loss means unavailable workspaces, not automatic failover or writable clones.

A user may start several clients and compose applications from several hosted
workspaces. Disconnecting a client leaves independent applications and workers
at their hosts. Hive discovery must identify candidate nodes and workspaces;
authentication and explicit attachment policy still decide access. Being on the
same home network does not grant control. Runtime cluster/naming changes remain
separate work; Bee should consume the native mesh and capability contracts.

## Host and client composition

The built-in profiles should compose the same owners:

| Profile | Starts | Lifetime |
|---|---|---|
| Local | Workspace host plus a local desktop client | Existing single-command experience |
| Headless Hive | Enrolled node and workspace hosts; no physical terminal or presenter | Continues without connected clients |
| Hive client | Physical terminal, client layout and authorized attachments | Disconnect ends attachments, not hosted work |

These are proposed roles, not current CLI commands. A host owns workspace
admission, its broker and its database. The client owns the physical terminal,
presenter and desktop layout. The current workspace actor combines these roles;
extract them before adding a network switch. A node directory resolves workspace
IDs to hosts; it must not become a second owner of application lifecycle or state.

Enrollment is explicit once; subsequent boots may rejoin the configured trusted
Hive automatically. Discovery alone never enrolls another machine. A selected
node can list authorized existing workspaces or create a new workspace there.
The client records the resulting workspace ID and host reference. Identical
folder names on two hosts are distinct workspaces, and losing a host does not
change where an application launch is sent.

Idle hosting must not create a desktop render loop per workspace. Start views on
demand, use native event subscriptions and arm lifecycle timers only while a
deadline exists. Mesh membership and active attachment lease renewals still have
traffic; “dormant” cannot promise zero traffic. Measure idle CPU, memory and bytes
with no client, then with observing and controlling clients, before claiming
large home-network capacity. The current local broker/presenter tick loops are
not evidence of that behavior.

## Identity and ownership

Workspace, execution node and client are distinct identities. A workspace is a
logical scope for applications, resources and authorization. Its default storage
can be local without making its identity a filesystem path or hostname.

| Identity | Owner and meaning |
|---|---|
| `workspace_id` | Durable opaque ID created with the workspace; unchanged by folder rename or client reconnect |
| `node_id` | Runtime execution placement; never substitutes for workspace identity |
| `definition_id` | Application type; installation revision is a separate value |
| `instance_id` | Logical application instance within a workspace; independent from its current process |
| `run_id` | A particular background operation owned by an application/subsystem |
| `view_id` | Logical application presentation, separate from the run it observes |
| `client_id` | Saved client presentation identity; not an authentication credential |
| `attachment_id` | One live, authorized binding between a client and an application view |

An application reference always includes `(workspace_id, instance_id)` and a
view reference adds `view_id`. A local implementation may resolve these directly;
a later remote implementation resolves an owner endpoint without changing the
logical reference. PIDs, names, mounts and connection IDs are temporary routing
or capability values, never durable identity or proof of user authority.

A workspace owns instance admission, application state and resource references.
The application/subsystem owns run state and durable event history. The client
owns tab ordering, placement, focus and appearance. A client can show several
workspaces; several clients can show one workspace with independent layouts.
Closing a tab detaches a view. Stopping an application or cancelling a run is a
separate authorized operation. Existing view-owned apps retain close-to-stop
behavior until a supported independent lifetime is explicitly introduced.

## Visible workspace identity

Every tab, window and action target retains its workspace reference, including
minimized windows and restored layouts. In a single-workspace desktop, the
workspace label can be compact; mixed desktops display a short workspace label
alongside each application's title. A color is supplementary, never the only
identifier. Duplicate display names must be disambiguated with a stable short
ID. Renaming a workspace changes presentation, not saved references.

Start and resource-open actions carry an explicit target workspace. Focus can
select the initial target, but an asynchronous reply must remain bound to the
workspace in the original request. Moving or reordering a tab changes only the
client layout; it does not migrate execution, copy files or change permissions.
Remote failures leave a clearly disconnected tab, not a new local application.

## Attachment lifecycle

The intended flow is resolve owner, authenticate, authorize an exact view and
rights, bind to the actual recipient, receive a full snapshot, then consume live
updates. Discovery only finds candidates; registry metadata never authorizes an
attachment. Restoring saved layout must repeat authorization and obtain fresh
capabilities. It must not replay persisted terminal mounts.

Attachment states are connecting, observing or controlling, disconnected, denied
and ended. Denied/ended are explicit outcomes. Transport loss leaves execution at
its owner and retries attachment with bounded backoff; it must not automatically
launch a replacement run. After reconnect, a full snapshot establishes the
current frame before accepting incremental updates. Application checkpoints and
thread replay restore domain state; terminal snapshots only restore pixels.

A native PTY has one geometry and one active input/resize controller. A second
client observes it with clipping or letterboxing unless control is explicitly
transferred. Independent resizable views require application support; they cannot
be simulated by having two clients race to resize the same PTY. Control grants
need a revocable generation checked by the owner so stale input cannot survive a
handoff. Runtime capability semantics must be verified before implementing this.

## Storage and profiles

Add workspace identity through a new immutable migration, preserving existing
desktop and application records. Separate client layout from workspace domain
state when adding multiple clients; existing desktop state becomes the initial
local client's projection. Copying a database for a backup retains identity;
creating an independent workspace from it needs an explicit fork operation with
a new identity. Two writable clones must not silently claim one workspace.

Keep SQLite owned and local initially. A workspace spanning nodes still needs an
explicit authoritative service for each resource. Do not share the SQLite file
over a network filesystem or infer replication from mesh connectivity. Future
replication needs its own consistency contract, recovery and conflict behavior.
Application source revisions and activation intent can be published separately;
process-local overlay handles and live Lua stacks cannot be replicated as state.

Local is the default profile, with no cluster discovery, gossip or join traffic.
An explicitly selected Hive profile will configure trusted peers and attachment
policy. A client need not become a voting node. `bee codex` can eventually launch
an admitted application in the selected workspace and attach its view, but driver
integration and the profile CLI are separate, unimplemented slices.

## Verified runtime boundary

Inspected the runtime commit pinned by `runtime/lock.json`,
`055505effbb0816ee833fb85c817d2954f6a0ccc`, rather than a dirty development tree:

- `system/tty/service.go` creates virtual viewports from actor context without a
  physical terminal host. The producer/broker can therefore be headless; Bee's
  current workspace bootstrap still requires its physical TTY.
- `system/tty/mount.go` binds mounts to an exact recipient PID, independently
  scoped observe/input/resize rights and a lease. Closing a recipient attachment
  removes that mount; it does not by itself close the producer. A replacement
  client process needs a fresh grant.
- `system/tty/README.md` specifies 128 issued mounts per broker and 128 remote
  views/pending RPCs per runtime, a 512 KiB frame limit, 30-second leases and
  10-second idle renewals. These are limits, not evidence of a 100-node Bee test.
- The runtime explicitly requires asynchronous remote input with bounded queues.
  Bee's current presenter calls `attached.view:send` synchronously. A remote
  attachment driver must isolate RPC waits from local input/exit before Hive can
  be shipped. Queue overflow and uncertain input delivery must be visible; no
  blind retry of keystrokes or mouse actions.

These primitives support the design, but do not prove discovery, controller
handoff, workspace authorization or two-client Bee behavior. Those remain Bee
integration/acceptance work. Mesh connectivity does not replicate SQLite state.

## Implementation sequence and acceptance

### Headless nodes and composed applications

A Bee node may be headless. The intended headless profile starts the workspace's
authorized services and background workers without a physical terminal host,
presenter, input loop or default UI processes. A desktop is an optional client;
its disconnection must not stop independently owned runs. This profile is not
implemented by today's terminal-dependent launcher.

An application can compose several modules and standalone workers behind native
contracts. Keep its definition, execution placement, durable run state and views
separate. Remote calls require explicit resource authorization and report unknown
outcomes during connection loss; replaying history must not rerun side effects.
An application's own run owner coordinates dependencies and cancellation, rather
than adding a workflow engine to the desktop. A headless worker need not publish
a TTY view: it may expose only authorized operations and durable progress events.

Acceptance for that profile must boot without a TTY, finish a run without any
client, attach a desktop later and replay results, then detach while work
continues. Local mode must still create no mesh traffic. Export to a future
hosted service should carry versioned definitions, resource references and
checkpoints; local credentials, live PIDs and terminal grants are not exportable
authority. Hosted execution and billing are outside this foundation.

1. Finish the local run/view separation using the test-status application. A
   closed view must not cancel its run; reopening replays committed events.
2. Persist workspace identity and carry it through launch, snapshot, checkpoint
   and UI values. Test restore, rename, invalid identities and mismatched replies.
3. Introduce explicit client layout ownership and local attachment lifecycle.
   Test independent layouts and denied/stale control changes before networking.
4. Bind the same contract to verified runtime mesh capabilities behind the Hive
   profile. Test two actual runtimes, distinct workspace tabs, recipient denial,
   controller handoff, disconnect/reconnect and owner failure. Confirm local mode
   starts without cluster traffic.

Remote tab composition is not proved by a runtime mesh unit test alone. Completion
requires the two-Bee acceptance path, with work remaining at its owner during
client loss and workspace identity visible throughout. Live migration, automatic
failover of arbitrary native processes, shared writable workspace replication
and a 100-node deployment remain outside this local foundation milestone.

A future standalone Cluster application under **Start → Tools → Cluster** can expose node health, connectivity and
workspace placement through native runtime contracts. Authorized controls belong
to that application/subsystem, not the desktop presenter. Installing or opening
its UI must not silently enable cluster mode in the local profile.
