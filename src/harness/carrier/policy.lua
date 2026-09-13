-- MIT. The launch policy: a host-selected protected entry that decides
-- what a managed launch requires of its placement and binds executables.
-- The caller and the driver never choose it; the owner pins its digest.
local hash = require("hash")
local registry = require("registry")
local env = require("env")
local bounds = require("bounds")
local canonical = require("canonical")
local placement_types = require("placement_types")
local configuration = require("configuration")
local preferences = require("preferences")
local M = {}
M.SCHEMA = "bee.launch-policy@2"
M.TYPE = placement_types.LAUNCH_POLICY_TYPE
-- The host enables a permission exchange by naming the adapter, the
-- acceptance record and the proven fixture digest here; a production
-- policy may only name the adapter the profile itself pins.
type PermissionExchange = {adapter_ref: string, acceptance_ref: string, fixture_digest: string, approver_policy: string, poll_ms: integer, ttl_ms: integer}
type EnvironmentResolver = (string) -> (string?, string?)
type Policy = {
    ref: string,
    digest: string,
    permission_exchange: PermissionExchange?,
    provider_ref: string?,
    instructions: string?,
    instruction_builder: configuration.InstructionBuilder?,
    prepare_options: {[string]: unknown},
    required_cleanup: placement_types.Capability,
    required_exit_observation: placement_types.ExitObservation,
    start_ms: integer,
    stop_grace_ms: integer,
    drain_ms: integer,
    runner_drain_ms: integer,
    retain_ms: integer,
    executables: {[string]: string},
    environment: {[string]: string},
    -- gateway_tools names the gateway tools a launch under this policy is
    -- admitted to; empty means the launch has no gateway binding.
    gateway_tools: {string},
    -- gateway_ttl_ms bounds a gateway binding's life from admission.
    gateway_ttl_ms: integer,
    -- gateway_hooks names the hook events the launch reports to the gateway.
    gateway_hooks: {string},
    hook_command_ref: string?,
    fixture: boolean,
    placement_binding: string?,
}
local function decode_map(value: unknown, name: string): ({[string]: string}?, string?)
    local result: {[string]: string} = {}
    if value == nil then return result, nil end
    local object = bounds.object(value)
    if not object then return nil, name .. " must be an object" end
    for key, item in pairs(object) do
        local text = bounds.text(item, 4096)
        if not text or text == "" then return nil, name .. "." .. key .. " must be nonempty text" end
        result[key] = text
    end
    return result, nil
end
-- executable_env resolves only named env.variable entries. It is deliberately
-- separate from registry interpolation: plain registry.entry data is opaque,
-- and an absent optional component must make its policy unavailable rather
-- than fail registry boot. The resolved value is included in the policy digest.
local function decode_executable_env(value: unknown, executables: {[string]: string}, resolve: EnvironmentResolver): string?
    if value == nil then return nil end
    local object = bounds.object(value)
    if not object then return "executable_env must be an object" end
    for executable, variable in pairs(object) do
        if not bounds.id(executable) then return "executable_env names a non-identifier" end
        if executables[executable] ~= nil then return "executable_env." .. executable .. " overlaps executables" end
        local variable_ref = bounds.id(variable)
        if not variable_ref then return "executable_env." .. executable .. " is not an env.variable identifier" end
        local resolved, resolve_error = resolve(variable_ref)
        if type(resolved) ~= "string" or resolve_error then
            return "executable_env." .. executable .. " is unavailable from " .. variable_ref
        end
        executables[executable] = resolved
    end
    return nil
