# Client layout persistence

Status: source `bee` and `bee-app` now select the independent client and this
store. Source/pack migration acceptance proves import from the old combined
desktop, retained application identities and placement, unchanged workspace
migrations, F12, and preservation of later client edits on a second boot.
Full UI, failure-path and standalone acceptance pass. This establishes local
launch and attachment, not remote operation or automatic deployment replacement.
Trusted private client bootstrap can now supply a final version-1 options record
with `legacy_desktop`. It imports before client readiness and returns `import_receipt` in
`bee.client.ready` only after the client-store commit. Without an offer, that field
is empty. The source/pack desktop fixture retries the same offer after client exit
and verifies the receipt and later layout are retained.
The shared launch readiness decoder takes an explicit `require_import` boolean.
Local migration launch passes true; attachment without a legacy offer passes
false. Both require a valid durable client ID and matching workspace. A missing
or malformed receipt field is rejected in either mode; only the explicit empty
string represents no import.

The workspace host owns application membership, checkpoints and producer
appearance. A desktop client owns placement, tab order, focus, personal titles,
accents and chrome preferences. `bee.client:state` represents the latter using
the existing scene model plus one qualified target per window:

`{tab_id, workspace_id, instance_id, view_id}`

The local launch selects workspace appearance: its supervisor grants
host-owned preference writes, and bootstrap projects the fresh host preferences
over any stale client copy. Layout and targets remain client-owned. The two stores
do not share a transaction; the host value is authoritative for this local mode.
Ordinary attached clients retain independent chrome preferences. See the
[appearance contract](CLIENT_HOST_SPLIT.md#identity-and-appearance) for commit,
projection, failure and permission behavior.

Scene IDs are client tab keys. Every target must match its window's workspace
and instance identity. Equal view and instance IDs from different workspaces do
not collide. The current scene limit remains sixteen windows per desktop; this
does not constrain total workspaces or applications hosted elsewhere.

`import_desktop(workspace_id, legacy_desktop)` validates and copies the old
desktop, derives stable tab keys from each qualified target, and preserves
geometry, focus, order, modes and personalization. A foreign window is refused.
It imports no application checkpoint, registry definition, execution PID,
connection ID, policy, catalog or TTY mount. Decoders construct fresh values;
they do not persist unknown fields from incoming tables.

## Owned database

Every successful session acknowledgement carries a complete projection. The
client commits that projection before forwarding success to its presenter,
including ordinary layout changes. Scene notifications and acknowledgements use
separate topics and may arrive independently; neither ordering is required for
persistence. Older projections cannot replace a newer committed revision.
`make layout-ack-check` withholds the rename scene notification, verifies the
acknowledged label in the store and checks recovery after abrupt runtime exit.
This does not provide durable request deduplication across reconnects; that is
still required for the proposed desktop-owner protocol.

`bee.client:store` defaults to the host-supplied `bee:client_db` resource, separate
from `bee:workspace_db`, runtime registry history and the journal. Protected
bootstrap may instead supply `bee.client.db:<name>` to `open(resource)` for each
independent client. Names contain only letters, digits, underscores and hyphens;
the whole resource ID is bounded to 160 bytes. File paths, wildcards and workspace
database bindings are rejected before acquisition. Native `db.get` still requires
an exact host-selected resource grant; a valid name grants nothing. Normal local
boot declares `bee:client_db` at `${env:bee:workspace_db_path}.client`, alongside
the selected workspace database. Public command arguments never select a database
resource. Fixtures may supply isolated bindings. Merely disabling `auto_start` is insufficient: native SQLite resources
open their files during registry loading. The client-storage policy grants only
that default database; additional bindings require their own exact policy. The
ordinary application boundary denies both the default resource and all
`bee.client.db:*` and `bee.workspace.db:*` resources, including when an app has a
broader database grant. No current default app receives the
client-storage policy. Native processes still have OS-user file authority.

The private API is `open(resource?)`, `read(handle)`, `write(handle, state)`,
`import_legacy(handle, workspace_id, desktop)` and `close(handle)`. Handles and
their native database fields must remain inside the owning client process.
Each store has a stable random client identity. Reads validate the whole state;
writes compare the generation observed by that handle. A stale writer must read
again and reconcile. Values are bounded to 2 MiB and schema version 1.

The append-only migration ledger verifies its name and SQL checksum. Unknown,
changed or corrupt schemas fail closed. A missing identity after migration is
corruption, not a reason to generate another client. Migration 1 must remain
immutable once deployed; subsequent changes append migrations.

## Recoverable legacy import

The first import writes layout and a random receipt in one atomic SQLite update.
It can initialize only an untouched client store. It cannot replace a layout
the client has already created. Retrying the same workspace returns the original
receipt and does not reset later user edits. A different workspace cannot reuse
that first-import receipt. Adding ordinary tabs from another workspace will use
normal client layout writes, not repeat the legacy migration.

The remaining host/client migration protocol must:

1. Retain the workspace's legacy desktop while offering it to the first client.
2. Wait for the client's durable import receipt before acknowledging completion.
3. On interruption, replay the offer; the existing client receipt makes it safe.
4. Preserve the original workspace ID and application records throughout.

There is no cross-database transaction or durable host acknowledgement yet.
The private readiness receipt establishes only the client-side commit; the
supervisor must authenticate the sending client and match its workspace before
using it. The source desktop is retained, so interruption can safely retry the
same offer. No legacy workspace record is deleted or rewritten by client import.
The client store alone does not authorize attachment or restore a native process.
Standalone launch still needs a client-data binding when the new client actor is
integrated; `BEE_CLIENT_DB` is not currently a public workspace-selector command.

`make test` checks mixed-workspace and malformed target values. `make check`
also runs the source/pack Lua storage fixture, restart/retry, existing-layout
protection, failed import and migration rollback, stale writers, schema corruption
and native app database denial. These checks cover persistence. The separate
`client_desktop` fixture exercises two actual private desktop actors.
The storage fixture also selects two client and two workspace resources, writes
different state, restarts and verifies isolation in source and pack. Native
checks reject ungranted resources and broad-grant attempts to bypass the core
database boundary. Normal local launch selects the adjacent default client store;
the multi-client fixture supplies separate explicit bindings for each client.

`make client-desktop-check` also terminates a desktop client without a save/quit
handshake, then starts a fresh client against the same store. Source and pack
checks preserve its durable identity and application target and recover the
live shell variable. The other desktop continues operating. This proves abrupt
client-actor loss within the existing fixture; separate physical-process loss
and public named-desktop rejoin remain required.

## Node-owned desktops: next boundary

`bee.launch:retained` is a private supervisor composition for one workspace host
and its initial retained desktop. Trusted bootstrap context identifies its node
owner; this is not a public enrollment API. It creates the host once, starts the
desktop through `bee.client:desktops`, verifies the committed import receipt and
handles host admission and renderer replacement using the existing lifecycle.
The initial virtual display is 100 by 32 cells and uses the default client store.
Do not start this supervisor per physical display or for each desktop over an
already running host. General node-level workspace/store selection is still
required before public activation.

After initial renderer admission it sends `bee.retained.ready` to its bootstrap
owner. Only that authenticated sender may issue the version-1 private
`bee.retained.request` attach/detach messages, qualified by workspace and durable
desktop identity. The strict decoder rejects unknown fields and invalid modes.
Attachments are recipient-bound; a successful attach installs a process monitor.
Display EXIT revokes that recipient's attachment while preserving the desktop.
An explicit desktop quit still uses the existing guarded save/shutdown sequence.

The source/pack supervisor fixture proves startup/admission, forged-sender
denial, competing-controller denial, automatic display EXIT cleanup, explicit
detach/rejoin to the same shell and negotiated shutdown without failed runtime
services. Ordinary `bee` still uses its existing local launcher. No additional
listener, remote enrollment or physical-client runtime transport is enabled.

`bee.client:desktops` holds virtual desktop resources inside a supervising actor.
The caller serializes access and selects an existing workspace host, exact client
database resource and child scope. `start` creates a virtual viewport and starts
`bee.client:main`; it does not create a workspace host or claim readiness. The
supervisor still authenticates child readiness and arranges host admission and
renderer selection. A second start against a retained database binding is refused.
The reservation is local to this supervisor; it is not a distributed writer lock.
Store generation checks remain the persistence fence.

Only an observed desktop process exit releases that desktop's viewport and store
reservation through `exited`. A physical display exit does not match it. The
source/pack desktop fixture uses this component for all of its desktop actors,
including duplicate rejection, display replacement, desktop restart and resource
cleanup. The default local launcher has not yet adopted this composition.

`bee.client:attachments` is a private supervisor helper for one retained virtual
desktop viewport. It reuses the existing native grant/revocation implementation,
permits one controller and up to 16 observers, and rejects a competing controller.
Changing a recipient's mode requires explicit detach first. Failed revocations
retain their records for retry. The caller owns the viewport lifetime and must
admit recipients before calling the helper; the helper is not a public admission
API. Neither its state nor its grants may be persisted or shared with apps.
Default local launch does not yet use this helper; the desktop fixture exercises
it as preparation for retained supervisor composition.

The source/pack desktop fixture now also presents a retained virtual desktop
through a separate display actor using ordinary native viewport mounts. It
terminates that display actor, continues using the same desktop and shell, then
attaches a fresh display actor and verifies the shell state is retained. The
supervisor revokes the old recipient mount after observing display exit.
The fixture also closes a display normally, attaches a replacement and reads
the same shell variable. Its adapter consumes physical `close` locally instead
of forwarding it to the retained desktop. The regression fails with the old
forwarding behavior because that behavior terminates the desktop. Physical
detach and an explicit desktop shutdown must remain separate operations.
This proves a local composition option without a new transport or application
restart. The display surfaces are virtual and all actors share one runtime;
it is not an independent physical-process or remote reconnect acceptance test.

The requested public model is a named desktop retained by an owning Bee node.
A physical client attaches to that desktop; closing or losing the physical
client does not delete its layout or stop applications. This is the intended
extension of the existing client store, not a currently callable selection API.

Keep three identities separate:

| Identity | Lifetime and authority |
|---|---|
| Desktop | Durable layout identity on its owner node; a mutable name is a label. The existing store's `client_id` is the migration starting point. |
| Attachment | One authenticated physical-client connection; replacement requires fresh admission and grants. |
| Application target | Workspace, instance and view identity; execution remains with the application's owner, which may be another node. |

The desktop owner is the sole layout writer. Multiple physical presentations of
one desktop must share that owner, rather than open competing writers on its
database. The first implementation should admit one controlling attachment and
make any additional presentation explicitly observational. Independent monitor
layouts use separate desktops; presentation alone cannot take control or resize
another controller's application. Broader simultaneous editing requires its own
explicit concurrency contract.

The host permits admitted clients to select an observational renderer. A client
without control permission receives observe-only mounts even if its bind asks
for control. The broker tracks up to 16 observer recipients per application,
separately from its controller. Replacement and detach retain failed revocations
for retry. The presenter clips fresh producer frames to its own window; it never
resizes the application or sends input through an observer attachment.

Source/pack acceptance covers the actual desktop presenter, different display
sizes, F12, denied input, and controller continuity after observer loss. Public
shared-desktop selection and owner-authorized controller transfer remain pending;
a controlling bind is not evidence of user consent to displace another controller.

Rejoin loads the last committed layout and resolves its qualified targets under
current owner permissions. It never restores a saved PID, mount, connection or
grant. An unreachable application owner is distinct from a confirmed closed
application; loss of connectivity must not erase its saved tab. Physical-client
failure must not prevent already accepted layout changes from committing.
Node restart recovers committed layout and supported application checkpoints;
it does not resurrect a dead native Terminal process.

Desktop discovery and selection belong to Bee's admission service. A desktop
name, node advertisement or registry descriptor grants no read or control access.
Storage stays on the desktop's owner node; no centralized Hive database is
required. Runtime transport supplies authenticated attachment and lifecycle
events through the agreed mesh boundary, not a Bee-specific TLS side path.

Before public activation, prove abrupt physical-client loss and rejoin with
retained layout and the same live shell; fresh grants with stale-input denial;
two independent desktop layouts; denial of competing controllers and database
writers; owner restart with durable layout; and retention of unavailable remote
targets. Existing same-runtime fixtures cover parts of this, not public named
desktop selection or automatic client reconnect.

## Public launch selection: proposed default

The default under consideration is an independent desktop when another physical
client already controls the current desktop. This follows the multiple-monitor
model above; it is not implemented by the current single-desktop admission
fixture. Explicitly selecting an existing controlled desktop may offer observation,
but must never silently displace its controller or label an observer as interactive.

Transport attachment, desktop selection and creating a desktop are separate
steps. An ordinary second `bee` should reuse the running node through native
rendezvous, then resolve a desktop under destination-owned permissions. One
available retained desktop can be resumed directly. Multiple candidates need a
selector; no directory scan, node name or discovery order establishes ownership.
Creating another layout requires another durable desktop identity and one store
writer. It must not start a second writer against the existing client database
binding. The public allocation operation and its storage owner still need
implementation; `bee.desktop:list`, `attach` and `detach` do not provide creation.

Acceptance must exercise two concurrent physical clients with independent layouts,
retained applications after each display exits, explicit observation of an existing
desktop, denied competing control, and unambiguous restart selection. A single
physical client's successful detach/rejoin does not establish these guarantees.

## Native mesh rendezvous candidate

The unregistered native `hive/rendezvous` component publishes the running owner's
execution ID, node ID, literal-IP mesh endpoints and public key in a protected
discovery file. It reuses the native cluster listener. Reads create no state and
open no application databases; the owner publishes after cluster startup while
holding the application-state lock. A stale descriptor does not prove liveness
or permission. Client admission must authenticate the execution and obtain fresh
grants. Public `bee` does not select this component yet.

See [the native contract](../native/hive/rendezvous/README.md). The focused
Makefile check includes a live native stack, retained socket, owner exclusion,
strict decoding and atomic file publication; it does not prove public client
attachment or enrollment.

## Independent desktop records (source component)

Migration 2 adds `client_desktops` beside the existing singleton `client_state`.
Migration 1, the default desktop's identity, layout and legacy-import receipt stay
unchanged. Each additional desktop has an opaque identity, its own layout and a
compare-and-swap generation. Its identity is neither a node identity nor a physical
client actor. A shared SQL resource does not make the layouts interchangeable.

The trusted owner can call `bee.client:store.allocate(default_store, desktop_id)`
to reserve an empty record. The supplied identity must be 32 lowercase hexadecimal
characters and differ from the default identity. Identical allocation is idempotent.
There are at most 32 additional records; capacity never silently evicts a resumable
layout. Only a default store handle can allocate. This is an internal persistence
surface, not application or remote admission authority.

`store.open(database_resource, desktop_id)` opens an existing additional record;
missing identities fail rather than minting replacements. Omitting the identity
keeps the original default-store behavior. Reads, writes and generations address
only that record. Additional desktops cannot import the legacy default layout.
The calling supervisor must reserve one live writer per selected identity and
apply its normal permission checks before opening a record.

This component does not yet allocate or select additional desktops in public
launch. Client bootstrap now accepts the selected record identity, and the
retained-desktop helper reserves one writer per database/identity until actual
desktop EXIT. Source/pack acceptance runs two desktops over the same SQL resource,
including independent layouts, Settings, F12 and retained Terminal reattachment.
Public allocation, supervisor readiness and catalog publication remain required.
The global installed binary includes this migration and bootstrap support,
but its public launch still selects one retained desktop. Do not treat the
internal source/pack proof as an installed multiple-display selector.
