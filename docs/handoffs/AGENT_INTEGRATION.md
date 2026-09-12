# Agent integration checkpoint — September 12

Launch readmission is now implemented in `fa50d4d`. Its typed continuation
references retain the original action/thread/session while current owner reads
and fresh resource grants admit a new attempt. An empty brief prevents prompt
replay. All 626 Lua tests, 23 focused admission/continuation tests, harness
isolation and five managed-window cases pass. The broader foundation check is
still running in `recovery-admission-foundation.log`; no new full-pass claim is
made. The new admission fixture constructs placement completion explicitly and
does not prove native cleanup. The Agent app still declares no recovery schema.
See [the recovery handoff](NATIVE_AGENT_RECOVERY.md) for the native terminal
identity boundary and the possible Claude inline-configuration route.

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

Passive listing invokes no provider code. Selection checks the driver's
configuration before launch effects, and the displayed plan digest includes
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
