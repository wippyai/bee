# Global Bee candidate — September 10, 2026

The installed executable is a development candidate built from source
in `/tmp/bee-global-checkpoint-20260910` at source checkpoint `9ca211b` with the observer native pin below
on `checkpoint/global-bee-candidate-20260910`. No runtime PR or main merge was
performed for this update. The standalone suites and the full foundation gate pass. The foundation run
checked the same Lua source, and the observer native change passed its own gates.

- Runtime: `674b58a1a117fa79398f723c4311201cca8472e1`.
- Native Bee: `142e75380203`, `checkpoint/native-client-binding-20260910`.
- Builder: `70acb10175fbeb42a3a4d382677715a0c2a969e4`.
- Installed executable: `/home/wolfy-j/.local/bin/bee`.
- Build output: `/tmp/bee-observe-global-candidate`.
- SHA256: `c1f5d871f419b1bffa08e5dc3aa978e90a65e4bb687f83adf0c973571d69a94d`.
- Previous binary archive: `/home/wolfy-j/.local/bin/bee.previous-20260910T194019Z`.
  This UI update adds no migration. The preceding build appended client-store
  migration 2; older archives are not supported database downgrades.

## Launch and ownership

Run `bee` normally. It loads embedded code with shared registry history and
starts or authenticates the same-state owner through the native mesh. Ctrl+Q and
Ctrl+] detach the physical client while retaining the owner and applications.
A busy application-state lock routes to authenticated attachment; it grants no
access. If the owner is still preparing discovery, the client waits cancellably
for publication before authenticating. Warm launch creates no owner contender or
additional owner log. Cold startup still captures output in `owner-*.log`.

The first owner starts in the launching process's project directory. Later clients
using that same state directory join the existing owner; they do not change its
working directory. Newly opened Terminals inherit that owner's directory. Dynamic
project/workspace selection is not implemented by this attachment route.

Installing a new executable does not hot-replace an already-running owner.
After the user authorized restarting Bee, the stale owner was stopped gracefully
and the installed executable started a fresh owner on the same workspace store.
Actual user-state readiness took 1.396 seconds; reconnect took 0.114 seconds and
detach took 0.082–0.100 seconds. Evidence:
`/tmp/bee-user-owner-restart-check.log`. An older owner's failure cannot be
repaired merely by launching a newer client against it.

Explicit `--base` remains a recovery mode. The embedded-default deployment policy
is in runtime PR #726, stacked on #703 and assigned to Rodrigo (`skhaz`); the
candidate does not yet consume a released runtime main revision.

## Earlier acceptance and remaining limits

`/tmp/bee-startup-responsive-acceptance.log` passes the actual executable's cold
owner/client launch, exact clipboard copy, F12, retained explicit reconnect,
bounded stalled-owner exit with uncertainty preserved, delayed owner publication,
and SIGKILL followed by reconnect to the same shell. Warm reconnect measured
0.218 seconds. The SIGKILL test waits 40 seconds for native node-departure delivery;
it does not establish immediate crash detection.

Both Bee supervisors now use the existing `trap_links` option. LINK_DOWN revokes
the physical attachment without declaring its actor dead or terminating retained
applications. The real-owner diagnostic rejects failed service states and passes
race/vet: `/tmp/bee-owner-linkdown-fixed2.log` and its companion trace. This fixes
the earlier link-loss-induced supervisor failure and stale-name restart loop.

The exact-actor monitor gate remains failing on the current runtime: registration
succeeds but no EXIT arrives when the target finishes while transport stays alive.
See [the runtime handoff](STATUS_RUNTIME_GATE.md). No Bee polling substitute,
parallel transport or new ingress API is used.

Before the loopback profile adjustment, timing probes found fresh-owner startup at 1.53–2.58 seconds, terminal restoration
at about 21 ms, and clean process exits at 0.84–0.92 seconds. An earlier clean exit
at 1.008 seconds failed the existing one-second limit; it has not been erased by
the later passing samples. Test-only stage timings place 0.37–0.95 seconds in the
native stack's shutdown, with naming cleanup taking microseconds. Evidence:
`/tmp/bee-global-launch-timings.log`, `/tmp/bee-client-close-stages.log`, journal716.

