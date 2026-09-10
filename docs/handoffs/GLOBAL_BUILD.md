# Global Bee candidate — September 10, 2026

The installed global executable is a tested development candidate built from the
frozen source at `/tmp/bee-global-final-crjl7na9`. Runtime and Bee changes remain
on branches; no PR or main merge was performed.

- Runtime: `674b58a1a1`, `integration/bee-launch-selection-20260910`.
- Native Bee: `1abf5b28a0e5`, `checkpoint/native-client-binding-20260910`.
- Builder: `70acb10175fbeb42a3a4d382677715a0c2a969e4`.
- Installed executable: `/home/wolfy-j/.local/bin/bee`.
- SHA256: `285a51bf448f212cdfc67e8eea51b6a9a296da8d5ab221f3e3f2562b289bcb0a`.
- Rollback: `/home/wolfy-j/.local/bin/bee.rollback-20260910T145306Z`.

Run `bee` normally. Its foreground client automatically starts or authenticates
an owner for the selected state. Ctrl+Q and Ctrl+] detach locally, retaining
applications. An already running older executable must exit before the upgraded
owner can take its state lock. This does not hot-replace a running owner.

Ordinary app launches use the executable's embedded code and the selected state's
shared registry history. Explicit `--base` remains a separate recovery mode.
[Runtime PR 726](https://github.com/wippyai/runtime/pull/726), stacked on PR 703
and assigned to Rodrigo (`skhaz`), adds that host-selected deployment policy.
Other combined runtime slices retain their existing upstream PRs.

## Evidence

`/tmp/bee-final-binary-acceptance.log` passes all three actual-executable targets:

- `native-client-check`: cold owner/client, exact clipboard copy, local quit,
  retained shell after reconnect, F12, and no clipboard replay. Fixture cleanup
  uses a PID handle to stop only its own retained owner.
- `native-binary-check`: explicit app launches, Settings recovery, clipboard,
  discrete wheel and burst scrolling, fullscreen aliases and literal arguments.
- `native-upgrade-check`: upgrade from the Sep 8 executable without `--base`,
  fresh app catalog, retained Ocean theme/workspace identity and unchanged applied
  migrations.

Native mesh/physical race tests pass. Runtime application, terminal/proxy/TTY and
Lua module race tests pass. The history/changed-baseline tests pass, including the
SQLite-backed authored-entry preservation proof in
`TestDependencyHandler_DeploymentRootSelfUpdateRepairsStoredResolution`.

The final frozen `make check` failed at `tests/drag_failure.py`: its initial
four-second wait saw a blank desktop. An isolated diagnostic passed; the
full-suite failure remains unresolved. Evidence: `/tmp/bee-final-full-check.log`.
Public external Hive enrollment, independent observer selection, and consuming a
released runtime main revision remain outstanding.

Reproduce the build using the candidate's pinned `wippy.build.json` and Makefile:

```sh
make native-tools
make standalone
make native-client-check native-binary-check
make native-upgrade-check PREVIOUS_BEE=/path/to/pre-Hive-Manager/bee
make check WIPPY="$PWD/.wippy/bin/bee-wippy"
```

## Reported attachment failure

The installed candidate has a user report of mount retirement followed by a slow
detach. A private copy of the user databases passes both launch modes, five
large-terminal reconnects, and normal exits under one second. Stalling a fixture
owner reproduces a 3.9-second Ctrl+Q exit. Native candidate `08a5761b809d` limits
explicit detach acknowledgment to 200 ms and preserves uncertain outcomes; the rebuilt global executable passes
`native-client-check`, including stalled-owner exit within two seconds, terminal
restoration, preserved uncertainty, and retained owner. Session race tests and
vet pass. Evidence: `/tmp/bee-detach-fixed-acceptance.log`. Unexpected mount retirement and
immediate reconnect after abrupt client death remain under investigation.

## Warm launch and crash reproduction

Native `08a5761b809d` uses the runtime's existing application-state lock for
routing: busy means direct authenticated attachment; a free probe releases the
lock before the existing cold-owner contender path. No new election or lock is
introduced. Warm startup creates no child contender or owner log. The installed
binary reaches the retained desktop in 0.204 seconds in the disposable acceptance
fixture; that is not a timing guarantee for an unhealthy owner. Client-launch
race/vet and the actual native-client checks pass, including the stalled-owner
exit regression. Evidence: `/tmp/bee-warm-fixed-acceptance.log`.

Abrupt-client-death acceptance is still failing: controller-busy refusals persist
for about twenty seconds, then the retained owner's readiness requests time out
around the mount lease boundary. A test-owner stack dump shows idle mesh workers,
not a confirmed mutex deadlock. The user owner was not stopped. Cold-start logs
still exist; their reporting and lifecycle remain under review.

The native monitor gate was rerun against runtime `674b58a1a1`: registration and a
later FIFO message succeed, but no EXIT arrives after the target actor finishes
with its transport still alive. `make -C native mesh-monitor-check` fails at
`monitor_gate_test.go:77`. This is current evidence, not a historical blocker;
the runtime lane handoff is Bee Harness seq698. No Bee polling workaround is
being substituted for native process observation.

## Preparing-owner race correction

The installed native revision is now `1abf5b28a0e5`. When a second launch sees the
runtime state lock before discovery exists, it waits for publication (up to15s,
cancellable), then authenticates normally. It writes no owner state and never
treats the lock or descriptor as admission. The previous binary failed this
window with a missing `mesh-owner.json` error. Actual standalone acceptance now
holds the runtime lock, starts a waiting client, releases the lock, starts the
owner, and proves the original client reaches the desktop and detaches while
retaining the owner. Normal warm readiness measured0.208s. Session and launcher
race/vet pass. Evidence: `/tmp/bee-publication-fixed-acceptance.log` and
`/tmp/bee-preparing-owner-before.log`. The remote EXIT and full-suite gates above
are still open.


### Link-down handling installed

The global executable now includes the Bee-only link-loss fix in the Hive and
retained desktop supervisors. Both use the existing `trap_links` process option
and revoke disconnected physical attachments without claiming process completion.
No runtime changes were made. `/tmp/bee-linkdown-native-acceptance.log` passes
normal client acceptance (warm reconnect 0.213 seconds), stalled detach, delayed
owner publication, and client SIGKILL followed by same-shell reconnect after a
40-second native node-departure observation interval. The isolated supervisor
trace also rejects failed service states and passes race/vet.

This replaces the earlier crash-induced supervisor restart failure for new owners.
It does not hot-replace the user's running owner, and does not prove immediate
exact-actor EXIT with a live transport. Full foundation verification is running
in `/tmp/bee-linkdown-foundation-check.log`; the earlier intermittent initial-frame
failure is not yet cleared. Cold startup still creates an owner output log.
