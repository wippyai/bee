# Runtime base needed by the native Bee client

Runtime changes go through PRs only. Do not push to main, merge PRs, or ship Bee
against a temporary worktree. After reviewed fixes land and a main-based runtime
release is available, pin that release through Bee's normal builder and repeat
local launch, remote Terminal and crash/rejoin acceptance.

## Current integration correction (2026-09-09)

The inventory below preserves earlier experiments and evidence. Bee no longer
requires Lua `Message:ingress()` or connection handles: supervisor admission
uses native sender identity, established peer identity and destination policy.
PR #711 is therefore not a Bee Lua prerequisite. Remote-monitor PR #716 remains
paused for the cluster lane's ownership review; do not resume its semantics from
the older proposal below.

Runtime #718 implements receiver-local typed listeners for decoded v1 maps,
with Go-Lua #44 supplying inference. Runtime #717 now correctly declares Future
completion as nonoptional `Channel<unknown>`. All target main and are assigned
to Rodrigo (`skhaz`). The temporary Bee validation runtime at `beb5c014a1`
combines those changes with the existing #702 pack command-host fix. Strict
production/test lint, source/pack host restart and source/pack desktop-client
acceptance pass on that candidate. Full foundation validation is still running;
release pins and the global executable are unchanged. See
[the current status gates](STATUS_RUNTIME_GATE.md).

Source provenance is a separate unresolved native release gate. Current main's
`cluster/internode/internode.go` decodes then delivers the package without binding
`Source.Node` to the authenticated callback peer. Historical `944736c999` even
tests that differing transitive sources survive. The earlier Bee
`runtime/patches/actor-provenance.patch` enforced direct source provenance; it is
absent from the new patch-free candidate. The cluster lane owns the universal
routing guarantee and any explicit external-peer delegation semantics. Bee
supervisors send as themselves. Do not restore Lua ingress/connection handles,
or treat successful trusted-peer fixtures as proof against source impersonation.

## Candidate versus main

Audit on 2026-09-09 against runtime main `fdad09cef2`. The tested candidate is
`944736c999`. These commits are outside main by ancestry; this is an integration
inventory, not proof that every commit needs its own PR or that equivalent work
has not landed elsewhere. Check patch equivalence and existing ownership before
opening additional PRs. In particular, the metrics fix has existing PR #690.

```
5c24317b5a Expose terminal input events independently of actor scheduling
85736d0524 Add native launch preparation before application state is opened
e3aee1a13c Allow admitted client attachment when application state is owned
31e4345e10 Retain automatic mesh listeners through startup and cleanup
3b9620ee31 Accept host-approved peer keys for new mesh handshakes
1b81a3d817 fix(metrics): exclude in-flight sends before collector shutdown
7334244f75 Expose native surface transport for compiled client assembly
7c999b9659 Assert surviving row repaint in Lua surface shrink check
8c2b982548 Integrate cancellable native mesh control admission
3982711303 Carry native ingress identity and connection lifetime to receivers
e43ed241b3 Expose native mutual TLS configuration in compiled cluster stacks
ef22d02d4e Consume native socket-first TLS shutdown for client integration
ff98884382 Select native internode TLS through normal cluster boot configuration
4c6675c68d Prepare native owner resources under the application state lock
9663ea8263 End native cluster admission when its execution context is canceled
819c859f15 Preserve command lifetime and clean up failed runtime startup
14ae99cebe Preserve native ingress evidence through Lua message delivery
699597ef70 Honor explicit command host for pack launches
944736c999 Isolate blocking terminal reads and bound dispatcher admission
```

The terminal dispatcher fix has been isolated directly on main as `1926243b1c`
on branch `fix/tty-blocked-read-isolation`. All terminal packages pass race tests
and vet there. The broader physical Bee acceptance used the combined candidate;
it must be repeated after the main-based release cutover.

## Behavioral gates beyond this inventory

