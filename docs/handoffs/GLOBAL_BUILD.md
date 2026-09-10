# Global Bee build — September 10, 2026

This page describes the current global executable and its verified capabilities.
[Earlier build history](GLOBAL_BUILD_HISTORY.md) preserves failed runs and older
measurements; those entries do not describe the current install.

The user has since reproduced a mount-expired/revoked failure on this installed
build, followed by a60-second read-only catalog timeout. A guarded restart
restored access; the cause remains unresolved. Journal909 records the actual
process stack and reproduction. Passing acceptance below does not prove sustained
reconnect reliability. The current retained process after recovery is2493278.

## Reconnect investigation

The opt-in `make native-reconnect-check` reproduced detach uncertainty twice
with three overlapping clients and retained Hive Manager. In one failure the
service still answered the following catalog request in 0.291s. A separate
30-round run passed, so this remains intermittent. Ten idle reconnects with
Hive Manager also passed.

A private 750 ms detach-budget candidate (`094d0c4416dd`, binary
`/tmp/bee-detach-budget-candidate`, SHA256
`deb6a3e888e04ba178aeb61577eaa47289e6f1581152ab6f06bf72ac3fb788db`)
passed native race/vet, client acceptance and standalone acceptance. Its longer
stress check failed at round 46: successful detach took 1.090s, exceeding the
one-second exit requirement; the subsequent catalog took 1.739s. It is **not
installed or selected for builds**. The native pin remains `ced4008999f4`.

A longer acknowledgment budget alone is insufficient. Diagnosis must distinguish
detach acknowledgment from native client shutdown. No cause or fix is established
for the separate actual-user expired mount and 60-second catalog stall.
Evidence: `/tmp/bee-detach-budget-reconnect-check.log`, fixture
`/tmp/bee-native-reconnect-i94l7w7b`.

## Installed

`/home/wolfy-j/.local/bin/bee` is the explicit-selection and Hive session-identity candidate:

| Component | Revision |
|---|---|
| Bee production source | `c3b2c9f` |
| Native Bee | `ced4008999f4` |
| Runtime | `674b58a1a117fa79398f723c4311201cca8472e1` |
| Builder | `70acb10175fbeb42a3a4d382677715a0c2a969e4` |
| Executable SHA256 | `cbb6d6a5bc71b5c37b281f2b3075122e990296c50830d641c8fa21939f389e59` |

The full foundation check passed (session61042, exit0): 494 Lua tests, 525
source/pack entries, storage, permissions, desktop/client lifetimes, recovery and
bundled applications. Evidence: `/tmp/bee-hive-session-identity-full-check.log`.
The existing `desktop_lifecycle` InterprocFacts convergence warning remains.

Plain `bee` loads embedded code with registry history and attaches through the
native mesh. A same-state lock conflict routes to authenticated attachment.
A second controller gets an independent retained desktop; an available desktop
is reused before another is allocated. `bee observe` explicitly shares the
default desktop read-only and refuses if no Bee is running.

Ctrl+Q and Ctrl+] detach the physical client and retain applications. F12 replaces
only the presenter. F9 or the workspace label opens compact Hive/node/workspace/
display status; Alt+F9 still minimizes. Named commands such as `bee terminal`
launch through the admitted workspace catalog. Native client-role metadata helps
Hive Manager distinguish clients from Bee services and grants no permissions.

Actual-user checks measured cold startup1.486s, warm control0.215s and
observe0.221s, with detach0.077–0.086s. These are individual measurements, not a
cold-start timing breakdown. The retained user process was2452472 after the
verified install; always revalidate the live process and executable before
restarting it. Logs: `/tmp/bee-explicit-selection-global-install.log` and
`/tmp/bee-explicit-selection-global-reconnect.log`.

## Explicit selection

The installed build artifact is `/tmp/bee-explicit-desktop-candidate`, from checkpoint
`checkpoint/explicit-desktop-selection-20260910`. Its production source is
`c3b2c9f`, native pin `ced4008999f4`, and runtime/builder are unchanged.
SHA256: `cbb6d6a5bc71b5c37b281f2b3075122e990296c50830d641c8fa21939f389e59`.
The previous executable is archived as `bee.previous-20260910T232822Z`.
Existing application databases were preserved.

It fences Hive Manager session presentation by node and owner generation and
adds authenticated commands against the running Bee selected by `--state-dir`:

```sh
bee desktops
bee attach WORKSPACE DISPLAY
bee observe WORKSPACE DISPLAY
```

Exact selection refuses occupied or foreign targets without allocating a
replacement. The executable passes explicit selection, the connection UI, three
independent desktops and the full native-client gate (74144, exit0), including
named commands, clipboard, stalled cancellation and client-crash reconnect.
Evidence: `/tmp/bee-explicit-desktop-client-check.log`.

The identical Lua source passed full `make check` (61042, exit0), and the
standalone binary gate passed (79123, exit0), including Settings recovery, native
Terminal, scrolling, selection/copy and source-free boot. Evidence:
`/tmp/bee-explicit-desktop-binary-check.log`.
The separate one-hour idle diagnostic50459 tests the previous installed candidate
in disposable state and remains pending.

## Remaining boundaries

Multiple neutral displays choosing and switching workspaces remains unfinished.
The current retained desktop client has one workspace host. Live Hive Manager
browsing/attachment, multi-host tab composition and public remote enrollment are
not implemented by the explicit local commands. See
[workspace attachments](../WORKSPACE_ATTACHMENTS.md).

The user's current reconnect failure is not explained by successful short
reconnect tests. New evidence: `/tmp/bee-user-failure-catalog-20260910.log` and
`/tmp/bee-user-stuck-owner-2452472.stack`. Runtime owner-isolation/session-loss completion recovery remains
a cluster-lane gate (journal894); no Bee monitor substitute is being added.
The candidate does not consume a released runtime main revision.

The initial Bee starts in its launching project directory; later same-state
clients do not change that directory. A binary update does not replace a running
Bee's loaded code. `--base` is a recovery choice, not required for embedded code.
Cold startup captures child output in private `owner-*.log` files; warm attachment
does not create an extra owner or log. Application databases are preserved.

## Rebuild and checks

Use the checkpoint's manifest and Makefile, keeping its pinned runtime:

```sh
make native-tools
make standalone
make native-client-check native-desktop-selection-check native-connection-ui-check
make native-binary-check
make check WIPPY="$PWD/.wippy/bin/bee-wippy"
```

Checkpoint branches are pushed for review. No Bee PR or main merge was made.
