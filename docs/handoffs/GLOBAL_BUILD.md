# Global Bee build — September 11, 2026

## Current install: Hive name recovery

Global SHA256: `82afdae8791a79fc45703ea61134f48c652794d96da3ba913a776702a9e7dc50`.
Application fix `6c6c574`, native `2a2117ad4fe7`, runtime `674b58a1`,
builder `70acb10175fb`. Artifact `/tmp/bee-hive-name-candidate-20260911`;
backup `bee.previous-name-recovery-20260911T133017Z`. Installed atomically with
license and provenance sidecars, then restarted using validated process identity
and a pidfd. Existing databases were preserved.

Bee's production policy now grants eventual-name unregister as well as register.
Previously a retained desktop exit could leave the supervisor name behind and
make every restart fail with `eventualreg: name already registered`. Cleanup
failures and the original retained-process result error are now reported.
Native regression `5545061` uses the production policy and real eventual naming:
removal releases the old name and re-add publishes a fresh PID. Removing the
unregister permission reproduces the stale-name failure; restoring it passes.

Candidate lint, 11 production policy tests, standalone build and native-client
acceptance pass. Actual-user installed smoke: cold frame 1.976s, warm frame
0.218s, detach 0.114s each (exit zero), catalog 0.203s (exit zero).
A private ten-minute diagnostic run completed 20 successful catalog requests
without a captured service failure. This does not explain the initial unexpected
retained desktop exit or establish sustained multi-node recovery. The full
foundation check on retirement source completed successfully (session 80193,
exit zero): 516 Lua tests, storage/module/permission gates, source/pack desktop
interactions, client lifetimes, recovery and bundled apps. Evidence:
`/tmp/bee-retirement-foundation-check-20260911.log`. This full run predates the
name-cleanup source delta, whose focused policy/native proofs are listed above.

The installed name-recovery build also passed a ten-minute, 20-cycle actual-user
reconnect run (session39137, exit zero). Catalog calls took0.139–0.229s,
frames0.102–0.224s and every detach0.114s. Evidence:
`/tmp/bee-global-reconnect-soak-20260911.log`.

A separate source candidate `81f72d1` gives the initial retained display the same
independent lifetime as all other displays. The baseline fails the injected
initial-display crash; the candidate passes source/pack with the other display's
shell and the original default shell preserved. All six retained lifecycle
variants and the standalone build pass. Full check72192, native-client70191 and
native-binary39180 are running. Artifact:
`/tmp/bee-display-lifetimes-candidate-20260911`. Not installed globally yet.

The installation records below are historical.

## Previous install: membership retirement

Global SHA256: `723fb40b8c32ee277d8dcda8041e51499bb1c0adf3f0cf54c01115f75303802f`.
Application source `6b2da06`, native `2a2117ad4fe7`, runtime `674b58a1`.
Artifact `/tmp/bee-retirement-candidate-20260911`; backup
`bee.previous-retirement-20260911T125322Z`.

Hive Manager retires departed presentation rows after 60 seconds of absence in
complete samples. Partial samples update reported members without proving other
nodes absent; the cache remains bounded. Returning nodes clear departure status,
and retirement clears stale selection hints. Saved layouts/apps remain intact.

All 516 Lua tests, standalone build, native-client and native-binary checks pass.
Logs: `/tmp/bee-retirement-recovered-test-20260911.log`,
`/tmp/bee-retirement-{build,client-check,binary-check}-20260911.log`.
A guarded restart loaded this install into the actual user's workspace: first
frame 1.428s, detach 0.090s, exit zero. Databases were preserved.
The intermittent catalog/startup stall remains unresolved. A separate private
trace build is for diagnosis and is not installed globally.

The installation records below are historical.

## September 11: installed detach acknowledgment update

Global `/home/wolfy-j/.local/bin/bee` SHA256:
`1206b961045cb761cb3cd7d4ba49aeb5a90d0c12043d372151cb0ebeafde4225`.
Application source: `80611ee`; native: `2a2117ad4fe7`; runtime:
`674b58a1a117fa79398f723c4311201cca8472e1`; builder: `70acb10175fb`.
The only native production change from `a0fc01e088b2` increases detach
acknowledgment allowance from 200 ms to one second; successful replies return
immediately. Backup: `bee.previous-recovery-20260911T123909Z`.

