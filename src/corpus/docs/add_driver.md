# Add a driver for a new agent CLI

To add a driver, or write a driver for any new agent CLI, a person authors it
in a component or an agent authors it from inside Bee with the `overlay` and
`delivery` tools. The person approves it once in Needs you. It then appears in
Agents (N opens the agent picker), the profile editor shows its options, and
its sessions open the CLI in a window. Agents needs no code change: it lists
what the registry declares.

## What a driver is

| Entry | Kind and `meta.type` | What it says |
|---|---|---|
| CLI descriptor | `registry.entry`, `bee.driver.cli_descriptor` | the executable, its version probe, its options and how they render as arguments |
| Profiles | `registry.entry`, `harness.profile` | the modes the CLI runs in; an interactive CLI has one `window` profile on `pty` |
| Binding | `contract.binding`, `harness.driver` | `driver_id`, `descriptor_ref`, `profiles_ref` and five one-line methods over the shared implementation |
| Launch definition | `registry.entry`, `bee.launch_definition` | what Agents lists: title, binding, profile, policy, working folder |
| Launch policy | `registry.entry`, `bee.launch_policy` | the absolute executable the person approves and the options a person may set |

Bee derives the rest:

- Approving the `driver.<name>` overlay activates its `harness.driver`
  binding. A driver declares no activation requirement; one selecting into
  `bee.harness.launch:harness_activation` is refused.
- A window definition keeps its session in the host session resource, its
  `launch_id` is its registry id, and `schema_revision` may be left out.
- A launch policy defaults to process-group cleanup, independent exit
  observation and native placement.
- Readiness in Agents probes the executable the policy binds, so the CLI need
  not be on PATH.
- The profile editor builds its controls from the descriptor's
  `options.fields`; Agents lists every definition with
  `presentation.start_menu: true`.

## From inside Bee

1. Work as an agent session with the authoring tools, or pair an external MCP
   client (`docs/external_mcp`) and request the `bee.mcp:authoring` trait.
