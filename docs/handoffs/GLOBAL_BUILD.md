# Global Bee candidate — September 10, 2026

The installed executable is a development candidate built from the frozen source
at `/tmp/bee-global-final-crjl7na9`. The functional source checkpoint is `18caf09`
on `checkpoint/global-bee-candidate-20260910`. No runtime PR or main merge was
performed for the latest Bee-only link-loss fix.

- Runtime: `674b58a1a117fa79398f723c4311201cca8472e1`.
- Native Bee: `d4b427d90a2e`, `checkpoint/native-client-binding-20260910`.
- Builder: `70acb10175fbeb42a3a4d382677715a0c2a969e4`.
- Installed executable: `/home/wolfy-j/.local/bin/bee`.
- Build output: `/tmp/bee-startup-responsive`.
- SHA256: `c8847373cfa079a2835e2c567376bb2b7ae25273f80813e817aec6739d8d077a`.
- Rollback: `/home/wolfy-j/.local/bin/bee.rollback-20260910T153642Z`.

## Launch and ownership

Run `bee` normally. It loads embedded code with shared registry history and
starts or authenticates the same-state owner through the native mesh. Ctrl+Q and
Ctrl+] detach the physical client while retaining the owner and applications.
A busy application-state lock routes to authenticated attachment; it grants no
access. If the owner is still preparing discovery, the client waits cancellably
for publication before authenticating. Warm launch creates no owner contender or
additional owner log. Cold startup still captures output in `owner-*.log`.

Installing a new executable does not hot-replace an already-running owner. The
user's older owner and its apps have not been stopped. An older owner's failure
cannot be repaired merely by launching a newer client against it.

Explicit `--base` remains a recovery mode. The embedded-default deployment policy
is in runtime PR #726, stacked on #703 and assigned to Rodrigo (`skhaz`); the
candidate does not yet consume a released runtime main revision.

## Verified behavior and limits

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

## Retained-owner command alias gap

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