- Remote actor EXIT while its native transport stays alive: currently failing.
- Native enrollment evidence for destination-owned dynamic client admission:
  awaiting a reviewed consumable checkpoint.
- Same-name immediate restart at a different automatic port: native membership
  conflict reproduced. Physical clients normally get fresh identities; their
  explicitly pre-enrolled fresh-identity LAN crash/rejoin proof passes.
- Full foundation check against a coherent frozen snapshot: session20832 failed
  on 13 Inbox fixture type errors; production lint passed. See
  `/tmp/bee-ui-fixture-errors.txt`. Separate `make pack desktop-check` session11731 passed on the frozen
  `/tmp/bee-foundation-verified-20260909-8yoe13c_` snapshot. This does not supersede
  the full-check failure.

Two remaining behavioral gates never meant only two unmerged commits. Public
launcher activation also remains Bee work after runtime integration. Journal
`Bee Harness` is the coordination authority; do not copy the primary runtime
owner's large dirty cluster worktree to manufacture a release candidate.

The pack command-host slice is independently adapted to main as `6c335d88a5`
(`fix/pack-command-host`). Both pack paths preserve explicit CLI host selection.
Regression test fails with original fallback behavior and passes with the fix;
pack/command-launch race tests and CLI vet pass. Candidate commit699597ef70's
unrelated startup/shutdown ancestry is not part of this isolated slice.

## Additional existing graphics PRs

Graphics stack (all draft/open at inspection): #692 native PNG resources, #693
Lua handles and physical Kitty presentation, #697 authorized remote capture and
image transfer. Dependencies are #692 → #693 → #697; Rodrigo is already assigned.
These are not commits in the client candidate inventory above. Do not duplicate
them. Child PTY Kitty/Sixel ingestion, Bee composition and combined raster
screenshots remain outside their implemented scope. PR descriptions report test
results; final main-based acceptance remains required after integration.

Launch admission is draft PR #703 (`248446506a`), directly on main, assigned to
Rodrigo. Application race tests and vet pass. The bundled event-stream default
was removed from this isolated PR. Draft status reflects the command startup
cleanup dependency still being isolated, not an implemented public Bee launcher.

Command lifecycle cleanup is PR #704, main-based `d644cf9b75`, assigned to Rodrigo.
Boot/command race tests and vet pass. It preserves caller lifetime through boot,
stops loaded components on startup failure, and performs command cleanup once.
Review/integration of #704 is required before promoting owner activation in #703.

Terminal event input is PR #705 (`1bbf7693d8`), assigned Rodrigo, directly on main.
It exposes the sink reader and per-session Done/Err while preserving the scheduler
adapter. Terminal race suites and full repository lint pass. Graphics #693 also
changes this file for capability probing; integration must preserve both features
and rerun input and graphics acceptance. No launcher event-stream default change
is included in this API PR.

Native surface transport is PR #706 (`8b9d93886a`), directly on main, assigned
Rodrigo. Boot and compiled clients reuse the same adapter. It now tracks successful
receiver admission and releases once; failed duplicate cleanup and retired cleanup
cannot clear a replacement. Native host code must not directly replace that class
behind the adapter. Already-dispatched callbacks remain TTY-service-fenced. Internode,
boot and TTY race suites, 50 concurrent cleanup repetitions and full lint pass.

## Remaining candidate groups after PR706

| Group | Candidate commits | Existing PR scope / remaining work |
|---|---|---|
| Automatic listeners | 31e4345e10 | Draft #708; CI convergence failure and isolated metrics race under investigation |
| Host-approved peer keys | 3b9620ee31 | Draft #709 stacked on #708; convergence failure under investigation |
| Cancellable mesh control admission | 8c2b982548 | PR #710 directly on main; race suites and lint pass |
| Native source provenance | 3982711303, 14ae99cebe | PR #711 ready for review, with existing #675 prerequisite; Bee uses the runtime sender rather than ingress evidence or Lua API |
| Compiled/normal-boot TLS and admission expiry | e43ed241b3, ff98884382, 9663ea8263 | PR #712 stacked on #708; full race suites and lint pass |
| Socket-first TLS shutdown | ef22d02d4e | #675 is a different closed-before-Run race; it does not cover this slice |
| Metrics cleanup | 1b81a3d817 | Existing #690; do not duplicate |

