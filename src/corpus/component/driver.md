# Bee driver

`bee.driver` is the shared Lua contract and implementation for external CLI
drivers. It defines declarative launches, protocol normalization, saved
preferences, configuration delivery, and host-evidence-based location. It does
not execute a process, read credentials, or write thread records.

A provider binding is selected by the host. The host decides which provider
bindings are active, the executable each may use, its credential projections,
launch policy, resources and MCP ceiling; installing a component grants none of
those.

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

The six external CLI packages (`bee.driver.<claude|codex|agy|grok|muse|opencode>`) use the shared `bee.driver.binding:universal`
implementation. Each contributes a strict `bee.driver.cli_descriptor` registry
entry (`bee.driver.cli-descriptor@3`) with executable and version probe, an any-of login evidence declaration, launch templates,
OptionSpec value schemas, form labels, contexts, capability evidence and renders, JSON paths, and a codec ID. The same declaration supplies form choices, argv, structured configuration and environment delivery; there is no separate profile-options map. Locate reports capabilities established by version/help probes. The host validates the
descriptor before using it. CLI-specific configuration rendering remains in
the provider package where formats and hook protocols differ.

The Harness catalog discovers `contract.binding` entries with `meta.type: harness.driver`.
Each declares `driver_id`, `profiles_ref` and the four `bee.driver:driver`
methods. CLI bindings also name `descriptor_ref`. The profiles entry has
`meta.type: harness.profile` and `meta.driver_ref` naming that exact binding.
The binding ID and method targets may belong to different namespaces and use
different entry names. Threads sessions resolve the declared targets from one pinned
registry snapshot and requires `function.lua` entries. Configuration resolves
the selected binding's descriptor explicitly; it never infers a binding from
a configure target's name. Provider renderers retain their formats and permissions.

The person selects the exact binding in the host-owned
`bee.harness.launch:harness_activation` declaration and admits the launch
definition, policy, executable, placement, credentials, resources and gateway
ceiling. An optional host-selected admission reader contributes bindings from
Gov's consumed approvals and exact installed artifacts to this same resolver.
Metadata discovery, installation and a matching name confer no launch
authority. An unselected binding returns `binding <id> is not activated`.
External turns re-admit through the host and use its planned normalize target.

An agent authors typed method functions, binding metadata, profiles and, for a
CLI, a descriptor plus provider configuration renderer. Existing executions keep
their pinned route; a changed target takes effect for new routes after
authorized registry publication.

Governed overlays require the person's approval of the exact candidate; a
changed candidate requires review again. The host's exact binding activation
and launch permissions still apply.

Shared configuration calls, option rendering, shell quoting and TOML literals
live in `bee.driver.binding` (`configuration`, `option_render`, `quote`,
`toml`, `resolver`, `universal`). Observation builders and the normalizer
boundary live in `bee.driver.codec`; framing and stream decoding live in
`bee.driver.transport`. Consumers import these helpers directly.

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

| CLI | Declared evidence | Provider home variable |
|---|---|---|
| Claude | `.claude/.credentials.json` under `CLAUDE_CONFIG_DIR`; `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`; `auth status` exit 0 | `CLAUDE_CONFIG_DIR` |
| Codex | `.codex/auth.json` under `CODEX_HOME`; `OPENAI_API_KEY`, `CODEX_API_KEY`; `login status` exit 0 | `CODEX_HOME` |
| Agy | `.gemini/antigravity-cli/antigravity-oauth-token`; `GEMINI_API_KEY` | none |
| Grok | `.grok/auth.json` under `GROK_HOME`; `XAI_API_KEY`, `GROK_CODE_XAI_API_KEY` | `GROK_HOME` |
| Muse | `.config/muse/auth.json` under `XDG_CONFIG_HOME`; `META_API_KEY` | none |
| OpenCode | `.local/share/opencode/auth.json`; `.config/opencode/opencode.json` or `.jsonc`; provider key names or `OPENCODE_CONFIG_CONTENT` | `XDG_CONFIG_HOME`, `XDG_DATA_HOME` |

Config file existence establishes setup without inspecting keys or provider
selection; actual authentication remains the CLI's responsibility.

Each observed wire protocol has one shared codec: Claude stream-json, Codex
JSONL, OpenCode JSON events, Agy stream-json, Grok streaming-json and Muse
record JSONL. The codec registry (`bee.driver.codec:codec_registry`) selects the
implementation by the descriptor's codec ID. `bee.driver.wippy` is a separate
non-CLI driver and does not use this registry.

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

Custom configure targets decode the common request with
`bee.driver.binding:configuration.decode_request`, including its optional
host-selected `configure_renderer`. The universal driver uses this same decoder;
an arbitrary target does not need a namespace-derived adapter.

Provider-specific command syntax, profile options, authentication, hook wire
formats, and MCP configuration belong in that provider's component guide and
Lua package.

`bee.driver:types` `AUTHENTICATION_STATUS` is the shared release gate for
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

Descriptor config renders encode bounded declared objects, arrays, numbers and booleans as JSON or TOML values, or text files in the admitted private home. The owner-derived `provider.system_prompt_files` token supplies the prompt-file array for OpenCode; it is not a saved option. Configuration delivery may contain a bounded `environment` map of nonreserved literal variables, persisted with files and arguments. Credential values remain broker references and are never returned by the driver.

Driver observation builders bound text by its encoded size through the nested
session journal envelopes. Long text splits at Unicode character boundaries;
tool previews and error messages remain bounded, and oversized extension
payloads retain an omission-size object rather than invalid partial JSON.

Workspace-authored drivers use the governed `driver.<name>` overlay rule. Read
the overlay guide's `drivers` section for ownership, descriptor-based method
factories, the exact host activation append and delivery approval. The driver's
`.profiles` launch definition sets `presentation.start_menu: true` to appear in
the Sessions agent picker (N); false keeps it programmatic. A window definition
also sets `session_resource: session`, selecting the host's existing retained
session resource.
