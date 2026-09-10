# Global Bee candidate — September 10, 2026

The installed global executable is a tested development candidate built from the
frozen source at `/tmp/bee-global-final-crjl7na9`. Runtime and Bee changes remain
on branches; no PR or main merge was performed.

- Runtime: `674b58a1a1`, `integration/bee-launch-selection-20260910`.
- Native Bee: `f02e10111c36`, `checkpoint/native-client-binding-20260910`.
- Builder: `70acb10175fbeb42a3a4d382677715a0c2a969e4`.
- Installed executable: `/home/wolfy-j/.local/bin/bee`.
- SHA256: `8be60049802226257b2f71c89b54a120598d1c259314418cd32b524891636dd9`.
- Rollback: `/home/wolfy-j/.local/bin/bee.rollback-20260910T135712Z`.

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
owner reproduces a 3.9-second Ctrl+Q exit. Native candidate `f02e10111c36` limits
explicit detach acknowledgment to 200 ms and preserves uncertain outcomes; the rebuilt global executable passes
`native-client-check`, including stalled-owner exit within two seconds, terminal
restoration, preserved uncertainty, and retained owner. Session race tests and
vet pass. Evidence: `/tmp/bee-detach-fixed-acceptance.log`. Unexpected mount retirement and
immediate reconnect after abrupt client death remain under investigation.
