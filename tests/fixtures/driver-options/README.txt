Driver option schema step 2 — lane/drvopts2

Installed compatibility targets: Claude Code 2.1.296; codex-cli 0.160.1.
56 Claude options added; 56 Codex options added and model_providers extended.
Existing model, effort, permissions/sandbox, config profile, prompt append, folder trust and operational resume mappings remain declared by step 1.

Default I means inherit the CLI/effective configuration when the value is absent; the effective schema reports default_source=CLI. Explicit false and empty selections remain distinct from absence. Chrome=false renders the advertised --no-chrome flag.
F=free; P=person-only; H=host-ceiling. Enum and boolean capability maps name explicit values only. Free-valued and structured options use the existing capability-rights list form for unconditional grants; empty replacements grant those same rights. Authority-bearing selections require profile-option in that option's placement ceiling and launch-policy admission. The shipped placement ceiling grants no new authority. Locks, list-right subsets, deny unions and numeric maxima remain independent constraints. Restrictive options declare no expansion rights.
Custom Codex model_providers uses [profile-option]; effective.compile calls placements.context and ceiling_value checks that list against placement option_ceilings, the descriptor ceiling and launch-policy option_constraints.capabilities. Native placement has no such grant. Profile admission also uses the existing harness.profiles.binding.validation driver placement_profiles check. Keyless definitions omit env_key; raw API keys are not fields.

Remaining renderer vocabulary (existing nodes cannot express these operations):
  each={field,flag?}: join emits one token; repeated flags and variadic arguments need multiple argv tokens with injection-safe boundaries.
  field encoding=json: field accepts scalars and format substitutes scalar text; neither can canonically encode a structured JSON argv value.
Existing declaration forms gain generic validation, without CLI-named types or wildcard semantics:
  pattern accepts bounded alternatives: Lua patterns have no alternation, and the native threshold accepts auto plus several bounded numeric spellings.
  json value_schema type accepts a bounded list of existing types: JSON Schema documents accept object and boolean roots.
  additionalProperties=true and empty child schemas decode bounded JSON: response schemas contain arbitrary dialect keys and mixed typed values; existing structured controls select their types.
  capabilities accepts the same rights-list form as host and placement declarations: unconditional rights belong to the option, independent of a free/structured value.
  option_constraints.maximum compares validated numeric text: native USD decimals stay in CLI units and still take the host minimum.
Removed: autocompact/json_schema runtime types/formats, cents_usd encoding, capability wildcard/empty-list keys. Claude budget_cents becomes budget_usd (positive decimal text); it renders without conversion. No new public Lua functions, external methods, migrations, runtime code or pins. Option/capability capacity remains 128 and total argv remains capped at 128.

Existing public contract bound requiring landing review: sessions catalog Candidate.features increases from 64 to 128 in locator, decoder and MCP output schema. Codex supplies 66 option-capability markers plus driver/presentation markers; the former bound silently removes it from the picker. No key, type or method is added. The public reference-list bounds for other fields stay 64.

Options added/extended (all mappings are native; configuration files are isolated):
ID | Type / allowed values | Default | Group | Mapping | Class | Contexts

