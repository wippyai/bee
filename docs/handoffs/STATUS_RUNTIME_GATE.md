# Runtime gate for status and desktop acceptance

## Current global candidate — 2026-09-10

Global `/home/wolfy-j/.local/bin/bee` now uses combined runtime `674b58a1a1`
and Bee native `08a5761b809d`. The pinned builder produced the executable from
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

Installed SHA256: `434be069787e26e8395ab158e2338d66acf3685c0f6ba7c73b1b67342fe3031d`.
Rollback: `/home/wolfy-j/.local/bin/bee.rollback-20260910T141438Z`.
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
