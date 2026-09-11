# Send app to display — implementation status

The local workspace host now owns the transfer decision.  It accepts a
connection-qualified request from an admitted controller, persists the exact
source/target/revision intent, revokes the source through the broker's exact
view bind, commits the target assignment, and leaves the target's ordinary
assignment-fenced bind to mount the existing app.  Completed receipts replay
their original outcome after later moves, detach, or retirement; a prepared
receipt fences both displays through restart. A startup-recovered manual checkpoint
keeps its prepared fence until an ordinary open restores that exact view and instance;
then the host commits its recovered receipt before the target's routed bind. A current
runtime prepared transfer cannot use that path and still waits for its broker revoke
reply. Checkpoint-absent assignments retire at startup after any prepared receipt is
settled, while checkpointed exact identities remain. The source/pack attachment proof
covers live Terminal PID and shell-state preservation, target admission denial,
stale source-bind denial, repeated moves, receipt replay, manual restore settlement,
and dead-assignment retirement.

This is not installed globally. Source and target layout-save failure/reconnect
checks pass on source and pack. Final combined gates and host recovery lifecycle
corrections remain pending.


## Ownership

The workspace host owns application assignment. A display owns its saved layout;
the broker owns the running app and its exact `(workspace_id, view_id,
instance_id)` identity. Supervisors bind a durable display ID to a client
execution during admission. A new admission cannot change the display identity
of an existing client or replace a display whose detach is still pending.
Renderer replacement preserves that identity.

Assignment is the control decision. Layout saves acknowledge presentation
convergence and cannot restore an old source's authority. Neither display labels,
PIDs in payloads, registry metadata nor saved tabs authorize a transfer.

## Durable decision and broker barrier

`bee.storage:assignments` is an internal library opened through the existing
workspace persistence handle. Migration 3 appends assignment and transfer-receipt
tables; migrations 1 and 2 are unchanged. Stable app/display identities and
revisions are persisted; execution PIDs and native mounts are not.

Initial claims are idempotent, reject a different display and refuse a prepared
transfer. Prepare persists the exact request fingerprint and source revision.
Commit atomically updates the destination assignment and receipt; fail retains
the source assignment. Exact retries return historical outcomes. Completed
receipts remain on disk; bounded indexed reads do not enumerate that history.
Retirement reclaims an exact dead app assignment, preserves its receipts and
refuses an unresolved intent. Active assignments and reconciliation reads are
bounded by the workspace's 16-app limit.

Transfer uses the broker's existing exact-view bind with an empty recipient:

```lua
{op = "bind", id = view_id, instance_id = instance_id, recipient = ""}
```

This is the revocation barrier for one app. Recipient-wide `unbind` would also
remove unrelated apps and must not be used here. The existing attachment fixture
proves wrong-instance refusal, exact revocation, unaffected neighboring Terminal,
and rebind of the same shell PID and variable, on source and pack.

The host must persist prepare before revocation, fence ordinary controlling
binds while pending, and commit the target assignment only after the final
successful broker reply. A failed commit after revocation retains the prepared
fence. A failed target mount leaves the committed destination assignment and an
unattached live app; it never silently regrants the source. Host startup must
reconcile prepared intents before control grants. Only checkpoint-capable apps
can restart after host death; transferring a live Terminal does not make its
process recoverable after workspace-host failure.

## Client and presenter boundaries

`bee.host:transfer.request` checks workspace, connection, renderer generation,
request ID, exact view/instance, target display and expected assignment revision.
The authenticated admission supplies the source display. Extra authority fields,
invalid identities and exhausted revisions are rejected.

The host's `bee.host.assignments` snapshot is qualified by workspace, connection,
display and a monotonic revision. It carries at most 16 assignments and 8 admitted
displays. Each assignment includes its exact app identity, owning display,
revision and pending flag. Each display reports current availability and control
permission. Host replies use `bee.host.transfer_result`; success means committed
destination assignment, independently of the target's subsequent native mount.

`bee.client:assignments` computes layout changes from that snapshot and live
inventory. Discovery alone never selects a new tab. A committed destination
assignment adds only the exact live app; an assignment elsewhere removes only
that app's source tab. Pending transfers, dead receipts and old incarnations
cannot launch apps. Geometry remains client state. The host independently checks
all controlling binds even if renderer readiness precedes the snapshot.

The client projects eligible destinations to the presenter on
`bee.display.transfers`. `bee.protocol:display_transfer` validates these bounded
menu values and the selected action/result. The window menu uses friendly labels,
keeps the clicked app's identity, and invalidates stale choices when the
projection changes. Its action goes to the client owner on `bee.workspace.control`.
The client rechecks the exact target, assignment revision and destination before
sending the host request; result delivery is fenced by the requesting renderer.
The presenter grants no authority.

## Evidence and remaining acceptance

Storage tests use real runtime SQLite handles and prove populated-store upgrade,
prepared restart, a trigger-induced receipt-commit failure that rolls back the
assignment update, successful retry, more than 64 retained receipts, conflicting
replay refusal and receipt preservation after retirement.

Admission has passing unit and source/pack attachment/client checks. Pure client
reconciliation and menu eligibility tests pass. The presenter lane's full unit
suite passed 528 tests. The combined client/UI unit run passed 529 tests. The real window-menu transfer
passed on source and pack: it preserved the shell PID and variable, kept the
neighbor working, reconciled both layouts, and passed source F12. The separate
host fixture also proves old input revocation, target rebind and committed retry
after destination detach. Injected source/target layout-save failures also preserve the committed transfer:
reconnecting the source removes its stale tab, and reconnecting the target adds
the missing tab with the same shell PID and variable. Both paths retain the
neighbor app. These modes run in `make client-desktop-check`. Host manual-restore
settlement and dead-assignment retirement after restart still require correction
and acceptance before global installation.

The combined proof must move a Terminal through the real window menu, preserve
its exact PID and in-memory variable, retain the neighboring app, reconcile both
saved layouts and survive source display reload. Host acceptance must also prove
forged/stale requests and invalid targets are refused; repeated and conflicting
keys do not duplicate revocation; old source layouts cannot reclaim control;
failed saves/mounts do not reverse assignment; and interrupted prepared transfers
settle correctly after restart. A test that merely loads the protocol is not
end-to-end transfer evidence.
