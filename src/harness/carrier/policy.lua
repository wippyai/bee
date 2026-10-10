-- MIT. The launch policy: a host-selected protected entry that decides
-- what a managed launch requires of its placement and binds executables.
-- The caller and the driver never choose it; the owner pins its digest.
local hash = require("hash")
local registry = require("registry")
local env = require("env")
local json = require("json")
local bounds = require("bounds")
local canonical = require("canonical")
local placement_types = require("placement_types")
local configuration = require("configuration")
local preferences = require("preferences")
local mcp = require("mcp")
local gateway_protocol = require("gateway_protocol")
local surface = require("surface")
local trait_access = require("trait_access")
local gateway_hooks_catalog = require("gateway_hooks_catalog")
local descriptors = require("descriptors")
local M = {}
M.MAX_AGENT_DELEGATES = 16
M.MAX_AGENT_MODELS = 16
M.SCHEMA = "bee.launch-policy@3"
M.TYPE = placement_types.LAUNCH_POLICY_TYPE
-- The launch overrides a host policy may admit. A request override takes
-- effect only when the definition allows it and its policy admits it too.
M.OVERRIDES = {"workdir", "thread", "placement"}
-- The host enables a permission exchange by naming the adapter, the
-- acceptance record and the proven fixture digest here; a production
-- policy may only name the adapter the profile itself pins.
type PermissionExchange = {adapter_ref: string, acceptance_ref: string, fixture_digest: string, approver_policy: string, poll_ms: integer, ttl_ms: integer}
type EnvironmentResolver = (string) -> (string?, string?)
type Policy = {
    ref: string,
    digest: string,
    permission_exchange: PermissionExchange?,
    permission_answers: string,
    provider_ref: string?,
    instructions: string?,
    instruction_builder: configuration.InstructionBuilder?,
    prepare_options: {[string]: unknown},
    required_cleanup: placement_types.Capability,
    required_exit_observation: placement_types.ExitObservation,
    stop_grace_ms: integer,
    drain_ms: integer,
    runner_drain_ms: integer,
    retain_ms: integer,
    executables: {[string]: string},
    environment: {[string]: string},
    host_environment: {[string]: string},
    allow_host_home: boolean,
    -- gateway_tools names the gateway tools a launch under this policy is
    -- admitted to; empty means the launch has no gateway binding.
    gateway_tools: {string},
    gateway_surface: {[string]: unknown}?,
    -- agent_model_map approves framework agent models for this route: each
    -- agent-declared model name maps to the driver model identifier the
    -- launch carries. An agent model without a mapping is refused.
    agent_model_map: {[string]: string},
    -- agent_delegates lists the framework agent references a run under this
    -- policy may delegate to. Empty means the run may delegate to nothing.
    agent_delegates: {string},
    -- gateway_ttl_ms bounds a gateway binding's life from admission.
    gateway_ttl_ms: integer,
    -- gateway_hooks names the hook events the launch reports to the gateway.
    gateway_hooks: {string},
    hook_command_ref: string?,
    fixture: boolean,
    placement_profiles: {string},
    placement_binding: string?,
    placement_options: {[string]: unknown}?,
    allowed_overrides: {string},
}
local function decode_map(value: unknown, name: string, empty: boolean?): ({[string]: string}?, string?)
    local result: {[string]: string} = {}
    if value == nil then return result, nil end
    local object = bounds.object(value)
    if not object then return nil, name .. " must be an object" end
    for key, item in pairs(object) do
        local text = bounds.text(item, 4096)
        if not text or text:find("%z") or (text == "" and not empty) then return nil, name .. "." .. key .. " must be bounded text" end
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
local function optional_environment(ref: string): (string?, string?)
    -- A missing OS value is ordinary; a misspelled resource or denied read is not.
    local entry, entry_error = registry.get(ref)
    if entry_error or not entry or entry.kind ~= "env.variable" then return nil, "environment reference unavailable" end
    local value, value_error = env.get(ref)
    if value_error and value_error:kind() == errors.NOT_FOUND then return "", nil end
    if value_error then return nil, tostring(value_error) end
    return value, nil
