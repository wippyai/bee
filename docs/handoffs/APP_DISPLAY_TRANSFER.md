# Send app to display — implementation proposal

This is not a callable API. The desktop-transfer control is not implemented.

## Existing foundation

Retained local displays share one workspace host and app broker. Each display
has an independent client/layout. The broker owns the app process and its
qualified `(workspace_id, view_id, instance_id)` identity. Its exact-view bind
already revokes the old controller mount and grants the same viewport to a new
renderer. It does not respawn the app. Host admission currently restricts an
ordinary bind to the requesting client's current renderer.

## Required owner decision

A transfer belongs to the existing workspace authority. It must validate the
source display's current controller, the exact app identity, the destination
client's admission/control permission and current renderer generation. Durable
display IDs select a target; labels and raw PIDs do not grant authority.

The host must reject source or unrelated rebinds while a transfer is unresolved.
Moving the mount and then asking the source to remove its tab is insufficient:
if that save fails, source reconnect loads its old tab and can reclaim control.
The workspace commits the target assignment before completing the transfer.
Client layout saves acknowledge presentation convergence; they do not decide
ownership. A timeout retains the same operation identity and reports uncertainty;
it must not launch another app.

Persist the intent and assignment revision in the workspace-owned store. The host
must reconcile interrupted intents before issuing control grants after restart.
Persist neither mount tokens nor execution PIDs. The assignment remains the
control fence even when a client reconnects with an older saved layout.

## Failure and acceptance

Revocation failure retains the source grant. Successful revocation followed by
a failed target mount leaves an unattached live app and a reconcilable transfer;
do not silently reverse the transfer or respawn the app. Target disconnection,
renderer replacement, duplicate request IDs and conflicting retries must be
fenced by exact identity and revision.

A two-display terminal proof must preserve the process PID and an in-memory
shell variable, move input authority exactly once, remove the source tab, keep
unrelated displays working, and exercise both layout-save failure boundaries.
It must also restart the source client with stale saved state and prove it cannot
reclaim the target's app. Workspace-host restart needs a separate persistence
proof if included in the implemented contract.

## Source review: one durable assignment authority

The implementation should not require a transaction spanning two client layout
stores. A workspace-owned assignment is the decision; layouts project that
assignment. Their save acknowledgments prove presentation convergence, not the
right to regain application control. This refines the earlier requirement above:
keep the assignment fence after layout acknowledgment rather than deleting it.
Otherwise a sufficiently old layout backup could still reclaim the app.

The inspected admission boundary currently has no durable display identity:
`bee.host:protocol` carries only recipient, connection, renderer and permissions.
The retained supervisor already knows the display ID. Its authenticated `admit`
operation must bind that ID to the exact client execution before assignment can
be checked. A display ID supplied by an ordinary app request cannot establish
this relationship. Renderer replacement preserves it; a new admission must be
checked again. Multiple physical observers of a retained display do not create
additional workspace assignments.

The concrete integration points are:

- `src/core/host/protocol.lua` and `clients.lua`: supervisor-selected display
  admission, assignment checks before every controlling bind, and transfer
  requests authorized against both current assignment and target admission.
- `src/core/storage/store.lua` and workspace persistence: an appended checked
  migration and owner-only assignment/retry records. Save stable workspace,
  view, instance and display identities plus revision; never execution PIDs or
  native mounts. The existing host checkpoint writer must preserve this state.
- `src/core/applications/broker.lua` and `attachment.lua`: reuse the existing
  exact-view `bind` with both view and instance IDs and an empty recipient as
  the revocation barrier. It removes only that controller and returns a final
  `bind` reply. A later exact-view bind grants the destination renderer. Do not
  use recipient-wide `unbind`, which also removes unrelated views.
- `src/core/client/main.lua`, state and session: reconcile incoming assignment
  revisions before using saved targets. Keep geometry as client state. Source
  removal and target insertion are repeatable projections of the committed
  assignment, not independent authorization decisions.

Persist a bounded transfer intent with the source assignment revision and exact
request fingerprint before revocation. While it is pending, fence controlling
binds for that app and settle previously queued broker work before the revoke
barrier. A rejected revocation leaves the source grant and assignment intact;
no target mount may be issued. After successful revocation, commit the target
assignment and revision before granting its current renderer. A commit failure
leaves the live app unattached and the durable intent available for reconciliation.
A target-mount failure leaves the committed target assignment in place and
reports the view as unavailable; it never silently grants the source again.

