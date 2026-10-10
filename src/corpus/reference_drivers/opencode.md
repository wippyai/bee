# Reference driver: OpenCode CLI

The complete `bee.driver.opencode` driver, every file verbatim from Bee's source. A CLI driver is these entries: the env entries naming its executable, the CLI descriptor (version and help probes, login evidence, options), the profiles it admits, the credential projections, the security policies, and the binding whose prepare, dispatch, normalize, configure and locate functions implement the driver contract (`component/driver`).

To write a driver for another CLI, author an overlay named `driver.<name>` (for example `driver.gemini`) and copy these files into it with every namespace renamed from `bee.driver.opencode` to `bee.driver.<name>`. An overlay driver defines its entries in `bee.driver.<name>.binding`, `.descriptor`, `.profiles`, `.security`, `.types` and `.credentials`. Its `.credentials` holds exactly one `bee.credential_format` for provider `<name>`: the login file under the home and any files to initialize beside it; profiles name the credential `<name>_login`, and the descriptor's `provider_home.files` list exactly those files: the login file with kind `login` and `source_path` equal to its path, each initialized file with kind `state` and no `source_path`, every file with a boolean `optional` and `write_back: false`, since an approved driver's machine login is admitted without write-back. Approving the driver lets its sessions use the person's machine login for that provider, and no other. The executable path is host configuration: leave `env/_index.yaml` out, and in each launch policy replace `executable_env` with `executables: {<executable>: <absolute path>}` naming the installed CLI, which the person reviews with the overlay. Change the descriptor, argv rendering and output normalization to the new CLI, then freeze and deliver it. The person approves the overlay and admits the new binding through harness activation (`component/harness`).

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
- name: api_key
  kind: env.variable
  storage: bee.credentials.env:entered_values
  variable: OPENCODE_PERSON_KEY
  default: ''
  meta:
    type: bee.credential_source
    credential_name: opencode_api_key
    credential:
      provider: opencode
      format_ref: bee.driver.opencode.credentials:credential_format
      workspace_id: '*'
      audience: '*'
      projection_kinds: [environment]
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
    schema_revision: bee.driver.cli-descriptor@4
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
      permission_answers:
        window:
          transport: hook_http
          adapter_ref: bee.driver.permission:permission_request_hook
          reason: The supervised observer relays Bee hook decisions to the OpenCode permission reply endpoint.
        first_turn:
          transport: provider
          reason: Bee runs opencode run --format json with stdin closed; batch turns retain provider permission handling.
        resume:
          transport: provider
          reason: Bee runs opencode run --format json with stdin closed; batch turns retain provider permission handling.
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
          id: system_prompt_append
          group: behavior
          security_class: free
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
          - kind: config
            contexts:
            - window
            file: .config/opencode/opencode.json
            format: json
            path:
            - model
            merge: set
            value:
              field: provider.model
          id: model
          group: model/provider
          security_class: free
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
          id: variant
          group: model/provider
          security_class: free
        providers:
          path: provider.options.providers
          value_schema:
            type: object
            maxProperties: 16
            additionalProperties:
              type: object
              additionalProperties: false
              properties:
                npm:
                  type: string
                  enum:
                  - '@ai-sdk/openai-compatible'
                name:
                  type: string
                  maxLength: 128
                options:
                  type: object
                  additionalProperties: false
                  properties:
                    baseURL:
                      type: string
                      maxLength: 512
                    apiKey:
                      type: string
                      enum:
                      - '{env:OPENAI_API_KEY}'
                    includeUsage:
                      type: boolean
                  required:
                  - baseURL
                  - apiKey
                models:
                  type: object
                  maxProperties: 16
                  additionalProperties:
                    type: object
                    additionalProperties: false
                    properties:
                      name:
                        type: string
                        maxLength: 128
                      tool_call:
                        type: boolean
                      limit:
                        type: object
                        additionalProperties: false
                        properties:
                          context:
                            type: integer
                            minimum: 1
                          output:
                            type: integer
                            minimum: 1
                      options:
                        type: object
                        additionalProperties: false
                        properties:
                          temperature:
                            type: number
                            minimum: 0
                            maximum: 2
                          seed:
                            type: integer
                          maxTokens:
                            type: integer
                            minimum: 1
              required:
              - npm
              - options
              - models
          label: Custom providers
          description: Custom providers
          section: advanced
          order: 10
          contexts: &id001
          - window
          - first_turn
          - resume
          support:
            config_schema_ref: bee.driver.opencode.descriptor:cli
          render:
          - kind: config
            contexts: *id001
            file: .config/opencode/opencode.json
            format: json
            path:
            - provider
            merge: set
            value:
              field: provider.options.providers
          id: providers
          group: model/provider
          security_class: host-ceiling
        enabled_providers:
          path: provider.options.enabled_providers
          value_schema:
            type: array
            maxItems: 16
            items:
              type: string
              maxLength: 128
          label: Enabled providers
          description: Enabled providers
          section: advanced
          order: 11
          contexts: *id001
          support:
            config_schema_ref: bee.driver.opencode.descriptor:cli
          render:
          - kind: config
            contexts: *id001
            file: .config/opencode/opencode.json
            format: json
            path:
            - enabled_providers
            merge: set
            value:
              field: provider.options.enabled_providers
          id: enabled_providers
          group: model/provider
          security_class: host-ceiling
        folder_trust:
          id: folder_trust
          path: provider.options.folder_trust
          value_schema:
            type: string
            enum:
            - ask
          default: ask
          label: Folder trust
          description: Folder trust is unsupported by this driver
          group: access/trust
          security_class: person-only
          section: advanced
          order: 90
          contexts:
          - window
          - first_turn
          - resume
          support:
            config_schema_ref: bee.driver.opencode.descriptor:cli
          render: []
          trust:
            unsupported: true
      rules:
      - kind: values
        field: gateway_hooks
        values:
        - SessionStart
        - UserPromptSubmit
        - PreToolUse
        - PostToolUse
        - PostToolUseFailure
        - PermissionRequest
        - Stop
        - StopFailure
        - SessionEnd
        message: unsupported gateway hook
      - kind: profile_fields
        profile: batch
        fields:
        - gateway_hooks
        message: gateway hooks require the window profile
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
        observer: local_http
        hooks:
          transports: [http]
          events:
          - SessionStart
          - UserPromptSubmit
          - PreToolUse
          - PostToolUse
          - PostToolUseFailure
          - PermissionRequest
          - Stop
          - StopFailure
          - SessionEnd
          adapter_ref: bee.driver.opencode.descriptor:cli
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
          mode: adapter
          adapter_ref: bee.driver.permission:permission_request_hook
          adapter_digest: a9b3fec616bd9b96c628352d4f1e8d5078f0a708444c9507a148f68d17c72867
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
    private_credentials:
    - opencode_login
    - opencode_api_key
    docker_credentials:
    - opencode_login
    - opencode_api_key
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
    - opencode_api_key
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
    environment_destination: OPENAI_API_KEY
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
    - profile_get
    - profile_list
    - profile_put
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
    - question
    gateway_hooks: []
    prepare_options: {}
    placement_profiles:
    - bee.placement.profiles:native
    - bee.placement.docker.profiles:coding
    profile_restrictions:
      provider.model:
        kind: declared
      provider.options.providers:
        kind: declared
      provider.options.enabled_providers:
        kind: declared
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
    - profile_get
    - profile_list
    - profile_put
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
    - question
    - capabilities
    - overlay
    - docs
    - components
    - install_request
    - uninstall_request
    - install_status
    - delivery
    - tests
    - app_tools
    - publish
    gateway_surface:
      access:
        policy: agent-access
        traits:
        - bee.app:share
        - bee.app:tools
        - bee.hub:library
    gateway_hooks:
    - SessionStart
    - UserPromptSubmit
    - PreToolUse
    - PostToolUse
    - PostToolUseFailure
    - PermissionRequest
    - Stop
    - StopFailure
    - SessionEnd
    prepare_options: {}
    placement_profiles:
    - bee.placement.profiles:native
    - bee.placement.docker.profiles:coding
    profile_restrictions:
      provider.model:
        kind: declared
      provider.options.providers:
        kind: declared
      provider.options.enabled_providers:
        kind: declared
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
    observer_events: bee.driver.opencode.observer:events
    bounds: bee.values:bounds
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
    - funcs.call
    resources:
    - '*'
    expression: (action == "registry.get" && resource == "bee.driver.opencode.descriptor:cli") || action == "registry.snapshot" || (action == "funcs.call" && resource == "bee.placement.profiles:context")
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
-- SPDX-License-Identifier: MIT
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
local observer_events = require("observer_events")
local bounds = require("bounds")
local function handle(request: configure_protocol.Request): {[string]: unknown}
    if request.provider_ref or request.provider then
        return {ok = false, error = "opencode configures no model provider; the user selects models in their own OpenCode home"}
    end
    local files: {configure_protocol.Configuration} = {}
    local gateway = request.gateway
    if gateway then
        for _, event in ipairs(gateway.hooks) do
            if not bounds.member(event, observer_events.HOOKS) then return {ok = false, error = "opencode does not support gateway hook event " .. event} end
        end
    end
    if gateway and #gateway.tools > 0 then
        local file, err = configuration.settings_file(gateway)
        if not file then return {ok = false, error = tostring(err)} end
        files[#files + 1] = file
    elseif request.private_home == true then
        local file, err = configuration.login_configuration()
        if not file then return {ok = false, error = tostring(err)} end
        files[#files + 1] = file
    end
    return {ok = true, delivery = {arguments = {}, files = files}}
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

## observer/_index.yaml

```yaml
version: '1.0'
namespace: bee.driver.opencode.observer
entries:
- name: events
  kind: library.lua
  source: file://events.lua
  imports:
    bounds: bee.values:bounds
- name: declaration
  kind: registry.entry
  meta:
    type: bee.driver.window_observer
    driver_ref: bee.driver.opencode.binding:binding
    profile_id: window
    observer: local_http
  data:
    process: bee.driver.opencode.observer:subscriber
    server_arguments: [serve, --port, '0', --hostname, 127.0.0.1]
    endpoint_pattern: 'http://127%.0%.0%.1:%d+'
- name: subscriber
  kind: process.lua
  source: file://subscriber.lua
  method: main
  modules: [process, channel, http_client, json]
  imports:
    bounds: bee.values:bounds
    framing: bee.driver.transport:framing
    events: bee.driver.opencode.observer:events
    observer_types: bee.driver:window_observer
    delivery: bee.driver.opencode.observer:delivery
  security:
    policies: [bee.driver.opencode.observer:http_policy]
- name: http_policy
  kind: security.policy.expr
  policy:
    effect: allow
    actions: [http_client.request, http_client.private_ip, process.send]
    resources: ['*']
    expression: action == "process.send" || (action == "http_client.private_ip" && resource == "127.0.0.1") || (action == "http_client.request" && resource matches "^http://127[.]0[.]0[.]1:[0-9]+/")
- name: delivery
  kind: library.lua
  source: file://delivery.lua
  imports:
    bounds: bee.values:bounds
```

## observer/delivery.lua

```lua
-- SPDX-License-Identifier: MIT
local bounds = require("bounds")
local M = {}
type Object = {[string]: unknown}
type IO = {submit: (Object) -> Object?, permission: (string, Object) -> (), record: (string) -> ()}
function M.send(io: IO, row: Object): boolean
    local ok = pcall(function()
        local response = io.submit(row)
        if row.hook_event_name ~= "PermissionRequest" or not response then return end
        local output = bounds.object(response.hookSpecificOutput) or {}
        local decision = bounds.object(output.decision) or {}
        if decision.behavior == "allow" or decision.behavior == "deny" then
            io.permission(tostring(row.permission_id), {reply = decision.behavior == "allow" and "once" or "reject", message = decision.message})
        end
    end)
    if not ok then io.record(tostring(row.hook_event_name) .. ": hook delivery failed") end
    return ok
end
return M
```

## observer/events.lua

```lua
-- SPDX-License-Identifier: MIT
local bounds = require("bounds")
local M = {}
M.HOOKS = {"SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "Stop", "StopFailure", "SessionEnd"}
type Object = {[string]: unknown}
type Message = {info: Object, parts: {[string]: Object}}
type Session = {messages: {[string]: Message}, order: {string}, prompts: {[string]: boolean}, permissions: {[string]: boolean}, tools: {[string]: boolean}, active: string?, stopped: {[string]: boolean}, ended: boolean, failed: boolean}
type State = {sessions: {[string]: Session}, failure: string?}
function M.new(): State return {sessions = {}} end
local function text(message: Message): string
    local parts: {string} = {}
    local ids: {string} = {}
    for id in pairs(message.parts) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local part = message.parts[id]
        if part.type == "text" and part.synthetic ~= true and part.ignored ~= true and type(part.text) == "string" then parts[#parts + 1] = part.text end
    end
    return table.concat(parts, "\n")
end
local function record(event: string, session: string, fields: Object?): Object
    local row: Object = {hook_event_name = event, session_id = session}
    for key, value in pairs(fields or {}) do row[key] = value end
    return row
end
local function session_start(state: State, info: Object): {Object}
    local id = bounds.id(info.id)
    if not id or info.parentID ~= nil or state.sessions[id] then return {} end
    state.sessions[id] = {messages = {}, order = {}, prompts = {}, permissions = {}, tools = {}, stopped = {}, ended = false, failed = false}
    return {record("SessionStart", id, {source = "startup"})}
end
local function message_update(session: Session, info: Object)
    local id = bounds.id(info.id)
    if not id then return end
    if not session.messages[id] then
        local created: Message = {info = info, parts = {}}
        session.messages[id] = created
        session.order[#session.order + 1] = id
    end
    session.messages[id].info = info
end
local function prompt(session: Session, id: string, session_id: string): {Object}
    local message = session.messages[id]
    if not message or message.info.role ~= "user" or session.prompts[id] then return {} end
    local content = text(message)
    if content == "" then return {} end
    session.prompts[id] = true
    session.active = id
    session.failed = false
    return {record("UserPromptSubmit", session_id, {prompt_id = id, prompt = content})}
end
local function part_update(session: Session, part: Object, session_id: string): {Object}
    local message_id = bounds.id(part.messageID)
    local part_id = bounds.id(part.id)
    if not message_id or not part_id then return {} end
    local message = session.messages[message_id]
    if part.type ~= "tool" then
        if message then message.parts[part_id] = part end
        return prompt(session, message_id, session_id)
    end
    local tool = bounds.id(part.tool)
    local call = bounds.id(part.callID)
    local status = bounds.object(part.state)
    if not tool or not call or not status then return {} end
    local key_base = message_id .. ":" .. call .. ":"
    if session.tools[key_base .. "PostToolUse"] or session.tools[key_base .. "PostToolUseFailure"] then return {} end
    if message then message.parts[part_id] = part end
    local name: string? = nil
    if status.status == "running" then name = "PreToolUse"
    elseif status.status == "completed" then name = "PostToolUse"
    elseif status.status == "error" then name = "PostToolUseFailure" end
    if not name then return {} end
    local key = key_base .. name
    if session.tools[key] then return {} end
    session.tools[key] = true
    return {record(name, session_id, {tool_name = tool, tool_use_id = call, tool_input = status.input or {}, tool_response = status.output, error = status.error})}
end
local function stop(state: State, session: Session, id: string): {Object}
    local active = session.active
    if not active or session.stopped[active] then return {} end
    for i = #session.order, 1, -1 do
        local message = session.messages[session.order[i]]
        local info = message.info
        if info.role == "assistant" and info.parentID == active then
            if info.error ~= nil then session.failed = true end
            local time = bounds.object(info.time)
            if not session.failed and info.finish == "stop" and time and type(time.completed) == "number" then
                session.stopped[active] = true
                return {record("Stop", id, {prompt_id = active, last_assistant_message = text(message), stop_hook_active = false})}
            end
        end
    end
    if session.failed then
        session.stopped[active] = true
        return {record("StopFailure", id, {prompt_id = active, error = "OpenCode turn failed"})}
    end
    state.failure = "OpenCode idle omitted a completed reply"
    return {}
end
function M.snapshot(state: State, id: string, messages: {unknown}): {Object}
    local session: Session? = state.sessions[id]
    if not session then return {} end
    local rows: {Object} = {}
    for _, raw in ipairs(messages) do
        local message = bounds.object(raw)
        local info = message and bounds.object(message.info)
        if info and message then
            message_update(session, info)
            local parts = bounds.array(message.parts, 4096) or {}
            for _, raw_part in ipairs(parts) do
                local part = bounds.object(raw_part)
                if part then
                    for _, row in ipairs(part_update(session, part, id)) do rows[#rows + 1] = row end
                end
            end
        end
    end
    return rows
end
function M.event(state: State, event: Object): {Object}
    local properties = bounds.object(event.properties) or {}
    local info = bounds.object(properties.info)
    if event.type == "session.created" or event.type == "session.updated" then return info and session_start(state, info) or {} end
    local id = bounds.id(properties.sessionID) or (info and bounds.id(info.sessionID))
    local part = bounds.object(properties.part)
    id = id or (part and bounds.id(part.sessionID))
    if event.type == "session.deleted" then id = info and bounds.id(info.id) end
    if not id or not state.sessions[id] then return {} end
    local session: Session = state.sessions[id]
    if event.type == "message.updated" and info then message_update(session, info); return prompt(session, tostring(info.id), id) end
    if event.type == "message.part.updated" and part then return part_update(session, part, id) end
    if event.type == "permission.asked" then
        local permission_id = bounds.id(properties.id)
        if not permission_id or session.permissions[permission_id] then return {} end
        session.permissions[permission_id] = true
        local tool = bounds.object(properties.tool) or {}
        local input = properties.metadata or {}
        local name = properties.permission
        for _, message in pairs(session.messages) do
            for _, known in pairs(message.parts) do
                if known.type == "tool" and known.callID == tool.callID then
                    local status = bounds.object(known.state)
                    if status then input = status.input or input; name = known.tool end
                end
            end
        end
        return {record("PermissionRequest", id, {tool_name = name, tool_use_id = tool.callID or properties.id, tool_input = input, permission_id = permission_id})}
    end
    if event.type == "session.error" then session.failed = true end
    if event.type == "session.idle" then return stop(state, session, id) end
    if event.type == "session.status" and (bounds.object(properties.status) or {}).type == "idle" then return stop(state, session, id) end
    if event.type == "session.deleted" and not session.ended then session.ended = true; return {record("SessionEnd", id, {reason = "clear"})} end
    return {}
end
function M.statuses(state: State, statuses: Object): {Object}
    local rows: {Object} = {}
    for id in pairs(state.sessions) do
        for _, row in ipairs(M.event(state, {type = "session.status", properties = {sessionID = id, status = statuses[id] or {type = "idle"}}})) do rows[#rows + 1] = row end
    end
    return rows
end
function M.finish(state: State): {Object}
    local rows: {Object} = {}
    for id, session in pairs(state.sessions) do
        if not session.ended then session.ended = true; rows[#rows + 1] = record("SessionEnd", id, {reason = "prompt_input_exit"}) end
    end
    return rows
end
return M
```

## observer/subscriber.lua

```lua
-- SPDX-License-Identifier: MIT
local process = require("process")
local channel = require("channel")
local http = require("http_client")
local json = require("json")
local bounds = require("bounds")
local framing = require("framing")
local events = require("events")
local observer_types = require("observer_types")
local delivery = require("delivery")
local function main(input: observer_types.Input)
    local state = events.new()
    local session_id: string? = nil
    local stopping = false
    local released = false
    local operation = "startup"
    local stream: http.StreamReader? = nil
    local controls = assert(process.listen(input.topic .. ".control", {message = true}))
    local signals = assert(process.events())
    local function report(kind: string, detail: string)
        process.send(input.owner, input.topic, {kind = kind, detail = detail})
    end
    local function get(path: string): unknown
        operation = "GET " .. path
        local reply = http.get(input.endpoint .. path, {timeout = "10s", headers = {["x-opencode-directory"] = input.working_directory}})
        if reply then operation = operation .. " (HTTP " .. tostring(reply.status_code) .. ")" end
        if not reply or reply.status_code ~= 200 then error("OpenCode read failed: " .. path) end
        return json.decode(assert(reply.body))
    end
    local function post(path: string, body: unknown): unknown
        operation = "POST " .. path
        local reply = http.post(input.endpoint .. path, {timeout = "10s", headers = {["Content-Type"] = "application/json", ["x-opencode-directory"] = input.working_directory}, body = json.encode(body)})
        if reply then operation = operation .. " (HTTP " .. tostring(reply.status_code) .. ")" end
        if not reply or reply.status_code < 200 or reply.status_code >= 300 then error("OpenCode write failed: " .. path) end
        return reply.body and reply.body ~= "" and json.decode(reply.body) or nil
    end
    local admitted: {[string]: boolean} = {}
    for _, name in ipairs(input.hooks) do admitted[name] = true end
    local function deliver(row: {[string]: unknown})
        if not admitted[tostring(row.hook_event_name)] then return end
        delivery.send({
            submit = function(payload: {[string]: unknown}): {[string]: unknown}?
                local reply = http.post(input.hook_endpoint, {timeout = payload.hook_event_name == "PermissionRequest" and "240s" or "10s",
                    headers = {Authorization = "Bearer " .. input.hook_token, ["Content-Type"] = "application/json"}, body = json.encode(payload)})
                if not reply or reply.status_code < 200 or reply.status_code >= 300 then error("hook endpoint refused delivery") end
                return reply.body and reply.body ~= "" and bounds.object(json.decode(reply.body)) or nil
            end,
            permission = function(id: string, decision: {[string]: unknown}) post("/permission/" .. id .. "/reply", decision) end,
            record = function(detail: string) report("delivery_failed", detail) end,
        }, row)
    end
    local function deliver_all(rows: {{[string]: unknown}})
        for _, row in ipairs(rows) do
            if row.hook_event_name == "PermissionRequest" then coroutine.spawn(function() deliver(row) end) else deliver(row) end
        end
        if state.failure then report("mapping_failed", state.failure); state.failure = nil end
    end
    local function snapshot(id: string)
        deliver_all(events.snapshot(state, id, assert(bounds.array(get("/session/" .. id .. "/message"), 4096))))
    end
    local function reconcile()
        for _, raw in ipairs(assert(bounds.array(get("/session"), 4096))) do
            local info = bounds.object(raw)
            if info and (info.id == session_id or state.sessions[tostring(info.id)]) then
                deliver_all(events.event(state, {type = "session.updated", properties = {info = info}}))
            end
        end
        for id in pairs(state.sessions) do snapshot(id) end
        local statuses = bounds.object(get("/session/status")) or {}
        deliver_all(events.statuses(state, statuses))
        for _, raw in ipairs(assert(bounds.array(get("/permission"), 4096))) do
            local permission = bounds.object(raw)
            if permission then deliver_all(events.event(state, {type = "permission.asked", properties = permission})) end
        end
    end
    local prompt: string? = nil
    local model: string? = nil
    for i, arg in ipairs(input.argv) do
        if arg == "--session" or arg == "-s" then session_id = input.argv[i + 1]
        elseif arg == "--prompt" then prompt = input.argv[i + 1]
        elseif arg == "--model" or arg == "-m" then model = input.argv[i + 1] end
    end
    coroutine.spawn(function()
        while not stopping do
            local selected = channel.select({controls:case_receive(), signals:case_receive()})
            if not selected.ok then return end
            if selected.channel == signals or tostring(selected.value:from()) == input.owner then
                local data = selected.channel == controls and bounds.object(selected.value:payload():data()) or nil
                if data and data.command == "release" then
                    released = true
                    if prompt and session_id then
                        local body: {[string]: unknown} = {parts = {{type = "text", text = prompt}}}
                        if model then local provider, name = model:match("^([^/]+)/(.+)$"); if provider then body.model = {providerID = provider, modelID = name} end end
                        local ok = pcall(post, "/session/" .. session_id .. "/prompt_async", body)
                        if not ok then report("prompt_failed", "OpenCode initial prompt submission failed") end
                    end
                else
                    stopping = true
                    if stream then stream:close() end
                    return
                end
            end
        end
    end)
    local first = true
    local ok = pcall(function()
        while not stopping do
            operation = "GET /event"
            local response = http.get(input.endpoint .. "/event", {stream = true, timeout = "0s", headers = {["x-opencode-directory"] = input.working_directory}})
            if response then operation = operation .. " (HTTP " .. tostring(response.status_code) .. ")" end
            if not response or response.status_code ~= 200 or not response.stream then error("OpenCode event subscription failed") end
            stream = response.stream
            if first then
                if not session_id then
                    local session = assert(bounds.object(post("/session", json.decode("{}"))))
                    session_id = assert(bounds.id(session.id))
                end
                reconcile()
                process.send(input.owner, input.topic, {kind = "ready", arguments = {"attach", input.endpoint, "--dir", input.working_directory, "--session", session_id}})
                first = false
            else
                report("reconnected", "OpenCode stream reconnected; rereading session messages")
                reconcile()
            end
            local framer = framing.new()
            while not stopping do
                local chunk = stream:read(8192)
                if not chunk or chunk == "" then break end
                for _, line in ipairs(assert(framing.feed(framer, chunk))) do
                    if line:sub(1, 5) == "data:" then
                        local event = bounds.object(json.decode(line:sub(6)))
                        if event then
                            operation = "event " .. tostring(event.type)
                            local properties = bounds.object(event.properties) or {}
                            local id = bounds.id(properties.sessionID)
                            local info = bounds.object(properties.info)
                            id = id or (info and bounds.id(info.sessionID))
                            if id and state.sessions[id] then
                                local status = bounds.object(properties.status) or {}
                                if event.type == "session.idle" or (event.type == "session.status" and status.type == "idle") then
                                    snapshot(id)
                                elseif event.type == "message.updated" and info and info.role == "user" then
                                    local message_id = assert(bounds.id(info.id))
                                    deliver_all(events.snapshot(state, id, {get("/session/" .. id .. "/message/" .. message_id)}))
                                end
                            end
                            deliver_all(events.event(state, event))
                        end
                    end
                end
            end
            stream:close()
            stream = nil
            if not stopping and not released then error("OpenCode stream ended before window startup") end
        end
    end)
    if stream then stream:close() end
    deliver_all(events.finish(state))
    if not ok and not stopping then report("failed", "OpenCode observer stopped during " .. operation) end
    process.send(input.owner, input.topic, {kind = "stopped"})
    process.unlisten(controls)
end
return {main = main}
```
