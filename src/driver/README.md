# bee.driver

The driver contract and everything a provider needs to implement it without
touching a process, a credential or a thread store. A driver returns
declarative launch and turn specifications and turns protocol envelopes into
thread observations; placement runs, carriers compose, the thread authority
commits.

## Slices

| Slice | Responsibility |
|---|---|
| `bee.driver` | Binding schema types, `meta.driver` profile validation, the `driver` contract (prepare, dispatch, normalize) |
| `bee.driver.kit` | Pure helpers: JSONL framing with fragment carry-over and a byte bound, POSIX quoting, observation builders |
| `bee.driver.transport.stream_json` | Frames bytes into JSON envelopes for stream-json protocols |
| `bee.driver.claude`, `bee.driver.codex` | Provider bindings: profiles, launch specification, protocol normalization |

## Rules

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
launch policy (`codex_provider_ref`): only the provider name, base URL and
model, with `env_key = "OPENAI_API_KEY"` and the responses wire API, plain
http for the loopback fixture only; the plan digest pins the adapter
revision and the rendered digest, and placement writes it with exclusive
creation. `tests/lua/harness/codex_runner_test.lua` proves API-key
authentication-path selection through the runner with a sentinel key and a
controlled endpoint when `BEE_CODEX_BIN` names the executable;
`launch.CODEX_AUTHENTICATION` stays `unproven` until the pinned build
carries the runtime capabilities, and no real credential is enabled.

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
