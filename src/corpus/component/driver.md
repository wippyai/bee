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
| `bee.driver.agy`, `bee.driver.claude`, `bee.driver.codex`, `bee.driver.grok`, `bee.driver.muse` | Separate provider components: profiles, launch specification, protocol normalization |

## Rules

The carrier validates every prepare/continuation launch reply before changing
its executable or resolving placement. It shares placement's bounded launch
decoder; malformed provider output is refused before executable measurement
or attempt admission. Driver replies are data, not trusted Lua type assertions.

`configure` receives only copied host-selected provider data, an optional
gateway descriptor (endpoint, action/tool/hook identities and environment
variable names, never token bytes), an optional owner-derived home directory,
and the fixture flag. Its reply is a bounded delivery of ordered argv literals
(including an empty literal) and unique, nonempty safe-relative private-home
files with lowercase SHA-256 digests. The shared decoder rejects unknown
fields, duplicate paths and mismatched bytes. The carrier fingerprints the
validated inputs, excluding the owner-derived home directory, under the
selected configure target; placement rechecks that fingerprint and renders the
delivery once while recording intent. The renderer still runs under an empty
scope. The protected host admission binding grants
scope management to the native harness application; ordinary applications
cannot enable it through metadata or launch arguments. Actor context remains
inherited, but the renderer has no placement, registry, executor or nested-call
permissions. Claude delivers its admitted MCP and hook settings as fresh argv
JSON with strict MCP and empty setting sources, so a retained provider home is
not rewritten. Codex uses protected files; changing retained Codex hook/trust
content still refuses rather than overwriting that home.

A normalizer never reports success from a process exit; only the protocol's
terminal event does. Answers come from the profile's declared answer path.
Everything a provider declares in `meta.driver` is decoded by
`bee.driver:profile` with exact shapes and conservative defaults; an unknown
field or an unsupported value rejects the binding.

Each provider component also owns one `default_window` launch definition for
its native TUI. The definition selects only that component's `window` profile
and carries no caller-controlled launch overrides. The host supplies a separate
per-driver launch policy whose `executable_env` map resolves the component's
read-only variable from `bee.harness.host:environment`. A missing executable
or optional component makes that policy unavailable, leaving the declaration
visible but unavailable; component metadata does not grant execution,
activation, or environment access.

## User-login configuration

A host Codex provider may select `authentication: chatgpt`, `name: openai`
and a reviewed model. That mode uses Codex's built-in OpenAI provider and
file credential storage, without a custom base URL or API-key environment
selection. A base URL, custom provider name or fixture endpoint is refused
for this mode. Omitting `authentication` retains the API-key configuration.
MCP and hook configuration still use the same admitted gateway delivery.

