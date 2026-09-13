# Runtime gate for status and desktop acceptance

## Current status

[GLOBAL_BUILD.md](GLOBAL_BUILD.md) is the authoritative installed-binary and
acceptance record. The candidate runtime pin is `674b58a1a1`; the current native
Bee pin is `a36ac552880d`. Earlier binary hashes and failed gates below are
historical evidence, not the current installation status.

Runtime [PR #716](https://github.com/wippyai/runtime/pull/716) was closed without
merge at the user's request on September 10. The Bee pin does not contain its
`system/topology/remote` subsystem, and Bee has no dependency on it. Do not
revive that branch or add Lua ingress evidence. The cluster lane owns any future
native lifecycle changes through its reviewed PRs; Bee consumes native mesh
signals. A link loss can retire a display attachment without claiming that its
remote actor exited or ending the retained applications.

## Historical global candidate — 2026-09-10

Global `/home/wolfy-j/.local/bin/bee` now uses combined runtime `674b58a1a1`
and Bee native `1abf5b28a0e5`. The pinned builder produced the executable from
frozen source `/tmp/bee-global-final-crjl7na9`; no runtime or Bee PR was merged.
Runtime PR #726 (stacked on #703, assigned to skhaz) supplies embedded-default
selection with shared registry history. Earlier blockers below are historical.

Actual binary checks pass: ordinary cold owner/client startup, exact clipboard
copy, Ctrl+Q detach, retained-shell reconnect, F12, scroll wheel and burst input,
explicit app/alias launches, and upgrade from the Sep 8 binary with a fresh app
catalog, retained Ocean theme/workspace identity and unchanged migration ledger.
The runtime SQLite history replay/changed-baseline tests also pass.
Evidence: `/tmp/bee-final-binary-acceptance.log` and
`/tmp/bee-combined-baseline-overlay.log`. The final full foundation run failed at the initial blank-frame wait in
`tests/drag_failure.py`; see `/tmp/bee-final-full-check.log`. No full-suite pass.

Installed SHA256: `282c1a2169c04da3cf410fc60bebe2db0247e8c3cf301c496d34866ab51f4731`.
Rollback: `/home/wolfy-j/.local/bin/bee.rollback-20260910T143654Z`.
Public remote enrollment, independent observer selection and the runtime main
release cutover remain separate unfinished work.


Latest checkpoint (2026-09-10): the user explicitly requested the tested
standalone candidate immediately. The global `bee` is now that candidate;
acceptance against the installed executable passes, including physical
selection/copy. The previous executable is preserved for rollback. Use
`bee --base` to select the fresh embedded baseline without resetting databases.
This installation does not complete the main-based runtime cutover.

The frozen foundation snapshot passes 481 Lua tests. Its first full run stopped
at an initial-frame timeout; a readiness probe did not reproduce that failure.
The second run passed that startup gate but stopped in the detached-attachment
fixture: its synthetic key lacked required `key_type` and `action` fields. The
fixture now supplies a valid key event before asserting revoked input is denied.
Detached acceptance now passes from source and pack with explicit per-mode
completion markers (`/tmp/bee-detached-completion-check.log`). Client-desktop
acceptance also passed in the resumed run, followed by launcher, recovery and
all three app gates. `/tmp/bee-foundation-remaining-desktop.log` ends with
`Remaining desktop recipes passed`. Every foundation recipe now has passing
evidence across the original run and resumed checks; there is no uninterrupted
full-run pass claim. The dated sections below retain earlier
snapshot evidence and must not be read as current release acceptance.

Bee source integration is implemented, with 68 combined focused
protocol/host/session/presentation/render tests passing. This is not a release
or remote-desktop acceptance checkpoint. Changes remain in the shared checkout.

The pinned runtime prevents the required gates from executing:

1. `funcs.Future.response()` is declared as `any` by
   `runtime/lua/modules/funcs/types.go`, as is `Future.channel()`. The actual
   completion channel needs the nonoptional native generic
   `Channel<unknown>` return in the manifest. Bee retains this channel in a typed pending
   record for event-loop selection; the assignment remains a strict lint error.
   Runtime [PR #717](https://github.com/wippyai/runtime/pull/717) proves strict Lua can store and select the
   returned channel. Do not substitute casts, polling or a Bee relay.

Bee's Lua ingress/connection checks have been removed at the user's direction.
Native sender validation, peer admission and process-exit cleanup remain.
Typed `process.listen(topic, {message = true, type = T})` is implemented in
[runtime PR #718](https://github.com/wippyai/runtime/pull/718), with inference
in [Go-Lua PR #44](https://github.com/wippyai/go-lua/pull/44).
All three PRs target main and are assigned to skhaz. No merge or Bee pin change
has been made. Receiver-local validation happens before channel delivery;
`message:data()` returns the checked value and `from()` retains native identity.

On the isolated candidate below, production lint (302 entries), staged test
lint (419 entries), and the focused Bee supervisor suites (39/39) pass. The
release pin still lacks typed listeners and the Future declaration correction.

Runtime changes use isolated PRs assigned to `skhaz`.
Do not enable the overlapping remote-monitor controllers or resume the paused
Bee-owned runtime branch. The user wants the eventual Bee build based on the
released runtime main line.

On receiving a usable runtime revision/build:

- Revalidate remaining lint errors against that exact runtime; update the build pin
  only through the coordinated runtime cutover.
- Run `make check`, `make client-desktop-check` and
  `make workspace-hosts-check`. Preserve failures and fix their causes.
- The workspace-host fixture now checks explicit thread references through
  replies, checkpoints and host restart, plus changed-retry and singleton
  conflicts. These assertions now pass from source and pack on the candidate.
- Bound-thread physical F12/client-reconnect acceptance now passes from source
  and pack on the candidate, including a fresh owner reply changing the badge
  after reconnect.
- Review and sync a coherent Bee checkpoint only after the required checks;
  do not stage the entire concurrently modified checkout.
- Continue the original local/remote launch target, including discovery and a
  usable remote Terminal on `100.70.10.28`. This status slice does not prove it.

The exact code contracts and focused evidence are in
[STATUS_SURFACE.md](STATUS_SURFACE.md). Bee Harness journal is
`01a06e56-ba58-7c5a-bd69-b7feb109a05d`, graph/node `bee-harness` / `root`.


## Isolated PR integration (2026-09-09)

An isolated test runtime combines runtime #718, corrected #717 and the existing
#702 pack command-host fix at `beb5c014a1`, using #44's published Go-Lua commit.
The pinned builder produced `/tmp/bee-wippy-typed-integration` without runtime
patches; its binary SHA-256 is
`d37dfda3ffbd27b34db4e3d1fe40816365148a001a14875b10dac69e84da824b`.
This does not change the release manifest or global executable.

Bee source uses receiver-local typed request/reply/hello listeners; v1 remote
values remain maps. Production and staged test lint pass. Source/pack
workspace-host acceptance passes, including host-authorized thread associations
and restart recovery. Source/pack desktop-client acceptance also passes for
independent/workspace appearance, physical displays, F12, retained-shell rejoin,
controller exclusion, display EXIT cleanup and bounded detach/shutdown.

All foundation check recipes now have passing evidence across the original run
and resumed focused runs: 454/454 Lua tests, 517 source/pack registry entries,
storage and subscription restart, module isolation, physical desktop, launcher,
recovery and bundled-app acceptance. This is not one uninterrupted `make check`
run. Runtime #717/#718 and Go-Lua #44 also have green hosted checks.

The strengthened client-desktop source/pack checks pass with explicit worker-host
execution and required completion markers. Bound-thread status survives F12 and
fresh-client reconnect; a subsequent owner reply visibly changes the badge to
Idle. The final log is `/tmp/bee-client-desktop-final.log`. Worker probes report
through the runtime logger because they have no physical terminal context.

Standalone module composition, public auto-attachment and remote release remain
unfinished. These local proofs do not resolve the cluster lane's native source
authority or remote-monitor gates, or establish release readiness.

## Selection and native channel integration checkpoint

The current frozen source at `/tmp/bee-selection-foundation-rvrlx14_` passes all
481 Lua tests with `/tmp/bee-wippy-selection-typed-candidate`. The exact older
430-entry fixture also passes strict lint. Go-Lua PR #45 now includes assertion
return preservation for instantiated channels; runtime PR #724 gives native
TTY events, viewport updates and terminal completion typed select cases.
Both PRs are ready for review and assigned to skhaz. Runtime #724's engine/TTY/exec
race suite and scoped lint pass; its hosted checks are green.

Runtime #722 provides explicit physical clipboard submission and has all hosted
checks green. Local source/pack selection acceptance includes exact foreground
text, frozen rows during live output replacement, hover, resumed input and
cancel/rejoin/resize. Remote clipboard routing remains unimplemented.

The first full `make check` in `/tmp/bee-selection-foundation-check.log`
stopped at the initial desktop frame assertion. The second run is
`/tmp/bee-selection-foundation-check-2.log`; it passed that assertion, Terminal,
scrolling, navigation, selection and lifecycle/load acceptance before the typed
event fixture error described above. Lua, thread/module, resource, gateway, headless,
architecture (513 source/pack entries) and storage checks passed.

The installed candidate has a local compiler replacement in its build provenance;
it is not a portable release pin. Standalone acceptance against the actual global
binary passed in `/tmp/bee-global-installed-check.log`. Journal seq 534/536 records
the explicit installation request, executable hash and rollback path.

Runtime PR #705 is now refreshed against main `d78a66c74b`, with head
`a544d7264e`. Terminal and Lua TTY race suites and focused lint pass; the full
hosted CI was triggered on this exact head. PRs #702/#718 are being refreshed
separately. All remain PR-only work assigned to skhaz; no main merge or paused
remote-monitor semantic work was performed.

## Embedded-default upgrade: confirmed deployment-policy mismatch

Read-only trace against launcher runtime `944736c9999a9bb8ee1bbd06b29f03b6b8d5901a`:
`application/run.go` selects the persisted deployment and shared `registry.db`
for ordinary launch. Only explicit `--base` selects the embedded bundle digest
and a separate registry history. `application/bundle.go::Bundle.Seed` explicitly
retains an existing deployment, including a different embedded version. Setting
Bee's manifest mode to `base` does not change that ordinary-launch policy.

This explains the two-binary reproduction in `tests/native_upgrade.py`: the new
binary still displays Test Status and lacks Hive Manager. Evidence is
`/tmp/bee-default-base-upgrade-red.log`. It is a runtime deployment-policy issue,
not a Bee menu cache. No runtime implementation was changed in this investigation.

Required runtime handoff: provide an explicit embedded-default launch policy that
loads the current bundle while retaining authorized registry overlays and stable
application stores. Preserve other applications' existing deployment/update
semantics. Define removed-entry and conflicting-overlay behavior explicitly;
failures must leave a recoverable prior deployment. Do not implement Bee's request
by silently forcing recovery mode or deleting registry history.

Acceptance requires both the existing two-binary test (fresh catalog, Settings
recovery, stable workspace identity, unchanged applied migrations) and a separate
fixture that publishes an overlay through its authorized owner, upgrades, then
proves that overlay survives and remains authorized. The current upgrade test does
not establish overlay preservation. A combined launch/selection runtime alone does
not resolve this independent release gate.

### September 10: crash timeout localized to Hive activation

A disposable owner/client crash probe now identifies the later readiness failure:
`bee.hive:activation` first fails with `linked process failed`, then its restart
fails repeatedly at supervisor name publication with `eventualreg: name already
registered`. Evidence: `/tmp/bee-owner-crash-trace7.log`; the isolated diagnostic's
race test and vet completed successfully (`/tmp/bee-owner-crash-diagnostic7.log`).
That diagnostic success means capture succeeded, not crash recovery acceptance.
No production runtime or user owner was changed.

On runtime `674b58a1a117fa79398f723c4311201cca8472e1`,
`Topology.HandleNodeExit` sends `LinkDown` to both remote watchers and linked
processes. Lua terminates on that event unless `trap_links` is enabled. Bee's
supervisor currently does not enable it. The next Bee correction should use the
existing process option and explicitly handle connection uncertainty; a lost link
must not be fabricated into authoritative process completion. The separate missing
remote EXIT gate remains open. Runtime naming cleanup stays with its existing lane;
no Bee-specific ingress, transport or monitoring fallback is justified by this trace.

The Bee correction now passes the isolated real-owner crash/reconnect probe:
`process.set_options({trap_links = true})` is enabled in both Hive and retained
desktop supervisors, which monitor physical recipients. Native link loss revokes
only the attachment via existing owner operations. Only an EXIT declares the
retained owner stopped. The first outer-supervisor-only change was insufficient;
its inner retained supervisor also needed this handling.

`/tmp/bee-owner-linkdown-fixed2.log` passes the race test and vet (52.758 seconds).
The strengthened diagnostic kills the physical client, waits 40 seconds for native
node departure, rejoins the retained shell and rejects owner service failures.
`/tmp/bee-owner-linkdown-fixed2-trace.log` contains no failed service state. The
standalone regression is `tests/native_client.py::crashed_client`; actual binary
acceptance and installation remain pending. This does not prove immediate actor
EXIT while transport remains alive; that runtime gate is unchanged.

## September 12: managed Agent MCP and Docker requirements

Local gateway activation work now reads an OS-selected loopback address through
the native supervisor state. The candidate uses runtime HTTP port-zero PR #737,
composed onto Bee's current launch-ABI pin; this is not a released runtime pin.
Two native address cases and 775 unit cases pass, including the appended gateway
migration 8's preservation of populated credentials and listener state. Explicit
open and readiness now also compare native execution identity. Focused native
admission, drain preservation and explicit-open checks pass, as do two-runtime
gateway operations. Actual native service restart acceptance remains unfinished.

The checksummed upstream patch is now tracked as
`build/patches/runtime-http-port0.patch`, with provenance alongside it. The
manifest no longer references ignored local build input. Production port-zero
listeners pass the two-runtime gateway acceptance. Default profiles now declare
the two bound-thread read tools; Claude/Codex also declare the five supported
hooks. Standalone managed launch and authenticated child MCP pass using fixture
executables. The refreshed full regression remains pending. See GLOBAL_BUILD.md
for the installed build and its limits.

Source audit of exact runtime pin `291f5c6b708c80afe5da07f3223767573b4d183f`
identifies two remaining native seams. These are requirements, not implemented
Bee APIs or passing integration claims:

- **OS-assigned HTTP listener port.** `service/http/server.go` binds the configured
  address but `ensureRunning` probes `s.config.Addr`, and startup status also
  reports that configured address. With `127.0.0.1:0`, readiness must instead use
  the actual bound listener address. The host also needs authoritative access to
  that address for the existing gateway endpoint and exact readiness permission.
  Retain ownership of the original listener; choosing a free port and releasing
  it before startup is not acceptable production allocation. No matching open
  runtime PR was found in the September 12 queue inspection.
- **Exact Docker attempt mounts.** The pin already has native Docker PTY
  attachment/resize through `exec.PTYProcess`. Executor volumes are static,
  while per-process options do not select the admitted project/private HOME
  mounts. The host executor needs an exact per-attempt mount selection and an
  execution identity that placement can reconcile after restart. Drivers must
  not receive Docker authority. Do not mount the entire placement root, create
  a second container, or introduce a CLI attachment lifecycle.

Changes belong in runtime PRs assigned to Rodrigo (`skhaz`), with native
acceptance before a Bee pin change. Existing global `f1a29d08` does not claim
production MCP activation or Docker execution. This audit changed no runtime code.

HTTP port-zero startup is now proposed in
[runtime PR #737](https://github.com/wippyai/runtime/pull/737), assigned to
Rodrigo (`skhaz`), commit `20e657b4ee`. It uses the bound address for readiness,
existing status details and request metadata only when port zero is configured;
fixed-port named hosts preserve their configured address. Native HTTP tests,
vet and focused race coverage pass, including real requests, cancellation and
sequential restart with the old port reserved. No new discovery API was added.
The PR is unmerged; Bee's runtime pin and global executable remain unchanged.

## September 13: retained PTY identity needed for cold Agent continuation

Bee's native streamed runner records the existing process PID, group ID, start
ticks and boot ID. The interactive route consumes that process through
`attach_terminal`; the returned `exec.TerminalSession` exposes send/close/done/status
but does not preserve the optional `exec.ProcessIdentity` capability or startup
readiness. The default Agent policies require process-group cleanup. Consequently
an ended window cannot prove the previous group's absence and release the retained
session home for another attempt. `continuation.resolve_window` correctly refuses
until cleanup is complete. The real `window-native-check` explicitly proves this
cleanup refusal; the model continuation tests do not prove cold provider recovery.

Required runtime behavior: preserve access to the started process's optional
identity through the existing terminal lifecycle, distinguishing not-started,
unsupported and failed states. Bee can then reuse its existing PID/start-time/boot
identity and process-group absence checks. Terminal disconnection alone must not
become process exit or cleanup evidence. This is a requirement under review, not
a new callable API or an excuse to relax the session-home guard. No runtime code
or pin changed for this finding. Docker additionally needs its own durable
container identity; a host PID cannot stand in for that.

The live-window supervision issue is fixed in Bee itself: the owner answers the
existing status probe and honors only committed stop intent. It does not solve
post-crash identity, turn settlement or provider-session recovery. Evidence and
global provenance are recorded in [GLOBAL_BUILD.md](GLOBAL_BUILD.md).
