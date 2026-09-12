# Agent integration checkpoint — September 12

Global has since been refreshed from source `97a9af2` at the user's request,
with unfinished backends accepted. Installed SHA starts `55b725aa`; see
[current global build](GLOBAL_BUILD.md) for upgrade/native evidence and the
remaining user-wide default-state limitation. Managed agents are not complete
end to end: drivers, native terminal views, configuration delivery and five-hook
thread integration are implemented, but first-use profile/credential setup,
production MCP activation, cold conversation recovery and Docker remain open.
The public Agent picker still has no default production launch profiles.
The authoring source completed full `make check` (session 43383,
`authoring-scoped-check.log`): 626 cases and all foundation/application gates
pass. This does not establish the unfinished managed-agent workflow.

Combined source `343eefa` includes driver configuration delivery and the Hive
fixture cleanup. Its standalone `bee-config-hive-reviewed` passes embedded boot,
Settings recovery, terminal input/scrolling/selection/copy, presenter rejoin and
the public empty Agent picker (detach 67 ms). SHA-256:
`a45e650d05e4ef9cc3bd4002bb0bc34de49ff1ec0a72c2b3e586284c6653abf8`.
All six combined Hive source/pack application cases and the failed-probe check
pass. Loading the 15 assembled release packs confirms 608 entries without test
or fixture registrations/references and without embedded assets. Evidence:
`config-hive-combined-{build,native,app}.log` and
`config-hive-combined-pack-audit.json` in the September 12 evidence directory.
The separate full configuration `make check` completed successfully (session
15767), including 629 unit cases, isolated hosts, storage/restart and all desktop
and application gates. The combined source passes 626 unit cases after removing
three fixture-only cases (session 78576, 209.2 seconds). These executable checks
do not establish an authenticated provider turn or cold conversation recovery.
That checkpoint was not installed; the later global refresh above supersedes
its installation hold while preserving the disclosed default-state limitation.

The required native-executable gate now fails when configured Codex lacks stdin
closure instead of returning a green non-execution. The unchanged dedicated
runner passes 268 cases with both real binaries and isolated provider endpoints
(`managed-executable-evidence-gate.log`, session 14910). A disposable forced
capability failure produces 267 passes and one specific configured-Codex failure,
and the runner rejects the missing required proof
(`managed-executable-evidence-counterfactual.log`). Ordinary no-binary unit
checks remain optional and must not be described as real-executable coverage.

Driver configuration delivery is being verified in a separate worktree. Each
driver owns its configuration format; placement validates and freezes that
delivery in its existing intent, and both terminal and headless launches consume
the same prepared arguments. All 629 unit cases pass with the real Claude and
Codex binaries selected. Strict lint, isolated harness and gateway checks,
native and managed windows, and HTTP hooks pass. The reviewed standalone
`bee-config-delivery-reviewed` passes executable acceptance, including embedded
boot, Settings recovery, terminal scrolling/selection, presenter rejoin and
the public empty Agent picker. Its SHA-256 is
`4e0ebdcfb15730f8fe2452769b079250e32392637dcd39ad8e380c287c0eeba7`.
The full foundation check completed successfully in
`config-delivery-reviewed-check.log` (session 15767).

Review removed the incomplete launch-side configure call: a driver requiring
placement's actual HOME now passes launch admission and renders at placement.
The regression fails with the old preflight and passes with the correction
(17 launch cases). Stored requests and private deliveries now pass their typed
decoders again before start; a corrupted delivery is refused without creating
a home or child (24 placement cases, with a failure on the old reader).
Codex rejects unsupported hook events explicitly. A separate probe holds the
same provider table across the real configure call and proves that native
argument isolation prevents the driver's mutation from reaching the caller;
no extra copying layer was added. See `config-delivery-launch-{original,fixed}`,
`config-delivery-persisted-{original,fixed}`, and
`config-delivery-reviewed-check` logs in the September 12 evidence directory.

