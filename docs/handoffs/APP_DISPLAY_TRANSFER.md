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
The target layout must be committed and source removal durably acknowledged
before completing the transfer. A timeout retains the same operation identity
and reports uncertainty; it must not launch another app.

An in-memory host record can fence a physical-client restart while the same
workspace execution remains alive. It cannot settle an interrupted transfer
after workspace-host restart. If restart recovery is included, persist the
logical target/transfer revision in the workspace-owned store and reconcile the
client layouts against it. Persist neither mount tokens nor execution PIDs.
This decision must be completed before implementing target-first UI behavior.

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
