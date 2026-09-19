# Workspace identity and client attachments

Status: attachment design, not a callable API. The primary store now persists an
opaque workspace ID through migration 2. Application launches carry it and the
app SDK exposes a logical view reference. Broker replies and desktop windows now
retain it too. Local application requests carry an explicit target checked by
the host and broker; missing or foreign targets are rejected. Public local launch
uses a separate workspace host and desktop client; independent-client fixtures
prove detach and reattachment to retained terminals. Mixed-workspace composition
and remote attachment remain proposals. [Workspace state](WORKSPACE_STATE.md) documents
the implemented envelope. This design leaves cluster transport and naming to the
runtime work; no remote discovery or network listener is enabled by it.

## Registry environment and portable application content

A workspace is a logical identity with an owning host, an application environment
and resource bindings. Its identity is not a database filename or the caller's
current directory. The registry owns definitions, configuration and registry
history. The workspace store owns supported app checkpoints and producer defaults;
each client owns its layout store, and the journal owns its events. Do not mirror registry definitions
into workspace tables and build a second registry reconciler there.

The planned portable export separates declarative content from execution state:

- Application definitions, pinned dependencies and explicit configuration form a
  versioned manifest using canonical registry/package representations. Selective
  export includes the dependency closure or names the external requirements.
- Supported overlay contributions retain their base revision, source and intended
  changes. Ephemeral overlay owner IDs and generations are local activation data,
  not portable authority. Export preserves authored content; destination admission
  decides whether and how to publish it through native registry operations.
- An application may separately export versioned saved state through its own
  contract. A checkpoint is not automatically a portable dataset: large stores,
  filesystem content and journal history need explicit owned export semantics.
- Credentials, live PIDs, TTY mounts, active database handles and source-machine
  policy grants are excluded. Resource references require destination bindings.

Import stages content, resolves dependencies, checks supported schema/runtime
requirements and presents conflicts and requested permissions before activation.
Retain definition IDs where possible; explicit conflicts must not silently replace
an unrelated installed application. Registry history records destination changes;
copying a source registry SQLite file is not the application transfer protocol.
Cross-store activation and application-data migration need recoverable receipts,
not an assumed transaction spanning unrelated owners.

The workspace catalog will reference the selected application environment and
its revision. Registry publication remains the authority boundary, whether its
input is a package, a reviewed file change or a supported overlay. This is a
design constraint for future transfer/self-edit work, not an implemented exporter.

## Workspace selection and Hive

The workspace subsystem owns durable identity, state and application membership
without requiring Hive. Hive provides authorized discovery and routing between
nodes. A future standalone Workspace Manager application presents local and
remote workspaces, their applications and optional node topology. A compact shell
switcher selects the target for new opens; existing tabs retain their original
workspace ownership. The client's layout can mix tabs from several workspaces.
Neither the manager nor a shell selection transfers ownership or authorization.
These UI and remote operations remain proposals until their contracts and
acceptance checks exist.

The default workflow supports several project hosts and several independent
client windows. A client is not permanently assigned to one node or workspace:
its picker changes the browsing target and destination for new opens, while
existing tabs retain their full owner references. It can retain admitted
attachments to several owners concurrently. Switching focus must not restart
applications, dispose another client's layout or implicitly close a connection.
Reuse a valid attachment when returning to an owner; expired or revoked
permissions require fresh admission. Show owner labels on mixed-host tabs and
distinguish an unreachable owner from an empty workspace. The current single-host
client composition must be extended to support this workflow; the fixture's
remote-client success does not prove multi-owner composition.

## Multiple displays and desktop extension

Proposal requested by the user: a client may attach as an independent desktop
or join an existing desktop as another named display. A display corresponds to
one terminal window; the operating system places it on a physical monitor.
Node, workspace, desktop group and display identities remain distinct.

A client may also organize several virtual displays inside one terminal window.
Neither physical nor virtual displays are assigned permanently to a node: each
can compose owner-qualified views from several nodes at once. A display may have
a preferred browsing/launch destination without restricting the origins of its
existing views. Moving a view between displays transfers presentation and input
control, not the application's execution or filesystem. Launching on another
node and any future execution migration are separate admitted operations.

