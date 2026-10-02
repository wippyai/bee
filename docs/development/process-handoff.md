# Process code handoff

Application process topics use `bee.app.*`. A topic rename requires one
deployment containing the SDK, broker and all senders and receivers, followed by
a full node owner restart from committed state. Selective process handoff does
not support mixing topic namespaces; saved applications recover with the current
protocol after restart.

Bee supports a same-PID code handoff for the desktop session. The
runtime delivers `OUTDATED` only after the session opts in. The session drains
accepted desktop commands and binding updates before calling `process.upgrade`
for its own definition. It passes a version-one checkpoint containing the
workspace identity, desktop projection, status revision, status bindings and a
bounded queued-command field. New code validates the checkpoint and its
workspace identity before publishing a scene and `bee.desktop.upgraded`
readiness. The PID and client relationship remain the same.

If the new session rejects the checkpoint or exits during upgrade, its client
spawns a replacement session from the last committed client layout. The client
keeps its presenter, host attachment and application executions. It replays
accepted tabs even when the view inventory has not arrived, pending tab
removal and initial fullscreen work, and reports pending appearance
requests as uncertain rather than silently retrying them. It reports
`bee.client.session_restarted` after the replacement publishes its first scene.
Recovery is bounded to two session replacements per client lifetime.

`make session-upgrade-check` changes the session definition while two desktops
and their shells are live, in both source and packed launches.
`make session-upgrade-fallback-check` makes the upgrade checkpoint incompatible
and verifies that the client reports replacement readiness while the shells
remain attached. `make session-fallback-check` exercises a session exit.
The session Lua tests check schema rejection, queued-command acknowledgements,
and same-PID readiness.

The desktop client checkpoints a version-one layout and requests an acknowledged
supervised replacement on `OUTDATED`. Its supervisor keeps the viewport and
physical attachments, starts a new client, admits the same display identity,
and announces readiness after the presenter renders. The replacement replays
accepted tabs from committed layout and receives a fresh terminal grant.
`make client-upgrade-check` and `make retained-client-upgrade-check` change the
client definition while two live shells remain attached in source and packed
launches. If the wire checkpoint is incompatible, the authenticated child is
still replaced from its last committed layout under the supervisor's retained
display identity. `make retained-client-fallback-check` checks that recovery.

The application broker drains checkpoint persistence and exits after its owner
acknowledges replacement. The workspace host starts a new broker and restores
automatic application records. Viewport grants belong to the old broker and
are reissued through the owner's existing admission path; manual executions
are not restarted automatically. `make broker-upgrade-check` checks automatic
Settings recovery and the retained desktop after a live definition change.
If a replacement broker cannot start, the retained supervisor restarts the
workspace host from its durable checkpoint and reattaches its desktops;
`make retained-broker-fallback-check` exercises that failure in source and
packed launches.

The workspace host drains client routes, open requests and broker work before
a same-PID `process.upgrade`. Its version-one checkpoint includes the broker
identity, catalog and view revisions, admitted clients, assignment revision and
questions. The new code validates the owner and workspace before announcing
`bee.host.upgraded`. If it rejects the checkpoint, the supervisor keeps its
viewports, starts a host from durable workspace state, restarts retained
clients and admits them again. The node host manager performs the same owner
acknowledgement and replacement for leased hosts while preserving leases.
`make host-upgrade-check` checks same-PID readiness with live shells;
`make retained-host-fallback-check` checks incompatible checkpoint recovery.
`make leased-host-upgrade-check` checks a live definition change through the
node host manager while a desktop lease and attachment remain held.
`make leased-host-fallback-check` checks an incompatible leased host checkpoint
and desktop reattachment under the same lease.

The retained owner command runs on `terminal.host`, which does not receive
`OUTDATED`. It keeps the route and workspace supervisor while a code-bearing
owner controller runs from the same `bee.launch:owner` definition on
`bee:workers`. Definition invalidation makes that
controller send a version-one route checkpoint, wait for command acknowledgement
and exit. The command starts the new definition and sends its current workspace
identity; an incompatible checkpoint falls back to a fresh controller while
the command, workspace host and desktop clients stay attached. The command
reobserves bridge readiness after controller replacement. `make
retained-owner-check` checks a live definition change and incompatible
checkpoint fallback in the source owner, plus packed owner startup.

Running applications follow admitted definition and imported Lua library changes
through the broker's execution replacement, using the last acknowledged
application checkpoint. Logical instance/view identities, windows/tabs and
terminal mounts survive. An incompatible schema restarts fresh with a persistent
one-line notice in the window. An unchanged definition is untouched. This is the
same replacement path used for application definition revision changes, not an
application `process.upgrade` handoff. Native PTY processes owned by a changed
application still follow that application's normal stop lifecycle; no native
session state is invented.

The standalone acceptance checks the live registry renderer and retained window
code marker using runtime PR #889 at `84c4b63d`. This proof runtime publishes
changed pack definitions before application replacement and verifies unchanged
owner PID; the repository runtime pin has not advanced in this change.

The desktop session and workspace host already use same-PID handoff; desktop
clients, application brokers and the owner controller already use acknowledged
supervised replacement. The terminal presenter changes through explicit F12.
Direct Registry changes to a `process.service` registration follow the runtime
supervisor's own stop/start lifecycle; direct code-only changes with equal
service configuration do not replace that controller. Hub transitions below
also restart code-only service updates.
Independent component `process.service` changes now use Hub durable receipt
intent, owner admission/drain and the runtime supervisor stop/start path. Hub
verifies exact process/handler definitions and the registry revision before
publication and owner boot-definition readiness before completion. Sessions is
the first production owner; unsupported service/process-host owners refuse the
change. Removal retains owned data and refuses while departing applications or
other processes remain alive. Existing broker closure revokes their grants and
resources. Crashes preserve the original operation for explicit recovery.

Bee does not add checkpoint handoff for running drivers,
managed agent sessions or the Hive supervisor here. Their running executions
retain code until their existing lifecycle replaces them. Later function calls
and newly spawned processes resolve the current registry definitions.

Hive supervisor handoff and generation rollback remain proposals. Native binary
cutover is available through the local `bee upgrade` commands: a person confirms the candidate digest, and `bee upgrade --rollback`
restarts the retained previous executable. No gateway operation exposes the
cutover. Viewport handles and registry metadata are never checkpoint authority
or permission grants.