The assembled-pack audit found an older production review fixture,
`bee.hive_manager:fixture`, among the 610 entries in 15 component packs. This
sample-node table must leave production with its test-only behavior; the live
default does not excuse shipping it. No embedded filesystem assets are selected.
Removal is committed separately as `ff90c03` and integrated as `1c8f002`.
Its final Go/Lua acceptance passes six source/pack application cases and an
explicit failing-probe check. Loading all 15 resulting component packs found
608 entries, no fixture/test registrations or test-library references, and no
embedded filesystem assets. Combined unit, Hive application and executable
acceptance now pass; this is not a claim of quality parity with Kickside.
Evidence: `hive-fixture-boundary-final.log`,
`hive-fixture-boundary-pack-audit.json`, `config-delivery-pack-audit.json` and
`config-delivery-{foundation,build}.log` in the September 12 evidence directory.
The global executable remains unchanged.

Launch readmission is now implemented in `fa50d4d`. Its typed continuation
references retain the original action/thread/session while current owner reads
and fresh resource grants admit a new attempt. An empty brief prevents prompt
replay. All 626 Lua tests, 23 focused admission/continuation tests, harness
isolation and five managed-window cases pass. The remaining foundation check
completed successfully in `recovery-admission-foundation.log` (session 66125,
exit 0). The new admission fixture constructs placement completion explicitly and
does not prove native cleanup. The Agent app still declares no recovery schema.
See [the recovery handoff](NATIVE_AGENT_RECOVERY.md) for the native terminal
identity boundary and driver-owned configuration delivery.

The latest component checkpoint adds exclusive retained session homes and
interactive continuation resolved from committed hook observations. Placement
uses its existing intent transaction to refuse a second unfinished attempt;
the carrier checks the predecessor, authenticated observation producer and
gateway binding before using the existing driver resume operation. Claude and
Codex reject option-like resume references. No additional store or manager is
introduced. The Agent app's saved-state and fresh-admission recovery wiring is
still pending.

Combined verification passed 625 Lua tests, harness isolation, five actual
managed-window cases and real window hook acceptance. The following producer
qualification change passed seven focused tests, with a counterfactual failure
when its guard was removed. The subsequent option-reference guard also passed
those seven tests. The final source `cf667d8` passes 18 focused continuation and
existing provider/configuration fixture tests with strict lint. Its standalone
passes embedded boot, Settings recovery, Terminal interaction, presenter rejoin
and the public empty Agent picker. The 15-component executable is
`bee-agent-components-final` in the evidence directory, SHA-256
`e9f38335e5b138a9433d2145f6b92ecce2c3341a59f2c5cf1ba48855ab623f98`.
Evidence: `interactive-continuation-integration.log`,
`interactive-continuation-producer-{original,fixed}.log`,
`interactive-continuation-option-boundary.log` and
`agent-components-native-binary.log`, `agent-components-provider-fixtures.log`
and `agent-components-final-{build,native}.log` in the September 12 evidence directory.
Global remains unchanged while per-project default state selection is gated.

## Earlier checkpoint acceptance

The current standalone candidate includes retained Agent homes and acknowledged
application checkpoints. The host launch definition selects the session
resource; separate launches keep separate homes. The broker exposes a new
resume value only after the workspace confirms persistence. Neither change
enables cold provider-conversation recovery yet.

On this source, all 620 Lua tests and five real managed-window cases pass,
along with strict lint and source/pack headless and two-workspace host checks.
The standalone build packages 15 components. Its executable checks pass embedded
boot, Settings recovery, Terminal, scrolling, selection/copy, aliases, literal
arguments, presenter rejoin and the public Agent picker. The picker still needs
host-defined profiles; this is not an authenticated provider-turn proof.

Global installation remains gated on executable-selected per-project state.
The runtime and builder PR heads remain unchanged. The remaining desktop
recipes pass, including client lifetimes, launcher/recovery and bundled apps.
The earlier lost control-delivery diagnostic remains unresolved, so there is
no new full-foundation pass claim. Evidence is under
`/home/wolfy-j/wippy/bee-evidence/0912/`, including
`checkpoint-native-binary.log`, `checkpoint-integration-remainder.log` and
`checkpoint-desktop-remainder.log`.

The earlier checkpoints below describe their own source and test runs.