end
-- Host-selected nonsecret environment references are measured with the policy.
-- Empty defaults mean the user has not set an override; leave that variable absent.
local function decode_environment_refs(value: unknown, environment: {[string]: string}, host_environment: {[string]: string}, resolve: EnvironmentResolver): string?
    if value == nil then return nil end
    local refs, refs_error = decode_map(value, "environment_refs")
    if not refs then return refs_error end
    for name, ref in pairs(refs) do
        if not name:match("^[A-Za-z_][A-Za-z0-9_]*$") or not bounds.id(ref) then return "environment_refs must name environment variables and registry references" end
        if environment[name] ~= nil then return "environment_refs." .. name .. " overlaps environment" end
        local resolved, resolve_error = resolve(ref)
        if type(resolved) ~= "string" or resolve_error then return "environment_refs." .. name .. " unavailable from " .. ref end
        if #resolved > 4096 or resolved:find("%z") then return "environment_refs." .. name .. " has an invalid value" end
        if resolved ~= "" then
            environment[name] = resolved
            host_environment[name] = resolved
        end
    end
    return nil
end
-- Decode the policy's declared gateway tools as a sorted dense list. The same
-- field is read before a preference replaces it, for the surface, and after,
-- for what reaches the child.
local function decode_gateway_tools(data: {[string]: unknown}, ref: string): ({string}?, string?)
    if data.gateway_tools == nil then return {}, nil end
    local declared, tools_error = bounds.ids(data.gateway_tools, true)
    if not declared then return nil, ref .. ": gateway_tools: " .. tostring(tools_error) end
    table.sort(declared)
    return declared, nil