end
function M.decode(ref: string, entry: {[string]: unknown}, resolver: EnvironmentResolver?, selected: preferences.Value?): (Policy?, string?)
    local meta = bounds.object(entry.meta) or {}
    if meta.type ~= M.TYPE then return nil, ref .. " is not a launch policy" end
    local data = bounds.object(entry.data)
    if not data then return nil, ref .. " has no data" end
    local unknown_field = bounds.fields(data, {"schema_revision", "required_cleanup", "required_exit_observation", "start_ms", "stop_grace_ms", "drain_ms", "runner_drain_ms", "retain_ms", "executables", "executable_env", "environment", "fixture", "permission_exchange", "provider_ref", "instructions", "instruction_builder", "prepare_options", "profile_options", "profile_instructions", "gateway_tools", "gateway_ttl_ms", "gateway_hooks", "hook_command_ref", "placement_binding"})
    if unknown_field then return nil, ref .. ": " .. unknown_field end
    if data.schema_revision ~= M.SCHEMA then return nil, ref .. ": schema_revision must be " .. M.SCHEMA end
    local cleanup = bounds.member(data.required_cleanup, placement_types.CAPABILITIES)
    if not cleanup then return nil, ref .. ": required_cleanup must name a cleanup capability" end
    local observation = bounds.member(data.required_exit_observation, placement_types.EXIT_OBSERVATIONS)
    if not observation then return nil, ref .. ": required_exit_observation must be independent or eof_gated" end
    local start_ms = bounds.integer(data.start_ms == nil and 15000 or data.start_ms)
    local stop_grace_ms = bounds.integer(data.stop_grace_ms == nil and 5000 or data.stop_grace_ms)
    local drain_ms = bounds.integer(data.drain_ms == nil and 5000 or data.drain_ms)
    local retain_ms = bounds.integer(data.retain_ms == nil and 30000 or data.retain_ms)
    local runner_drain_ms = bounds.integer(data.runner_drain_ms == nil and 5000 or data.runner_drain_ms)
    if not start_ms or start_ms < 1 then return nil, ref .. ": start_ms must be a positive integer" end
    if not stop_grace_ms or stop_grace_ms < 0 then return nil, ref .. ": stop_grace_ms must be a nonnegative integer" end
    if not drain_ms or drain_ms < 0 then return nil, ref .. ": drain_ms must be a nonnegative integer" end
    if not retain_ms or retain_ms < 100 then return nil, ref .. ": retain_ms must be at least 100" end
    if not runner_drain_ms or runner_drain_ms < 100 then return nil, ref .. ": runner_drain_ms must be at least 100" end
    local executables, executables_error = decode_map(data.executables, "executables")
    if not executables then return nil, ref .. ": " .. tostring(executables_error) end
    local resolve = resolver or function(variable_ref: string): (string?, string?) return env.get(variable_ref) end
    local executable_env_error = decode_executable_env(data.executable_env, executables, resolve)
    if executable_env_error then return nil, ref .. ": " .. executable_env_error end
    local environment, environment_error = decode_map(data.environment, "environment")
    if not environment then return nil, ref .. ": " .. tostring(environment_error) end
    local fixture = data.fixture == true
    if observation == "eof_gated" and not fixture then return nil, ref .. ": eof_gated execution is permitted only in a fixture policy" end
    local exchange: PermissionExchange? = nil
    if data.permission_exchange ~= nil then
        local declared = bounds.object(data.permission_exchange)
        if not declared then return nil, ref .. ": permission_exchange must be an object" end
        local unknown_exchange = bounds.fields(declared, {"adapter_ref", "acceptance_ref", "fixture_digest", "approver_policy", "poll_ms", "ttl_ms"})
        if unknown_exchange then return nil, ref .. ": permission_exchange: " .. unknown_exchange end
        local adapter_ref, acceptance_ref, approver = bounds.id(declared.adapter_ref), bounds.id(declared.acceptance_ref), bounds.id(declared.approver_policy)
        if not adapter_ref or not acceptance_ref or not approver then return nil, ref .. ": permission_exchange names adapter_ref, acceptance_ref and approver_policy" end
        local fixture_digest = bounds.id(declared.fixture_digest)
        if not fixture_digest then return nil, ref .. ": permission_exchange.fixture_digest must be a sha256 hex digest" end
        if #fixture_digest ~= 64 or not fixture_digest:match("^%x+$") then return nil, ref .. ": permission_exchange.fixture_digest must be a sha256 hex digest" end
        local poll_ms = bounds.integer(declared.poll_ms == nil and 1000 or declared.poll_ms)
        local ttl_ms = bounds.integer(declared.ttl_ms == nil and 600000 or declared.ttl_ms)
        if not poll_ms or poll_ms < 50 or not ttl_ms or ttl_ms < 1000 then return nil, ref .. ": permission_exchange poll_ms and ttl_ms are out of range" end
        exchange = {adapter_ref = adapter_ref, acceptance_ref = acceptance_ref, fixture_digest = fixture_digest, approver_policy = approver, poll_ms = poll_ms, ttl_ms = ttl_ms}
    end
    local digest_input: {[string]: unknown} = {}
    for key, value in pairs(data) do digest_input[key] = value end
    digest_input.executables = executables
    local encoded, encode_error = canonical.encode(digest_input)
    if not encoded then return nil, ref .. ": " .. tostring(encode_error) end
    local digest, hash_error = hash.sha256(encoded)
    if hash_error or not digest then return nil, ref .. ": digest failed" end
    -- Credentials bind the host policy; the launch separately measures the
    -- preferences and resulting configuration under that policy.
    if selected then
        local effective, preference_error = preferences.apply(data, selected)
        if not effective then return nil, ref .. ": " .. tostring(preference_error) end
        data = effective
    end
    -- Host-owned options for the driver's prepare: scalar values the
    -- driver decodes under its own rules (permission mode, turn bound,
    -- sandbox); the caller never chooses them.
    local prepare_options: {[string]: unknown} = {}
    if data.prepare_options ~= nil then
        local declared = bounds.object(data.prepare_options)
        if not declared then return nil, ref .. ": prepare_options must be an object" end
        local count = 0
        for name, item in pairs(declared) do
            count = count + 1
            if count > 8 then return nil, ref .. ": prepare_options carries more than 8 options" end
            if not bounds.id(name) then return nil, ref .. ": prepare_options names a non-identifier" end
            if type(item) ~= "string" and type(item) ~= "number" and type(item) ~= "boolean" then return nil, ref .. ": prepare_options." .. name .. " must be a scalar" end
            prepare_options[name] = item
        end
    end
    local instructions, instructions_error = configuration.instructions(data.instructions)
    if instructions_error then return nil, ref .. ": " .. instructions_error end
    local instruction_builder, builder_error = configuration.instruction_builder(data.instruction_builder)
    if builder_error then return nil, ref .. ": " .. builder_error end
    local provider_ref: string? = nil
    if data.provider_ref ~= nil then
        provider_ref = bounds.id(data.provider_ref)
        if not provider_ref then return nil, ref .. ": provider_ref is not an identifier" end
    end
    local placement_binding: string? = nil
    if data.placement_binding ~= nil then
        placement_binding = bounds.id(data.placement_binding)
        if not placement_binding then return nil, ref .. ": placement_binding is not an identifier" end
    end
    local options: {[string]: unknown} = {}
    for name, item in pairs(prepare_options) do options[name] = item end
    local gateway_tools: {string} = {}
    if data.gateway_tools ~= nil then
        local declared, tools_error = bounds.ids(data.gateway_tools, true)
        if not declared then return nil, ref .. ": gateway_tools: " .. tostring(tools_error) end
        table.sort(declared)
        gateway_tools = declared
    end
    local gateway_hooks: {string} = {}
    if data.gateway_hooks ~= nil then
        local declared, hooks_error = bounds.ids(data.gateway_hooks, true)
        if not declared then return nil, ref .. ": gateway_hooks: " .. tostring(hooks_error) end
        -- Events a harness emits only while shutting down are not reliably
        -- captured, so no generated configuration admits them.
        for _, event in ipairs(declared) do
            if event == "SessionEnd" or event == "StopFailure" then return nil, ref .. ": gateway_hooks names " .. event .. ", a shutdown event that generated configuration does not admit in this version" end
        end
        table.sort(declared)
        gateway_hooks = declared
    end
    local hook_command_ref: string? = nil
    if data.hook_command_ref ~= nil then
        hook_command_ref = bounds.id(data.hook_command_ref)
        if not hook_command_ref or #gateway_hooks == 0 then return nil, ref .. ": hook_command_ref requires hooks and an env.variable identifier" end
    end
    local gateway_ttl_ms = 3600000
    if data.gateway_ttl_ms ~= nil then
        local declared = bounds.integer(data.gateway_ttl_ms)
        if not declared or declared < 1000 or declared > 86400000 then return nil, ref .. ": gateway_ttl_ms must be between 1000 and 86400000" end
        gateway_ttl_ms = declared
    end
    local decoded: Policy = {ref = ref, digest = digest, permission_exchange = exchange, provider_ref = provider_ref, instructions = instructions, instruction_builder = instruction_builder, prepare_options = options, required_cleanup = cleanup :: placement_types.Capability, required_exit_observation = observation :: placement_types.ExitObservation,
        start_ms = start_ms, stop_grace_ms = stop_grace_ms, drain_ms = drain_ms, runner_drain_ms = runner_drain_ms, retain_ms = retain_ms, executables = executables, environment = environment, gateway_tools = gateway_tools, gateway_ttl_ms = gateway_ttl_ms, gateway_hooks = gateway_hooks, hook_command_ref = hook_command_ref, fixture = fixture, placement_binding = placement_binding}
    return decoded, nil
end
function M.load(ref: string): (Policy?, string?)
    local entry, err = registry.get(ref)
    if err or not entry then return nil, "launch policy " .. ref .. " is not in the registry" end
    return M.decode(ref, entry)
end
return M