The integration branch combines the native Agent picker, host-defined
profile preflight, measured provider configuration and stricter MCP argument
decoding. It runs the selected harness's own terminal UI. The host configuration
example is in [agent profiles](../../examples/agent-profiles/README.md); the
default composition still supplies no production launch definition or MCP
listener. Authenticated provider turns and public credential setup remain open.

Passive listing invokes no provider code. Placement checks the driver's
configuration before native execution intent, and the displayed plan digest includes
the provider entry. Codex instructions use its accepted `developer_instructions`
field with bounded, escaped TOML content. MCP read/wait rejects an explicitly
supplied non-object argument value and keeps the binding's thread scope.

## Verification

The current window follow-up passes 616 Lua tests and all three managed-window
tests. A real child submits duplicate hooks through its generated HTTP gateway
configuration. With the actual claim operation delayed three seconds, terminal
input remains responsive, one observation commits and is acknowledged, and
close returns only after the cancellation receipt is durable. Placement attachment
now precedes PTY open. Protected host admission selects the close allowance;
ordinary apps retain 250ms and force stop remains immediate. Full node shutdown
has its separate deadline and is not conversation-recovery acceptance.

The remaining foundation checks now pass, including storage/restart,
source/pack permissions and lifecycle, client detach/transfer/recovery, and
the bundled applications. These completed across the initial run and targeted
continuations after fixing two governance database path omissions in fixtures;
this is not a single uninterrupted `make check` run. Its first lint attempt
failed from the existing cache with five `expected tty.Viewport, got tty.Viewport`
errors; the cache and source were preserved before fresh strict lint passed
unchanged code. Evidence is in `/tmp/bee-window-close-*-20260911.log`, with the
completed desktop continuation in
`/tmp/bee-window-close-check-remainder-isolated-20260911.log`.

The combined authoring and gateway source passes 600 Lua tests. Earlier managed
window acceptance passed all three cases with an explicitly bound `/bin/sh`;
production executable checks remain intact. Source/pack headless checks pass.
The Go authoring restart probe proves immutable binary snapshots, durable retry
receipts, foreign-author denial and an unchanged migration ledger across two
actual boots. The focused gateway check proves a hook committed before revoke
can be replayed and acknowledged afterward with exactly one thread record.

Architecture tests and their Makefile gate have been removed at the user's
direction. Code review owns module-boundary assessment; behavioral tests cover
permissions, persistence and recovery.

The initial full continuation stopped because a packed core-delivery fault
exited without its expected error text in captured output. All five packed
fault cases passed on the focused rerun, along with command-failure and target
isolation checks. The remaining desktop recipes then passed, including retained
clients, launcher/recovery, Approvals, Hive Manager and Timeline. The original
missing diagnostic remains unexplained; this is not an uninterrupted clean
`make check`. The existing desktop-lifecycle fixpoint warning remains.

Evidence is retained under `/tmp/bee-agent-integrated-*-20260911.log`,
`/tmp/bee-control-delivery-diagnostic-20260911.log` and
`/tmp/bee-agent-desktop-remainder-20260911.log`.

## Remaining boundaries

Interactive provider conversation recovery must reuse the app checkpoint and
retained-session resource contracts; see [the next recovery unit](NATIVE_AGENT_RECOVERY.md).
Display reconnect already retains a running app. Cold restart of the same
native Agent conversation is not implemented.

Governed authoring and claimed-hook recovery are now integrated.
Authoring stages caller-owned database content; it grants no
registry publication or overlay activation. Higher service authority stays
inside host-selected owners. User/agent calls require exact resource scopes;
app state, traits and overlay metadata cannot select a stronger authority.
Even the stored author needs a current operation grant for the exact workspace;
read-only access cannot write or reach another workspace owned by that actor.

The global executable has not been replaced. Actual standalone testing still
finds the runtime's default state under the shared user directory instead of
the selected project directory. Runtime #726 and builder #7 remain open on the
same tested heads, assigned to Rodrigo. The executable-selected default must
be resolved before locking, with explicit `--state-dir` taking precedence.
Public MCP additionally needs the existing HTTP service's OS-assigned endpoint
and readiness contract. See [runtime cutover](RUNTIME_MAIN_CUTOVER.md).
