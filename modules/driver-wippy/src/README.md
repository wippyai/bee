# Bee Wippy Driver

Native in-process agent harness driver for Wippy.

Runs a framework `agent.gen1` closure (resolved by `bee.harness.launch:agent_resolver`)
in-process with its traits, tools, and contracts, against an OpenAI-compatible chat
completions endpoint chosen by host config (no provider or key baked in; key by
credential reference).

`bee.driver.wippy:run` is the harness's in-process execution adapter. The harness
owns the carrier claim and checkpoint, terminal receipt, status, wait and
durable cancel intent; this package owns the provider conversation, tool calls
and inbox delivery as new turns. The adapter receives an admitted
`thread_id`, `action_id` and `attempt_id`, so its carrier records and terminal
receipt use the same thread owner as other managed runs. Tool calls use a
fresh per-attempt actor narrowed to the tool's declared scopes.

## Host configuration

`bee.driver.wippy:run` accepts `host_config`, defaulting to the
`bee.driver.wippy:host_config` registry entry. Fields:

- `endpoint`: https URL, or plain http only for the 127.0.0.1 loopback fixture.
- `credential_ref`: registry reference for the chat key. An unresolvable
  reference fails the run; the reference string is never sent as the key,
  and the key never enters logs or errors.
- `model`: host-selected model identifier, mapped from the agent model.
- `timeout_ms`: clamped to 1s..120s.
- `stream`: consume server-sent events when true.
- `admitted_delegates`: host-admitted agent delegates. The agent definition
  never admits its own delegates.
- `max_turns`: 1..16, default 16.

The native route admits agent memory and refuses every trait behavior,
contract, wrapper, hook, option or delegate capability it cannot prove.
Tools run under a fresh per-attempt actor narrowed to the tool's own
declared scopes; any narrowing failure denies the call. The shared lifecycle
fences carrier commits by epoch and revision and checks each commit: a conflict
fails the run instead of continuing unfenced.

Placement `prepare` and `dispatch` are refused: the driver executes
in-process through `bee.driver.wippy:run` and describes no launch binary.
