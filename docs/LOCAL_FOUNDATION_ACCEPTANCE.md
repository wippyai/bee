# Local foundation acceptance

This records the delivered local-foundation goal and the remaining host/client
work. It is not a claim that Bee's proposed Hive, agent or installation APIs exist.

## Current installed candidate (2026-09-10)

Global `bee` now starts or attaches to a retained local owner using the native
mesh and embedded code with shared registry history. Explicit detach retains
applications. The latest Bee-only change handles native LINK_DOWN in the two
supervisors instead of letting client loss terminate the retained desktop.
Actual-executable acceptance proves normal reconnect, clipboard/F12, bounded
stalled-owner detach, delayed owner publication, and client SIGKILL followed by
same-shell reconnect after a 40-second node-departure observation interval.
The current source checkpoint is `18caf09`; exact executable pins, hash and
rollback are in [the global build handoff](handoffs/GLOBAL_BUILD.md).

Immediate exact-actor EXIT while its transport remains live is still a runtime
gate. A full `make check` is running against the frozen build source; earlier
passing subsets do not establish its result. Cold owner startup still captures
output in an owner log file. The user's already-running older owner is not
hot-replaced by installing a new executable.

## Earlier selection candidate (2026-09-10)

The global Bee now contains the tested local selection/scrolling candidate at the
user's request. `bee --base` selects its embedded baseline while preserving
application databases. Acceptance against that actual executable passes embedded
boot, Settings recovery, native Terminal, wheel/burst scrolling, window-local
selection/copy, literal arguments, fullscreen aliases and F12. The previous
executable is retained for rollback; see [the journal](handoffs/JOURNAL.md).

The current production source matches the frozen snapshot used by the foundation
check. That run passes 481 Lua tests, module/storage/architecture checks, local
UI and Terminal checks, 161 navigation cases, selection and lifecycle/load tests.
It stopped on a synthetic detached-probe key missing required event fields. The
corrected fixture passes all six modes from source and pack, now with an explicit
completion marker after every probe's assertions. The resumed client-desktop and
public-launcher checks also pass, including legacy migration without ledger
changes and retained PTY reconciliation after a lost renderer reply. Recovery
and bundled-app recipes also passed. Every foundation recipe now has passing
evidence across the initial run and resumed checks; this is not a passing
uninterrupted `make check` claim.

Evidence: `/tmp/bee-selection-foundation-check-2.log`,
`/tmp/bee-detached-completion-check.log`,
`/tmp/bee-foundation-remaining-desktop.log`, and
`/tmp/bee-global-scroll-check-2.log`. The build uses the integration runtime
candidate. A portable upstream runtime pin, a coherent source checkpoint sync,
public second-invocation attachment and remote launch remain open. Hardware
trackpad behavior and scrolling inside an actual Codex conversation are not
established by the terminal-protocol tests.

## Earlier verified checkpoint

Production checkpoint `aaf3628` passed `make check` and rebuilt standalone binary
acceptance. Attachment-only checks were subsequently strengthened through
`c2e079b` and passed in source and pack. The work is synced on
`feat/independent-view-bindings`; GitHub rejected a direct main update because
main now requires a pull request and status checks. No PR was opened or merged.
Uncommitted native packaging work owned by another contributor is not certified
by this checkpoint.

## Previous verified local acceptance

Latest isolated checkpoint `9308a39` on `feat/independent-view-bindings` passes
full source/pack checks, standalone assembly and native acceptance. Its private
`bee.client:desktops` component retains virtual desktop resources under a
supervising actor against an existing workspace host. Duplicate store bindings
are rejected within that supervisor; only the matching desktop EXIT releases
its resources. Checkpoint `4a81c86` also proves crashed and normally closed
display actors can be replaced without losing the same live shell. These are
same-runtime virtual-display fixtures; public physical-client attachment is
still unimplemented. Shared source contains the reviewed component changes;
the isolated result does not certify unrelated shared-tree work.

The public host/client launcher passes full `make check` (115 typed unit cases
plus source/pack acceptance) and standalone executable checks. Verified behavior
includes a real combined-owner database upgrade, once-only client import, retained
layout and checkpoint identities, independent local clients, bounded presenter
recovery, visible structural failures and retryable ordinary command failures.
No applied workspace migration changed. The 16-app load check exited in 322 ms
in this test environment. Remote/Hive operation is not established by these checks.

