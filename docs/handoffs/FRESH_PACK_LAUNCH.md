# Fresh pack launch (temporary) and the stale global bee

Status 2026-09-09. The application source is current: Approvals, Timeline and
Hive Manager are in, Test Status is removed. The installed global `bee` is
not: `~/.local/bin/bee` was built on 2026-09-08 and embeds that day's pack, so
it still shows Test Status and no Hive Manager. This document names the
verified way to run the current application until the global binary can be
rebuilt, and why it cannot be rebuilt yet.

## Why the global bee cannot be rebuilt now

`make standalone` packs and validates the application source, and that
validation lints `bee.hive.supervisor:ingress`, which calls a `message:ingress`
runtime method that none of the available runtime binaries define
(`bee-wippy`, `-hive`, `-events`, `-host`, `-trust` all report the same three
errors). The build refuses. This is the supervisor lane's runtime cutover; it
is not worked around here, and the runtime pins, the supervisor ingress and
the monitor contracts are untouched. Installation follows a verified runtime
build; there is no automatic reinstall script.

## The verified temporary launch

`dist/bee.wapp` is the current application, packed with `pack` (which does
not lint). Run it on the pinned runtime:

```sh
~/wippy/bee/.wippy/bin/bee-wippy run ~/wippy/bee/dist/bee.wapp bee
```

Run it from any working directory; that directory receives the workspace
stores under `.wippy/`. This is the command `tests/fresh_pack.py` boots
verbatim in a disposable directory. It is distinct from the global `bee`
command, which is stale and should not be used to judge the current
application.

## What `tests/fresh_pack.py` verifies (`make fresh-pack-check`)

| Check | Result on the pinned runtime |
|---|---|
| The quoted command boots to the empty desktop and exits on Ctrl+Q | passes, exit under 0.1 s |
| Start → Tools lists Approvals, Timeline, Hive Manager, Process Manager, Settings | passes |
| Test Status is absent from the menu and the frame | passes |
| Terminal accepts input (`echo`), survives a resize to 120×40 and back, and F12 (presenter reload) with the shell still running | passes |
| Clean exit with a Terminal open (confirmed quit), exit 0 | passes |
| A Settings theme change (Honey → Ocean) persists across quit and relaunch | passes |

The check runs `run` on the pack and never `wippy lint`, so the pinned lint
failure does not block it; `make desktop-check` includes it. `make check` as a
whole remains blocked by that lint for everyone.

## Hive on this pack

The hive code is present (supervisor, telemetry, desktop bridge, thread
admission, principal mapping) and inert on one node: cross-node send and
cross-node approvals report `false`, no production hive service is activated,
and the supervisor's ingress path needs the runtime method above. A two-node
hive needs the runtime cutover plus enablement.

## When the cutover lands

Rebuild with `make standalone` and install `dist/bee` over `~/.local/bin/bee`
only after that build's own acceptance (`make native-binary-check`) passes.
