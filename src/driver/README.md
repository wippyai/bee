# bee.driver

The driver contract and everything a provider needs to implement it without
touching a process, a credential or a thread store. A driver returns
declarative launch and turn specifications and turns protocol envelopes into
thread observations; placement runs, carriers compose, the thread authority
commits.

## Slices

| Slice | Responsibility |
|---|---|
| `bee.driver` | Binding schema types, profile validation, strict activation/configuration decoding, and the `driver` contract (prepare, dispatch, normalize, configure) |
| `bee.driver.kit` | Pure helpers: JSONL framing with fragment carry-over and a byte bound, POSIX quoting, observation builders |
| `bee.driver.transport.stream_json` | Frames bytes into JSON envelopes for stream-json protocols |
| `bee.driver.claude`, `bee.driver.codex` | Provider bindings: profiles, launch specification, protocol normalization |

## Rules

The carrier validates every prepare/continuation launch reply before changing
its executable or resolving placement. It shares placement's bounded launch
decoder; malformed provider output is refused before executable measurement
or attempt admission. Driver replies are data, not trusted Lua type assertions.

`configure` receives only copied host-selected provider data, an optional
gateway section and the fixture flag. Its reply is either explicit no
configuration for a policy without a provider, or one nonempty, safe relative
private-home file with a lowercase SHA-256 digest over its content and the
selected provider identity. The shared decoder rejects unknown fields,
provider substitution and mismatched bytes. The trusted carrier resolves the
activated binding and provider from its pinned registry snapshot, then calls
`configure` under an empty scope. Placement independently renders and compares
the file while admitting intent. The protected host admission binding grants
scope management to the native harness application; ordinary applications
cannot enable it through metadata or launch arguments. Actor context remains
inherited, but the renderer has no placement, registry, executor or nested-call
permissions. A gateway extension
to provider configuration remains Codex-only until a generic driver hook
contract exists.

A normalizer never reports success from a process exit; only the protocol's
terminal event does. Answers come from the profile's declared answer path.
Everything a provider declares in `meta.driver` is decoded by
`bee.driver:profile` with exact shapes and conservative defaults; an unknown
field or an unsupported value rejects the binding.

## Testing

`make test` runs `tests/lua/driver`: profile validation, framing with
fragmented and oversized input, quoting, observation builders, and each
provider's normalizer against the captured fixtures under
`tests/fixtures/drivers/<harness>/<protocol_revision>/`.

## Codex authentication path

The Codex launch writes the brief to stdin and Codex reads it until end of
file, so the launch declares `stdin_eof`: placement admits it only where
the executor can close stdin (`close_stdin`, runtime PR 698), the runner
writes the complete input, closes stdin once and records
`stdin.accepted`, `stdin.closed` or `stdin.uncertain`, and later writes are
refused. The pinned executable does not take `OPENAI_API_KEY` from the
environment alone: it selects the API-key path only through a provider
configuration in the private `CODEX_HOME`. `bee.driver.codex:configuration`
renders that file from the host's `bee.codex_provider` entry named by the
launch policy (`provider_ref`): only the provider name, base URL,
model and optional `reasoning_effort` (`low`, `medium`, `high`, `xhigh` or
`max`), with `env_key = "OPENAI_API_KEY"` and the responses wire API, plain
http for the loopback fixture only; the plan digest pins the adapter
revision and the rendered digest, and placement writes it with exclusive
creation. `tests/lua/harness/codex_runner_test.lua` proves API-key
authentication-path selection through the runner with a sentinel key and a
controlled endpoint when `BEE_CODEX_BIN` names the executable;
`launch.CODEX_AUTHENTICATION` stays `unproven` until the pinned build
carries the runtime capabilities, and no real credential is enabled.

## Host-selected model options

Claude launch policies may set `model` and `effort` in `prepare_options`.
The Claude driver accepts only a bounded model identifier and the executable's
`low`, `medium`, `high`, `xhigh` or `max` effort values, then emits
`--model` and `--effort`. Codex keeps its model and optional reasoning effort
in the host-selected provider entry; its generated TOML emits only
`model_reasoning_effort` for the same five accepted values. The caller never
contributes either value: the carrier copies only the selected policy's
`prepare_options`, and provider configuration is rendered from the policy's
`provider_ref`.

## Claude authentication path

The Claude launch is settings-free: `claude -p <brief>` with the stream-json
output, no stdin protocol and no file in the private home. The API-key path
is selected by the environment alone: the launch policy's `environment`
carries the host-selected `ANTHROPIC_BASE_URL`, the credential broker
projects `ANTHROPIC_API_KEY`, and the runner's private `HOME` carries no
login state that could take precedence. `tests/lua/harness/claude_runner_test.lua`
proves the selection through the runner when `BEE_CLAUDE_BIN` names the
executable: the controlled endpoint records `x-api-key: <sentinel>` at
`/v1/messages` and answers 400, so the proof covers path selection only;
`launch.CLAUDE_AUTHENTICATION` stays `unproven` until the pinned build
runs it, and no real credential is enabled.

## Claude permission exchange

`bee.driver.claude:permission_adapter` is the captured control protocol
(`tests/fixtures/drivers/claude/stream-json-2/control.jsonl`). When the
host enables the exchange the carrier prepares with
`permission_exchange = true` and the launch changes shape: `--input-format
stream-json` with the brief as the first user line on stdin (canonically
encoded), `--permission-prompt-tool stdio --permission-prompts host`, and
stdin left open and `session_end = "stdin_close"` declared, so the carrier
ends the session by closing stdin after the turn is decided, with the
cooperative stop as the fallback; a close while a prompt is pending denies
it. The `-p <brief>` launch stays as it is when no exchange is enabled.

The launch builders also accept the reserved `window` profile for native
interactive command specifications. Empty prompts open the native UI; a supplied
prompt follows `--` so it cannot become a flag. Codex uses its native `resume`
subcommand and Claude its resume flag. Window launches have no structured stdin,
JSON output flags or stdin-EOF lifecycle. Claude rejects explicit structured-turn
limits and the stdio permission exchange for this profile.

`terminal:attached` means a terminal transport is attached, not that the provider
has accepted a turn or is ready for automated input. The production catalog does
not yet declare this profile compatible; the managed PTY owner and its acceptance
must land first. These are command specifications, not public window activation.

Claude's structured print command also places positional prompt text after `--`.
Previously a prompt such as `--version` was parsed as a CLI option. The real
native resume check now uses that literal prompt and still requires a completed
turn and retained conversation history. Stdio permission-exchange launches keep
their existing structured input encoding.

Launch specifications separate the executable from its arguments: `argv` never
contains the program name. The host may bind `executable` to a measured absolute
path; placement prepends that selected executable exactly once. A window with
an empty brief therefore supplies no prompt argument.