Independent clients already have separate layout state. Extending one desktop
requires an explicit shared display group and an owner for window placement.
That owner coordinates moving a window between displays while its application
and native shell remain on their existing workspace host. Layout stores should
reference stable display identities, not a renderer PID or monitor coordinates.
Presenter replacement and reconnection must reacquire a fresh attachment.

A move must revoke the old input controller before granting the new controller;
an uncertain revocation cannot produce two controllers. Observation on several
displays is a separate permission from input. Display loss must retain the app
and offer an explicit move to an available display without silently stealing
control from a temporarily disconnected client. Shared display groups, handoff,
and their recovery UI are not implemented. The current remote fixture proves
independent-client attachment and shell retention, not an extended desktop.

Several clients viewing one application must share its producer and application
state. Native controller/observer mounts already provide the transport primitive;
the existing observation fixture covers updates and recipient-rights isolation.
Bee's broker currently publishes controller mounts only. Extend its owner-held
attachment records to admit bounded observers without replacing the controller.
The initial policy is many viewers with one input/resize controller. Observers
fit or clip the owner's viewport; they cannot repeatedly resize the shared PTY
to match their own windows. Prove independent observer revocation and continued
controller operation before exposing this in the client UI.

The input actor is a live routing endpoint, not the durable identity of the
person or agent controlling the application. Future admission must bind an
authenticated principal to the exact owner-qualified view, permitted operations
and a revocable attachment generation. The owner checks that binding; a saved
client ID, node display name or payload PID cannot establish it. Presenter
replacement changes the recipient and requires a fresh mount without changing
the application instance or the principal's identity. The richer principal and
delegation contract remains proposed; current mounts enforce exact recipient
and operation rights.

## Setup without repeated keys

Pairing is a proposed Bee convenience layer over native configuration. The pinned
runtime example (`boot/components/system/cluster.example.yaml`) provides seed
addresses, stable unique node names, membership secret configuration and server/
client roles. It does not establish the proposed one-time invitation protocol.
The current proposed commands and machine/node/workspace mapping are in
[Hive topology](HIVE_TOPOLOGY.md); none of its setup commands are implemented yet.

An explicit first setup should persist the selected profile, native node identity,
seed addresses and protected credential references. Subsequent `bee` launches
can reuse that choice without asking for a long key or profile flags. Fresh
installations remain local-only. Several clients on one computer should reuse
their selected local host; several actual nodes require separate identities,
ports and runtime-state directories. A workspace catalog reference selects the
workspace independently of those node boot settings.

A future invitation needs expiration, single-use redemption, authenticated
destination binding and revocation semantics. Nearby discovery only finds a
candidate. Membership credentials establish the transport boundary; application
placement and workspace access still require owner admission. Keep credentials
out of exported application definitions and ordinary registry metadata.

The 2026-09-07 local native mesh proof used a clean archive of runtime `055505ef`:
two runtimes, mutual TLS, one scheduler worker each and 20 cross-node PTY commands
per runtime passed. The same clean-build proof subsequently passed across two
authorized Linux hosts after a confirmed Go build cache was cleared on the second
host. Both peers connected over mutual TLS and completed 20 cross-host commands;
observed command-to-screen p95 was approximately 17–19 ms in that test environment.
Temporary identities and scratch files were isolated from existing cluster state.
This is a runtime primitive proof, not two Bee desktops or Hive discovery.

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

An infrastructure application may expose an authorized provisioning contract from
one workspace, for example a Proxmox service. Its host owns credentials and
resource limits. Other nodes discover its public operations, then authenticate
and request permission; membership alone does not grant provisioning authority.
A durable request/run identity correlates allocation results with the requesting
workflow. Provisioned machines enroll explicitly before exposing services to the
Hive. A retried request must resolve the original allocation or report an unknown
outcome instead of blindly creating another machine. This is an example consumer
of the proposed service boundary, not an implemented Proxmox integration.

