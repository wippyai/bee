# Add a driver for a new agent CLI

To add a driver, or write a driver for any new agent CLI, a person authors it
in a component or an agent authors it from inside Bee with the `overlay` and
`delivery` tools. The person approves it once in Needs you. It then appears in
Agents (N opens the agent picker), the profile editor shows its options, and
its sessions open the CLI in a window. Agents needs no code change: it lists
what the registry declares.

## What a driver is

A window CLI is three declarations:

| Entry | Kind and `meta.type` | What it says |
|---|---|---|
| CLI descriptor | `registry.entry`, `bee.driver.cli_descriptor` | the executable, its version probe, its options and how they render as arguments |
| Launch definition | `registry.entry`, `bee.launch_definition` | what Agents lists: title, driver, profile, policy, working folder |
| Launch policy | `registry.entry`, `bee.launch_policy` | the absolute executable the person approves and the options a person may set |

The descriptor is the whole driver. Bee derives the rest:

- A descriptor that no `harness.driver` binding names is its own driver: its
  id is the driver's id (the definition's `binding_ref`), its methods are the
  shared implementation in `bee.drivers.universal`, and its one profile is a
  `window` on a PTY.
- Approving the `driver.<name>` overlay activates that driver. A driver
  declares no activation requirement and no security policy; one selecting
  into `bee.harness.launch:harness_activation` or carrying a policy is
  refused.
- A window definition keeps its session in the host session resource, its
  `launch_id` is its registry id, and `schema_revision` may be left out.
- A launch policy defaults to process-group cleanup, independent exit
  observation and native placement, and leaves the overrides its definition
  allows in force; `allowed_overrides` in the policy restricts them.
- A descriptor without login evidence needs no account, without a platform
  admits every one, and without a codec runs only in a window.
- Readiness in Agents probes the executable the policy binds, so the CLI need
  not be on PATH.
- The profile editor builds its controls from the descriptor's
  `options.fields`; Agents lists every definition with
  `presentation.start_menu: true`.

A CLI that runs turns, or needs its own methods, declares a `contract.binding`
with `meta.type: harness.driver`, `driver_id`, `descriptor_ref` naming the
descriptor and `profiles_ref` naming a `harness.profile` record. Its methods
may name the shared ones; Bee passes each the binding's descriptor
(`descriptor_ref`, and the declaration as `descriptor` to `configure`). The
shipped drivers in `bee.drivers` are written this way.

## From inside Bee

1. Work as an agent session with the authoring tools, or pair an external MCP
   client (`docs/external_mcp`) and request the `bee.mcp:authoring` trait.
2. `overlay {operation: "create", overlay_id: "driver.<name>", expected_revision: 0, idempotency_key}`.
   The name is a lowercase letter followed by lowercase letters or digits.
   Entries live in `bee.driver.<name>.descriptor`, `.profiles` and
   `.security`.
3. `overlay {operation: "put", path: "entries.json", content}` with the JSON
   list below, then `overlay {operation: "freeze"}`. The reply's `digest` is
   the snapshot digest.
4. `delivery {operation: "preflight", source_overlay_id: "driver.<name>", version, snapshot_digest}`
   reports problems before anyone is asked; `operation: "request"` asks the
   person, who approves "Install agent driver driver.<name>" in Needs you.
5. In Agents press N: the driver is listed. N in the picker creates a profile
   with its options (Ctrl+P shows them); Enter starts a session and opens the
   CLI window in the chosen folder.

Existing sessions keep their pinned routes; a changed driver applies to new
sessions after its new version is approved.

## Complete minimal example

`echoagent` is an interactive CLI at `/opt/echoagent/bin/echoagent`. It prints
`echoagent 1.0.0` for `--version`, accepts `--greeting TEXT` and lists that
flag in `--help`. This `entries.json` is the whole driver:

