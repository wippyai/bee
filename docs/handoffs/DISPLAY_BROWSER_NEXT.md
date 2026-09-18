# Display browser implementation boundary

This is an implementation plan, not a shipped capability. Finish the current
global appearance install before changing its frozen production snapshot.

The F9 presenter in `src/core/terminal/connection.lua` consumes only the trusted
current connection. It must continue rendering cached values without networking.
The desired node/workspace/display picker needs a client-owned asynchronous
reader with bounded pending work, generation fencing and cancellation on detach.

The Hive Manager directory in `src/apps/hive/directory.lua` currently returns
`DESKTOPS_UNAVAILABLE` for all live desktop reads. Its fixture catalog is not a
live implementation. Native clients already use `bee.desktop:list`, but
`src/hive/desktop/owner.lua` admits explicitly configured native nodes; giving a
Lua application a function policy does not establish this admission.

First expose read-only desktop descriptions through the existing supervisor
route with explicit host-selected access. Reuse the durable catalog and current
controller/observer facts; do not add another catalog database. Include workspace,
display and node identity, plus the reporting incarnation. Keep visibility
separate from control/observe admission. A failed directory read is not empty.

Then supply the same typed directory values to Hive Manager and the client-owned
F9 reader. Add friendly labels over durable IDs, preserving full IDs in Details
and disambiguating duplicate labels. A label grants nothing. Remote rows cannot
be actionable until their real destination admission is available.

Sending an application to another display is a later mutation over the existing
attachment owner. It must preserve the application PID and workspace, fence the
old controller and delayed geometry/appearance updates, and expose uncertain
outcomes. It cannot be two unrelated unbind/bind UI calls or create two controllers.

Acceptance must include two physical clients, independent selections, denied
visibility/control, stale catalog replies, disconnect during transfer, unchanged
application identity and the destination's committed size and appearance.