end
local function access_surface(raw: unknown, tools: {string}, seeds: {string}?): ({[string]: unknown}?, string?)
    local declared = bounds.object(raw)
    if not declared or bounds.fields(declared, {"policy", "traits"}) then return nil, "must be {policy, traits}" end
    local approver = bounds.id(declared.policy)
    local traits, traits_error = bounds.ids(declared.traits, true)
    if not approver or not traits or #traits == 0 then return nil, traits_error or "names no approver policy or trait" end
    local seen: {[string]: boolean} = {}
    for _, id in ipairs(traits) do seen[id] = true end
    for _, id in ipairs(seeds or {}) do if not seen[id] then return nil, "trait outside launch ceiling: " .. id end end
    local consent: {[string]: boolean} = {}
    for _, trait in ipairs(mcp.CONSENT_TRAITS) do consent[trait.id] = true end
    local extensions: {unknown} = {}
    local offered: {[string]: boolean} = {}
    for _, id in ipairs(traits) do
        if not consent[id] then
            local trait, err = trait_access.load(id)
            if not trait then return nil, err end
            extensions[#extensions + 1] = trait
        end
        offered[id] = true
    end
    local base: {string} = {}
    local requestable: {string} = {}
    local requested: {[string]: boolean} = {}
    for _, name in ipairs(tools) do
        local trait = gateway_protocol.CONSENT_TOOLS[name]
        if trait and offered[trait] then
            if not requested[trait] then requestable[#requestable + 1] = trait; requested[trait] = true end
        else base[#base + 1] = name end
    end
    for _, raw_trait in ipairs(extensions) do
        local trait = assert(bounds.object(raw_trait))
        requestable[#requestable + 1] = assert(bounds.id(trait.id))
    end
    table.sort(requestable)
    local composed: {[string]: unknown} = {tools = {}, traits = extensions, base_tools = base, active_traits = seeds or {}, fixed_context = {}, dynamic_keys = {}}
    if #requestable > 0 then composed.access = {policy = approver, traits = requestable} end
    return composed, nil
end
function M.decode(ref: string, entry: {[string]: unknown}, resolver: EnvironmentResolver?, selected: preferences.Value?, descriptor: descriptors.Descriptor?): (Policy?, string?)
    local meta = bounds.object(entry.meta) or {}
    if meta.type ~= M.TYPE then return nil, ref .. " is not a launch policy" end
    local data = bounds.object(entry.data)
    if not data then return nil, ref .. " has no data" end
    -- Revision two persisted a caller startup deadline. Its decoder validates
    -- the retired field and removes it before revision-three validation.
    if data.schema_revision == "bee.launch-policy@2" then
        if data.start_ms ~= nil then
            local retired = bounds.integer(data.start_ms)
            if not retired or retired < 1 then return nil, ref .. ": legacy start_ms must be a positive integer" end
        end
        local revised: {[string]: unknown} = {}
        for key, item in pairs(data) do if key ~= "start_ms" then revised[key] = item end end
        revised.schema_revision = M.SCHEMA
        data = revised
    end
    local unknown_field = bounds.fields(data, {"schema_revision", "required_cleanup", "required_exit_observation", "stop_grace_ms", "drain_ms", "runner_drain_ms", "retain_ms", "executables", "executable_env", "environment", "environment_refs", "allow_host_home", "fixture", "permission_exchange", "provider_ref", "instructions", "instruction_builder", "prepare_options", "profile_restrictions", "option_constraints", "profile_instructions", "gateway_tools", "gateway_surface", "agent_model_map", "agent_delegates", "gateway_ttl_ms", "gateway_hooks", "hook_command_ref", "placement_binding", "placement_options", "placement_profiles", "allowed_overrides"})
    if unknown_field then return nil, ref .. ": " .. unknown_field end
    if data.schema_revision ~= M.SCHEMA then return nil, ref .. ": schema_revision must be " .. M.SCHEMA end
    local cleanup = bounds.member(data.required_cleanup, placement_types.CAPABILITIES)
    if cleanup ~= "direct_process" and cleanup ~= "process_group" and cleanup ~= "contained_tree" then return nil, ref .. ": required_cleanup must name a cleanup capability" end
    local required_cleanup: placement_types.Capability = cleanup
    local observation = bounds.member(data.required_exit_observation, placement_types.EXIT_OBSERVATIONS)
    if observation ~= "independent" and observation ~= "eof_gated" then return nil, ref .. ": required_exit_observation must be independent or eof_gated" end
    local required_observation: placement_types.ExitObservation = observation
    local stop_grace_ms = bounds.integer(data.stop_grace_ms == nil and 5000 or data.stop_grace_ms)
    local drain_ms = bounds.integer(data.drain_ms == nil and 5000 or data.drain_ms)
    local retain_ms = bounds.integer(data.retain_ms == nil and 30000 or data.retain_ms)
    local runner_drain_ms = bounds.integer(data.runner_drain_ms == nil and 5000 or data.runner_drain_ms)
    if not stop_grace_ms or stop_grace_ms < 0 then return nil, ref .. ": stop_grace_ms must be a nonnegative integer" end
    if not drain_ms or drain_ms < 0 then return nil, ref .. ": drain_ms must be a nonnegative integer" end
    if not retain_ms or retain_ms < 100 then return nil, ref .. ": retain_ms must be at least 100" end
    if not runner_drain_ms or runner_drain_ms < 100 then return nil, ref .. ": runner_drain_ms must be at least 100" end
    local executables, executables_error = decode_map(data.executables, "executables")
    if not executables then return nil, ref .. ": " .. tostring(executables_error) end
    local resolve = resolver or function(variable_ref: string): (string?, string?) return env.get(variable_ref) end
    local executable_env_error = decode_executable_env(data.executable_env, executables, resolve)
    if executable_env_error then return nil, ref .. ": " .. executable_env_error end
    local environment, environment_error = decode_map(data.environment, "environment", true)
    if not environment then return nil, ref .. ": " .. tostring(environment_error) end
    local host_environment: {[string]: string} = {}
    local refs_error = decode_environment_refs(data.environment_refs, environment, host_environment, resolver or optional_environment)
    if refs_error then return nil, ref .. ": " .. refs_error end
    if data.allow_host_home ~= nil and type(data.allow_host_home) ~= "boolean" then
        return nil, ref .. ": allow_host_home must be a boolean"
    end
    local allow_host_home = data.allow_host_home == true
    local fixture = data.fixture == true
    if observation == "eof_gated" and not fixture then return nil, ref .. ": eof_gated execution is permitted only in a fixture policy" end
    local _, profile_restrictions_error = preferences.decode_profile_restrictions(data.profile_restrictions)
    if profile_restrictions_error then return nil, ref .. ": " .. profile_restrictions_error end
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
    local answer_mode = exchange and "ask" or "provider"
    if selected and selected.bee and selected.bee.permission_answers then answer_mode = selected.bee.permission_answers end
    if answer_mode ~= "provider" and not exchange then return nil, "bee.permission_answers=" .. answer_mode .. " requires a host-accepted permission transport" end
    if answer_mode == "provider" then exchange = nil end
    local digest_input: {[string]: unknown} = {}
    for key, value in pairs(data) do digest_input[key] = value end
    digest_input.executables = executables
    digest_input.environment = environment
    digest_input.permission_answers = answer_mode
    local encoded, encode_error = canonical.encode(digest_input)
    if not encoded then return nil, ref .. ": " .. tostring(encode_error) end
    local digest, hash_error = hash.sha256(encoded)
    if hash_error or not digest then return nil, ref .. ": digest failed" end
    -- The policy's own tool list is the host's declaration of what a launch
    -- under it admits, and the surface states what that declaration permits.
    -- A saved profile replaces the tool list with the narrower set it offers
    -- the child, so the surface must be measured against this declaration,
    -- read before any preference narrows it: a profile that leaves out a tool
    -- chooses what to offer, it does not unsay what the host declared.
    local admitted_tools, admitted_error = decode_gateway_tools(data, ref)
    if not admitted_tools then return nil, admitted_error end
    -- Credentials bind the host policy; the launch separately measures the
    -- preferences and resulting configuration under that policy.
    if selected then
        local effective, preference_error = preferences.apply(data, selected, descriptor)
        if not effective then return nil, ref .. ": " .. tostring(preference_error) end
        data = effective
    end
    -- Host-owned options for the driver's prepare: scalar values the
    -- driver decodes under its own rules (permission mode, turn bound,
    -- sandbox); the caller never chooses them.
    local prepare_options, prepare_options_error = preferences.decode_prepare_options(data.prepare_options)
    if not prepare_options then return nil, ref .. ": " .. tostring(prepare_options_error) end
    local instructions, instructions_error = configuration.instructions(data.instructions)
    if instructions_error then return nil, ref .. ": " .. instructions_error end
    local instruction_builder, builder_error = configuration.instruction_builder(data.instruction_builder)
    if builder_error then return nil, ref .. ": " .. builder_error end
    local provider_ref: string? = nil
    if data.provider_ref ~= nil then
        provider_ref = bounds.id(data.provider_ref)
        if not provider_ref then return nil, ref .. ": provider_ref is not an identifier" end
    end
    local placement_profiles, placement_profiles_error = bounds.ids(data.placement_profiles or {"bee.placement.profiles:native"}, true)
    if not placement_profiles then return nil, ref .. ": placement_profiles: " .. tostring(placement_profiles_error) end
    local placement_binding: string? = nil
    if data.placement_binding ~= nil then
        placement_binding = bounds.id(data.placement_binding)
        if not placement_binding then return nil, ref .. ": placement_binding is not an identifier" end
    end
    -- Component-owned options are measured here, then decoded by the selected
    -- placement before it records an intent. The harness does not interpret
    -- container, VM or native execution settings.
    local placement_options: {[string]: unknown}? = nil
    if data.placement_options ~= nil then
        if not placement_binding then return nil, ref .. ": placement_options requires an explicit placement_binding" end
        placement_options = bounds.object(data.placement_options)
        if not placement_options then return nil, ref .. ": placement_options must be an object" end
        local options_json, options_error = canonical.encode(placement_options)
        if not options_json or #options_json > 65536 then return nil, ref .. ": placement_options must be bounded encodable data" end
    end
    local options: {[string]: unknown} = {}
    for name, item in pairs(prepare_options) do options[name] = item end
    -- A preference replaces the declaration with the profile's selection, which
    -- is what actually reaches the child; without one the declaration above is
    -- already the effective list.
    local gateway_tools: {string} = admitted_tools
    if selected then
        local effective, effective_error = decode_gateway_tools(data, ref)
        if not effective then return nil, effective_error end
        gateway_tools = effective
    else
        gateway_tools = gateway_protocol.offered_tools(admitted_tools, data, false)
    end
    local agent_model_map: {[string]: string} = {}
    if data.agent_model_map ~= nil then
        local declared = bounds.object(data.agent_model_map)
        if not declared then return nil, ref .. ": agent_model_map must be an object" end
        local count = 0
        for name, mapped in pairs(declared) do
            count = count + 1
            if count > M.MAX_AGENT_MODELS then return nil, ref .. ": agent_model_map exceeds " .. tostring(M.MAX_AGENT_MODELS) .. " models" end
            if type(name) ~= "string" or #name == 0 or #name > 128 or name:find("%c") then
                return nil, ref .. ": agent_model_map keys must be bounded model names"
            end
            if type(mapped) ~= "string" or #mapped == 0 or #mapped > 128 or not mapped:match("^[A-Za-z0-9][A-Za-z0-9._:-]*$") then
                return nil, ref .. ": agent_model_map maps " .. tostring(name) .. " to a bounded model identifier"
            end
            agent_model_map[name] = mapped
        end
    end
    local agent_delegates: {string} = {}
    if data.agent_delegates ~= nil then
        local declared, delegates_error = bounds.ids(data.agent_delegates, true)
        if not declared then return nil, ref .. ": agent_delegates: " .. tostring(delegates_error) end
        if #declared > M.MAX_AGENT_DELEGATES then return nil, ref .. ": agent_delegates exceeds " .. tostring(M.MAX_AGENT_DELEGATES) .. " agents" end
        agent_delegates = declared
    end
    local gateway_hooks: {string} = {}
    if data.gateway_hooks ~= nil then
        local declared, hooks_error = bounds.ids(data.gateway_hooks, true)
        if not declared then return nil, ref .. ": gateway_hooks: " .. tostring(hooks_error) end
        for _, event in ipairs(declared) do
            if not bounds.member(event, gateway_hooks_catalog.EVENTS) then return nil, ref .. ": gateway_hooks names an unsupported event " .. event end
        end
        table.sort(declared)
        gateway_hooks = declared
    end
    local hook_command_ref: string? = nil
    if data.hook_command_ref ~= nil then
        hook_command_ref = bounds.id(data.hook_command_ref)
        if not hook_command_ref or #gateway_hooks == 0 then return nil, ref .. ": hook_command_ref requires hooks and an env.variable identifier" end
    end
    local gateway_surface: {[string]: unknown}? = nil
    if data.gateway_surface ~= nil then
        local declared = bounds.object(data.gateway_surface)
        if not declared then return nil, ref .. ": gateway_surface must be an object" end
        local encoded = json.encode(declared)
        local copied, copy_error = json.decode(encoded or "")
        gateway_surface = bounds.object(copied)
        if not gateway_surface or copy_error then return nil, ref .. ": cannot copy gateway_surface" end
        if declared.base_tools == nil then
            local synthesized, err = access_surface(declared.access, gateway_tools, selected and selected.active_traits or nil)
            if not synthesized then return nil, ref .. ": gateway_surface: " .. tostring(err) end
            for key, value in pairs(synthesized) do
                if gateway_surface[key] == nil then gateway_surface[key] = value end
            end
            gateway_surface.access = synthesized.access
        end
        if selected and selected.active_traits then gateway_surface.active_traits = selected.active_traits end
        if selected and (selected.active_traits or selected.requestable) then
            local allowed: {string} = {}
            for _, id in ipairs(selected.active_traits or {}) do allowed[#allowed + 1] = id end
            for _, id in ipairs(selected.requestable or {}) do if not bounds.member(id, allowed) then allowed[#allowed + 1] = id end end
            gateway_surface.selectable_traits = allowed
        end
        local configured, _, err = surface.prepare(gateway_surface, mcp.TOOLS, declared.base_tools == nil and gateway_tools or admitted_tools)
        if not configured then return nil, ref .. ": gateway_surface: " .. tostring(err) end
    elseif selected and (#(selected.active_traits or {}) > 0 or #(selected.requestable or {}) > 0) then
        return nil, ref .. ": trait outside launch ceiling: " .. ((selected.active_traits or {})[1] or (selected.requestable or {})[1])
    end
    local allowed_overrides, overrides_error = bounds.ids(data.allowed_overrides == nil and {} or data.allowed_overrides, true)
    if not allowed_overrides then return nil, ref .. ": allowed_overrides: " .. tostring(overrides_error) end
    for _, override in ipairs(allowed_overrides) do
        if not bounds.member(override, M.OVERRIDES) then return nil, ref .. ": allowed_overrides names " .. override .. ", which a launch policy does not admit" end
    end
    if selected and selected.context then
        gateway_surface = gateway_surface or {tools = {}, traits = {}, base_tools = gateway_tools, active_traits = {}, fixed_context = {}, dynamic_keys = {}}
        local fixed: {[string]: unknown} = {}
        for key, value in pairs(selected.context) do fixed[key] = value end
        for key, value in pairs(bounds.object(gateway_surface.fixed_context) or {}) do fixed[key] = value end
        gateway_surface.fixed_context = fixed
    end
    if gateway_surface and selected then gateway_surface.authority_grant_id = selected.authority_grant_id end
    local gateway_ttl_ms = 3600000
    if data.gateway_ttl_ms ~= nil then
        local declared = bounds.integer(data.gateway_ttl_ms)
        if not declared or declared < 1000 or declared > 86400000 then return nil, ref .. ": gateway_ttl_ms must be between 1000 and 86400000" end
        gateway_ttl_ms = declared
    end
    local decoded: Policy = {ref = ref, digest = digest, permission_exchange = exchange, permission_answers = answer_mode, provider_ref = provider_ref, instructions = instructions, instruction_builder = instruction_builder, prepare_options = options, required_cleanup = required_cleanup, required_exit_observation = required_observation,
        stop_grace_ms = stop_grace_ms, drain_ms = drain_ms, runner_drain_ms = runner_drain_ms, retain_ms = retain_ms, executables = executables, environment = environment, host_environment = host_environment, allow_host_home = allow_host_home, gateway_tools = gateway_tools, gateway_surface = gateway_surface, agent_model_map = agent_model_map, agent_delegates = agent_delegates, gateway_ttl_ms = gateway_ttl_ms, gateway_hooks = gateway_hooks, hook_command_ref = hook_command_ref, fixture = fixture, placement_profiles = placement_profiles, placement_binding = placement_binding, placement_options = placement_options, allowed_overrides = allowed_overrides}
    return decoded, nil
end
type SurfaceValue = {[string]: unknown}
-- The host-selected workspace a launch belongs to, carried into the admitted
-- gateway surface's fixed context. A bound subject reads it as host-selected
-- data and no tool argument can replace a host key (context.compose refuses).
function M.with_workspace(gateway_surface: SurfaceValue?, workspace_id: string): SurfaceValue?
    if not gateway_surface then return nil end
    local fixed: SurfaceValue = {}
    local declared = gateway_surface.fixed_context
    if declared ~= nil then
        if type(declared) ~= "table" then return nil end
        for key, value in pairs(declared) do fixed[key] = value end
    end
    local result: SurfaceValue = {}
    for key, value in pairs(gateway_surface) do result[key] = value end
    fixed["bee.workspace_id"] = workspace_id
    result.fixed_context = fixed
    return result
end
function M.load(ref: string): (Policy?, string?)
    local entry, err = registry.get(ref)
    if err or not entry then return nil, "launch policy " .. ref .. " is not in the registry" end
    return M.decode(ref, entry)
end
return M
