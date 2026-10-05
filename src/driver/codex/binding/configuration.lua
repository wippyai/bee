-- MIT. The generated Codex provider configuration: the one file the
-- private CODEX_HOME needs for the selected login method. A host-owned provider
-- entry selects the endpoint, model and optional developer instructions; this
-- module decodes it exactly,
-- renders only the reviewed fields as TOML with proper string escaping,
-- and measures the result. No arbitrary TOML, includes, commands or
-- caller-selected destination ever pass through here, and the key itself
-- stays in the credential broker. ChatGPT uses the built-in OpenAI provider
-- and a separately admitted login file, never a custom credential endpoint.
local hash = require("hash")
local bounds = require("bounds")
local canonical = require("canonical")
local shared_configuration = require("shared_configuration")
local toml = require("toml")
local M = {}
M.REVISION = "bee.codex-config@1"
M.PROVIDER_TYPE = "bee.codex_provider"
M.PROVIDER_SCHEMA = "bee.codex-provider@1"
M.ENV_KEY = "OPENAI_API_KEY"
M.WIRE_API = "responses"
M.PATH = ".codex/config.toml"
M.MAX_URL_BYTES = shared_configuration.MAX_ENDPOINT_BYTES
-- Keep the provider projection aligned with the shared one-file configure
-- boundary. Escaping can expand otherwise-valid instruction text, so this is
-- checked after rendering rather than inferred from the input bound.
M.MAX_CONFIGURATION_BYTES = 8192
-- Instructions are host-owned provider configuration. Keep this below the
-- shared generated-file bound so a gateway section can still be appended.
M.MAX_DEVELOPER_INSTRUCTIONS_BYTES = 4096
M.REASONING_EFFORTS = {"low", "medium", "high", "xhigh", "max"}
type Provider = {ref: string, name: string, base_url: string?, authentication: string?, model: string?, reasoning_effort: string?, developer_instructions: string?, loopback_fixture: boolean, digest: string}
type Projection = {revision: string, path: string, content: string, digest: string, provider_ref: string, provider_digest: string}
type Gateway = {endpoint: string, action_id: string, tools: {string}, hooks: {string}, token_environment: string, hook_token_environment: string?}
local function developer_text(value: unknown): string?
    local declared = bounds.text(value, M.MAX_DEVELOPER_INSTRUCTIONS_BYTES)
    if not declared or declared == "" then return nil end
    -- TOML basic strings permit newline, carriage return and tab only through
    -- escapes. Reject all other control bytes before rendering; otherwise a
    -- NUL/backspace/form-feed would be copied into invalid TOML.
    for index = 1, #declared do
        local byte = declared:byte(index)
        if (byte < 0x20 and byte ~= 0x09 and byte ~= 0x0a and byte ~= 0x0d) or byte == 0x7f then return nil end
    end
    return declared
end
local function measurable(value: unknown): (string?, string?)
    local encoded, encode_error = canonical.encode(value)
    if not encoded then return nil, encode_error end
    local sum, hash_error = hash.sha256(encoded)
    if hash_error or not sum then return nil, "digest failed" end
    return sum, nil
