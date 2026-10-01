# Bee driver

bee/driver is the shared Lua contract and implementation for external CLI
drivers. It defines declarative launches, protocol normalization, saved
preferences, configuration delivery, and host-evidence-based location. It does
not execute a process, read credentials, or write thread records.

## Install

Install this package with bee/threads and one provider component. The host
selects which provider bindings are active, the executable each binding may
use, its credential projections, launch policy, resources, and MCP ceiling.
Installing a component alone grants none of those things.

## Provider contract

A provider binding implements four Lua methods:

| Method | Result |
|---|---|
| prepare | A declarative launch for a new turn or window |
| dispatch | A declarative continuation input |
| normalize | Thread observations and an optional terminal outcome |
| configure | Bounded argv literals and private-home configuration files |

Placement validates the returned launch, measures the selected executable, and
runs it. The carrier writes accepted observations through Threads. A process
exit alone never establishes a successful turn.

External CLI bindings also implement `bee.driver:locate_facet`. Its `locate`
method evaluates host-probed executable presence and version, platform support,
and alternative provider login evidence. Results are `ready`, `missing`,
`unconfigured`, `incompatible`, or `unknown`. Login contents are never read;
file or config existence and environment presence are setup evidence, not proof that a login is valid.

The six external CLI packages use the shared `bee.driver:universal`
implementation. Each contributes a strict `bee.driver.cli_descriptor` registry
entry (`bee.driver.cli-descriptor@2`) with executable and version probe, an any-of login evidence declaration, launch templates,
option and flag templates, JSON paths, and a codec ID. The host validates the
descriptor before using it. CLI-specific configuration rendering remains in
the provider package where formats and hook protocols differ.

`login_evidence` declares a display-only `command` and one to eight `any_of`
alternatives. One positive observation makes the login ready. If all checks
are negative it is unconfigured; if none is positive and a check cannot run,
readiness is unknown. Alternatives are strict, bounded records:

| Kind | Fields | Host observation |
|---|---|---|
| `file_exists` | `paths` (1–8 relative paths; eight total), optional provider `variable`/`directory` | Metadata under the host-selected machine login source; no file reads |
| `env_present` | `names` (1–16 environment names) | Native host environment names only; no values enter Lua |
| `auth_status` | `argv` (1–8 arguments), `success_exit_code` (0–255), `timeout_ms` (1–30000) | The selected CLI's local non-interactive status command; stdin closed, stdout/stderr discarded before capture |

The host probe supplies machine HOME to status commands and bounds their
lifetime. It never runs interactive login, refresh, model listing or provider
requests to establish readiness. Descriptor metadata does not grant execution,
credential access, environment inheritance or home permissions. A private route
still needs its host-selected credential/config projection; a host-home route
still needs its admitted policy. Window file advisories retain the same
alternatives; they cannot report absence while non-file alternatives remain
unobserved.

| CLI | Declared sources | Default window home |
|---|---|---|
| Claude | `.claude/.credentials.json`; `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`; `auth status` exit 0 | Authorized host HOME (status also covers macOS Keychain) |
| Codex | `.codex/auth.json`; `OPENAI_API_KEY`, `CODEX_API_KEY`; `login status` exit 0 | Authorized host HOME (status also covers OS credential storage) |
| Agy | `.gemini/antigravity-cli/antigravity-oauth-token`; `GEMINI_API_KEY` | Authorized host HOME |
| Grok | `.grok/auth.json` or `.grok/config.toml`; `XAI_API_KEY`, `GROK_CODE_XAI_API_KEY` | Private HOME; existing `grok_login` projection carries auth and config independently |
| Muse | `.config/muse/auth.json`; `META_API_KEY` | Authorized host HOME |
| OpenCode | `.local/share/opencode/auth.json`, `.config/opencode/opencode.json` or `.jsonc`; declared provider key environment names or inline config | Authorized host HOME, including provider key files referenced by config |

Grok and OpenCode config existence establishes setup without inspecting keys,
provider selection or referenced file contents. A config with no usable provider
can therefore pass this evidence check; actual authentication remains the CLI's
responsibility. Agy, Grok, Muse and OpenCode do not expose a local status command
whose exit code alone proves login in the installed CLI help, so their
descriptors do not run one. Agy's OS-keyring-only login has no safe observable
status evidence; without its fallback token or API-key environment name it
reports unconfigured rather than inventing evidence.

Authentication sources: [Claude authentication](https://code.claude.com/docs/en/authentication),
[Codex authentication](https://developers.openai.com/codex/auth),
[OpenCode providers](https://opencode.ai/docs/providers) and
[config substitutions](https://opencode.ai/docs/config); Grok's bundled
`02-authentication.md` and configuration reference; installed Agy `--help` and
bundled API-key changelog; Muse `login --help` and `auth --help`. Claude and
Codex status commands are declared with a 3000 ms timeout.

Each observed wire protocol has one shared codec: Claude stream-json, Codex
JSONL, OpenCode JSON events, Agy stream-json, Grok streaming-json, and Muse
record JSONL. Claude and Agy both use newline-delimited JSON but have different
event schemas and terminal reports; OpenCode has no terminal event and uses
process EOF; Grok and Muse also use distinct event envelopes. The codec
registry selects these implementations by descriptor ID. Normalization decodes
state once into the selected codec's state record before applying events.
The lazy protocol adapter exposes typed `revision()` and `max_answer_bytes()`
accessors and preserves the legacy scalar properties at runtime. `driver-wippy` is a
separate non-CLI driver and does not use this external-driver registry.

External CLI descriptors do not impose a default turn, token or run-time cap.
Optional limits belong to the Sessions Work budget; codecs report normalized
turn signals and provider usage so the external executor can supervise them.

A window launch may declare `login`: a provider identifier, a display-only
sign-in command and bounded alternative file paths relative to its selected
provider home. Placement uses their existence to return a typed advisory
notice; a login declaration grants no filesystem or credential authority.

## Saved profiles

A saved profile contains a title, a launch definition, bounded scalar options,
selected MCP tools, and persistent instructions. The host policy declares which
option names and values are allowed. The shared profile format does not give any
option provider-specific meaning; a provider validates the options it consumes.

Instructions are persistent guidance separate from a turn's brief and dynamic
context. The host may append a reviewed instruction-builder result before a
launch is prepared. A profile cannot select executable paths, credentials,
permissions, or arbitrary configuration files.

## Configuration delivery

configure receives copied host-selected provider data and an optional scoped
gateway descriptor without token bytes. It returns bounded argv literals and
unique safe-relative files with digests. Placement rechecks the host-selected
inputs, materializes admitted secrets only into declared fields, and records the
resulting delivery before starting the process.

Provider-specific command syntax, profile options, authentication, hook wire
formats, and MCP configuration belong in that provider's component guide and
Lua package.

`bee.driver:types.AUTHENTICATION_STATUS` is the shared release gate for
executable-backed provider login acceptance. `unproven` records that the
configured provider executables have not all been exercised through placement;
it does not decide whether a login is valid or admit a launch.

An activated driver profile may declare a typed Git writable-roots adapter.
Native placement reads that choice from the pinned profile, then uses it only
when the granted workdir is writable and the launch arguments select the
adapter's edit-capable CLI mode. Configure replies and launch callers cannot
select the adapter or its paths. Placement discovers Git metadata and checks
the exact directories against host-admitted write roots before asking the CLI
to use its provider-specific option.