Use a typed consumer library over native mesh actor messages and service
resolution, not an additional Bee network protocol. Authorization is checked at
the service owner; a library check alone is insufficient. A synchronized component
or overlay can supply the client contract and code on another node, allowing its
client process to run there. Definition availability does not transfer credentials,
database ownership, live grants or placement policy. Destination admission and
resource bindings still govern spawn and use. Cross-node definition activation
and client placement require acceptance before they become supported operations.

Components may also declare filesystem resources and local overlays intended for
sharing. Keep their definitions, immutable packaged files, writable working files
and materialized overlays distinct. Destination bindings resolve access to local,
mounted or synchronized filesystems; component availability alone is not a
filesystem grant. A component may own explicit file synchronization and its
conflict/retry contract. Syncing its overlay does not implicitly replicate every
writable file or database it uses.

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
owns tab ordering, placement, focus and desktop chrome appearance. Producer page
defaults and application appearance remain workspace/application-owned, so clients
with different desktop themes cannot race to recolor one shared viewport.
A client can show several
workspaces; several clients can show one workspace with independent layouts.
Closing a tab detaches a view. Stopping an application or cancelling a run is a
separate authorized operation. Existing view-owned apps retain close-to-stop
behavior until a supported independent lifetime is explicitly introduced.

## Visible workspace identity

Every tab, window and action target retains its workspace reference, including
minimized windows and restored layouts. In a single-workspace desktop, the
workspace label can be compact; mixed desktops display a short workspace label
alongside each application's title. A color is supplementary, never the only
identifier. Bee derives a deterministic friendly alias from each opaque workspace
or display ID for these presentation surfaces. Each alias includes a short
deterministic hash fragment of its complete source ID, so labels remain stable
when another workspace appears or disappears and are easier to distinguish when
IDs are shown together. A hash fragment is not a uniqueness guarantee; technical
mode includes the raw IDs for diagnostics. These aliases never enter requests,
keys, journals or authorization, and changing a label changes presentation only.

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

Workspace storage identity is implemented through immutable migration 2,
preserving existing desktop and application records. It appears in app launch
values, logical view references, broker replies and desktop windows. Live reply
consumers reject a missing or mismatched workspace identity. Separate client
layout from workspace domain state when adding multiple clients; existing desktop state becomes the initial
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

Inspected the runtime commit pinned by `wippy.build.json`,
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

The [client/host extraction plan](CLIENT_HOST_SPLIT.md) maps these requirements to
the current actor owners, appearance scopes, storage transition and local gates.

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
2. Storage, app-launch and window identity are implemented, with reply and
   checkpoint workspace checks. Local request targets are enforced at both receivers.
   Finish cross-workspace dispatch and labels.
   Test restore, rename, invalid identities and mismatched replies.
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

A future standalone **Hive Manager** under **Start → Tools → Hive Manager** exposes
reachable nodes, connection health and hosted workspaces through native contracts.
Bee remains the client entry point: selecting a remote workspace attaches it to
the current client, rather than requiring a separate SSH terminal or a second
desktop. The compact workspace switcher uses the same workspace catalog and
attachment operations; it does not own a separate connection implementation.
Local workspace management owns names and environment/resource references;
Hive Manager adds discovery and remote placement without becoming their owner.

The required operation sequence is discover, inspect authorized workspaces,
request attachment, receive a current projection, then open/focus the selected
application using its full workspace reference. Detach, reconnect, unavailable
hosts and explicit controller transfer need first-class outcomes. A timeout is
not evidence that a remote application failed to start. Retry uses the original
request identity and resolves its outcome before spawning again.

Authorized controls belong to the relevant subsystem, not the presenter.
Installing or opening the manager must not silently enable cluster mode in the
local profile. When Hive is disabled, show its disabled state and the explicit
profile requirement; do not fabricate nodes or connection status.