The frozen production source now passes one uninterrupted full `make check`:
482 Lua tests; module/headless/resource/storage/subscription restart checks;
source/pack architecture at 517 entries; desktop smoke and fresh-pack inventory;
appearance, titles, dialogs, close confirmation and control-delivery failures;
drag recovery, Terminal/scrolling, 161 navigation cases and selection; lifecycle,
16-window load (394 ms exit), detached/observer/client/status checks; launcher and
legacy migration, recovery, Inbox, Hive Manager and Timeline. The command exited
successfully in unified exec session 94747. Evidence:
`/tmp/bee-responsive-foundation-check.log`. All 365 production files matched the
frozen source at run start; the run used `/tmp/bee-wippy-combined-final`.

Earlier full runs stopped at Settings or drag startup. Both gates pass in this
uninterrupted run with unchanged time limits; their causes are not established.
Historical evidence remains in `/tmp/bee-linkdown-foundation-check.log`,
`/tmp/bee-settings-startup-observe.log`, `/tmp/bee-linkdown-remaining-desktop.log`
and `/tmp/bee-final-full-check.log`. No intermittent-failure fix is claimed.

Prior standalone Settings/Terminal/scrolling/selection and old-binary upgrade
acceptance is recorded in `/tmp/bee-final-binary-acceptance.log`; those results
precede this Lua-only link-loss correction. Public external Hive enrollment,
remote selection and mixed-workspace client composition remain open.

## Rebuild

Use the candidate's pinned `wippy.build.json` and Makefile:

```sh
make native-tools
make standalone
make native-client-check native-binary-check
make native-upgrade-check PREVIOUS_BEE=/path/to/pre-Hive-Manager/bee
make check WIPPY="$PWD/.wippy/bin/bee-wippy"
```

## Startup responsiveness

Native checkpoint `d4b427d90a2e` adds immediate Starting/Connecting feedback,
separates cancellation of read-only discovery from uncertain attachment outcomes,
and sets the existing loopback-client gossip interval to 50 ms. This increases
local gossip frequency while retaining graceful leave; it changes no runtime API,
owner profile or remote failure-detection contract. Session and launcher race/vet
checks and the actual-owner composition pass. The standalone candidate is installed and passes the full native-client gate,
including the unchanged one-second exit limit and retained-shell crash/rejoin.
Its predecessor failed that exit gate at 1.005 seconds; that failure motivated the
local profile adjustment.

A free state lock starts the owner directly without network discovery. Measured
cold startup is still 1.5–2.6 seconds, not instantaneous. A busy lock routes to the
existing owner; an unresponsive owner must not cause a competing database owner.

The installed responsive build was also measured in three fresh disposable
workspaces: cold desktop readiness was 2.591, 1.856 and 1.429 seconds; clean exit
was 81, 89 and 97 ms. Evidence: `/tmp/bee-responsive-cold-timings.log`.
These samples confirm responsive shutdown, not instantaneous cold boot or a
universal timing guarantee. The user's existing owner was not touched.

A subsequent four-run cold-start trace observed feedback at 45–47 ms, local
endpoint publication at 276–362 ms, and desktop readiness at 1.370–1.470 seconds.
The endpoint is a transport hint, not application readiness. An instrumented
real-owner composition spends its cold wait discovering the supervisor name;
ready-owner catalog reads take about 3–4 ms. This does not yet distinguish owner
application startup from name propagation. A disposable owner-profile 50 ms gossip
trial still waited 5.5 seconds in that source-based diagnostic versus 6 seconds
before it; this is insufficient evidence of a fix and was not adopted. Both
composition runs passed race/vet. Logs: `/tmp/bee-cold-start-stages.log`,
`/tmp/bee-cold-native-stages.log`, `/tmp/bee-cold-owner-gossip-stages.log`.