The standalone build, native-client acceptance, native-binary acceptance and
30 overlapping three-client reconnect rounds passed. Evidence:
`/tmp/bee-recovery-{build,client-check,binary-check,reconnect}-20260911.log`.

**Actual-user startup remains broken intermittently.** After installation, a
PTY attachment against `/home/wolfy-j/.config/bee` remained at Connecting for
25 seconds without its first frame. The probe client was stopped; the retained
Bee and databases were preserved. Evidence:
`/tmp/bee-global-real-workspace-20260911.log`. These passing isolated gates do
not establish a fix for the user's startup or expired-mount failure.
The 60-second departed-display retirement work is not in this install.

Everything below is historical installation evidence.

## Current install: display isolation and direct appearance routing

Global `/home/wolfy-j/.local/bin/bee` now has SHA256
`ac0871a31007c4638c84d9e6836d512750e1ebdbbd1447eb96adfa626424416b`.
Artifact: `/tmp/bee-greenfield-global`. Runtime remains `674b58a1`; native remains
`a0fc01e088b2`. Settings allows independent instances, display custom/inherit mode
is persisted, and workspace-wide appearance writes/unscoped fallback are removed.

Standalone executable and actual two-display appearance acceptance pass. The
actual user's prior Bee process was stopped with SIGTERM; databases were preserved.
The installed build reached the existing desktop in 1.941s, F9 opened, and the
client detached in 0.072s. Backup: `bee.previous-display-20260911T023511Z`.
Logs: `/tmp/bee-greenfield-global-{build,install,smoke,native,appearance}.log`.

The wider cleanup is unfinished. Full current-cleanup repository acceptance is
not complete; the predecessor passed 511 Lua cases, and remaining desktop checks
are still running on that predecessor. No sustained mesh-recovery claim is made.
The dated installation descriptions below are historical, not the current binary.


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
installed or selected for builds**. The native pin now selects the separate cancellation fix `a0fc01e088b2`, retaining the original 200 ms detach budget.

A longer acknowledgment budget alone is insufficient. Diagnosis must distinguish
detach acknowledgment from native client shutdown. No cause or fix is established
for the separate actual-user expired mount and 60-second catalog stall.
Evidence: `/tmp/bee-detach-budget-reconnect-check.log`, fixture
`/tmp/bee-native-reconnect-i94l7w7b`.

## Installed

The global binary now includes the narrow physical cancellation-order fix:
cancel and join the input worker before closing its mount. A regression fails
without the change and passes with it; genuine delivery errors remain visible.
Native-client and standalone suites passed, as did mesh/physical, session and
retained-owner race/vet checks. The source and runtime are unchanged from the
previous install. Reconnect stress still reproduces pre-existing detach and
startup failures, so this is not a sustained-reliability claim.

Installed read-only attachment to the actual user's retained workspace reached
its first frame in 217 ms and detached in 87 ms. No owner restart or database
change was performed. Evidence: `/tmp/bee-cancel-drain-global-install.log` and
`/tmp/bee-cancel-drain-global-observe.log`. Backup:
`bee.previous-20260911T004912Z`. Artifact: `/tmp/bee-cancel-drain-candidate`.
The latest runtime-facing detach evidence is journal 935: accepted local send
in 21 microseconds, retained select resuming 599 ms later.

`/home/wolfy-j/.local/bin/bee` is the explicit-selection and Hive session-identity candidate:

| Component | Revision |
|---|---|
| Bee production source | `c3b2c9f` |
| Native Bee | `a0fc01e088b2` |
| Runtime | `674b58a1a117fa79398f723c4311201cca8472e1` |
| Builder | `70acb10175fbeb42a3a4d382677715a0c2a969e4` |
| Executable SHA256 | `2c1f11099dd970c12be11ee8cf7e51ad1521e093c94f1a880cfd1602d7908a61` |

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

The previous explicit-selection build artifact is `/tmp/bee-explicit-desktop-candidate`, from checkpoint
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
