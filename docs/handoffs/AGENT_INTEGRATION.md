# Agent integration checkpoint — September 11

Source checkpoint `586956d` combines the native Agent picker, host-defined
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

The combined source passes 581 Lua tests and the managed-window fixture passes
all three cases. The fixture now explicitly binds `/bin/sh`; production
executable checks remain intact. Packing, architecture, module isolation,
storage/restart, gateway and source/pack desktop checks have passing evidence
in segments on the same production source.

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

Governed authoring and claimed-hook recovery are separate integration branches
under review. Authoring stages caller-owned database content; it grants no
registry publication or overlay activation. Higher service authority stays
inside host-selected owners. User/agent calls require exact resource scopes;
app state, traits and overlay metadata cannot select a stronger authority.

The global executable has not been replaced. Actual standalone testing still
finds the runtime's default state under the shared user directory instead of
the selected project directory. Runtime #726 and builder #7 remain open on the
same tested heads, assigned to Rodrigo. The executable-selected default must
be resolved before locking, with explicit `--state-dir` taking precedence.
Public MCP additionally needs the existing HTTP service's OS-assigned endpoint
and readiness contract. See [runtime cutover](RUNTIME_MAIN_CUTOVER.md).
