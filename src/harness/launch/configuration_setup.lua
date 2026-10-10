local registry = require("registry")
local funcs = require("funcs")
local env = require("env")
local bounds = require("bounds")
local configuration = require("configuration")
local resolver = require("resolver")
local gateway_configuration = require("gateway_configuration")
local descriptors = require("descriptors")
local profiles = require("profiles")
local preferences = require("preferences")
local M = {}
type Plan = {binding_ref: string, policy_ref: string, profile_id: string, mode: string, effective_profile: unknown}
type Requirement = {provider: string, base_path: string}
function M.requirements(plan: Plan): ({Requirement}?, string?)
    local pinned, pin_error = registry.snapshot()
    if not pinned then return nil, tostring(pin_error) end
    local target, target_error = resolver.configure(pinned, plan.binding_ref)
    if not target then return nil, target_error end
    local entry = resolver.entry(pinned, plan.policy_ref)
    local data = entry and bounds.object(entry.data)
    if not data then return nil, "Agent configuration policy is unavailable." end
    local effective = bounds.object(plan.effective_profile)
    local private = true
    local placement = effective and bounds.object(effective.placement)
    if placement and placement.kind == "native" then private = placement.home == "private" end
    local binding = resolver.entry(pinned, plan.binding_ref)
    local meta = binding and bounds.object(binding.meta)
    local descriptor_ref = meta and bounds.id(meta.descriptor_ref)
    local descriptor = descriptor_ref and descriptors.load_from(pinned, descriptor_ref)
    local provider = descriptor and descriptor.provider or (meta and bounds.id(meta.driver_id))
    if not provider then return nil, "Agent configuration does not name its provider." end
    local saved = effective and profiles.profile(effective)
    if saved then
        local selected, selection_error = profiles.preferences(saved)
        if not selected then return nil, selection_error end
        local merged, preference_error = preferences.apply(data, selected, descriptor)
        if not merged then return nil, preference_error end
        data = merged
    end
    local options, option_error = preferences.decode_prepare_options(data.prepare_options)
    if not options then return nil, option_error end
    local request: configuration.Request = {fixture = data.fixture == true, context = plan.mode == "window" and "window" or "first_turn",
        option_values = options, private_home = private,
        instructions = type(data.instructions) == "string" and data.instructions or nil}
    local home, home_error = env.get("bee.env:machine_home")
    if type(home) ~= "string" or home_error then return nil, "The agent's home folder is unavailable." end
    request.home_directory = home
    local provider_ref = bounds.id(data.provider_ref)
    if provider_ref then request.provider_ref = provider_ref; request.provider = resolver.entry(pinned, provider_ref) end
    local tools = bounds.ids(data.gateway_tools or {}, true) or {}
    local hooks = bounds.ids(data.gateway_hooks or {}, true) or {}
    local profile = resolver.profile(pinned, plan.binding_ref, plan.profile_id)
    hooks = resolver.select_hooks(profile, hooks)
    if #tools > 0 or #hooks > 0 then
        local endpoint, endpoint_error = gateway_configuration.endpoint()
        if not endpoint then return nil, endpoint_error end
        local command, command_error = gateway_configuration.hook_command(bounds.id(data.hook_command_ref))
        if command_error then return nil, command_error end
        request.gateway = {endpoint = endpoint, action_id = "configuration-setup", tools = tools, hooks = hooks,
            hook_command = command, token_environment = gateway_configuration.DESTINATION,
            hook_token_environment = #hooks > 0 and gateway_configuration.HOOK_DESTINATION or nil}
    end
    local delivery, delivery_error = configuration.call(plan.binding_ref, target, request)
    if not delivery then return nil, delivery_error end
    local result: {Requirement} = {}
    local seen: {[string]: boolean} = {}
    for _, file in ipairs(delivery.files) do
        if file.composition and not seen[file.composition.base_path] then
            local path = file.composition.base_path
            seen[path] = true
            result[#result + 1] = {provider = provider, base_path = path}
        end
    end
    return result, nil
end
function M.run(plan: Plan, workspace: string, operation: string): ({needs_setup: boolean, paths: {string}}?, string?)
    local requirements, err = M.requirements(plan)
    if not requirements then return nil, err end
    local result: {needs_setup: boolean, paths: {string}} = {needs_setup = false, paths = {}}
    for _, requirement in ipairs(requirements) do
        local raw, call_error = funcs.call("bee.credentials.binding:configuration_setup", {workspace_id = workspace,
            provider = requirement.provider, base_path = requirement.base_path, operation = operation})
        local reply = bounds.object(raw)
        local value = reply and bounds.object(reply.value)
        if call_error or not reply or reply.ok ~= true or not value then
            local fault = reply and bounds.object(reply.error)
            return nil, tostring(call_error or (fault and fault.message) or "Choose Setup in Agents to allow its configuration file.")
        end
        if value.needs_setup == true then result.needs_setup = true end
        if type(value.path) == "string" then result.paths[#result.paths + 1] = value.path end
    end
    return result, nil
end
return M
