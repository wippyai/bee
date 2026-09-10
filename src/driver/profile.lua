-- MIT. Decodes a binding's meta.driver record into typed profiles. Every
-- field has an exact shape or a conservative default; unknown fields and
-- unsupported values are rejected, never guessed.
local bounds = require("bounds")
local types = require("types")
local M = {}
M.SCHEMA_REVISION = "bee.driver@1"
M.MAX_PROFILES = 16
M.DEFAULT_READY_TIMEOUT_MS = 15000
local function object(value: unknown, what: string): ({[string]: unknown}?, string?)
    local result = bounds.object(value)
    if not result then return nil, what .. " must be an object" end
    return result, nil
end
local function members(value: unknown, variants: {string}, what: string): ({string}?, string?)
    if value == nil then return {}, nil end
    local list, list_error = bounds.ids(value, true)
    if not list then return nil, what .. ": " .. tostring(list_error) end
    for _, item in ipairs(list) do
        if not bounds.member(item, variants) then return nil, what .. " does not support " .. item end
    end
    return list, nil
end
local function optional_ref(value: {[string]: unknown}, name: string, what: string): (string?, string?)
    local raw: unknown = value[name]
    if raw == nil then return nil, nil end
    local ref = bounds.id(raw)
    if not ref then return nil, what .. "." .. name .. " is not an identifier" end
    return ref, nil
end
local function flag(value: {[string]: unknown}, name: string, default: boolean, what: string): (boolean, string?)
    local raw: unknown = value[name]
    if raw == nil then return default, nil end
    if type(raw) ~= "boolean" then return default, what .. "." .. name .. " must be a boolean" end
    return raw, nil
end
local function optional_count(value: {[string]: unknown}, name: string, what: string): (integer?, string?)
    local raw: unknown = value[name]
    if raw == nil then return nil, nil end
    local number = bounds.count(raw)
    if not number then return nil, what .. "." .. name .. " must be a nonnegative integer" end
    return number, nil