end
-- The endpoint is a credential destination: https to a named host, or
-- plain http to the loopback address only for an explicit fixture.
function M.decode(ref: string, entry: {[string]: unknown}): (Provider?, string?)
    local meta = bounds.object(entry.meta) or {}
    if meta.type ~= M.PROVIDER_TYPE then return nil, ref .. " is not a " .. M.PROVIDER_TYPE end
    local data = bounds.object(entry.data)
    if not data then return nil, ref .. " has no data" end
    local unknown_field = bounds.fields(data, {"schema_revision", "name", "base_url", "model", "reasoning_effort", "developer_instructions", "loopback_fixture", "authentication"})
    if unknown_field then return nil, ref .. ": " .. unknown_field end
    if data.schema_revision ~= M.PROVIDER_SCHEMA then return nil, ref .. ": schema_revision must be " .. M.PROVIDER_SCHEMA end
    local name = bounds.id(data.name)
    if not name or not name:match("^[a-z][a-z0-9_]*$") then return nil, ref .. ": name must be a lowercase identifier" end
    local model = bounds.id(data.model)
    if data.model ~= nil and (not model or not model:match("^[A-Za-z0-9][A-Za-z0-9._-]*$")) then return nil, ref .. ": model must be a model identifier" end
    local reasoning_effort: string? = nil
    if data.reasoning_effort ~= nil then
        local declared = bounds.member(data.reasoning_effort, M.REASONING_EFFORTS)
        if not declared then return nil, ref .. ": reasoning_effort must be low, medium, high, xhigh or max" end
        reasoning_effort = declared
    end
    local developer_instructions: string? = nil
    if data.developer_instructions ~= nil then
        local declared = developer_text(data.developer_instructions)
        if not declared then return nil, ref .. ": developer_instructions must be bounded nonempty text without unsupported control bytes" end
        developer_instructions = declared
    end
    local loopback = data.loopback_fixture == true
    if data.loopback_fixture ~= nil and type(data.loopback_fixture) ~= "boolean" then return nil, ref .. ": loopback_fixture must be a boolean" end
    local authentication = data.authentication == nil and "api_key" or bounds.member(data.authentication, {"api_key", "chatgpt"})
    if not authentication then return nil, ref .. ": authentication must be api_key or chatgpt" end
    local base_url: string? = nil
    if authentication == "chatgpt" then
        if name ~= "openai" or data.base_url ~= nil or data.loopback_fixture ~= nil then
            return nil, ref .. ": chatgpt uses the built-in openai provider without base_url or loopback_fixture"
        end
    else
        if not model then return nil, ref .. ": model must be a model identifier" end
        local url_error: string?
        base_url, url_error = shared_configuration.endpoint(data.base_url, loopback, "base_url")
        if not base_url then return nil, ref .. ": " .. tostring(url_error) end
    end
    local digest, digest_error = measurable(data)
    if not digest then return nil, ref .. ": " .. tostring(digest_error) end
    return {ref = ref, name = name, base_url = base_url, authentication = authentication, model = model, reasoning_effort = reasoning_effort, developer_instructions = developer_instructions, loopback_fixture = loopback, digest = digest}, nil
