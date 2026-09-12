# Agent integration checkpoint — September 11

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