2. `overlay {operation: "create", overlay_id: "driver.<name>", expected_revision: 0, idempotency_key}`.
   The name is a lowercase letter followed by lowercase letters or digits.
   Entries live in `bee.driver.<name>.binding`, `.descriptor`, `.profiles`
   and `.security`.
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
      "login_evidence": {
        "command": "echoagent",
        "any_of": [{"kind": "auth_status", "argv": ["--version"], "success_exit_code": 0, "timeout_ms": 5000}]
      },
      "platform": {"os": ["linux", "darwin"], "arch": ["x86_64", "amd64", "arm64", "aarch64"]},
      "codec": "claude-stream-json",
      "configure": "plain",
      "json_paths": {},
      "flags": {},
      "provider_home": {"files": []},
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
      "argv_templates": {
        "window": {"argv": [{"render": "greeting", "context": "window"}], "readiness": "none"},
        "first_turn": {"argv": [], "readiness": "none"},
        "resume": {"argv": [], "readiness": "none"}
      }
    }
  },
  {
    "id": "bee.driver.echoagent.binding:prepare",
    "kind": "function.lua",
    "data": {
      "source": "local universal = require(\"universal\")\nreturn {handle = universal.prepare(\"bee.driver.echoagent.descriptor:cli\")}\n",
      "method": "handle",
      "imports": {"universal": "bee.drivers.binding:universal"}
    }
  },
  {
    "id": "bee.driver.echoagent.binding:dispatch",
    "kind": "function.lua",
    "data": {
      "source": "local universal = require(\"universal\")\nreturn {handle = universal.dispatch(\"bee.driver.echoagent.descriptor:cli\")}\n",
      "method": "handle",
      "imports": {"universal": "bee.drivers.binding:universal"}
    }
  },
  {
    "id": "bee.driver.echoagent.binding:normalize",
    "kind": "function.lua",
    "data": {
      "source": "local universal = require(\"universal\")\nreturn {handle = universal.normalize(\"bee.driver.echoagent.descriptor:cli\")}\n",
      "method": "handle",
      "imports": {"universal": "bee.drivers.binding:universal"}
    }
  },
  {
    "id": "bee.driver.echoagent.binding:locate",
    "kind": "function.lua",
    "data": {
      "source": "local universal = require(\"universal\")\nreturn {handle = universal.locate(\"bee.driver.echoagent.descriptor:cli\")}\n",
      "method": "handle",
      "imports": {"universal": "bee.drivers.binding:universal"}
    }
  },
  {
    "id": "bee.driver.echoagent.binding:configure",
    "kind": "function.lua",
    "data": {
      "source": "local universal = require(\"universal\")\nreturn {handle = universal.configure(\"plain\", {plain = function(_: unknown): {[string]: unknown} return {ok = true, delivery = {files = {}, arguments = {}}} end}, \"bee.driver.echoagent.descriptor:cli\")}\n",
      "method": "handle",
      "imports": {"universal": "bee.drivers.binding:universal"},
      "security": {"policies": ["bee.driver.echoagent.security:descriptor_read"]}
    }
  },
  {
    "id": "bee.driver.echoagent.security:descriptor_read",
    "kind": "security.policy",
    "data": {"policy": {"effect": "allow", "actions": ["registry.get", "registry.snapshot"], "resources": ["*"]}}
  },
  {
    "id": "bee.driver.echoagent.binding:binding",
    "kind": "contract.binding",
    "meta": {
      "type": "harness.driver",
      "driver_id": "echoagent",
      "descriptor_ref": "bee.driver.echoagent.descriptor:cli",
      "profiles_ref": "bee.driver.echoagent.profiles:profiles"
    },
    "data": {
      "contracts": [
        {
          "contract": "bee.drivers:driver",
          "methods": {
            "prepare": "bee.driver.echoagent.binding:prepare",
            "dispatch": "bee.driver.echoagent.binding:dispatch",
            "normalize": "bee.driver.echoagent.binding:normalize",
            "configure": "bee.driver.echoagent.binding:configure"
          }
        },
        {"contract": "bee.drivers:locate_facet", "methods": {"locate": "bee.driver.echoagent.binding:locate"}}
      ]
    }
  },
  {
    "id": "bee.driver.echoagent.profiles:profiles",
    "kind": "registry.entry",
    "meta": {"type": "harness.profile", "driver_ref": "bee.driver.echoagent.binding:binding"},
    "data": {
      "driver": {
        "schema_revision": "bee.driver@1",
        "kind": "harness",
        "title": "Echo agent",
        "implementation_version": "1.0.0",
        "default_profile": "window",
        "profiles": [
          {
            "id": "window",
            "mode": "window",
            "protocol": "pty",
            "protocol_revision": "native-window-1",
            "answer_path": {"strategy": "none"},
            "resume": {"strategy": "none", "portable": false},
            "inbound": [],
            "interrupt": {"methods": ["signal_group"]}
          }
        ]
      }
    }
  },
  {
    "id": "bee.driver.echoagent.profiles:window",
    "kind": "registry.entry",
    "meta": {"type": "bee.launch_definition"},
    "data": {
      "title": "Echo agent",
      "binding_ref": "bee.driver.echoagent.binding:binding",
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
      "allowed_overrides": ["workdir"],
      "profile_restrictions": {"provider.options.greeting": {"kind": "declared"}}
    }
  }
]
```

To write a driver for your CLI, replace `echoagent` in every id, the title, the
executable path and the descriptor's options and argv. Keep the binding
methods as written: they select the shared implementation for your descriptor.
Do not copy a codec.

## Descriptor fields

- `executable` is the name the policy's `executables` binds to an absolute path.
- `version_probe.argv` must print a version; `pattern` (optional) extracts it.
- `login_evidence` says how readiness learns the CLI is signed in:
  `file_exists` for a login file, `env_present` for a key variable,
  `auth_status` for a status command. A CLI without an account declares its
  version command as `auth_status`, as above; a window does not wait for it.
- `options.fields` holds one editor control per option: `value_schema`,
  `label`, `section`, `group`, `security_class` (`free` for a person's own
  choice), `support` (the `--help` flag that proves the installed CLI accepts
  it) and `render` (argv tokens). The policy's `profile_restrictions` lists
  each option a person may set; others show as disabled by host policy.
- `argv_templates.window.argv` is the window command line;
  `{"render": "<field>", "context": "window"}` inserts an option's tokens.
  Every template names its `readiness` (`none` when the CLI reports nothing);
  `first_turn` and `resume` stay empty for a window-only CLI.
- `codec` names a shared stream decoder. A window-only CLI names any listed
  codec (`claude-stream-json`) because a window decodes no stream.
  `json_paths`, `flags` and `provider_home.files` stay empty unless the CLI
  has them.
- `configure` names the configure renderer; `plain` delivers nothing. The
  configure method reads the descriptor, so it names the overlay's
  `descriptor_read` policy, which may grant only `registry.get` and
  `registry.snapshot`.

Batch and session profiles, hooks, MCP, credentials, logins and endpoints
follow the shipped drivers: see `reference_drivers/opencode` and
`component/driver`.

## When it does not appear

- `delivery preflight` names schema and authority problems.
- Agents counts unavailable entries ("U to show") with their status: a
  missing executable, an unsupported platform, absent login evidence.
- The profile editor shows only options the installed CLI's `support`
  evidence confirms and the policy admits.
