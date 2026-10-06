# Reference driver: OpenCode CLI

The complete `bee.driver.opencode` driver, every file verbatim from Bee's source. A CLI driver is these entries: the env entries naming its executable, the CLI descriptor (version and help probes, login evidence, options), the profiles it admits, the credential projections, the security policies, and the binding whose prepare, dispatch, normalize, configure and locate functions implement the driver contract (`component/driver`).

To write a driver for another CLI, author an overlay named `driver.<name>` (for example `driver.gemini`) and copy these files into it with every namespace renamed from `bee.driver.opencode` to `bee.driver.<name>`. An overlay driver defines its entries in `bee.driver.<name>.binding`, `.descriptor`, `.profiles`, `.security`, `.types` and `.credentials`. Its `.credentials` holds exactly one `bee.credential_format` for provider `<name>`: the login file under the home and any files to initialize beside it; profiles name the credential `<name>_login`, and the descriptor's `provider_home.files` list exactly those files: the login file with kind `login` and `source_path` equal to its path, each initialized file with kind `state` and no `source_path`, every file with a boolean `optional` and `write_back: false`, since an approved driver's machine login is admitted without write-back. Approving the driver lets its sessions use the person's machine login for that provider, and no other. The executable path is host configuration: leave `env/_index.yaml` out, and in each launch policy replace `executable_env` with `executables: {<executable>: <absolute path>}` naming the installed CLI, which the person reviews with the overlay. Change the descriptor, argv rendering and output normalization to the new CLI, then freeze and deliver it. The person approves the overlay and admits the new binding through harness activation (`component/agents`).

## env/_index.yaml

```yaml
version: '1.0'
namespace: bee.driver.opencode.env
entries:
- name: executable
  kind: env.variable
  storage: bee.harness.host:environment
  variable: opencode
  default: ''
  readonly: true
```

## descriptor/_index.yaml