end
-- render: exactly the reviewed fields, nothing else.
function M.render(provider: Provider, gateway_section: string?, instructions: string?): string
    local lines = {
        "# generated by bee " .. M.REVISION .. "; provider " .. provider.ref,
        "model_provider = " .. toml.string(provider.name),
    }
    if provider.model then lines[#lines + 1] = "model = " .. toml.string(provider.model) end
    if provider.reasoning_effort then lines[#lines + 1] = "model_reasoning_effort = " .. toml.string(provider.reasoning_effort) end
    local guidance = instructions or provider.developer_instructions
    if guidance then lines[#lines + 1] = "developer_instructions = " .. toml.string(guidance) end
    if provider.authentication == "chatgpt" then
        lines[#lines + 1] = 'forced_login_method = "chatgpt"'
        lines[#lines + 1] = 'cli_auth_credentials_store = "file"'
    else
        lines[#lines + 1] = ""
        lines[#lines + 1] = "[model_providers." .. provider.name .. "]"
        lines[#lines + 1] = "name = " .. toml.string(provider.name)
        lines[#lines + 1] = "base_url = " .. toml.string(provider.base_url or "")
        lines[#lines + 1] = "env_key = " .. toml.string(M.ENV_KEY)
        lines[#lines + 1] = "wire_api = " .. toml.string(M.WIRE_API)
    end
    lines[#lines + 1] = ""
    local content = table.concat(lines, "\n")
    -- The gateway section is rendered by the gateway library and appended
    -- verbatim, so the one file Codex reads carries both host selections.
    if gateway_section then content = content .. gateway_section end
    return content
end
-- projection: what placement writes into the private home, measured.
function M.projection(provider: Provider, gateway_section: string?, instructions: string?): (Projection?, string?)
    local content = M.render(provider, gateway_section, instructions)
    if #content > M.MAX_CONFIGURATION_BYTES then
        return nil, "configuration exceeds " .. tostring(M.MAX_CONFIGURATION_BYTES) .. " bytes after TOML escaping"
    end
    local digest, hash_error = hash.sha256(content)
    if hash_error or not digest then return nil, "configuration digest failed" end
    return {revision = M.REVISION, path = M.PATH, content = content, digest = digest, provider_ref = provider.ref, provider_digest = provider.digest}, nil
end
function M.login_configuration(): (shared_configuration.Configuration?, string?)
    local digest, err = hash.sha256("")
    if not digest then return nil, tostring(err or "Login configuration digest failed") end
    return {revision = "bee.codex-login-config@1", path = M.PATH, content = "", digest = digest,
        provider_ref = shared_configuration.LOGIN_PROVIDER_REF,
        composition = {kind = "copy", base_path = ".codex/.bee-user-config.toml"}}, nil
end
-- The gateway descriptor is already selected and validated by the host. This
-- driver owns the Codex syntax that consumes it; it never performs endpoint
-- lookup or receives token bytes.
function M.gateway_section(gateway: Gateway): string
    local url = "http://" .. gateway.endpoint .. "/mcp/" .. gateway.action_id
    local lines = {"[mcp_servers.bee]", "url = " .. toml.string(url), "bearer_token_env_var = " .. toml.string(gateway.token_environment), ""}
    if #gateway.hooks > 0 then
        local hook_url = "http://" .. gateway.endpoint .. "/hook/" .. gateway.action_id .. "/mcp"
        lines[#lines + 1] = "[mcp_servers.bee_hooks]"
        lines[#lines + 1] = "url = " .. toml.string(hook_url)
        lines[#lines + 1] = "bearer_token_env_var = " .. toml.string(gateway.hook_token_environment)
        lines[#lines + 1] = 'omit_tools_from = ["direct", "deferred", "code_mode"]'
        lines[#lines + 1] = ""
    end
    return table.concat(lines, "\n")
end
local HOOK_LABELS = {SessionStart = "session_start", UserPromptSubmit = "user_prompt_submit", PreToolUse = "pre_tool_use", PostToolUse = "post_tool_use", Stop = "stop", PermissionRequest = "permission_request"}
local HOOK_TEMPLATES = {
    SessionStart = {event = "${hook_event_name}", session_id = "${session_id}", source = "${source}"},
    UserPromptSubmit = {event = "${hook_event_name}", session_id = "${session_id}", turn_id = "${turn_id}", prompt = "${prompt}"},
    PreToolUse = {event = "${hook_event_name}", session_id = "${session_id}", turn_id = "${turn_id}", tool_name = "${tool_name}", tool_use_id = "${tool_use_id}", tool_input = "${tool_input}"},
    PermissionRequest = {event = "${hook_event_name}", session_id = "${session_id}", turn_id = "${turn_id}", tool_name = "${tool_name}", tool_input = "${tool_input}"},
    PostToolUse = {event = "${hook_event_name}", session_id = "${session_id}", turn_id = "${turn_id}", tool_name = "${tool_name}", tool_use_id = "${tool_use_id}", tool_response = "${tool_response}"},
    Stop = {event = "${hook_event_name}", session_id = "${session_id}", turn_id = "${turn_id}", last_assistant_message = "${last_assistant_message}"},
}
type HookHandler = {type: "mcp_tool", server: "bee_hooks", tool: "hook", input: {[string]: string}, timeout: integer}
type ProjectedHook = {event: string, label: string, handler: HookHandler, trusted_hash: string}
local function hook_projection(events: {string}): ({ProjectedHook}?, string?)
    local result: {ProjectedHook} = {}
    for index, event in ipairs(events) do
        local template, label = HOOK_TEMPLATES[event], HOOK_LABELS[event]
        if not template or not label then return nil, "Codex does not support gateway hook event " .. event end
        local handler: HookHandler = {type = "mcp_tool", server = "bee_hooks", tool = "hook", input = template, timeout = event == "PermissionRequest" and 650 or 2}
        local identity, identity_error = canonical.encode({event_name = label, hooks = {handler}})
        if not identity then return nil, identity_error end
        local digest, digest_error = hash.sha256(identity)
        if digest_error or not digest then return nil, "hook trust digest failed" end
        result[index] = {event = event, label = label, handler = handler, trusted_hash = "sha256:" .. digest}
    end
    return result, nil
end
local function measured(revision: string, path: string, content: string, provider_ref: string): (Projection?, string?)
    local digest, digest_error = hash.sha256(content)
    if digest_error or not digest then return nil, "configuration digest failed" end
    return {revision = revision, path = path, content = content, digest = digest, provider_ref = provider_ref, provider_digest = ""}, nil
end
function M.hook_files(gateway: Gateway, home_directory: string): ({Projection}?, string?)
    if #gateway.hooks == 0 then return {}, nil end
    local hooks: {[string]: unknown} = {}
    local trust: {[string]: string} = {}
    local projected, projection_error = hook_projection(gateway.hooks)
    if not projected then return nil, projection_error end
    for _, hook in ipairs(projected) do
        hooks[hook.event] = {{hooks = {hook.handler}}}
        trust[hook.label] = hook.trusted_hash
    end
    local content, content_error = canonical.encode({hooks = hooks})
    if not content then return nil, content_error end
    local hooks_file, hooks_error = measured("bee.codex-hooks@1", ".codex/hooks.json", content .. "\n", "bee.gateway.api:gateway_endpoint")
    if not hooks_file then return nil, hooks_error end
    local labels: {string} = {}
    for label in pairs(trust) do labels[#labels + 1] = label end
    table.sort(labels)
    local lines: {string} = {}
    for _, label in ipairs(labels) do
        lines[#lines + 1] = "[hooks.state." .. toml.string(home_directory .. "/.codex/hooks.json:" .. label .. ":0:0") .. "]"
        lines[#lines + 1] = 'trusted_hash = "' .. trust[label] .. '"'
    end
    local trust_file, trust_error = measured("bee.codex-hook-trust@1", ".codex/bee.config.toml", table.concat(lines, "\n") .. "\n", "bee.gateway.api:gateway_endpoint")
    if not trust_file then return nil, trust_error end
    return {hooks_file, trust_file}, nil
end
-- Session flags add Bee integration to Codex's ordinary user configuration.
-- No user config, hook file, login file or named profile is replaced.
function M.session_arguments(gateway: Gateway?): ({string}?, string?)
    local arguments: {string} = {}
    local function option(value: string)
        arguments[#arguments + 1] = "-c"
        arguments[#arguments + 1] = value
    end
    if not gateway then return arguments, nil end
    local function server(name: string, path: string, token: string, hidden: boolean)
        local value = "mcp_servers." .. name .. "={url=" .. toml.string("http://" .. gateway.endpoint .. path)
            .. ",bearer_token_env_var=" .. toml.string(token)
        if hidden then value = value .. ',omit_tools_from=["direct","deferred","code_mode"]' end
        option(value .. "}")
    end
    server("bee", "/mcp/" .. gateway.action_id, gateway.token_environment, false)
    if #gateway.hooks == 0 then return arguments, nil end
    if not gateway.hook_token_environment then return nil, "Codex hooks require their own token environment" end
    server("bee_hooks", "/hook/" .. gateway.action_id .. "/mcp", gateway.hook_token_environment, true)
    local projected, projection_error = hook_projection(gateway.hooks)
    if not projected then return nil, projection_error end
    local trust: {string} = {}
    for _, hook in ipairs(projected) do
        local names: {string} = {}
        for name in pairs(hook.handler.input) do names[#names + 1] = name end
        table.sort(names)
        local input: {string} = {}
        for _, name in ipairs(names) do input[#input + 1] = toml.string(name) .. "=" .. toml.string(hook.handler.input[name]) end
        option("hooks." .. hook.event .. '=[{hooks=[{type="mcp_tool",server="bee_hooks",tool="hook",timeout=' .. tostring(hook.handler.timeout) .. ',input={'
            .. table.concat(input, ",") .. "}}]}]")
        -- Supply the whole table: CLI dotted-key parsing does not preserve
        -- dots within a quoted source-path key.
        local key = "/<session-flags>/config.toml:" .. hook.label .. ":0:0"
        trust[#trust + 1] = toml.string(key) .. "={trusted_hash=" .. toml.string(hook.trusted_hash) .. "}"
    end
    option("hooks.state={" .. table.concat(trust, ",") .. "}")
    return arguments, nil
end
return M
