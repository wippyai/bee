# Display reliability acceptance

The release outcome is prompt local/Hive join, independent physical displays,
applications retained across detach/crash, and accurate Hive/node/workspace/display
status. Bee consumes native mesh. Runtime changes belong to the runtime lane and
its PRs; there is no Bee ingress or remote-monitor substitute.

## Installed checkpoint

Application source `6b2da06`, native `2a2117ad4fe7`, runtime `674b58a1`.
Global SHA256 `723fb40b8c32ee277d8dcda8041e51499bb1c0adf3f0cf54c01115f75303802f`.
See [global build](GLOBAL_BUILD.md) for installation and backup evidence.

The 516 Lua cases, native-client and native-binary gates passed. Departure rows
retire after 60 seconds of absence in complete samples. Partial samples update
reported members without treating omitted members as absent; the presentation
cache remains bounded at 64 rows. Saved layouts and app processes are preserved.
The one-second detach acknowledgment allowance returns immediately on success.
The user accepts slower detach when needed to obtain a reliable acknowledgment.

## Unresolved attachment failure

The actual-user workspace stalled at Connecting for 25 seconds after the earlier
native update. A separate read-only catalog probe reached `Desktop.List` and
waited in `Client.Call` / `Actor.Receive`. It had progressed beyond discovery and
request send; this does not establish whether request handling or reply delivery
failed. The retained process stack showed a supervised service at retry attempt
511, but did not identify the service or establish causality.

Guarded restart restored access (1.433 seconds cold, 102–217 ms warm). After the
retirement install a further restart reached a frame in 1.428 seconds and detached
in 90 ms. Successful short runs do not establish sustained reliability.

Private diagnostic builds collect existing supervisor state events and scalar
catalog stage events. They do not change runtime semantics and are not global
releases. Current actual-state capture: `/tmp/bee-service-events-soak-20260911.log`.
The probe restores the installed global executable's service when it finishes.

## Reproduced restart failure

The direct event capture reproduced the stall after about 256 seconds. Service
`bee.hive:activation` first reported that its retained desktop process exited.
Subsequent starts failed repeatedly because its eventual name remained registered.
The ninth catalog probe then timed out. Evidence:
`/home/wolfy-j/.config/bee/owner-1402978003.log` and
`/tmp/bee-service-events-soak-20260911.log`.

The production `bee:hive_names_policy` omitted
`process.registry.unregister.eventual`, which the pinned runtime explicitly
requires. The native test fixture granted it. Source fix `6c6c574` adds the
missing permission, reports failed name release, and preserves the retained
process exit error instead of discarding it. Lint passed; policy regression and
recovery validation remain pending. This fix is not yet installed globally and
does not explain the initial retained-process exit.

## Remaining acceptance

A startup fix must account for the failed catalog exchange and pass simultaneous
independent displays, retained application identity, cancellation, and reconnect
without stale control grants. A 60-second node discovery allowance must not delay
an already available local join. Preserve saved layouts and application databases.

The full foundation check is additionally required; isolated Lua and native gates
do not stand in for all storage, permission, packaging and architecture proofs.
Multi-node recovery, display/workspace switching, and moving a running app's view
to another display remain separate uncompleted requirements. App transfer must
retain the process and enforce the workspace authority's admission and grant
revocation; attaching a viewport alone does not transfer application ownership.