PR685 is local topology bookkeeping, explicitly excluding acknowledged remote
monitor installation and distributed incarnation fencing. It does not establish
Bee's remote actor-EXIT acceptance gate. Neither similar titles nor passing
transport tests substitute for the exact behavior required by the consumer.

Socket-first TLS teardown is now PR #707 (`004374b479`), assigned Rodrigo,
directly on main. Real mutual-TLS no-peer-read close/rejection tests pass;
full internode race suite and full lint pass. It complements #675 rather than
replacing its close-before-Run fix. No TLS verification bypass or Bee sidecar.

Automatic listeners are PR #708 (`b42c22f42d`), directly on main, assigned
Rodrigo. Full cluster, internode and system boot race suites and full lint pass.
Start retains the real sockets and advertises their assigned endpoints. Compiled
StackConfig zero ports now request OS allocation; explicit ports and normal boot
defaults are preserved. Twenty concurrent authenticated loopback stacks pass.
This does not prove enrollment, LAN discovery or same-name crash rejoin.

Host-approved peer keys are draft PR #709 (`755faad98d`), assigned Rodrigo,
stacked on #708. Full lint and internode/system boot race suites pass. Initial
full cluster race hit a twenty-node convergence timeout; three focused repetitions
pass on both parent and child, which does not resolve the intermittent failure.
The draft records that limit. Failure diagnostics are now in #708. Static pins
remain authoritative; dynamic approval affects new handshakes only.

Cancellable admission is PR #710 (`cbce0f9896`), directly on main, assigned
Rodrigo. Full internode/relay race suites and full lint pass. Rejected messages
remain caller-owned; successful queue admission is not remote delivery. Codec
execution is still synchronous. Preserve registration wakeups alongside #673
when integrating its idempotent registration changes. Native ingress, Lua ingress
evidence and boot TLS/cancellation remain separate candidate groups.

Native relay/Lua ingress is PR #711 (`4adafbef9f`), assigned Rodrigo and ready
for review. Prepared on current main with the existing #675 prerequisite and
its regression reused. Full relay API, internode, engine and process-module race
suites pass, as do strict native type tests and full lint. Registered class
receivers retain their existing interface; this proof covers actor messages.
PR #707 separately bounds socket teardown. Preserve #710 and ingress callbacks
when integrating their overlapping manager changes.

Native TLS configuration and boot admission lifetime are PR #712 (`72f03ff598`),
assigned Rodrigo, stacked on #708. Full cluster/system boot race suites and lint
pass. Malformed explicit TLS root values now fail instead of silently selecting
plaintext; the regression was red before the fix. The isolated two-stack proof
uses existing relay Send and verifies received content; it does not depend on
#710/#711 merely for test assertions. Preserve separate socket teardown #707.

All candidate commits listed above now have a PR mapping. This is not release
readiness: #703 and #709 remain drafts, the remote actor EXIT gate is unresolved,
and destination enrollment/public launcher acceptance and combined main-based
runtime cutover remain required. No runtime PR has been merged by this lane.

## CI and combined prerequisite follow-up

GitHub checks completed successfully for #701, #702, #705, #706 and #707.
CI lint findings in #703/#704 were corrected at `e348909100`/`3933abd56b`;
local full lint and application/cleanup race checks pass, new CI runs pending.