On host restart, reconcile durable intents before allowing controlling binds.
Only applications whose checkpoint contract supports restart can be recreated;
a Terminal's live process is not recoverable across host death. The transfer
proof preserves the existing live Terminal only across display/client changes.
Assignment rows for dead, nonrecoverable app identities require explicit bounded
cleanup without affecting the stored retry outcome or another app incarnation.

## Implemented storage slice

The workspace store now owns a bounded (16 live identities) assignment table
and a durable transfer-receipt ledger. Its internal
`bee.storage:assignments` helper accepts only an already-selected workspace
store; it does not open a database resource and is not a callable application
transfer API. A row is keyed by `(view_id, instance_id)` and records the stable
display ID and revision. `prepare` persists an exact request/source/target/
revision intent before revocation, `commit` atomically changes the assignment
and receipt after the caller confirms revocation, and `fail` preserves the
source assignment while recording the result. A prepared receipt remains
visible through restart and `get`, fencing stale layout projections.
`reconcile` reads at most the 16 live assignments and their prepared fences for
host startup; it does not enumerate the durable receipt history. Exact dead
identities may be retired only once their prepared intent is settled, leaving
their receipt outcome intact.

Host integration remains required: it must authenticate display admission,
invoke the existing exact `(id, instance_id)` empty-recipient bind as the
internal revoke barrier, then commit before the target bind. No mount, PID,
renderer, or client connection value is stored here.

These are implementation requirements, not implemented APIs or completed proofs.

## Existing revocation proof verified September 11

`tests/fixtures/attachments/terminal.lua` already covers the required primitive:
a wrong instance does not revoke the live controller; exact empty-recipient
bind denies the old input grant while a neighboring Terminal continues to
respond; rebind retains the original shell PID and in-memory variable. The
fixture also separately verifies recipient-wide detach and another recipient's
unaffected app. `tests/lifecycle.py::detached` runs it on source and pack; this
stage passed in foundation session72192. No new broker operation or runtime
change is required for this barrier. This primitive alone does not implement
transfer authorization, durable assignment or layout reconciliation.

## Layout reconciliation seam

The existing client `observe` path deliberately updates only already-selected
tabs; catalog discovery never selects a new view. Preserve that rule. A transfer
must deliver a separate, typed assignment projection from the authenticated
workspace host, qualified by the current client connection and a monotonic
assignment revision. It may select a tab because it represents an owner decision,
not merely discovery metadata.

Reconciliation uses the exact workspace/view/instance identity: include an app
assigned to this admitted display even when its layout save was lost, and retire
its local tab when a newer assignment selects another display. Keep layout
geometry in the client store. The deterministic existing tab key makes repeated
projection idempotent. Combine assignment with the live inventory before creating
a view; neither a receipt for a dead app nor a stale projection may launch a new
application. Pending transfers do not become target grants before owner commit.

Renderer readiness may arrive before this projection. The host's authoritative
bind check must therefore fence stale source requests regardless of message
ordering; waiting for a client to acknowledge tab removal is not authorization.
On reconnect, reset projection state for the newly admitted host/connection and
reconcile before treating saved targets as current control rights. Failure to
save either layout is presentation debt under the durable owner assignment,
not a reason to reverse the ownership decision.

## Storage review and host integration

The assignment store remains an internal foundation under review. Retain durable
retry receipts; silently deleting an old receipt makes a previously conflicting
request eligible for execution again. Bound active assignments and each read,
not the lifetime number of completed transfers. Repeating the same initial claim
must preserve its revision, and a pending intent must prevent a claim from being
interpreted as permission to bind. Retiring an exact dead app assignment must
preserve its retry receipts and refuse unresolved intent removal.

Open assignment storage through the existing workspace persistence handle. Do
not open a second database connection in the client router. At host startup,
read the bounded active assignments and reconcile their prepared intents before
publishing readiness. Automatic checkpoint restoration and manually restorable
apps retain their exact stable identities; missing live inventory during startup
alone does not prove an assignment is dead.

Successful open replies must establish the initiating admitted display's initial
assignment before exposing that reply as usable control. Every subsequent
controlling bind checks that assignment and its pending intent, independently of
client tab state. Broker replies for transfer revocation must be correlated and
consumed before ordinary client routes; only the authenticated broker can settle
the persisted intent. A source disconnect after prepare cannot erase the intent.

## Checked request boundary

`bee.host:transfer` now provides an internal pure request decoder. The request
names a workspace, current connection and renderer generation, request ID, exact
view and instance, target display and expected assignment revision. It rejects
extra fields, including source-display claims, permissions and native handles.
The host must derive the source display from the authenticated admission.
No actor listens for this operation yet; this decoder does not make transfer
callable or grant any authority.