end
local function decode_profile(value: unknown): (types.Profile?, string?)
    local profile, profile_error = object(value, "profile")
    if not profile then return nil, profile_error end
    local unknown_field = bounds.fields(profile, {"id", "mode", "protocol", "protocol_revision", "hooks", "answer_path", "resume", "inbound",
        "isolation_env", "trust_preanswer", "exit_codes_trustworthy", "input_ready", "interrupt", "mcp", "sandbox", "permission_exchange"})
    if unknown_field then return nil, "profile: " .. unknown_field end
    local id = bounds.id(profile.id)
    if not id then return nil, "profile id is not an identifier" end
    local what = "profile " .. id
    local mode = bounds.member(profile.mode, {"window", "session", "batch"})
    if not mode then return nil, what .. ": mode must be window, session or batch" end
    local protocol = bounds.member(profile.protocol, {"stream-json", "acp", "app-server", "rpc", "sdk", "native", "pty", "http-events"})
    if not protocol then return nil, what .. ": protocol is not supported" end
    local revision = bounds.id(profile.protocol_revision)
    if not revision then return nil, what .. ": protocol_revision is not an identifier" end
    local hooks: types.Hooks = {transports = {}, events = {}}
    if profile.hooks ~= nil then
        local declared, declared_error = object(profile.hooks, what .. ".hooks")
        if not declared then return nil, declared_error end
        local unknown_hook = bounds.fields(declared, {"transports", "events", "adapter_ref"})
        if unknown_hook then return nil, what .. ".hooks: " .. unknown_hook end
        local transports, transports_error = members(declared.transports, {"command", "http", "mcp_tool", "plugin"}, what .. ".hooks.transports")
        if not transports then return nil, transports_error end
        local events, events_error = bounds.ids(declared.events or {}, true)
        if not events then return nil, what .. ".hooks.events: " .. tostring(events_error) end
        local adapter, adapter_error = optional_ref(declared, "adapter_ref", what .. ".hooks")
        if adapter_error then return nil, adapter_error end
        hooks = {transports = transports :: {types.HookTransport}, events = events, adapter_ref = adapter}
    end
    local answer, answer_error = object(profile.answer_path, what .. ".answer_path")
    if not answer then return nil, answer_error end
    local unknown_answer = bounds.fields(answer, {"strategy", "adapter_ref"})
    if unknown_answer then return nil, what .. ".answer_path: " .. unknown_answer end
    local strategy = bounds.member(answer.strategy, {"terminal_field", "accumulate", "transcript", "runner"})
    local answer_adapter = bounds.id(answer.adapter_ref)
    if not strategy then return nil, what .. ".answer_path.strategy is not supported" end
    if not answer_adapter then return nil, what .. ".answer_path.adapter_ref is not an identifier" end
    local resume: types.Resume = {strategy = "none", portable = false}
    if profile.resume ~= nil then
        local declared, declared_error = object(profile.resume, what .. ".resume")
        if not declared then return nil, declared_error end
        local unknown_resume = bounds.fields(declared, {"strategy", "portable"})
        if unknown_resume then return nil, what .. ".resume: " .. unknown_resume end
        local resume_strategy = bounds.member(declared.strategy, {"per-process", "in-process", "none"})
        if not resume_strategy then return nil, what .. ".resume.strategy is not supported" end
        local portable, portable_error = flag(declared, "portable", false, what .. ".resume")
        if portable_error then return nil, portable_error end
        resume = {strategy = resume_strategy :: types.ResumeStrategy, portable = portable}
    end
    local inbound, inbound_error = members(profile.inbound, {"next_turn", "mcp_pull", "stream_stdin", "steering", "acp", "rpc", "runner"}, what .. ".inbound")
    if not inbound then return nil, inbound_error end
    local isolation: types.IsolationEnv = {variables = {}, private_home = true}
    if profile.isolation_env ~= nil then
        local declared, declared_error = object(profile.isolation_env, what .. ".isolation_env")
        if not declared then return nil, declared_error end
        local unknown_isolation = bounds.fields(declared, {"variables", "private_home"})
        if unknown_isolation then return nil, what .. ".isolation_env: " .. unknown_isolation end
        local variables, variables_error = bounds.ids(declared.variables or {}, true)
        if not variables then return nil, what .. ".isolation_env.variables: " .. tostring(variables_error) end
        local private_home, home_error = flag(declared, "private_home", true, what .. ".isolation_env")
        if home_error then return nil, home_error end
        isolation = {variables = variables, private_home = private_home}
    end
    local trust: types.TrustPreanswer = {supported = false}
    if profile.trust_preanswer ~= nil then
        local declared, declared_error = object(profile.trust_preanswer, what .. ".trust_preanswer")
        if not declared then return nil, declared_error end
        local unknown_trust = bounds.fields(declared, {"supported", "adapter_ref"})
        if unknown_trust then return nil, what .. ".trust_preanswer: " .. unknown_trust end
        local supported, supported_error = flag(declared, "supported", false, what .. ".trust_preanswer")
        if supported_error then return nil, supported_error end
        local adapter, adapter_error = optional_ref(declared, "adapter_ref", what .. ".trust_preanswer")
        if adapter_error then return nil, adapter_error end
        if supported and not adapter then return nil, what .. ".trust_preanswer needs adapter_ref when supported" end
        trust = {supported = supported, adapter_ref = adapter}
    end
    local exit_codes, exit_error = flag(profile, "exit_codes_trustworthy", false, what)
    if exit_error then return nil, exit_error end
    local ready: types.InputReady = {strategy = "none", timeout_ms = M.DEFAULT_READY_TIMEOUT_MS}
    if profile.input_ready ~= nil then
        local declared, declared_error = object(profile.input_ready, what .. ".input_ready")
        if not declared then return nil, declared_error end
        local unknown_ready = bounds.fields(declared, {"strategy", "adapter_ref", "timeout_ms"})
        if unknown_ready then return nil, what .. ".input_ready: " .. unknown_ready end
        local ready_strategy = bounds.member(declared.strategy, {"protocol", "hook", "probe", "none"})
        if not ready_strategy then return nil, what .. ".input_ready.strategy is not supported" end
        local adapter, adapter_error = optional_ref(declared, "adapter_ref", what .. ".input_ready")
        if adapter_error then return nil, adapter_error end
        local timeout, timeout_error = optional_count(declared, "timeout_ms", what .. ".input_ready")
        if timeout_error then return nil, timeout_error end
        ready = {strategy = ready_strategy :: types.ReadyStrategy, adapter_ref = adapter, timeout_ms = timeout or M.DEFAULT_READY_TIMEOUT_MS}
    end
    local interrupt: types.Interrupt = {methods = {}}
    if profile.interrupt ~= nil then
        local declared, declared_error = object(profile.interrupt, what .. ".interrupt")
        if not declared then return nil, declared_error end
        local unknown_interrupt = bounds.fields(declared, {"methods", "adapter_ref"})
        if unknown_interrupt then return nil, what .. ".interrupt: " .. unknown_interrupt end
        local methods, methods_error = members(declared.methods, {"protocol", "signal_group", "runner_cancel"}, what .. ".interrupt.methods")
        if not methods then return nil, methods_error end
        local adapter, adapter_error = optional_ref(declared, "adapter_ref", what .. ".interrupt")
        if adapter_error then return nil, adapter_error end
        interrupt = {methods = methods :: {types.InterruptMethod}, adapter_ref = adapter}
    end
    local mcp: types.Mcp = {client_transports = {}}
    if profile.mcp ~= nil then
        local declared, declared_error = object(profile.mcp, what .. ".mcp")
        if not declared then return nil, declared_error end
        local unknown_mcp = bounds.fields(declared, {"client_transports", "bridge_ref", "tool_filter", "initialize_timeout_ms", "call_timeout_ceiling_ms"})
        if unknown_mcp then return nil, what .. ".mcp: " .. unknown_mcp end
        local transports, transports_error = members(declared.client_transports, {"stdio", "streamable_http", "sse", "ws"}, what .. ".mcp.client_transports")
        if not transports then return nil, transports_error end
        local bridge, bridge_error = optional_ref(declared, "bridge_ref", what .. ".mcp")
        if bridge_error then return nil, bridge_error end
        local filter: types.ToolFilter? = nil
        if declared.tool_filter ~= nil then
            local declared_filter, filter_error = object(declared.tool_filter, what .. ".mcp.tool_filter")
            if not declared_filter then return nil, filter_error end
            local unknown_filter = bounds.fields(declared_filter, {"syntax", "adapter_ref"})
            if unknown_filter then return nil, what .. ".mcp.tool_filter: " .. unknown_filter end
            local syntax, filter_adapter = bounds.id(declared_filter.syntax), bounds.id(declared_filter.adapter_ref)
            if not syntax or not filter_adapter then return nil, what .. ".mcp.tool_filter needs syntax and adapter_ref" end
            filter = {syntax = syntax, adapter_ref = filter_adapter}
        end
        local initialize, initialize_error = optional_count(declared, "initialize_timeout_ms", what .. ".mcp")
        if initialize_error then return nil, initialize_error end
        local ceiling, ceiling_error = optional_count(declared, "call_timeout_ceiling_ms", what .. ".mcp")
        if ceiling_error then return nil, ceiling_error end
        mcp = {client_transports = transports :: {types.McpTransport}, bridge_ref = bridge, tool_filter = filter, initialize_timeout_ms = initialize, call_timeout_ceiling_ms = ceiling}
    end
    local sandbox: types.Sandbox = {providers = {}, required_placement_features = {}}
    if profile.sandbox ~= nil then
        local declared, declared_error = object(profile.sandbox, what .. ".sandbox")
        if not declared then return nil, declared_error end
        local unknown_sandbox = bounds.fields(declared, {"providers", "required_placement_features"})
        if unknown_sandbox then return nil, what .. ".sandbox: " .. unknown_sandbox end
        local providers, providers_error = bounds.ids(declared.providers or {}, true)
        if not providers then return nil, what .. ".sandbox.providers: " .. tostring(providers_error) end
        local features, features_error = bounds.ids(declared.required_placement_features or {}, true)
        if not features then return nil, what .. ".sandbox.required_placement_features: " .. tostring(features_error) end
        sandbox = {providers = providers, required_placement_features = features}
    end
    local exchange: types.PermissionExchange = {mode = "none"}
    if profile.permission_exchange ~= nil then
        local declared, declared_error = object(profile.permission_exchange, what .. ".permission_exchange")
        if not declared then return nil, declared_error end
        local unknown_exchange = bounds.fields(declared, {"mode", "adapter_ref", "adapter_digest"})
        if unknown_exchange then return nil, what .. ".permission_exchange: " .. unknown_exchange end
        local exchange_mode = bounds.member(declared.mode, {"none", "adapter"})
        if not exchange_mode then return nil, what .. ".permission_exchange.mode must be none or adapter" end
        local adapter, adapter_error = optional_ref(declared, "adapter_ref", what .. ".permission_exchange")
        if adapter_error then return nil, adapter_error end
        local adapter_digest: string? = nil
        if declared.adapter_digest ~= nil then
            local raw = bounds.id(declared.adapter_digest)
            if not raw or #raw ~= 64 or not raw:match("^%x+$") then return nil, what .. ".permission_exchange.adapter_digest must be a sha256 hex digest" end
            adapter_digest = raw
        end
        if exchange_mode == "adapter" and (not adapter or not adapter_digest) then return nil, what .. ".permission_exchange needs adapter_ref and adapter_digest when enabled" end
        if exchange_mode == "none" and (adapter or adapter_digest) then return nil, what .. ".permission_exchange names an adapter while disabled" end
        exchange = {mode = exchange_mode :: types.PermissionMode, adapter_ref = adapter, adapter_digest = adapter_digest}
    end
    return {id = id, mode = mode :: types.Mode, protocol = protocol :: types.Protocol, protocol_revision = revision, hooks = hooks,
        answer_path = {strategy = strategy :: types.AnswerStrategy, adapter_ref = answer_adapter}, resume = resume, inbound = inbound :: {types.Inbound},
        isolation_env = isolation, trust_preanswer = trust, exit_codes_trustworthy = exit_codes, input_ready = ready, interrupt = interrupt, mcp = mcp, sandbox = sandbox,
        permission_exchange = exchange}, nil