#708 is now draft: Ubuntu CI reproduced the twenty-node convergence timeout.
The peer-key callback is absent there, so #709 is not its unique cause. A
constrained five-run test on #708 also reproduced the existing metrics shutdown
race covered by #690. Keep both failures visible. A local integration tree at
`/tmp/wippy-client-pr-integration-20260909` combines only #708 and existing
#673/#675/#690 commits; five constrained race repetitions pass (69.551s). This
is combined evidence, not proof that a particular prerequisite fixes convergence
or that the isolated #708 branch is ready. No timeout was relaxed.

## Remote monitor diagnosis

The native monitor request currently reaches ordinary actor delivery instead of
the production topology owner; generic remote handlers exist only in test code.
The proposed fix is still unvalidated at
`/tmp/wippy-topology-ingress-prototype-20260909` (base `944736c999`). Do not
cherry-pick it: handler lifetime, mixed-package ownership, strict complete
validation, payload integrity, local-only boot independence and compiled-client
composition need correction. The tested candidate tree was restored clean at
`944736c999`; its binary SHA256 is unchanged. No monitor PR is ready yet.

## Combined race evidence and monitor authorization refinement

The integration tree at `ad6dd713ec` completed the full cluster, internode and
metrics race suites: 12.191s, 8.061s and 2.046s respectively. The log is
`/tmp/wippy-client-pr-integration-full.log`. The isolated #708 Ubuntu failure
still stands; combined success does not identify its cause or make #708 ready.

The remote monitor boundary needs target-owner authorization in addition to
transport identity. The design below is a proposal, not a callable API:

- Use a dedicated native relay host for topology control, composed explicitly
  in normal boot and compiled clients. Leave local-only topology independent of
  cluster startup. Do not reuse `node:control`, which already owns supervision.
- The target owner authorizes the exact remote actor, local actor, operation and
  lifetime. Enrollment or a dynamic peer-key lookup cannot grant ambient monitor
  rights. Bee admission conveys the grant; the presenter cannot mint it.
- Require authenticated, integrity-protected, live immediate-peer ingress. Match
  the envelope source to the control caller and that caller's node to ingress.
  Validate the entire bounded package before mutating topology; reject mixed
  application/control packages. The wire version and grant format remain open.
- Tie inbound relations to the exact connection and grant. Admission, revocation
  and teardown must serialize so a late frame cannot reinstall a retired monitor.
  Reconnection requires a fresh authorized relationship.
- Distinguish queued from installed using correlated owner receipts. A lost
  receipt is uncertain. Any retry needs bounded receiver idempotency. Authorized
  missing targets produce a terminal result; unauthorized requests must not
  reveal target existence. Preserve the actual target identity in EXIT evidence.
- Remote links require bilateral failure-coupling authorization and reconciliation;
  do not accidentally enable them by implementing one-way monitoring.
- Registration must have owned teardown: a failed duplicate or stale binding
  cannot unregister a replacement. The current unconditional UnregisterHost is
  insufficient if independent replacement is allowed.

Acceptance must cover missing targets, target exit during installation, lost
receipts, denied grants, expired/revoked grants, connection-close races, duplicate
binding teardown and actual actor EXIT while the peer node stays connected.
Existing local monitor tests and a transport FIFO barrier do not prove this.

The rejected-delivery ownership prerequisite is runtime PR #714 (`dad1070bbf`),
assigned Rodrigo, directly on main. A rejected incoming package now releases its
messages and retention leases; successful delivery still transfers ownership to
the receiver. The rejection regression failed before the fix. Full internode
race suite passes (8.576s), full repository lint reports zero issues and the
publish credential test passes. The main baseline field-order lint correction
is included without changing test behavior. Initial lint disk exhaustion was
resolved by clearing 6.01 GiB of old generated Go cache objects. No monitor
protocol is implemented by this PR. GitHub CI has not yet been verified.

Current CI refresh: #703 checks are all green but it remains draft for combined
launch/cleanup acceptance. #704 has a failed native Wippy Lua application check;
its other checks passed. The failure is under investigation, not waived.

## Full composition cleanup acceptance