```json
[
  {
    "id": "bee.driver.echoagent.descriptor:cli",
    "kind": "registry.entry",
    "meta": {"type": "bee.driver.cli_descriptor"},
    "data": {
      "schema_revision": "bee.driver.cli-descriptor@4",
      "provider": "echoagent",
      "executable": "echoagent",
      "version_probe": {"argv": ["--version"]},
      "configure": "plain",
      "options": {
        "profiles": ["window"],
        "fields": {
          "greeting": {
            "id": "greeting",
            "path": "provider.options.greeting",
            "value_schema": {"type": "string", "maxLength": 80},
            "label": "Greeting",
            "description": "First line the agent prints",
            "section": "basic",
            "order": 0,
            "group": "model/provider",
            "security_class": "free",
            "contexts": ["window"],
            "support": {"help_probe": {"argv": ["--help"], "flag": "--greeting"}},
            "render": [
              {
                "kind": "argv",
                "contexts": ["window"],
                "tokens": [{"if": "greeting", "then": ["--greeting", {"field": "greeting"}]}]
              }
            ]
          }
        }
      },
      "argv_templates": {"window": {"argv": [{"render": "greeting", "context": "window"}], "readiness": "none"}}
    }
  },
  {
    "id": "bee.driver.echoagent.profiles:window",
    "kind": "registry.entry",
    "meta": {"type": "bee.launch_definition"},
    "data": {
      "title": "Echo agent",
      "binding_ref": "bee.driver.echoagent.descriptor:cli",
      "profile_id": "window",
      "default_mode": "window",
      "policy_ref": "bee.driver.echoagent.security:window",
      "presentation": {"start_menu": true},
      "workdir_policy": {"kind": "declared_resource", "resource_ref": "project"},
      "allowed_overrides": ["workdir"]
    }
  },
  {
    "id": "bee.driver.echoagent.security:window",
    "kind": "registry.entry",
    "meta": {"type": "bee.launch_policy"},
    "data": {
      "executables": {"echoagent": "/opt/echoagent/bin/echoagent"},
      "profile_restrictions": {"provider.options.greeting": {"kind": "declared"}}
    }
  }
]
```

To write a driver for your CLI, replace `echoagent` in every id, the title, the
executable path and the descriptor's options and argv. Do not copy a codec.

## Descriptor fields

- `executable` is the name the policy's `executables` binds to an absolute path.
- `version_probe.argv` must print a version; `pattern` (optional) extracts it.
- `login_evidence` says how readiness learns the CLI is signed in:
  `file_exists` for a login file, `env_present` for a key variable,
  `auth_status` for a status command. Leave it out for a CLI with no account.
- `platform` restricts `os` and `arch`; leave it out to admit every platform.
- `options.fields` holds one editor control per option: `value_schema`,
  `label`, `section`, `group`, `security_class` (`free` for a person's own
  choice), `support` (the `--help` flag that proves the installed CLI accepts
  it) and `render` (argv tokens). The policy's `profile_restrictions` lists
  each option a person may set; others show as disabled by host policy.
- `argv_templates.window.argv` is the window command line;
  `{"render": "<field>", "context": "window"}` inserts an option's tokens.
  Every template names its `readiness` (`none` when the CLI reports nothing).
  A window-only CLI declares only `window`.
- `codec` names a shared stream decoder and is required once the CLI runs
  turns (`first_turn` or `resume`); a window decodes no stream. `json_paths`,
  `flags` and `provider_home` default to empty.
- `configure` names the configure renderer; `plain` delivers nothing beyond
  what the options render. A descriptor driver supports `plain`; a CLI with its
  own configuration format declares a binding with its own `configure`.

## Hooks

A driver without a hook declaration answers no hook point: extensions that
need one are refused with that reason, and the CLI runs normally. A CLI whose
hooks Bee can answer declares them in one `registry.entry` with
`meta.type: bee.driver_hooks` and `meta.driver_id: <name>`, named
`bee.driver.<name>.descriptor:hooks`:

```json
{"id": "bee.driver.echoagent.descriptor:hooks", "kind": "registry.entry",
 "meta": {"type": "bee.driver_hooks", "driver_id": "echoagent"},
 "data": {"response": "hook_specific_output", "transport": "command",
          "points": {"tool.before": {"results": ["pass", "change", "deny"],
                                     "reason": "PreToolUse updatedInput and permissionDecision=deny"}}}}
```

`points` names `session.start`, `prompt.submit`, `tool.before` and
`tool.after` with the results Bee may return (`pass`, `add_context`,
`change`, `deny`); `transport` (`command`, `http` or `mcp`, per point or for
all) bounds the hook chain; `response` is the answer format
(`hook_specific_output` as Claude Code reads it, `agy`, or `host` for an
in-process driver). Optional rules: `allow_on_change` adds
`permissionDecision=allow` to a change, `input` (`command` or `additive`)
restricts changed tool input, `input_bytes` and `output_bytes` bound changes,
`unsupported` explains the points not listed, and `mcp_meta` names the request
metadata fields a CLI sets on MCP hook-engine and model calls. The shipped
drivers' declarations are in `reference_drivers/opencode` and the
`bee.driver.<name>.descriptor` entries.

## When it does not appear

- `delivery preflight` names schema and authority problems.
- Agents counts unavailable entries ("U to show") with their status: a
  missing executable, an unsupported platform, absent login evidence.
- The profile editor shows only options the installed CLI's `support`
  evidence confirms and the policy admits.