CLAUDE
fallback_models | array of string | I | model/provider | --fallback-model | free | window, first_turn, resume
system_prompt | string | I | behavior | --system-prompt | host-ceiling | window, first_turn, resume
agent | string | I | behavior | --agent | host-ceiling | window, first_turn, resume
agents | object | I | behavior | --agents | host-ceiling | window, first_turn, resume
autocompact | text (auto or 100k–1M, declared patterns) | I | behavior | --autocompact | free | window, first_turn, resume
budget_usd | text (positive decimal USD) | I | behavior | --max-budget-usd | host-ceiling | first_turn, resume
prompt_snapshot | string (on, off) | I | behavior | --system-prompt-snapshot | free | window, first_turn, resume
exclude_dynamic_prompt | boolean | I | behavior | --exclude-dynamic-system-prompt-sections | free | window, first_turn, resume
brief_mode | boolean | I | behavior | --brief | free | window, first_turn, resume
prompt_suggestions | boolean | I | behavior | --prompt-suggestions | free | window, first_turn, resume
permission_bypass | boolean | I | access/trust | --dangerously-skip-permissions | host-ceiling | window, first_turn, resume
allow_permission_bypass | boolean | I | access/trust | --allow-dangerously-skip-permissions | host-ceiling | window, first_turn, resume
permission_prompts | string (host, none) | I | access/trust | --permission-prompts | host-ceiling | first_turn, resume
tools | array of string | I | access/trust | --tools | host-ceiling | window, first_turn, resume
tool_allow | array of string | I | access/trust | --allowedTools | host-ceiling | window, first_turn, resume
tool_deny | array of string | I | access/trust | --disallowedTools | host-ceiling | window, first_turn, resume
additional_dirs | array of string | I | access/trust | --add-dir | host-ceiling | window, first_turn, resume
mcp_servers | object | I | tools/integrations | --mcp-config | host-ceiling | window, first_turn, resume
strict_mcp | boolean | I | tools/integrations | --strict-mcp-config | host-ceiling | window, first_turn, resume
plugin_dirs | array of string | I | tools/integrations | --plugin-dir | host-ceiling | window, first_turn, resume
plugin_urls | array of string | I | tools/integrations | --plugin-url | host-ceiling | window, first_turn, resume
disable_slash_commands | boolean | I | tools/integrations | --disable-slash-commands | host-ceiling | window, first_turn, resume
setting_sources | array of string | I | advanced | --setting-sources | host-ceiling | window, first_turn, resume
settings_ref | string | I | advanced | --settings | host-ceiling | window, first_turn, resume
bare | boolean | I | advanced | --bare | host-ceiling | window, first_turn, resume
restricted | boolean | I | advanced | --restricted | host-ceiling | window, first_turn, resume
safe_mode | boolean | I | advanced | --safe-mode | host-ceiling | window, first_turn, resume
json_schema | json (object or boolean) | I | advanced | --json-schema | free | first_turn, resume
output_format | string (text, json, stream-json) | I | advanced | --output-format | host-ceiling | first_turn, resume
input_format | string (text, stream-json) | I | advanced | --input-format | host-ceiling | first_turn, resume
partial_messages | boolean | I | advanced | --include-partial-messages | host-ceiling | first_turn, resume
hook_events | boolean | I | advanced | --include-hook-events | host-ceiling | first_turn, resume
forward_subagent_text | boolean | I | advanced | --forward-subagent-text | host-ceiling | first_turn, resume
replay_user_messages | boolean | I | advanced | --replay-user-messages | host-ceiling | first_turn, resume
verbose | boolean | I | advanced | --verbose | person-only | window, first_turn, resume
debug | string | I | advanced | --debug | person-only | window, first_turn, resume
debug_file | string | I | advanced | --debug-file | person-only | window, first_turn, resume
screen_reader | boolean | I | advanced | --ax-screen-reader | person-only | window
no_session_persistence | boolean | I | advanced | --no-session-persistence | host-ceiling | first_turn, resume
session_name | string | I | advanced | --name | host-ceiling | window, first_turn, resume
continue_session | boolean | I | advanced | --continue | host-ceiling | window
fork_session | boolean | I | advanced | --fork-session | host-ceiling | resume
session_id | string | I | advanced | --session-id | host-ceiling | window, first_turn, resume
startup_files | array of string | I | advanced | --file | host-ceiling | window, first_turn, resume
worktree | string | I | advanced | --worktree | host-ceiling | window
tmux | boolean | I | advanced | --tmux | host-ceiling | window
from_pr | string | I | advanced | --from-pr | host-ceiling | window
teleport | string | I | advanced | --teleport | host-ceiling | window
chrome | boolean | I | tools/integrations | --chrome | host-ceiling | window
ide | boolean | I | tools/integrations | --ide | host-ceiling | window
desktop | boolean | I | tools/integrations | --desktop | host-ceiling | window
background | boolean | I | tools/integrations | --background | host-ceiling | window
cloud | string | I | tools/integrations | --cloud | host-ceiling | window
remote_control | string | I | tools/integrations | --remote-control | host-ceiling | window
environment | string | I | tools/integrations | --environment | host-ceiling | window
betas | array of string | I | advanced | --betas | host-ceiling | window, first_turn, resume