TTY-specific runtime gaps belong in the scoped viewport PR (#653); cluster
membership and Raft remain separately owned. Before requesting an extension,
check the actual PR revision and reproduce the missing behavior through native
contracts. Required end-to-end evidence remains two Bee runtimes with remote
input/resize, recipient denial, safe controller handoff, disconnect/reconnect
and tab identity preserved. Current local broker tests do not satisfy that gate.

### Neutral displays and qualified attachment state

Several clients on one machine are separate displays, each able to choose a
workspace. A display identity must not encode its machine, node or chosen
workspace. Changing that choice changes its attachments; it must not recreate
applications or transfer execution implicitly. The installed local independent
desktops are a foundation for this behavior, not completed workspace switching.

Hive Manager session presentation now records node and owner generation around
each workspace/display reference. Identical IDs on another node cannot inherit
"your session" or its control affordance. Owner replacement, removed catalog
items and evicted nodes retire the corresponding displayed session state; late
old-owner outcomes cannot restore it. This bookkeeping grants no permissions
and binds an attachment, not the neutral display's identity. Focused Lua tests
pass; this follow-up is installed globally.

### Explicit desktop selection candidate

The native ced4008999f4 candidate exposes `bee desktops`,
`bee attach WORKSPACE DISPLAY` and `bee observe WORKSPACE DISPLAY` against the
running Bee selected by the local state directory. Listing uses authenticated
supervisor admission and returns durable identities; it does not acquire control.
Exact attachment refuses an occupied or foreign target without allocating a
replacement. Missing Bee refuses without starting one. Plain `bee` keeps its
independent-desktop behavior.

Executable acceptance proves selected observation, occupied/foreign refusal,
unchanged catalog on refusal, exact retained-shell reattachment and continued
input on the other display. These commands are installed globally after full foundation and native acceptance.
They do not implement a live workspace picker, remote enrollment or composition
of applications from several hosts. Neutral physical displays remain independent
of their selected workspace; the command's DISPLAY identifies its attachment
target, not a permanent workspace binding for the physical client.

### Next implementation boundary: one display, several workspace attachments

This is a proposal, not an available switcher API. The current client still
requires one workspace at bootstrap. Keep that guard until all host messages and
operations below route through a qualified attachment.

| Identity | Owns | Changes when selecting another workspace? |
|---|---|---|
| Physical client execution | Terminal input, physical size and clipboard output | No; its runtime actor is replaced only on execution restart |
| Durable display | Layout, focused tab and presentation preferences | No |
| Workspace attachment | Selected workspace host, current admission and renderer generation | Yes |
| Application instance | Application process, content and owned resources | No; execution stays at its host |

The display's saved targets already include workspace, instance and view IDs.
They must not persist execution PIDs, mount grants or admission tokens. On rejoin,
the supervisor resolves and authorizes each target again. A node address is a
current route to an owner, not a replacement for durable workspace identity.

The client currently has one `host`, `connection_id`, `renderer_generation`,
catalog, view revision and question inbox in `core/client/main.lua`. Those values
must belong to each admitted workspace attachment. The display/session owns the
combined layout and focus. Incoming messages match the native sender, workspace,
connection and relevant generation before changing a tab, question or binding.
Outgoing input, close, bind and question answers select the attachment of their
specific target. Changing the focused workspace must not redirect an older reply
or callback. The launcher catalog for a new app must also name its selected
workspace explicitly.

Host loss retires only that host's live bindings and reports unavailable targets;
it cannot delete another workspace's tabs or invent application completion.
Presenter replacement keeps the display identity and rebinds each admitted host.
The physical client's clipboard stays local even for a remotely executed app.

Acceptance must exercise two hosts with colliding instance/view names, two
independent physical clients, workspace changes with delayed replies, one shared
application observed without respawning it, controller refusal, denied foreign
messages, F12 and client crash/rejoin. Check each application's original process
and retained shell state. A second local desktop or command-line selection alone
does not satisfy these checks. Live Hive Manager browsing additionally needs a
host-authorized catalog route; exposing the native client's control route to
ordinary applications is not an implementation of that read permission.

The full-height connection dropdown shows the friendly name and complete ID on
separate rows. Source/pack acceptance requires both workspace and display IDs to
fit without truncation and remain unchanged after F12. Compact-height rendering
keeps the shorter identity presentation. The naming changes are integrated with
the retained-display recovery candidate; global installation has passed both executable
acceptance suites. They do not implement workspace switching or app transfer.