The follow-up service-event trace distinguishes late application activation from
name propagation in the source-based diagnostic: client lookup began at
11:45:57.226819, Hive activation started at 11:46:02.936028, and lookup completed
6.450557 seconds after it began (about 0.741 seconds after activation started).
Thus most of that diagnostic's delay precedes activation; faster gossip cannot
remove it. This is not a timing breakdown of the installed binary. Temporary Lua
logger markers were silent in the fixture profile; the measured boundaries use
its existing native service-event capture. The composition passes race/vet:
`/tmp/bee-cold-service-stages.log`. No production logging or runtime changes were
introduced by this investigation.

## Historical command gap and implementation checkpoints

This section records the earlier failure and intermediate states. The installed
route and its complete acceptance are documented in the following section.

The installed build's automatic route handles argument-free `bee`, but command
aliases such as `bee terminal` still enter the in-process launcher. With a retained
owner running, both `bee terminal` and `bee --command bee run terminal` fail with
`application lock is busy`. Reproduction with disposable state and successful
fixture cleanup: `/tmp/bee-retained-alias-probe-clean.log`. The full foundation
suite tests aliases in the in-process composition; it does not cover this public
retained-owner case. Until corrected, launch ordinary `bee`, open Terminal from
Start, and run the installed program there.

The missing behavior needs an owner-authorized launch operation over the existing
Hive desktop contract. Resolve command names at the owner using the existing
`bee.applications:command` resolver and admitted catalog; preserve literal arguments
and fullscreen metadata. The current desktop wire operations are list, attach,
detach and copy only. Do not add a second command-name table to native code or
bypass the broker. Admission, duplicate/retry behavior, controller exclusion and
uncertain outcomes need acceptance before exposing the route.

Implementation has begun with the internal `bee.launch:retained_protocol.launch`
decoder. It requires matching workspace/desktop identities, a bounded request
and recipient, a command token and an explicit argument vector. It copies values
and uses the existing application argument bounds. Production strict lint and
all seven retained-protocol cases pass (`/tmp/bee-launch-envelope-check.log`).
This is not a public operation: controller validation, client/broker request and
reply wiring, native launch routing and actual retained-owner alias acceptance
are still required. The installed executable and its frozen source are unchanged;
this new decoder is work in progress in the shared source/checkpoint.

The internal launch path now reaches the existing retained client and broker.
The core supervisor accepts `bee.retained.launch` only from its retained owner
and only for the current controller; one launch may be pending. The client
accepts `bee.client.launch` only from its supervisor, resolves the admitted
command catalog, and forwards literal arguments to the existing host open
operation. It applies fullscreen metadata and returns the broker's view/instance
identities before rewriting IDs for the presenter. Enqueue alone is not success.
The reply decoder rejects successful results without identities and failures
that pretend to carry successful identities.

Production lint, eight protocol cases, and the actual retained-supervisor fixture
pass from source and pack. The fixture proves forged-sender rejection, observer
and retired-controller denial, unknown-command refusal, literal shell-looking
arguments and a successful broker identity while preserving the original shell
through detach/rejoin. Logs: `/tmp/bee-launch-result-check.log` and
`/tmp/bee-retained-launch-core-verified.log`. An initial observer fixture wrongly
used the supervisor's already-monitored parent; it was replaced with a distinct
physical display actor, preserving the monitor contract. Hive wire admission,
receipt/deadline handling and native CLI routing still need integration; global
`bee terminal` is not fixed or rebuilt by this internal checkpoint.

## Installed command routing acceptance

The installed candidate at `/tmp/bee-command-launch-candidate` uses native
checkpoint `a36ac552880d` and source checkpoint `689e3b0`, with the same runtime
and builder pins. Its SHA256 is
`f5063813d7a82ffc84a6753953220174d1f4dd53b07b0cdaefe245ee746cb40a`.
Frozen source is `/tmp/bee-command-candidate-nqwpkmi3`.

Named commands now attach as a controller and submit one launch through the
retained owner's existing desktop contract. The owner resolves its admitted
command catalog; the detached owner child receives no startup command arguments.
Explicit qualified application IDs and `--base` retain their existing routes.
Installing this client cannot add the operation to an older running owner.

