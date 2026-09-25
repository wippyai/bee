# Process code handoff

Bee currently supports a same-PID code handoff for the desktop session. The
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
pending tab removal and initial fullscreen work and reports pending appearance
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

Live handoff for the retained owner, workspace host, desktop client, application
broker, Hive supervisors and module services is **proposed, not implemented**.
Those owners retain live resources and in-flight work that need their own
versioned checkpoints and coordinated fallback. In particular, a broker owns
native viewports and a client owns the physical terminal surface; their runtime
handles cannot be treated as serialized state or as authorization. The other
RSI design slices, including service reconciliation, rollback and native
cutover, are also proposals rather than callable operations.

The retained owner currently runs as a `terminal.host` command. The pinned
runtime delivers `OUTDATED` through `process.host` schedulers, so opting that
command into upgrades would not receive definition-change events. An owner
handoff first needs a supervised process boundary that receives invalidation
and can restart an incompatible checkpoint without dropping its desktops.
