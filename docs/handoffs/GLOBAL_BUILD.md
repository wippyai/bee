# Global Bee build — September 10, 2026

This page describes the current global executable and the next candidate.
[Earlier build history](GLOBAL_BUILD_HISTORY.md) preserves failed runs and older
measurements; those entries do not describe the current install.

## Installed

`/home/wolfy-j/.local/bin/bee` is the corrected Hive UI candidate:

| Component | Revision |
|---|---|
| Bee production source | `0b44b0f` |
| Native Bee | `5172d7dc2396` |
| Runtime | `674b58a1a117fa79398f723c4311201cca8472e1` |
| Builder | `70acb10175fbeb42a3a4d382677715a0c2a969e4` |
| Executable SHA256 | `440890d7fec500ccc16b799e73c9e166c35d023a8c27731ed55226d83a291951` |

The full foundation check passed (session46307, exit0): 493 Lua tests, 525
source/pack entries, storage, permissions, desktop/client lifetimes, recovery and
bundled applications. Evidence: `/tmp/bee-hive-safe-full-check.log`.
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

Actual-user checks measured cold startup4.027s, warm control0.217s and
observe0.240s, with detach0.105–0.141s. These are individual measurements, not a
cold-start timing breakdown. The retained user process was2197478 after the
verified install; always revalidate the live process and executable before
restarting it. Logs: `/tmp/bee-hive-safe-global-install.log` and
`/tmp/bee-hive-safe-global-reconnect.log`.

## Candidate awaiting the full foundation result

The next executable is `/tmp/bee-explicit-desktop-candidate`, from checkpoint
`checkpoint/explicit-desktop-selection-20260910`. Its production source is
`c3b2c9f`, native pin `ced4008999f4`, and runtime/builder are unchanged.
SHA256: `cbb6d6a5bc71b5c37b281f2b3075122e990296c50830d641c8fa21939f389e59`.
It is not installed globally.

It fences Hive Manager session presentation by node and owner generation and
adds authenticated commands against the running Bee selected by `--state-dir`:

```sh
bee desktops
bee attach WORKSPACE DISPLAY
bee observe WORKSPACE DISPLAY
```

Exact selection refuses occupied or foreign targets without allocating a
replacement. The candidate passes explicit selection, the connection UI, three
independent desktops and the full native-client gate (74144, exit0), including
named commands, clipboard, stalled cancellation and client-crash reconnect.
Evidence: `/tmp/bee-explicit-desktop-client-check.log`.

The identical Lua source is still in full `make check`, session61042:
`/tmp/bee-hive-session-identity-full-check.log`. Do not restart a live run merely
because it is quiet. The separate one-hour idle diagnostic50459 tests the
installed candidate in disposable state and remains pending.

## Remaining boundaries

Multiple neutral displays choosing and switching workspaces remains unfinished.
The current retained desktop client has one workspace host. Live Hive Manager
browsing/attachment, multi-host tab composition and public remote enrollment are
not implemented by the explicit local commands. See
[workspace attachments](../WORKSPACE_ATTACHMENTS.md).

The user's older idle connection failure is not explained by successful short
reconnect tests. Runtime owner-isolation/session-loss completion recovery remains
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
