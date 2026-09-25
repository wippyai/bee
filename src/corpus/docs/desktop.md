# Desktop

Bee separates the workspace that runs applications from the desktop that
presents them. The workspace host can run without a physical terminal. A
desktop client can be replaced or detached while the host and its applications
continue to run.

## Owners and identities

| Identity | Owner | Meaning |
| --- | --- | --- |
| Node | Bee runtime and its membership boundary | The runtime that hosts services and workspaces. A node identity does not identify a workspace or grant access to one. |
| Workspace | Workspace host | A durable application environment. The host owns its identity, project bindings, application membership, broker, checkpoints and producer viewports. |
| Desktop | Desktop client store | A durable layout identity. It owns window placement, tab order, focus and client appearance. |
| Display attachment | Host admission and the current client execution | A transient physical presentation. It has a connection, renderer generation and recipient-bound mounts. These are recreated on reconnect. |
| Application target | Application host | A qualified `workspace_id`, `instance_id` and `view_id`. A client tab ID is only a local key for that target. |

A workspace ID is independent of a project folder, node address or database
filename. A desktop ID is independent of a terminal process or operating
system display. A PID, connection, mount or renderer value is an execution
address or capability, never a durable identity.

## Provider homes

A managed agent window that uses the host home runs the provider with the
operating-system user's `HOME` and the provider's own home variable,
`CODEX_HOME` for Codex and `CLAUDE_CONFIG_DIR` for Claude. Bee reads those
variables from the environment of the project's owner, which inherits the
environment of the `bee` invocation that started it. A later `bee` invocation
joins the running owner and does not change them: to use another provider home,
run `bee stop`, then start Bee with the new variable set. Sign in with the
provider's own CLI in that home before opening the window (for example
`codex login`); a window whose provider has no login shows the provider's own
sign-in screen.

## Composition

The local supervisor starts and owns one workspace host and one or more desktop
clients. It coordinates readiness, admission, renderer replacement, save and
shutdown. It does not become a second workspace or application owner.
Other logical workspaces of the node get their hosts from the node host
manager when a lease asks for them (see
[workspace catalog](../reference/workspace-catalog.md#live-hosts)); a desktop
shows one of them through the desktop bridge: `bee client` on a daemon picks
one, and a running display switches to another from its workspace menu (F9,
W). New workspaces come from the Workspaces viewer (Tools → Workspaces, N, or N
in the workspace menu) or `bee workspace create`.

The workspace host owns the workspace database and application authority. It
restores supported application checkpoints, routes application requests and
publishes revisioned catalog and live-view snapshots to admitted clients. The
host does not own client layout state.

The desktop client owns the physical terminal adapter, presenter, session and
client database. It asks the host to open and bind applications through the
host's admission path. It cannot read the workspace database or use a registry
record as authority. Settings changes and layout edits go through the client
session and host-approved appearance operations.

Terminal is a standalone application. Its native execution has the operating
system user's authority; a project binding or desktop permission does not make
it a sandbox. Application lifecycle and persistence rules are described in
[application contracts](../reference/applications.md).

## Admission and presentation

The host admits an exact client execution to a workspace and a desktop
identity. Admission supplies explicit open, close, control and appearance
permissions. A successful admission creates a fresh connection ID. The host
also supplies complete catalog and live-view snapshots with independent
revisions; clients authenticate the sender and reject stale revisions.

One desktop has at most one input and resize controller. It may have bounded
read-only observers. An observer receives a recipient-bound view and cannot
send input, resize the producer or change the layout. Replacing a controller
requires the old attachment to be detached; an uncertain revocation leaves the
desktop unavailable until it is resolved.

Every bind is checked against the current connection and renderer generation.
Stale generations and detached recipients are rejected. A presenter replacement
gets a new renderer generation and fresh mounts while the application instance,
workspace and desktop layout remain in place. F12 uses this same replacement
path.

Closing or losing a physical display revokes its attachment. It does not stop
the workspace host, application processes or retained desktop. `bee observe`
uses an observation attachment and never creates another layout writer. A
controller can detach after its final committed save; an explicit workspace
shutdown is a separate operation.

## Layout persistence

The client store is separate from the workspace database, registry history,
thread records and other subsystem stores. A layout contains the scene,
geometry, focus, tab order, appearance preferences and one qualified target for
each window. The current client limit is sixteen windows per desktop.

Client writes validate the complete state and compare the generation read by
the owning client process. A stale writer must read and reconcile before it can
write. The store has an append-only migration ledger with checksums; applied
migrations are never edited. Session acknowledgements carry the complete
projection, so the client commits accepted layout changes before reporting them
to the presenter. A graceful exit takes one final session snapshot. Pointer
motion, drawing and uncommitted drag previews do not write the database.

The first import from the former combined desktop is an atomic layout-and-
receipt operation. Retrying the same import returns its receipt and preserves
later edits. Import does not copy application checkpoints, registry definitions,
execution processes, mounts, credentials or permissions.

The workspace host stores application checkpoints separately. An application
owns the meaning of its opaque checkpoint state; the client layout never
pretends to checkpoint a shell, terminal job or conversation.

## Reconnect and recovery

Rejoining a retained desktop reads its last committed layout and resolves each
qualified target under current host admission. It creates a new client
execution, connection, renderer generation and mounts. It never restores a PID,
mount token, connection or permission grant from the layout store. An owner
that is unavailable is not thereby proven to have closed an application; only a
confirmed removal may retire a saved target.

The host can restore applications whose definitions declare a supported restart
policy and resume schema. It recreates their execution and capabilities, then
the client binds fresh views. A native Terminal process has no cold-resume
contract: a live presenter replacement preserves its PTY, but a dead shell is
not recreated at its former instruction.

## Current limits

- A desktop client presents one workspace at a time. On a node without a folder
  workspace (`bee daemon`) the client picks the workspace and switches through
  the picker (Ctrl+] returns to it). Mixed tabs from several workspaces or
  several owning nodes are not a supported client mode.
- Local retained desktops and authenticated attachment paths are available.
  Nodes of one host join one hive with `bee hive invite` and `bee hive join`
  (see the [Hive module](../../modules/hive/src/README.md)); explicit joins
  across machines require a host-selected address. Discovery, remote workspace
  composition and automatic cross-node desktop reconnect are not exposed as a
  single desktop workflow.
- A workspace has one writable host owner. Node loss does not create a writable
  clone or silently move the workspace to another node.
- Desktop layout has one writer. Multiple displays may observe a desktop, but
  concurrent layout editing and implicit controller transfer are not supported.
- The desktop store does not replicate workspace databases, application data,
  credentials, live processes or grants. Those require the owning subsystem's
  explicit transfer or synchronization contract.

See [storage](../reference/storage.md) for database ownership and migration rules, and the
[system map](../development/ownership.md) for the boundaries between the desktop, host,
applications and other Bee subsystems.