```yaml
version: '1.0'
namespace: bee.driver.opencode.descriptor
entries:
- name: cli
  kind: registry.entry
  meta:
    type: bee.driver.cli_descriptor
    comment: OpenCode CLI command, JSON event codec, login evidence and version probe
  data:
    schema_revision: bee.driver.cli-descriptor@3
    provider: opencode
    executable: opencode
    version_probe:
      argv:
      - --version
      pattern: ([0-9]+[.][0-9]+[.][0-9]+)
    login_evidence:
      command: opencode auth login
      any_of:
      - kind: file_exists
        paths:
        - .local/share/opencode/auth.json
        variable: XDG_DATA_HOME
        directory: .local/share
      - kind: file_exists
        paths:
        - .config/opencode/opencode.json
        - .config/opencode/opencode.jsonc
        variable: XDG_CONFIG_HOME
        directory: .config
      - kind: env_present
        names:
        - ANTHROPIC_API_KEY
        - OPENAI_API_KEY
        - GOOGLE_GENERATIVE_AI_API_KEY
        - XAI_API_KEY
        - OPENCODE_API_KEY
        - OPENCODE_CONFIG_CONTENT
    platform:
      os:
      - linux
      - darwin
      arch:
      - x86_64
      - amd64
      - arm64
      - aarch64
    codec: opencode-json-events
    json_paths:
      resume_id:
      - sessionID
      result_text:
      - part
      - text
      errors:
      - error
      - data
      - message
      usage:
      - part
      - tokens
    configure: opencode
    capabilities:
      budgets:
        provider_steps: agent_turn
        tokens: true
        cost_usd: false
        tool_calls: true
        wall_time_ms: true
      permission_answers:
        window:
          transport: provider
          reason: Bee runs opencode run --format json with stdin closed. It does not run the HTTP server permission API. The window retains provider prompts; no Bee
            hook transport is selected.
        first_turn:
          transport: provider
          reason: Bee runs opencode run --format json with stdin closed. It does not run the HTTP server permission API. The window retains provider prompts; no Bee
            hook transport is selected.
        resume:
          transport: provider
          reason: Bee runs opencode run --format json with stdin closed. It does not run the HTTP server permission API. The window retains provider prompts; no Bee
            hook transport is selected.
    options:
      profiles:
      - window
      - batch
      unknown_prefix: ''
      fields:
        resume_ref:
          type: id
          forbid_option: true
          invalid: resume_ref must not be a command-line option
        gateway_tools:
          type: ids
          pattern: ^[a-z_]+$
          default: []
          transform: sorted
          invalid: gateway_tools names a tool that is not a plain identifier
        gateway_hooks:
          type: ids
          default: []
        system_prompt_append:
          path: provider.system_prompt_append
          value_schema:
            type: string
            maxLength: 4096
          label: System prompt append
          description: Additional instructions in the session private home
          section: advanced
          order: 100
          contexts:
          - window
          - first_turn
          - resume
          support:
            config_schema_ref: bee.driver.opencode.descriptor:cli
          render:
          - kind: config
            contexts:
            - window
            - first_turn
            - resume
            file: .bee/system-prompt-append.txt
            format: text
            path: []
            merge: append
            value:
              field: provider.system_prompt_append
          - kind: config
            contexts:
            - window
            - first_turn
            - resume
            file: .config/opencode/opencode.json
            format: json
            path:
            - instructions
            merge: append
            value:
              field: provider.system_prompt_files
        model:
          path: provider.model
          value_schema:
            type: string
            maxLength: 128
            format: model
          label: Model
          description: OpenCode model
          section: basic
          order: 1
          contexts:
          - window
          - first_turn
          - resume
          support:
            help_probe:
              argv:
              - --help
              flag: --model
          render:
          - kind: argv
            contexts:
            - window
            - first_turn
            - resume
            tokens:
            - if: model
              then:
              - --model
              - field: model
        variant:
          path: provider.options.variant
          value_schema:
            type: string
            maxLength: 128
            format: id
          label: Variant
          description: OpenCode variant
          section: advanced
          order: 2
          contexts:
          - first_turn
          - resume
          support:
            help_probe:
              argv:
              - run
              - --help
              flag: --variant
          render:
          - kind: argv
            contexts:
            - first_turn
            - resume
            tokens:
            - if: variant
              then:
              - --variant
              - field: variant
      rules:
      - kind: forbid_nonempty
        field: gateway_hooks
        message: opencode declares no hook transport for gateway hooks
    flags: {}
    argv_templates:
      window:
        argv:
        - render: model
          context: window
        - if: resume_ref
          then:
          - --session
          - field: resume_ref
        - if: brief
          then:
          - --prompt
          - field: brief
        readiness: terminal:attached
        provider_home_private: false
        login: true
      first_turn:
        stdin: ''
        stdin_eof: true
        argv:
        - render: variant
          context: first_turn
        - render: model
          context: first_turn
        - run
        - --format
        - json
        - --
        - field: brief
        readiness: protocol:thread.started
        provider_home_private: true
      resume:
        stdin: ''
        stdin_eof: true
        argv:
        - render: variant
          context: resume
        - render: model
          context: resume
        - run
        - --format
        - json
        - --session
        - field: resume_ref
        - --
        - field: brief
        readiness: protocol:thread.started
        provider_home_private: true
    provider_home:
      extra_variables:
      - variable: XDG_CONFIG_HOME
        directory: .config
      - variable: XDG_DATA_HOME
        directory: .local/share
      files:
      - source_path: .local/share/opencode/auth.json
        path: .local/share/opencode/auth.json
        kind: login
        optional: true
        write_back: true
      - source_path: .config/opencode/opencode.json
        path: .config/opencode/.bee-global-opencode.json
        kind: config
        optional: true
        write_back: false
        container_content: '{}'
      - source_path: .config/opencode/towers.key
        path: .config/opencode/towers.key
        kind: config
        optional: true
        write_back: false
- name: command
  kind: registry.entry
  meta:
    type: bee.app_command
    comment: CLI command to launch OpenCode in the agent window
  data:
    name: opencode
    definition_id: bee.harness.app:app
    arguments:
    - bee.driver.opencode.profiles:default_window
    fullscreen: true
```

## profiles/_index.yaml