| Goal requirement | Implementation and acceptance evidence |
|---|---|
| Settings and nostalgic themes | Standalone Settings provides DOS and Windows Classic among 16 themes, 11 backgrounds and tab appearance. `tests/tui_smoke.py`, `taskbar.py`, `personalization.py` and `console.py` exercise appearance, saved preferences and readable Classic terminal defaults. |
| Window behavior and prompt exit | Source/pack UI, navigation, drag failure, dialog and close-confirmation checks cover resize, fullscreen, minimize, focus, input isolation and presenter recovery. The 16-app lifecycle load check completed shutdown in about 335 ms at this checkpoint. Timings describe the test environment, not a universal latency guarantee. |
| Durable state and permissions | Storage, recovery and control-delivery checks cover migration integrity, stable workspace identity, stale-writer rejection, checkpoint receipts, cold recovery and interrupted core delivery. App scopes deny direct workspace SQL, registry mutation and foreign terminal access; native shells retain OS-user authority. |
| Thread/subscriber prototype | `make threads` tests the isolated native actor/contract prototype: bounded replay, cursor resume, live catch-up, authenticated denial, duplicate/conflicting appends and migration checks. This is distinct from production subscriptions. |
| Thread-reading application | `tests/timeline_app.py` and `tests/lua/timeline` prove the Timeline application: launch arguments, the owner's subscription cursor moved only on acknowledgment, resume under a new lease, and refusal of a non-member. Durable scheduling remains unimplemented. |
| Standalone processes and typed contracts | Registry/import audits and strict lint cover source and pack. Each app is a process. The host owns checkpoints and broker; the client owns its store, session and replaceable presenter; the local supervisor coordinates lifetime. |
| Workspace/client design | `WORKSPACE_ATTACHMENTS.md` and `CLIENT_HOST_SPLIT.md` define qualified identities and native mesh boundaries. Source/pack tests prove two local client actors, independent layout/appearance, retained terminals, controller revocation and migration receipts. Later two-runtime fixtures prove remote attachment under fixture-selected admission; see `HIVE_POC.md`. Public discovery and mixed-workspace composition remain unimplemented. |
| Cluster disabled by default | Source configuration declares no cluster/membership profile. The Linux source/pack UI check inspects the running Bee process's socket inodes after boot and rejects TCP listeners or bound UDP endpoints. This verifies the default test composition, not user-supplied profiles or arbitrary native commands. |
| Accurate scope | Kickside compatibility, AI drivers, models, MCP, Hub activation and in-app self-update remain proposals. Command aliases launch installed native programs. Runtime cluster/Raft changes remain with their separate owner. |

## Observer attachment checkpoint

The host now derives observe-only mounts for admitted clients without control
permission. Source/pack acceptance covers controller continuity, observer
replacement, revocation failure/retry, stale-grant denial and actual desktop F12.
Observer displays may have different dimensions; they clip fresh producer frames
without resizing the application. Client loss does not close that application.
These are same-runtime actor proofs, not public physical-client discovery or a
shared-desktop selector. The frozen observer checkpoint passed every `make check`
gate, including 317 Wippy tests and source/pack desktop acceptance. Fixture fixes
were validated before resuming the remaining gates. A later two-file placement
delta also passed strict lint and 318 tests; subsequent concurrent changes are
outside that proof. An isolated multi-pack standalone probe passes native acceptance;
the shared packaging workflow has not adopted it. See
[the composition handoff](handoffs/STANDALONE_MODULE_COMPOSITION.md). Exact input
hashes and result logs are recorded in [the journal](handoffs/JOURNAL.md).

## Launch

For the locally assembled development executable:

```sh
install -Dm755 dist/bee "$HOME/.local/bin/bee"
export PATH="$HOME/.local/bin:$PATH"
bee
bee terminal
bee codex
```

Run from the desired project directory. The native program must be installed on
PATH. Existing runtime registry state may retain an earlier selected deployment;
`bee --base` selects the embedded base while preserving application databases.
See `README.md` and `DEVELOPMENT.md` for the distribution/development distinction.
There is no stable published release implied by these instructions.

## Still required for the requested Hive direction

The local foundation does not complete the broader requested headless/Hive work.
The stable workspace host is now separate from the physical terminal client,
keeping broker and workspace persistence together. Public local launch passes
the full acceptance suite. Its supervisor owns the host; client
detach, app close and host shutdown are distinct operations. Two independently
persisted local client actors and retained terminals have source/pack acceptance.
These actors run inside a runtime; this does not prove that a second ordinary
`bee` invocation attaches as an independent physical client. Automatic host reuse
and client-profile allocation remain required. The current candidate uses Wippy's
native mesh and native TLS, with no Bee listener sidecar. The separately compiled
client now obtains supervisor admission to a retained desktop and passes a real
PTY check: shell input, F12 with the same shell, resize, bounded detach and terminal
attribute restoration. This proof uses explicit fixture enrollment and the
candidate runtime's terminal-dispatcher correction; it does not activate public
startup. See [client state](CLIENT_STATE.md#native-mesh-rendezvous-candidate).

| Public client gate | Current evidence |
|---|---|
| Native transport, destination admission and physical rendering | Compiled client/real owner PTY fixture passes. |
| Client crash followed by controller rejoin | Remote monitor gate still fails in the consumed runtime; explicit detach is insufficient. |
| Ordinary first/second `bee` and desktop selection | Not activated or accepted; independent layout allocation is still required. |
| Remote node selection and Terminal on `100.70.10.28` | Not accepted through the public launch path. |

The remaining public remote milestone must prove discovery, destination admission
and remote Terminal use through ordinary Bee launch, plus qualified tabs from
two workspaces. Existing desktop fixtures exercise the actual client against a
remote host with preselected admission; they do not prove the public enrollment
or discovery path. Only after these gates expose the managed headless profile,
workspace switcher and Hive Manager. Fresh local launches must remain local-only.

Application drivers and installation/self-edit subsystems are subsequent work,
not extra responsibilities to put into the desktop loop.