CODEX
plan_effort | string (none, minimal, low, medium, high, xhigh, max) | I | model/provider | .codex/config.toml: plan_mode_reasoning_effort | free | window, first_turn, resume
reasoning_summary | string (auto, concise, detailed, none) | I | model/provider | .codex/config.toml: model_reasoning_summary | free | window, first_turn, resume
verbosity | string (low, medium, high) | I | model/provider | .codex/config.toml: model_verbosity | free | window, first_turn, resume
personality | string (none, friendly, pragmatic) | I | model/provider | .codex/config.toml: personality | free | window, first_turn, resume
context_window | integer >=1 | I | model/provider | .codex/config.toml: model_context_window | free | window, first_turn, resume
compaction_threshold | integer >=1 | I | model/provider | .codex/config.toml: model_auto_compact_token_limit | free | window, first_turn, resume
review_model | string / model | I | model/provider | .codex/config.toml: review_model | free | window, first_turn, resume
service_tier | string (fast, flex) | I | model/provider | .codex/config.toml: service_tier | free | window, first_turn, resume
oss | boolean | I | model/provider | --oss | host-ceiling | window, first_turn
local_provider | string (ollama, lmstudio) | I | model/provider | --local-provider | host-ceiling | window, first_turn
auth_kind | string (chatgpt, api) | I | model/provider | .codex/config.toml: forced_login_method | host-ceiling | window, first_turn, resume
instructions_file | string | I | behavior | .codex/config.toml: model_instructions_file | host-ceiling | window, first_turn, resume
project_doc_max_bytes | integer >=0 | I | behavior | .codex/config.toml: project_doc_max_bytes | host-ceiling | window, first_turn, resume
project_doc_fallback_filenames | array of string | I | behavior | .codex/config.toml: project_doc_fallback_filenames | host-ceiling | window, first_turn, resume
approve_for_me | boolean | I | access/trust | --approve-for-me | host-ceiling | window, first_turn
bypass_hook_trust | boolean | I | access/trust | --dangerously-bypass-hook-trust | host-ceiling | window, first_turn, resume
writable_roots | array of string | I | access/trust | --add-dir | host-ceiling | window, first_turn
network_access | boolean | I | access/trust | .codex/config.toml: sandbox_workspace_write.network_access | host-ceiling | window, first_turn, resume
exclude_slash_tmp | boolean | I | access/trust | .codex/config.toml: sandbox_workspace_write.exclude_slash_tmp | host-ceiling | window, first_turn, resume
exclude_tmpdir_env_var | boolean | I | access/trust | .codex/config.toml: sandbox_workspace_write.exclude_tmpdir_env_var | host-ceiling | window, first_turn, resume
web_search | string (disabled, cached, live) | I | access/trust | .codex/config.toml: web_search | host-ceiling | window, first_turn, resume
strict_config | boolean | I | advanced | --strict-config | host-ceiling | window, first_turn, resume
ignore_user_config | boolean | I | advanced | --ignore-user-config | host-ceiling | first_turn, resume
ignore_rules | boolean | I | advanced | --ignore-rules | host-ceiling | first_turn, resume
shell_inherit | string (all, core, none) | I | advanced | .codex/config.toml: shell_environment_policy.inherit | host-ceiling | window, first_turn, resume
output_schema | string | I | advanced | --output-schema | free | first_turn, resume
json | boolean | I | advanced | --json | host-ceiling | first_turn, resume
color | string (always, never, auto) | I | advanced | --color | host-ceiling | first_turn
last_message_file | string | I | advanced | --output-last-message | host-ceiling | first_turn, resume
hide_agent_reasoning | boolean | I | advanced | .codex/config.toml: hide_agent_reasoning | person-only | window, first_turn, resume
show_raw_agent_reasoning | boolean | I | advanced | .codex/config.toml: show_raw_agent_reasoning | person-only | window, first_turn, resume
no_alt_screen | boolean | I | advanced | --no-alt-screen | person-only | window
images | array of string | I | advanced | --image | host-ceiling | window, first_turn, resume
workdir | string | I | advanced | --cd | host-ceiling | window, first_turn
worktree | boolean | I | advanced | --worktree | host-ceiling | window, first_turn, resume
skip_git_repo_check | boolean | I | advanced | --skip-git-repo-check | host-ceiling | first_turn, resume
ephemeral | boolean | I | advanced | --ephemeral | person-only | first_turn, resume
history_persistence | string (save-all, none) | I | advanced | .codex/config.toml: history.persistence | person-only | window, first_turn, resume
history_max_bytes | integer >=1 | I | advanced | .codex/config.toml: history.max_bytes | person-only | window, first_turn, resume
thread_source | string | I | advanced | --thread-source | host-ceiling | first_turn, resume
remote | string | I | tools/integrations | --remote | host-ceiling | window
remote_auth_token_env | string | I | tools/integrations | --remote-auth-token-env | host-ceiling | window
no_daemon | boolean | I | advanced | --no-daemon | host-ceiling | window
log_dir | string | I | advanced | .codex/config.toml: log_dir | host-ceiling | window, first_turn, resume
notify | array of string | I | advanced | .codex/config.toml: notify | host-ceiling | window, first_turn, resume
mcp_servers | object | I | tools/integrations | .codex/config.toml: mcp_servers | host-ceiling | window, first_turn, resume
shell_exclude | array of string | I | advanced | .codex/config.toml: shell_environment_policy.exclude | host-ceiling | window, first_turn, resume
shell_include_only | array of string | I | advanced | .codex/config.toml: shell_environment_policy.include_only | host-ceiling | window, first_turn, resume
shell_set | object | I | advanced | .codex/config.toml: shell_environment_policy.set | host-ceiling | window, first_turn, resume
shell_ignore_default_excludes | boolean | I | advanced | .codex/config.toml: shell_environment_policy.ignore_default_excludes | host-ceiling | window, first_turn, resume
plugins | object | I | tools/integrations | .codex/config.toml: plugins | host-ceiling | window, first_turn, resume
skills | array of object | I | tools/integrations | .codex/config.toml: skills.config | host-ceiling | window, first_turn, resume
agents | object | I | tools/integrations | .codex/config.toml: agents | host-ceiling | window, first_turn, resume
otel | object | I | advanced | .codex/config.toml: otel | host-ceiling | window, first_turn, resume
features | object | I | advanced | .codex/config.toml: features | host-ceiling | window, first_turn, resume
model_providers [extended] | object | I | model/provider | .codex/config.toml: model_providers | host-ceiling | window, first_turn, resume
hooks | object | I | tools/integrations | .codex/config.toml: hooks | host-ceiling | window, first_turn, resume