Runtime #704 now has head `4dbd7c737c` and remains assigned to Rodrigo. A new
combined #703/#704 application.Run probe exposed nil-cancel panics when cleanup
stopped WebSocket, security, store and event dispatchers after Load but before
Start. Their Stop paths now tolerate that boot state. The bootstrap regression
fails only after every StandardComponents entry loads; the public Stop contract
now documents the requirement. Full race suites pass for all four dispatchers,
commands and boot; full repository lint reports zero issues.

The combined tree `/tmp/wippy-launch-cleanup-integration-20260909`, committed at
`70064f81d6`, retains the application.Run proof. It verifies runtime Stop before
owner Close, both under the application lock, then successful lock acquisition
after failure. Its focused race run passes (1.191s). This is runtime integration
evidence, not ordinary Bee launch acceptance. The integration commit is local;
all production changes are in #703/#704.

#704 was converted to draft. Its earlier CI failure was a separate 10-second
startup-event timeout in `app.test.registry:generation_drain` (391/392 passed),
not the cleanup panic. Other inspected PR/main runs passed; that does not prove
the cause. The failure is preserved in `/tmp/wippy-cleanup-native-ci-failed.log`.
No timeout was increased. New-head GitHub checks remain pending.

## Owned native host registration

Runtime PR #715 (`12c471667d`), assigned Rodrigo, adds the optional
`relay.OwnedHostRegistrar` with
`RegisterOwnedHost(pid.HostID, Receiver) (context.CancelFunc, error)`.
The concrete node stores a unique registration identity and removes it by
CompareAndDelete. Duplicate failure returns no release handle. A stale or repeated
release cannot remove a replacement, including one reusing the same receiver.
Existing Node implementations need no new method; original receiver capabilities
remain visible through GetHost, SendContext and Attach. Release does not drain
already-dispatched calls or authorize remote operations. A topology receiver must
close its own admission before release and retire its own relations afterward.

Full relay, topology, system boot-component and relay API races pass, as do full
repository lint and the publish credential check. Independent read-only review
found no correctness issue. The registration primitive is implemented; the native
monitor protocol and compiled-client integration remain pending. GitHub CI for
#715 is not yet verified.

PR #714 now includes the known surviving-row repaint test correction at
`a5b05370da`: its Ubuntu failure was the baseline terminal shrink expectation,
not the incoming-package fix. The focused terminal race check passes; new-head
CI remains pending. #704's latest native Lua CI passed; the earlier generation
startup-event timeout remains unexplained and is not erased by that pass.

## Authorized monitor admission draft

Runtime draft PR #716 (`0f14ff2470`), assigned Rodrigo and stacked on #711,
adds `system/topology/remote`: bounded host-owned monitor grants and strict
version-1 admission/release controls. A grant names one peer, watcher, local
target and expiry, then binds to one protected connection. Lease.Use is the
required mutation gate. Close fences new admission and all concurrent callers
wait for admitted callbacks; panics release the gate. Done follows capacity
reclamation. No wildcard/link authority is present.

Control decoding validates the complete one-message package, canonical actor
identities, exact envelope source/destination, protected live ingress, canonical
request/grant encodings and JSON field uniqueness. Tests roundtrip the actual
internode codec and prove that another actor on the same authenticated peer is
still denied by the grant. Remote/topology race suites and full lint pass;
authority focused tests also pass twenty repetitions. Control fuzzing passed
71,948 executions in 11.289s. Root review corrections are preserved in tests.

This remains a draft implementation boundary, not repaired remote monitoring.
Native receiver/receipt state, verified EXIT/result forwarding, Lua grant use,
boot composition and compiled client integration remain to build in this lane.
The runtime README names those requirements. #715 supplies owned registration;
#714 supplies rejected-package release. No Bee manifest or global binary was
changed. #704 now has all GitHub checks green; its prior generation startup-event
timeout remains recorded and unexplained.