end
M.decode_profile = decode_profile
function M.decode(value: unknown): (types.Binding?, string?)
    local binding, binding_error = object(value, "meta.driver")
    if not binding then return nil, binding_error end
    local unknown_field = bounds.fields(binding, {"schema_revision", "kind", "title", "implementation_version", "profiles", "default_profile"})
    if unknown_field then return nil, "meta.driver: " .. unknown_field end
    if binding.schema_revision ~= M.SCHEMA_REVISION then return nil, "meta.driver.schema_revision must be " .. M.SCHEMA_REVISION end
    local kind = bounds.member(binding.kind, {"harness", "runner"})
    if not kind then return nil, "meta.driver.kind must be harness or runner" end
    local title = bounds.line(binding.title, 160)
    if not title then return nil, "meta.driver.title must be one bounded line" end
    local version = bounds.id(binding.implementation_version)
    if not version then return nil, "meta.driver.implementation_version is not an identifier" end
    local default_profile = bounds.id(binding.default_profile)
    if not default_profile then return nil, "meta.driver.default_profile is not an identifier" end
    local raw_profiles: unknown = binding.profiles
    if type(raw_profiles) ~= "table" then return nil, "meta.driver.profiles must be a list" end
    local profiles: {types.Profile} = {}
    local seen: {[string]: boolean} = {}
    local count = 0
    for key in pairs(raw_profiles) do
        if type(key) ~= "number" then return nil, "meta.driver.profiles must be a list" end
        count = count + 1
    end
    if count == 0 then return nil, "meta.driver.profiles must name at least one profile" end
    if count > M.MAX_PROFILES then return nil, "meta.driver.profiles exceeds " .. tostring(M.MAX_PROFILES) end
    for index = 1, count do
        local profile, profile_error = decode_profile(raw_profiles[index])
        if not profile then return nil, profile_error end
        if seen[profile.id] then return nil, "profile " .. profile.id .. " is declared twice" end
        seen[profile.id] = true
        profiles[index] = profile
    end
    if not seen[default_profile] then return nil, "default_profile " .. default_profile .. " is not declared" end
    return {schema_revision = M.SCHEMA_REVISION, kind = kind, title = title, implementation_version = version, profiles = profiles, default_profile = default_profile}, nil
end
function M.find(binding: types.Binding, id: string): types.Profile?
    for _, profile in ipairs(binding.profiles) do
        if profile.id == id then return profile end
    end
    return nil
end
return M