Skipped target rows / portions:
Claude: provider_kind, base_url, key_ref/auth_kind, cloud region/project/resource/model-alias environment; output_style; tool_ask; sandbox enabled/auto-allow/unsandboxed/filesystem/network settings; settings env and standalone hooks/skill definitions. These config/environment-only mappings have no installed-version semantic compatibility proof in this lane; no credential destinations or broker API are invented. Plugin directories/URLs and slash-command disabling are covered.
Claude: hidden system_prompt_file, max_turns, thinking_tokens stay out. Agent-definition permissionMode/maxTurns overrides also stay out: they lack a semantic compatibility proof and cannot bypass the global permission/budget declarations. --version accepts an invented flag too, so version-only parser acceptance is not compatibility evidence. Existing Bee-owned prompt-append file mapping is unchanged.
Claude: separate persisted resume selection stays operational (resume_ref), not an editable profile option; folder trust is already step 1. A brief launch option is named brief_mode to avoid collision with Bee's prompt payload.
Codex: named permission profiles, network-proxy domain/socket rules and command execpolicy references stay out; matching permission selector/platform semantics are not compatibility-tested. MCP enabled/disabled tool filters are covered; no universal tool allow/deny flag exists.
Codex: arbitrary process env and credential references stay out; shell inheritance/exclude/include/set rules are covered as H and gated. Provider headers, header env references, query params, command auth helper, retry/timeout/WebSocket fields are part of the typed model_providers extension. Endpoint-specific credential brokerage is not a new API.
Codex: rollout_budget enabled/limit_tokens stays out. The installed CLI requires reminder_at_remaining_tokens when enabled; the target pair alone is not a compatible complete declaration and is not a billing ceiling.
Codex: max_turns and dollar budget stay out because there is no verified native mapping. Native ephemeral/history, thread_source, workdir/worktree/images and remote flags are covered; resume/fork selection remains session-owned.
Codex: otel covers verified environment/exporter=none/log_user_prompt fields; telemetry exporter endpoints and auth are not verified here. Features includes the installed stable/experimental IDs, all H; removed, deprecated and development-only switches stay out. Native --search is represented by web_search=live, and provider_id/providers/bypass use the existing model_provider/model_providers/dangerously_bypass_approvals_and_sandbox IDs.

Validation:
  tests/driver_option_compat.py verifies 113 installed-version mappings with strict-config negative controls and isolated homes; no provider/login calls.
  Review cleanup adds production-path regression coverage for removed formats, generic patterns/JSON roots, exact false JSON argv, explicit capability maps, unconditional empty replacement ceilings and native USD host minima. Editor round trips use the existing type/choice/text/collection controls, profile protocol, storage and launch preferences in every driver group.

Fixtures:
  coverage.json: independent per-option captured argv/config selections and declared versions.
  *-help.txt: installed help captures, including Codex exec/resume.
  codex-0.160.1-features.txt: installed feature IDs, stages and defaults.
  option_coverage_cases.lua mirrors the captured data for the native Lua runner; option_coverage_test uses production prepare, configure, effective schema, typed controls, profile schema storage, the real profile protocol codec and launch-preference reconstruction.