```yaml
version: '1.0'
namespace: bee.driver.opencode.profiles
entries:
- name: profiles
  kind: registry.entry
  meta:
    type: harness.profile
    driver_ref: bee.driver.opencode.binding:binding
  data:
    driver:
      schema_revision: bee.driver@1
      kind: harness
      title: OpenCode
      implementation_version: 1.18.32
      default_profile: window
      profiles:
      - id: batch
        mode: batch
        protocol: stream-json
        protocol_revision: opencode-run-json-1
        answer_path:
          strategy: accumulate
          adapter_ref: bee.driver.opencode.descriptor:cli
        resume:
          strategy: per-process
          portable: false
        inbound:
        - next_turn
        isolation_env:
          variables:
          - HOME
          private_home: true
        exit_codes_trustworthy: false
        input_ready:
          strategy: none
        interrupt:
          methods:
          - signal_group
        mcp:
          client_transports:
          - streamable_http
          initialize_timeout_ms: 30000
        permission_exchange:
          mode: none
      - id: window
        mode: window
        protocol: pty
        protocol_revision: native-window-1
        hooks:
          transports: []
          events: []
        answer_path:
          strategy: none
        resume:
          strategy: none
          portable: false
        isolation_env:
          variables:
          - HOME
          private_home: false
        exit_codes_trustworthy: false
        input_ready:
          strategy: none
        permission_exchange:
          mode: none
- name: default_window
  kind: registry.entry
  meta:
    type: bee.launch_definition
    comment: Component-owned OpenCode window declaration; the host separately selects its policy, activation, executable and permissions
  data:
    schema_revision: bee.launch-definition@1
    launch_id: opencode-window
    title: OpenCode
    binding_ref: bee.driver.opencode.binding:binding
    profile_id: window
    docker_credentials:
    - opencode_login
    policy_ref: bee.driver.opencode.security:launch_policy_opencode_window
    default_mode: window
    allowed_overrides:
    - thread
    - workdir
    workdir_policy:
      kind: declared_resource
      resource_ref: project
    thread_policy:
      kind: new
    session_resource: session
    credentials: []
    presentation:
      start_menu: true
      fullscreen: true
      reuse: never
- name: research_batch
  kind: registry.entry
  meta:
    type: bee.launch_definition
    comment: Component-owned bounded OpenCode batch route for a host-selected coordinator and caller-owned shared thread; the CLI offers no sandbox or permission
      flag Bee can select, so the host records it as unconfined
  data:
    schema_revision: bee.launch-definition@1
    launch_id: opencode-research-batch
    title: OpenCode researcher
    binding_ref: bee.driver.opencode.binding:binding
    profile_id: batch
    policy_ref: bee.driver.opencode.security:launch_policy_opencode_batch
    default_mode: batch
    allowed_overrides:
    - thread
    - workdir
    workdir_policy:
      kind: declared_resource
      resource_ref: project
    thread_policy:
      kind: caller
    session_resource: session
    credentials:
    - opencode_login
    presentation:
      start_menu: false
      fullscreen: false
      reuse: never
    unconfined: true
```

## credentials/_index.yaml

```yaml
version: '1.0'
namespace: bee.driver.opencode.credentials
entries:
- name: credential_format
  kind: registry.entry
  meta:
    type: bee.credential_format
    provider: opencode
  data:
    schema_revision: bee.credential-format@1
    file:
      path: .local/share/opencode/auth.json
      content_format: json
      initialize: []
```

## security/_index.yaml

```yaml
version: '1.0'
namespace: bee.driver.opencode.security
entries:
- name: launch_policy_opencode_batch
  kind: registry.entry
  meta:
    type: bee.launch_policy
    comment: Host-selected non-interactive OpenCode batch policy for bounded research actions on a caller-owned thread
  data:
    schema_revision: bee.launch-policy@3
    allowed_overrides:
    - thread
    - workdir
    required_cleanup: process_group
    required_exit_observation: independent

    stop_grace_ms: 5000
    drain_ms: 5000
    fixture: false
    executables: {}
    executable_env:
      opencode: bee.driver.opencode.env:executable
    environment: {}
    allow_host_home: false
    gateway_tools:
    - session_catalog
    - session_open
    - session_run
    - session_send
    - session_await
    - session_join
    - session_get
    - session_list
    - session_cancel
    - session_close
    - thread_read
    - thread_message
    gateway_hooks: []
    prepare_options: {}
    placement_profiles:
    - bee.placement.profiles:native
    - bee.placement.docker.profiles:coding
    profile_restrictions: {}
    profile_instructions: true
- name: launch_policy_opencode_window
  kind: registry.entry
  meta:
    type: bee.launch_policy
    comment: Host-selected executable binding for the component-owned OpenCode window; missing host executable leaves the
      declaration unavailable
  data:
    schema_revision: bee.launch-policy@3
    allowed_overrides:
    - thread
    - workdir
    required_cleanup: process_group
    required_exit_observation: independent

    stop_grace_ms: 5000
    drain_ms: 5000
    fixture: false
    executables: {}
    executable_env:
      opencode: bee.driver.opencode.env:executable
    environment: {}
    allow_host_home: true
    gateway_tools:
    - session_catalog
    - session_open
    - session_run
    - session_send
    - session_await
    - session_join
    - session_get
    - session_list
    - session_cancel
    - session_close
    - thread_read
    - thread_message
    - capabilities
    - overlay
    - docs
    - components
    - delivery
    gateway_hooks: []
    prepare_options: {}
    placement_profiles:
    - bee.placement.profiles:native
    - bee.placement.docker.profiles:coding
    profile_restrictions: {}
    profile_instructions: true
```

