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

Ordinary local launch and retained displays use display-scoped appearance.
Fresh displays inherit the node defaults; an explicit Settings choice persists a
custom override. “Use node default” restores inheritance. Existing version-1
layouts upgrade to custom, preserving saved choices even when they equal the
old defaults. The mode is stored separately from the effective preferences.
Applications follow their controlling display; observers cannot recolour them.
See the [appearance contract](CLIENT_HOST_SPLIT.md#identity-and-appearance).
This source change is under acceptance and is not yet installed globally.

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
again and reconcile. Values are bounded to 2 MiB. State schema version 2 requires
`appearance_mode` (`inherit` or `custom`); version-1 reads upgrade to custom.
No applied SQL migration changes. Older readers reject version 2.

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
services. Ordinary `bee` now uses the installed native owner/client composition.
Public external enrollment remains separate from this same-account route.

`bee.client:desktops` holds virtual desktop resources inside a supervising actor.
The caller serializes access and selects an existing workspace host, exact client
database resource and child scope. `start` creates a virtual viewport and starts
`bee.client:main`; it does not create a workspace host or claim readiness. The
supervisor still authenticates child readiness and arranges host admission and
renderer selection. A second start against the same retained database/desktop identity is refused.
The reservation is local to this supervisor; it is not a distributed writer lock.
Store generation checks remain the persistence fence.

Only an observed desktop process exit releases that desktop's viewport and store
reservation through `exited`. A physical display exit does not match it. The
source/pack desktop fixture uses this component for all of its desktop actors,
including duplicate rejection, display replacement, desktop restart and resource
cleanup. The installed retained launcher uses this composition for the default
desktop; public creation and selection of additional desktops remain pending.

`bee.client:attachments` is a private supervisor helper for one retained virtual
desktop viewport. It reuses the existing native grant/revocation implementation,
permits one controller and up to 16 observers, and rejects a competing controller.
Changing a recipient's mode requires explicit detach first. Failed revocations
retain their records for retry. The caller owns the viewport lifetime and must
admit recipients before calling the helper; the helper is not a public admission
API. Neither its state nor its grants may be persisted or shared with apps.
The retained supervisor uses this helper for public local launch and observation;
the desktop fixture also checks it independently.

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
database. The current physical attachment path admits one controller and
explicit observers; `bee observe` opens a read-only view of the current local
desktop without another layout writer. Independent monitor
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

The native `hive/rendezvous` component publishes the running owner's
execution ID, node ID, literal-IP mesh endpoints and public key in a protected
discovery file. It reuses the native cluster listener. Reads create no state and
open no application databases; the owner publishes after cluster startup while
holding the application-state lock. A stale descriptor does not prove liveness
or permission. Client admission must authenticate the execution and obtain fresh
grants. Public `bee` selects this same-account native path; this does not establish
public external Hive enrollment.

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


### Durable desktop catalog

The private client store's `catalog(default_store)` returns typed
`{desktop_id, is_default}` values: the default identity first, followed by up to
32 allocated identities in stable ID order. One bounded query provides the
snapshot. It reads no saved layout bodies and reports no live readiness or
control availability. Those values must come from the supervising actor before
selection and admission.

Closed handles and handles opened for a selected desktop refuse catalog access;
the allocation/catalog entry point uses the default store under the host's
existing database policy. This library check is not an authorization grant.
Duplicate identities, an inconsistent default identity, and excess rows fail
without returning a partial catalog. No migration or permission change is needed.
`make client-storage-check` verifies source and pack, catalog recovery across
process restarts, capacity/corruption refusal and unchanged populated-v1 upgrade.
The public supervisor allocation/selection path remains unfinished.

The implemented function entries `bee.client:list_desktops` and
`bee.client:allocate_desktop` expose this storage boundary without passing a SQL
handle to their caller. Both accept `{version = 1, database_resource = ...}`;
allocation additionally requires a caller-retained `desktop_id`. They reject
unknown fields and non-client resource references. The caller must have
`bee.client.desktops.read` or `bee.client.desktops.allocate` for that exact
resource, respectively. Permission to call the function alone is insufficient.
The entry's host-selected database policy supplies the store access only during
the operation; the caller has no additional SQL authority afterwards.

Replies contain `code`, `message`, `desktop_id` and `desktops`. Codes are `OK`,
`INVALID_ARGUMENT`, `DENIED`, `UNAVAILABLE`, `CAPACITY` and `CONFLICT`. Listing
returns identities only; allocation returns its supplied identity and no catalog.
Repeating an allocation with the same identity is idempotent, including at
capacity. Allocating the default identity conflicts. An unavailable allocation
reply does not prove that the row is absent: keep the same identity on retry.
These methods neither start a desktop process nor admit a physical client.
No ordinary application receives these grants. The source retained supervisor now
receives exact grants for `bee:client_db`. The source Hive adapter now exposes
catalog and identity allocation; automatic launcher selection is still pending.

The source/pack acceptance calls the real function entries with authorized,
read-only and unauthorized scopes. It proves caller SQL denial before and after
calls, no schema creation on denied calls, durable retry across process restarts,
read-only allocation denial, resource fencing and strict request decoding.

### Supervisor storage requests (source; not installed)

The retained supervisor accepts `bee.retained.desktops` only from its authenticated
bootstrap owner after initial desktop readiness. Requests contain version 1,
workspace_id, request_id and op (`list` or `allocate`); allocation also requires
a caller-retained desktop_id. Unknown fields and other workspace identities are
rejected. Callers cannot select a database resource through this protocol.

The `bee.launch:desktop_storage` adapter calls the two protected function entries
asynchronously against `bee:client_db`. One request may be in flight; another
gets BUSY. The actor continues handling attachment and desktop events. Completion
is decoded into bounded identity-only values and returned through
`bee.retained.desktops_result` with the workspace and request IDs. Five seconds
without a result cancels the future and reports UNAVAILABLE with the supplied
allocation identity: the write may have committed, so an explicit retry must keep
that identity. Late responses cannot become a subsequent operation's result.
Supervisor shutdown cancels an outstanding future.

This reserves durable records only. It does not start another workspace host,
activate an additional desktop, transfer control, or enable a public create command.
The already installed global build predates this adapter. The focused
`make retained-desktop-check` exercises the real actor from source and pack,
including unauthorized senders, allocation replay/default conflict and slow storage
while the physical desktop remains usable.

### Additional retained activation (source; not installed)

After initial readiness, the bootstrap owner can send `bee.retained.activate`
with version 1, workspace_id, desktop_id and request_id. The identity must already
be allocated. `bee.launch:desktop_lifecycle` starts that client record on the
existing host, checks its actual readiness identity, admits it and binds its
renderer before replying on `bee.retained.activated`. An active identity is reused;
an activation or shutdown already in progress returns BUSY. Missing records fail
rather than allocating replacements. At most 32 additional actors are retained,
and reservations are released only on their actual EXIT.

Additional desktops have independent layouts and appearance, without legacy import.
They share the workspace's application owner. Activation itself opens no application;
launch requests are qualified by desktop and its current controller. Physical
attach/detach and copy select that desktop's grants. A recipient still attached to
another desktop keeps its monitor when one attachment ends. Additional F12 uses
its own host correlation and lifetime state. Save/exit of an additional desktop
preserves the host and applications; the default desktop's explicit workspace
shutdown remains unchanged. Reactivation reuses the durable record and can attach
to its still-running Terminal.

Source/pack normal and slow-storage retained-desktop probes pass: forged activation
is ignored, repeated activation reuses the identity, separate desktops run separate
Terminals, additional F12 replaces its presenter, save/reactivation retains its
live shell, and the first desktop remains usable. This does not yet expose public
creation, automatic selection on a controller conflict or Hive Manager control.
The source Hive-facing owner now publishes allocated identities and qualifies
its sessions by desktop, as described below. The native launch choice remains
the next integration boundary.

### Desktop interruption and concurrent presenter recovery (source)

An additional desktop EXIT retires its outstanding launch and copy requests.
A launch may already have committed at the host; its reply is UNCERTAIN, with the
original operation/idempotency identity preserved by the Hive adapter. The
supervisor clears the pending slot without replaying the launch. Copy retirement
returns no text and an explicit failure. Neither keeps another desktop's launch
or copy path busy. A fault fixture exits after an actual Terminal launch commits
but before its reply; a file written by that Terminal establishes the unknown
outcome is not equivalent to "nothing happened".

Renderer and quit events for additional desktops continue while the default
presenter's admission is pending. The default keeps at most its latest deferred
renderer and quit request. A pending quit dialog permits renderer replacement so
the user can still answer after F12. Accepted shutdown waits for an in-flight
renderer bind to settle before issuing save with a new request identity. The withheld-renderer probe
fails on the earlier supervisor, then passes with the additional presenter
replaced while the default waits and the default subsequently recovered by F12.
Normal source/pack launch-exit, copy-exit and withheld-renderer probes pass.
These changes are included in the September 10 independent-desktop global candidate.

### Hive desktop catalog and selected sessions

The native-client route now exposes `bee.desktop:list` and `bee.desktop:create`
through the same supervisor admission as attachment. List carries owner_execution
and returns workspaces with desktop_id/is_default records. These are durable
identities, not a claim that an actor or controller is live. The default is
explicit; native selection never depends on discovery order.

Create carries owner_execution, workspace_id and the caller's retained 32-hex
desktop_id. Its envelope idempotency_key must equal desktop_id. The underlying
allocation is durable and idempotent, so a new transport request can retry that
same identity after a lost reply. Create does not activate the desktop or grant a
mount. The Hive adapter owns one asynchronous catalog request at a time and
returns BUSY under contention. Late replies cannot retire a later request.
An unavailable or malformed allocation completion is UNCERTAIN; a failed list is
UNAVAILABLE. Neither retries or chooses a replacement identity.

A control attach to an additional identity activates its existing record on the
same workspace host before requesting a mount. Observe never activates a dormant
desktop. Each physical actor's session and pending cleanup retain its exact target;
attach, detach, launch, copy and replies cannot substitute the default desktop.
Changing desktop while a session exists requires detach first. A controller
collision is DESKTOP_CONTROLLED and retires the refused client's empty record immediately;
unknown admission/revocation outcomes retain cleanup responsibility.

`make hive-desktop-catalog-check` proves this route over two actual runtimes:
allocation replay, explicit default identity, dormant observer refusal, simultaneous
controllers on separate desktops, target-qualified launch/copy rejection, default
shell continuity during the other desktop's work, and explicit detach/reconnect.
It uses fixture-selected enrollment and native-client-role Lua actors, not the
public executable's automatic second-launch choice. The separate native executable
suite proves three simultaneous desktops, default observation, F12 and reusing
a detached desktop without another allocation. Native binding race/vet checks
cover Create identity/uncertainty and strict default catalog decoding. The separate
`hive-desktop-admission-check` still exposes the runtime's unresolved remote actor
EXIT cleanup failure; catalog acceptance does not waive that gate.


### Automatic physical desktop selection

An ordinary control launch first attempts the default desktop. Only an explicit
DESKTOP_CONTROLLED refusal permits trying other durable identities, in stable
order within the same workspace. If all are controlled, it allocates one new
identity and attaches there. Explicit selections and observers never allocate or
fall back. Catalog contention retries the same allocation identity; capacity is
LIMIT_EXCEEDED, and uncertain mutation outcomes stop without a replacement.

Cold node startup, supervisor readiness, attachment admission and native Hive
calls allow up to 60 seconds per bounded stage. Successful operations proceed
immediately; caller cancellation and the shorter detach bound still apply. These
are client-side ceilings. Destination operation limits still apply: the desktop
owner caps a dispatched request at 30 seconds and catalog/storage stages have
their own shorter bounds. These changes do not alter native membership failure
detection or prove automatic reconnect after established transport loss.

## Retained display lifetime correction (candidate, September 11)

After initial readiness, the default display joins the same lifecycle table as
all other retained displays. Closing or crashing that client retires its viewport
and writer reservation while the workspace host, broker and other displays stay
alive. Reopening the default selects its existing default-store identity; it does
not allocate a new display or replay the initial launch arguments. A pending copy
or launch receives an unavailable/uncertain outcome if its display exits.

The default display's in-desktop quit now saves and closes that display, matching
additional displays. It does not negotiate shutdown of every workspace app.
Physical-client detach remains separate and retains the display itself. The
nonretained development launcher still coordinates its own workspace shutdown.

The source/pack crash regression injects failure into the initial display during
a copy operation. The previous source loses the reply and workspace; the
candidate settles the reply, keeps the second display's in-memory shell state,
reactivates the same default identity and reattaches its original live shell.
The retained source/pack matrix passes normal operation, slow storage, launch
exit, delayed initial renderer, additional-display copy exit and initial-display
crash. The standalone build passes. Both assembled-binary suites pass and this correction is installed globally.
The full foundation check remains running; public Hive default-display
reactivation after display exit still needs its own admission proof.

Public admission follow-up (candidate): every fresh controlling attachment first
asks the retained supervisor to activate the selected durable display, including
the default. Existing active displays answer immediately through that same
operation. Observation never activates a stopped display. This removes the
assumption that the default can never stop. The executable regression closes the
default through Start → Exit, then invokes Bee again and requires the same shell
PID and in-memory variable. The prior executable returns `NOT_FOUND` on rejoin;
the corrected executable passes and is installed globally. Observation of the
stopped default refuses before a controlling attachment reactivates it.