The driver selects the authentication mode; the credential materializer owns
login discovery and private session state. No login file is read by this pure
driver. Login refresh across launches and Docker execution are outside this
contract.
The configuration follows the [official Codex authentication contract](https://developers.openai.com/codex/auth).

## Codex authentication path

The default managed window inherits the host user's HOME and normal Codex
configuration/login. Bee adds its scoped MCP connection and hooks with session
arguments; it does not select a separate named profile or write global config.
A host-selected provider remains an explicit configuration path, described below.
Generated files stay in Bee's private session directory.

A saved agent profile may select one Codex config profile through the generic
host option `profile_options.config_profile` (a bounded text descriptor).
The selected value reaches the Codex driver's `config_profile` launch field;
the executable layers `$CODEX_HOME/<name>.config.toml` on top of its base user
config through `-p/--profile`. Bee's own session `-c` MCP and hook arguments
still apply, and Codex resolves a later `-c` override over the named profile's
value. The Codex driver validates the name as a bounded identifier matching
what Codex accepts; a dot, path separator, leading dash, space, empty or
overlong value is refused, so it can never escape the Codex home. The shipped
policies declare this option only on Codex routes whose launch inherits the
host Codex home: the picker's native Codex window
(`launch_policy_codex_window`) and the structured `bee.driver.codex:named_batch`
route. The private-home Codex batch policy also declares the option, but a
private home never carries the named file, so that route refuses the launch
with a diagnostic naming the profile. No non-Codex policy declares the option.

The named file lives in the *inherited* home. Where Bee runs Codex with a
private `CODEX_HOME` instead (the host-selected provider path, retained homes,
Docker), that file does not exist and Bee refuses the launch with a diagnostic
naming the profile. Bee does not copy the owner's config files or anything
carrying credentials into a private home; there is no sanctioned named-file
projection in `bee.credentials` or the materializer to use instead. A launch
whose named file is absent from the inherited home is refused before the
process starts, by an existence check through the read-only host volume that
never reads the file's contents.

The Codex launch writes the brief to stdin and Codex reads it until end of
file, so the launch declares `stdin_eof`: placement admits it only where
the executor can close stdin (`close_stdin`), the runner
writes the complete input, closes stdin once and records
`stdin.accepted`, `stdin.closed` or `stdin.uncertain`, and later writes are
refused. The executable does not take `OPENAI_API_KEY` from the
environment alone: it selects the API-key path only through a provider
configuration in the private `CODEX_HOME`. `bee.driver.codex:configuration`
renders that file from the host's `bee.codex_provider` entry named by the
launch policy (`provider_ref`): only the provider name, base URL,
model, optional `reasoning_effort` (`low`, `medium`, `high`, `xhigh` or
`max`) and optional bounded `developer_instructions` (ordinary text plus
escaped line breaks, carriage returns and tabs), with
`env_key = "OPENAI_API_KEY"` and the responses wire API; plain HTTP is allowed
only for loopback endpoints. Unsupported control bytes are rejected,
and the rendered file remains within the shared 8192-byte configuration bound
after escaping. The plan digest pins the adapter
revision and the rendered digest, and placement writes it with exclusive
creation. Real credentials are never enabled by this driver contract; provider
authentication remains the responsibility of the host and placement path.

## Host-selected model options

Claude launch policies may set `model` and `effort` in `prepare_options`.
The Claude driver accepts only a bounded model identifier and the executable's
`low`, `medium`, `high`, `xhigh` or `max` effort values, then emits
`--model` and `--effort`. Codex keeps its model and optional reasoning effort
in the host-selected provider entry; its generated TOML emits only
the reviewed `model_reasoning_effort` and `developer_instructions` keys. The caller never
contributes either value: the carrier copies only the selected policy's
`prepare_options`, and provider configuration is rendered from the policy's
`provider_ref`. A Codex launch definition can therefore select a provider
with shared instructions and MCP gateway content through the existing
`driver.configure` boundary; a second profile schema is unnecessary.

## Instructions and turn prompts

A launch definition's host-selected policy may declare `instructions`: nonempty
text up to 4096 bytes, allowing line breaks and tabs. This is persistent profile
guidance, separate from the request's `brief` (the turn prompt) and dynamic `ctx`
context. It grants no permissions. The policy and configuration digests include
it; changing it after planning refuses the stale launch before recording an intent.
Callers cannot supply it as a launch override.

The driver configuration method maps this field to each native mechanism:
Claude appends it with `--append-system-prompt`; Grok appends it with `--rules`;
Codex writes `developer_instructions` in its private configuration. Declaring it
both in the Codex provider and launch policy is refused as ambiguous. These paths
preserve the harness's built-in guidance; there is no shared system-prompt
replacement option. Agy receives the exact text in the retained session's
`.agents/AGENTS.md`, supplied as an additional customization root with
`--add-dir` while its ordinary HOME remains intact. Its selected `--agent` and turn
prompt are unchanged. Agy custom agents still control inheritance of ambient
rules; this file is not a system-prompt replacement. The configuration boundary refuses an instruction file
when no instructions were selected or its content differs from the selection.

### Instruction builders

A host launch policy may select `instruction_builder = {func_id = ..., args = ...}`.
The function receives a bounded JSON object and returns text. Empty text means
there is no additional guidance. Nonempty output
is appended to static `instructions` with a blank line; the combined text retains
the 4096-byte limit. Drivers receive only the resulting instructions, preserving
built-in harness guidance and keeping the turn prompt separate.

The builder inherits the authenticated caller and actual runtime `ctx`. It runs
with an empty inherited scope; only its own declared policies can grant resource
access. Declare reviewed read permissions, since an interrupted preparation may
retry the function. Placement storage, process execution and gateway authority
are not inherited. Host policy selects the builder; launch callers cannot override it.

The configuration digest covers the function identifier and arguments. Changing
either invalidates a prepared launch plan. It does not pin the function's code:
a reviewed revision at the same identifier may change the next evaluation.
Evaluation occurs during launch preparation, after checking for an existing
receipt. A committed intent stores the validated delivery, and replay uses that
frozen value even if the builder later changes or fails. Failures before commit
can evaluate again. Builder errors or invalid output refuse the new intent.

This supports launch-time guidance, not per-turn refresh inside a running CLI.

## Claude authentication path

The Claude launch uses stream-json output for structured turns and inline
settings supplied by the configure method, with no generated configuration file
in the private home. The API-key path
is selected by the environment alone: the launch policy's `environment`
carries the host-selected `ANTHROPIC_BASE_URL`, the credential broker
projects `ANTHROPIC_API_KEY`, and the runner's private `HOME` carries no
login state that could take precedence. Provider authentication and
conversation recovery remain outside this driver contract.

## Claude permission exchange

`bee.driver.claude:permission_adapter` defines the control protocol. When the
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
has accepted a turn or is ready for automated input. These are command
specifications, not public window activation.

Claude's structured print command places positional prompt text after `--`, so a
prompt such as `--version` remains data. Stdio permission-exchange launches keep
their existing structured input encoding.

Launch specifications separate the executable from its arguments: `argv` never
contains the program name. The host may bind `executable` to a measured absolute
path; placement prepends that selected executable exactly once. A window with
an empty brief therefore supplies no prompt argument.

JSON configuration files may declare bounded `secret_fields`: object-key paths,
selected gateway environment names and literal prefixes. The template target is
an empty string. Driver admission and native placement both restrict these fields
to the admitted gateway credentials. Placement fills them only during private
file materialization; token bytes never enter the stored driver delivery or argv.
This supports harnesses such as Agy that require literal HTTP headers. Existing
protected-create and retained-content checks still apply; this does not add
configuration replacement or general environment interpolation.