## binding/_index.yaml

```yaml
version: '1.0'
namespace: bee.driver.opencode.binding
entries:
- name: prepare
  kind: function.lua
  source: file://prepare.lua
  method: handle
  imports:
    universal: bee.driver.binding:universal
- name: dispatch
  kind: function.lua
  source: file://dispatch.lua
  method: handle
  imports:
    universal: bee.driver.binding:universal
- name: configure
  kind: function.lua
  source: file://configure.lua
  method: handle
  imports:
    configuration: bee.driver.opencode.binding:configuration
    configure_protocol: bee.driver.binding:configuration
    universal: bee.driver.binding:universal
  security:
    policies:
    - bee.driver.opencode.binding:configuration_policy
- name: locate
  kind: function.lua
  source: file://locate.lua
  method: handle
  imports:
    universal: bee.driver.binding:universal
- name: normalize
  kind: function.lua
  source: file://normalize.lua
  method: handle
  imports:
    universal: bee.driver.binding:universal
- name: configuration_policy
  kind: security.policy.expr
  meta:
    comment: Read only the descriptor that declares this configuration renderer
  policy:
    effect: allow
    actions:
    - registry.get
    - registry.snapshot
    resources:
    - '*'
    expression: (action == "registry.get" && resource == "bee.driver.opencode.descriptor:cli") || action == "registry.snapshot"
- name: configuration
  kind: library.lua
  source: file://configuration.lua
  modules:
  - hash
  imports:
    canonical: bee.values:canonical
    configure_protocol: bee.driver.binding:configuration
- name: binding
  kind: contract.binding
  contracts:
  - contract: bee.driver:driver
    methods:
      prepare: bee.driver.opencode.binding:prepare
      dispatch: bee.driver.opencode.binding:dispatch
      normalize: bee.driver.opencode.binding:normalize
      configure: bee.driver.opencode.binding:configure
  - contract: bee.driver:locate_facet
    methods:
      locate: bee.driver.opencode.binding:locate
  meta:
    type: harness.driver
    driver_id: opencode
    descriptor_ref: bee.driver.opencode.descriptor:cli
    accepts_model: false
    profiles_ref: bee.driver.opencode.profiles:profiles
```

## binding/configuration.lua