Verified on the assembled candidate:

- The full native-client gate, including cold/warm command launches, clipboard,
  stalled-owner exit, delayed startup and native-departure crash/rejoin:
  `/tmp/bee-command-native-client-check.log` (warm attachment 0.216 seconds).
- The standalone Settings, Terminal, scrolling, selection/copy, fullscreen
  Claude/Codex/Agy aliases, literal arguments, F12 and retained rejoin:
  `/tmp/bee-command-native-binary-check-r2.log`.
- Explicit `--command bee run terminal`, unknown-command refusal and rejoin to
  the surviving Terminal: `/tmp/bee-command-explicit-refusal-check.log`.
- Native mesh authorization, command refusal and deadline-bound replay returning
  the same broker identities: `/tmp/bee-launch-replay-owner-check.log`.

The first foundation run stopped at a missing declaration of the desktop
protocol's shared argument decoder in the architecture audit. The exact interface
is now admitted under the existing transitive purity check; source and pack pass
at 517 entries. The first standalone alias check expected whole-workspace quit;
it now checks detach and retained rejoin and cleans up its disposable owner.
Both fixes are test-only. These failures remain recorded in
`/tmp/bee-command-foundation-check.log` and
`/tmp/bee-command-native-binary-check.log`.

The uninterrupted full foundation rerun completed with exit 0 (session 4024):
484 Lua tests, 517 source/pack entries, storage/subscription restart, all desktop,
client, launcher, recovery and bundled-app checks. The 16-window load test exited
in 367 ms. Evidence: `/tmp/bee-command-foundation-check-r2.log`.
All 365 production files matched the frozen source before atomic installation.
The installed executable also passed isolated cold/warm command launch, literal
arguments, retained rejoin and F12: `/tmp/bee-global-command-install-check.log`.
The user's existing owner and applications were not restarted.

## Installed responsive Hive Manager update

Checkpoint `ad23c45` draws local supervisor/membership state before per-node
queries, then runs directory calls in one asynchronous worker. This preserves the
Hive client's single reply listener and keeps UI input and close responsive.
Source and pack regression tests inject an eight-second directory delay; this is
a test-only stall, not a production discovery timeout. Both pass. The candidate
also includes selected desktop-record bootstrap and per-record writer reservations;
public allocation and multiple-display selection remain unimplemented.

Binary `/tmp/bee-responsive-hive-candidate-final` has SHA256
`53c7ce500d06546cbf44df6656dc6aee308374bb06de2da2a4d39634d76af1d0`.
Native client and binary suites pass (`/tmp/bee-responsive-hive-standalone-check.log`).
A real Start-menu launch shows Hive Manager in 1.229 seconds, with physical detach
in 0.108 seconds (`/tmp/bee-responsive-hive-native-smoke.log`). The full foundation
check passed in `/tmp/bee-responsive-hive-foundation-check.log` (terminal exit 0,
session 9154): 485 Lua tests, 517 source/pack entries, storage and populated-store
upgrade, client/desktop source-and-pack checks, recovery and all bundled apps.
The 16-window load case exited in 0.336 seconds.

The candidate is installed globally and the user’s Bee was restarted under their
explicit restart authorization. The actual desktop appeared in 1.323 seconds and
detached in 0.124 seconds, preserving the workspace databases. Evidence:
`/tmp/bee-responsive-hive-global-install.log`. The installed binary’s isolated
Start-menu test opened Hive Manager in 1.030 seconds and detached in 0.088 seconds
(`/tmp/bee-responsive-hive-global-smoke.log`). The actual user-state warm reconnect
also passed (`/tmp/bee-responsive-hive-user-reconnect.log`).