```lua
-- MIT. The OpenCode configuration file: the one file the inherited home
-- needs for the admitted gateway. OpenCode reads MCP servers only from its
-- JSON configuration, so configure renders opencode.json with the single
-- scoped bee remote entry and composes it into the user's own configuration
-- without replacing unrelated keys. Token bytes never enter the content;
-- placement injects them through secret_fields before OpenCode reads the
-- file. Models, providers and permissions stay
-- user-configured; this component renders no provider entry. OpenCode has no
-- hook transport, so any requested hook event is refused.
local hash = require("hash")
local canonical = require("canonical")
local configure_protocol = require("configure_protocol")
local M = {}
M.REVISION = "bee.opencode-config@1"
M.PATH = ".config/opencode/opencode.json"
M.BASE_PATH = ".config/opencode/.bee-global-opencode.json"
M.SCHEMA = "https://opencode.ai/config.json"
M.MAX_CONFIGURATION_BYTES = 8192
type Gateway = configure_protocol.GatewayInput
type Configuration = configure_protocol.Configuration
function M.settings_file(gateway: Gateway): (Configuration?, string?)
    for _, event in ipairs(gateway.hooks) do
        return nil, "opencode does not support gateway hook event " .. event
    end
    if #gateway.tools == 0 then return nil, "opencode configuration needs a gateway" end
    local document: {[string]: unknown} = {
        ["$schema"] = M.SCHEMA,
        mcp = {
            bee = {
                type = "remote",
                url = "http://" .. gateway.endpoint .. "/mcp/" .. gateway.action_id,
                enabled = true,
                headers = {Authorization = ""},
            },
        },
    }
    local content, content_error = canonical.encode(document)
    if not content then return nil, content_error end
    content = content .. "\n"
    if #content > M.MAX_CONFIGURATION_BYTES then return nil, "configuration exceeds " .. tostring(M.MAX_CONFIGURATION_BYTES) .. " bytes" end
    local digest, digest_error = hash.sha256(content)
    if not digest then return nil, tostring(digest_error or "configuration digest failed") end
    local operations: {configure_protocol.JsonOperation} = {
        {kind = "default", path = {"$schema"}},
        {kind = "insert", path = {"mcp", "bee"}},
    }
    local file: Configuration = {revision = M.REVISION, path = M.PATH, content = content, digest = digest,
        provider_ref = configure_protocol.GATEWAY_PROVIDER_REF,
        composition = {kind = "json_patch", base_path = M.BASE_PATH, operations = operations},
        secret_fields = {{path = {"mcp", "bee", "headers", "Authorization"}, environment = gateway.token_environment, prefix = "Bearer "}}}
    return file, nil
end
function M.login_configuration(): (configure_protocol.Configuration?, string?)
    local digest, digest_error = hash.sha256("")
    if not digest then return nil, tostring(digest_error or "configuration digest failed") end
    return {revision = M.REVISION, path = M.PATH, content = "", digest = digest,
        provider_ref = configure_protocol.LOGIN_PROVIDER_REF, composition = {kind = "copy", base_path = M.BASE_PATH}}, nil
end
return M
```

## binding/configure.lua

```lua
-- MIT. The pure OpenCode configuration contract: the carrier and placement
-- select both this method and its gateway from their pinned host records.
-- OpenCode takes no provider entry: models stay user-configured, so a
-- request naming one is refused rather than rendered.
local configuration = require("configuration")
local configure_protocol = require("configure_protocol")
local universal = require("universal")
local function handle(request: configure_protocol.Request): {[string]: unknown}
    if request.provider_ref or request.provider then
        return {ok = false, error = "opencode configures no model provider; the user selects models in their own OpenCode home"}
    end
    local prompt_files: {configure_protocol.Configuration} = {}
    if (not request.gateway or #request.gateway.tools == 0) then
        if request.gateway then
            for _, event in ipairs(request.gateway.hooks) do
                return {ok = false, error = "opencode does not support gateway hook event " .. event}
            end
        end
        if request.private_home ~= true then return {ok = true, delivery = {arguments = {}, files = {}}} end
        local file, file_error = configuration.login_configuration()
        if not file then return {ok = false, error = tostring(file_error)} end
        return {ok = true, delivery = {arguments = {}, files = {file}}}
    end
    local no_tools: {string} = {}
    local no_hooks: {string} = {}
    local empty_gateway: configure_protocol.GatewayInput = {endpoint = "", action_id = "", tools = no_tools, hooks = no_hooks, token_environment = "BEE_UNUSED"}
    local gateway = request.gateway or empty_gateway
    local file, file_error = configuration.settings_file(gateway)
    if not file then return {ok = false, error = tostring(file_error)} end
    prompt_files[#prompt_files + 1] = file
    return {ok = true, delivery = {arguments = {}, files = prompt_files}}
end
return {handle = universal.configure("opencode", {opencode = handle}, "bee.driver.opencode.descriptor:cli")}
```

## binding/dispatch.lua

```lua
-- MIT. The universal driver implements this contract method.
local universal = require("universal")
return {handle = universal.dispatch("bee.driver.opencode.descriptor:cli")}
```

## binding/locate.lua

```lua
-- MIT. The universal driver implements this contract method.
local universal = require("universal")
return {handle = universal.locate("bee.driver.opencode.descriptor:cli")}
```

## binding/normalize.lua

```lua
local universal = require("universal")
return {handle = universal.normalize("bee.driver.opencode.descriptor:cli")}
```

## binding/prepare.lua

```lua
-- MIT. The universal driver implements this contract method.
local universal = require("universal")
return {handle = universal.prepare("bee.driver.opencode.descriptor:cli")}
```