The user subsequently reported another rejected viewport followed by detach
uncertainty on the installed binary. A display probe then remained at Connecting
without receiving a frame. Under the user's explicit authorization to restart
Bee, the running node was stopped and restarted with its databases preserved.
The actual user desktop appeared in 1.389 seconds and detached in 0.109 seconds
(`/tmp/bee-user-node-recovery-r2.log`). This restores access but does not establish
the cause of the recurring failure. The fresh-candidate tests above do not prove
that this retained-node failure is fixed. Refer to the user-visible topology as
Bees in a Hive; "owner" in implementation contracts denotes state authority, not
another service the user should manage.

`make native-client-retention-check BEE_BINARY=/path/to/bee` now reproduces the
idle-reconnect scenario in disposable state: eight graceful detach/rejoins with
20-second gaps, preserving one live Terminal and enforcing bounded detach. It
passes against the candidate (`/tmp/bee-native-client-retention-check.log`), with
reconnects between 0.106 and 0.229 seconds. This roughly three-minute probe does
not establish long-running or network-loss recovery. The earlier one-off probe
also passed (`/tmp/bee-retained-reconnect-soak.log`).

## Membership presentation update installed

The installed Hive Manager separates native MEMBERSHIP from BEE SERVICE readiness;
Raft role is only in Details. Native presence alone does not establish a Bee
supervisor route or grant authority. The standalone suites pass in
`/tmp/bee-membership-standalone-check.log`; the app smoke shows the new columns
in `/tmp/bee-membership-candidate-hive-smoke.log` (first frame1.542s, detach0.168s).
Authorized restart preserved the user stores: frame1.398s, detach0.109s,
retained Bee PID839818, `/tmp/bee-membership-global-install.log`. Warm reconnect
is recorded in `/tmp/bee-membership-user-reconnect.log`.

The full frozen-source check completed as session69756, exit 0, with output in
`/tmp/bee-membership-foundation-check.log`: 486 Lua tests and 517 source/pack entries.
The separate-runtime physical SIGKILL proof passes within the existing
node-departure window (`/tmp/bee-mesh-physical-crash-proof-r3.log`); a five-second
cleanup bound still fails. Same-name/new-port rejoin and the user's intermittent
mount/connection failure remain unresolved. No runtime changes were made.

## Public observation installed

`bee observe` adds a read-only physical presentation of the running local Bee.
It uses the existing supervisor admission and native observation mount. It
cannot type into or resize the shared desktop; Ctrl+Q/Ctrl+] detaches only this
view. With no Bee running it refuses promptly, without creating an owner or
opening databases. Application-launch arguments are refused. This is a shared
layout, not independent workspaces or public remote enrollment.

Native launch race/vet passes (`/tmp/bee-observe-launch-check.log`). The built
executable passes the public observer proof plus the complete native client and
binary suites (`/tmp/bee-observe-public-check.log`,
`/tmp/bee-observe-standalone-check.log`, session97094 exit 0). The new client also
joined the existing user Bee in0.219s and detached in0.085s. The global binary was
replaced atomically without restarting PID839818 or its applications. Its `/proc`
executable therefore still refers to the preceding binary image; this is expected.
Installed smoke: `/tmp/bee-observe-installed-check.log`.

The same Lua source's full foundation run69756 passed (exit 0). All 365 production
files match the observer build. Native changes
are limited to selecting the existing observer mode and refusing observer startup
when the state lock is free; runtime674b58a1 is unchanged.

## Uninstalled window-retirement candidate

`/tmp/bee-retirement-global-candidate` was built from source089e1c2 with the same
native/runtime pins. SHA256:
`d65ff9000d0949f5e6a5bf17d551ba886e243ad1d95890f08d1d177c7d224632`.
It adds the protected desktop storage operations and retires a removed window's
attachment/error even when removal arrives through its committed scene alone.
Source/pack regression and the original Process Manager check pass. Native client
and binary suites also pass (`/tmp/bee-retirement-standalone-check.log`, session6869).
The combined full run38854 is still active in
`/tmp/bee-desktop-authority-foundation-check.log`; the candidate is not installed.
The earlier catalog-only run57240 failed on the stale Settings error; that evidence
remains in `/tmp/bee-desktop-catalog-foundation-check.log`.
