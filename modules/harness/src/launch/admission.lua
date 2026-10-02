-- MIT. Launch admission: resolve a definition into a measured plan with no
-- effects, then admit a request for the authenticated requester, obtaining
-- attempt-bound grants and credential projections in that requester's own
-- authority, and start the carrier with a durable identity so a retry
-- after an ambiguous start recovers the same attempt.
local hash = require("hash")
local registry = require("registry")
local funcs = require("funcs")
local process = require("process")
local security = require("security")
local time = require("time")
local bounds = require("bounds")
local record_bounds = require("record_bounds")
local canonical = require("canonical")
local catalog = require("catalog")
local policy = require("policy")
local definition = require("definition")
local agent_resolver = require("agent_resolver")
local carrier = require("carrier")
local placement_types = require("placement_types")
local placement_resolver = require("placement_resolver")
local placement_profiles = require("placement_profiles")
local continuation = require("continuation")
local interrupted = require("interrupted")
local profiles = require("profiles")
local profile_validation = require("profile_validation")
local descriptors = require("descriptors")
local budgets = require("budgets")
local M = {}
M.CARRIER = "bee.harness.service:carrier"
M.CARRIER_HOST_REF = "bee.harness.env:carrier_host_ref"
M.THREADS = "bee.threads.binding"
M.CARRIER_OPS = "bee.threads.binding"
M.RESOURCES = "bee.resources.binding"
M.CREDENTIALS = "bee.credentials.binding"
M.MAX_BRIEF_BYTES = 16384
M.MAX_AGENT_INSTRUCTIONS_BYTES = 4096
-- A saved window that can never be resumed; recovery ends it instead of
-- retrying or asking for review.
M.NOT_RESUMABLE = "NOT_RESUMABLE"
type Fault = {code: string, message: string}
type Reply = {ok: boolean, error: Fault?, value: unknown}
type Plan = {
    budget_capabilities: descriptors.BudgetCapabilities?,
    effective_profile: profiles.Profile?,
    effective_profile_digest: string?,
    saved_profile_id: string?,
    saved_profile_revision: integer?,
    owner_component_revision: integer?,
    title: string,
    definition_ref: string,
    definition_digest: string,
    launch_id: string,
    binding_ref: string,
    binding_digest: string,
    driver_id: string,
    profile_id: string,
    profile_digest: string,
    session_resource: string?,
    policy_ref: string,
    policy_digest: string,
    placement_profile_ref: string?,
    placement_profile_digest: string?,
    permission_answers: string,
    placement_binding_ref: string,
    placement_binding_digest: string,
    placement_methods: {[string]: string},
    executables: {[string]: string},
    placement_kind: string,
    -- The overrides a request may make: the definition's own, with workdir,
    -- thread and placement kept only where the launch policy admits them too.
    overrides: {string},
    catalog_generation: integer,
    mode: string,
    plan_digest: string,
    -- The admitted framework agent closure, pinned by digest. Absent for
    -- legacy routes without an agent reference.
    agent_ref: string?,
    agent_digest: string?,
    spec_digest: string?,
    agent_tools: {string}?,
    agent_model: string?,
    declined_tuning: {string}?,
}
type OriginView = {view_id: string, instance_id: string}
type Admitted = {
    plan: Plan, request: carrier.Request, requester: string,
    request_id: string, thread_id: string, action_id: string, attempt_id: string,
    session_ref: string?,
    carrier: string?, mode: string?, started_at: string?,
    saved_profile_revision: integer?,
    owner_component_revision: integer?,
}
type Continuation = {origin_request_id: string, previous_attempt_id: string, thread_id: string, reauthorize: boolean?}
type Request = {
    placement_override: profiles.Placement?,
    saved_profile_id: string?,
    saved_profile_revision: integer?,
    owner_component_revision: integer?,
    agent_ref: string?,
    spec_digest: string?,
    request_id: string,
    definition_ref: string,
    workspace_id: string,
    brief: string,
    mode: string?,
    workdir: string?,
    thread_id: string?,
    thread_title: string?,
    placement: string?,
    expected_plan_digest: string?,
    continuation: Continuation?,
    parent_action_id: string?,
    origin_view: OriginView?,
}
type SessionTurnContext = {owner_id: string, session_ref: string, action_id: string, attempt_id: string}
local function fail(code: string, message: string): Reply
    return {ok = false, error = {code = code, message = message}, value = nil}
end
local function succeed(value: unknown): Reply
    return {ok = true, error = nil, value = value}
end
local function actor(): string?
    local current = security.actor()
    if not current then return nil end
    return bounds.id(current:id())
end
local function call(target: string, request: unknown): ({[string]: unknown}?, Reply?)
    local raw, err = funcs.call(target, request)
    if err or type(raw) ~= "table" then return nil, fail("UNAVAILABLE", target .. " did not answer") end
    local reply = bounds.object(raw)
    if not reply then return nil, fail("UNAVAILABLE", target .. " did not answer") end
    if not reply.ok then
        local fault = bounds.object(reply.error)
        local code = fault and bounds.id(fault.code) or "DENIED"
        return nil, fail(code or "DENIED", target .. ": " .. tostring(fault and fault.message))
    end
    local value = reply.value
    if type(value) ~= "table" then return {}, nil end
    return value, nil
end
local function digest_of(value: unknown): (string?, string?)
    local encoded, encode_error = canonical.encode(value)
    if not encoded then return nil, encode_error end
    local sum, hash_error = hash.sha256(encoded)
    if hash_error or not sum then return nil, "digest failed" end
    return sum, nil
end
local function resource_grant(value: {[string]: unknown}, workspace_id: string, name: string, purpose: placement_types.Purpose, audience: string, attempt_id: string): (placement_types.ResourceGrant?, string?)
    local grant_id, returned_workspace, returned_name = bounds.id(value.grant_id), bounds.id(value.workspace_id), bounds.id(value.name)
    local root_ref, returned_subject, returned_audience = bounds.id(value.root_ref), bounds.id(value.subject), bounds.id(value.audience)
    local subpath = bounds.subpath(value.subpath)
    if not grant_id or not returned_workspace or not returned_name or not root_ref or not returned_subject or not returned_audience or not subpath then
        return nil, "resource grant returned an invalid identity or subpath"
    end
    if returned_workspace ~= workspace_id or returned_name ~= name or returned_subject ~= audience or returned_audience ~= audience
        or value.access ~= "write" or value.purpose ~= purpose or value.attempt_id ~= attempt_id then
        return nil, "resource grant returned the wrong scope"
    end
    return {name = returned_name, grant_ref = grant_id, root_ref = root_ref, subpath = subpath, access = "write", purpose = purpose}, nil
end
-- resolve: the measured plan for a definition, with no effects. The plan
-- digest pins the definition, the binding and profile measurements and
-- the launch policy at one catalog generation.
local function read_definition(pinned: catalog.Pinned, definition_ref: string): (definition.Definition?, string?)
    local entry = catalog.entry(pinned, definition_ref)
    if not entry then return nil, "launch definition " .. definition_ref .. " is not in the registry" end
    return definition.decode(definition_ref, entry)
end
type Selected = {profile_id: string, revision: integer, profile: profiles.Profile}
local function selected_profile(workspace: string, id: string, revision: integer, definition_ref: string): (Selected?, Reply?)
    local raw, err = funcs.call("bee.harness.binding:call", {operation = "get", workspace_id = workspace, profile_id = id})
    if err then return nil, fail("UNAVAILABLE", "saved profile did not answer") end
    local reply = bounds.object(raw)
    if not reply then return nil, fail("UNAVAILABLE", "invalid saved profile reply") end
    if reply.ok ~= true then return nil, fail(bounds.id(reply.code) or "DENIED", "saved profile is unavailable") end
    local value = bounds.object(reply.value)
    if not value or value.workspace_id ~= workspace or value.profile_id ~= id then return nil, fail("UNAVAILABLE", "saved profile identity differs") end
    if value.tombstone ~= false or value.revision ~= revision then return nil, fail("CONFLICT", "saved profile changed; select it again") end
    local profile, profile_error = profiles.profile(value.profile)
    if not profile then return nil, fail("UNAVAILABLE", profile_error or "invalid saved profile") end
    if profile.definition_ref ~= definition_ref then return nil, fail("CONFLICT", "saved profile selects a different launch definition") end
    return {profile_id = id, revision = revision, profile = profile}, nil
end
local function preference_value(selected: Selected?): placement_types.Preferences?
    if not selected then return nil end
    local value = profiles.preferences(selected.profile)
    return value
end
-- agent_preferences: the carrier preferences for one admitted agent closure.
-- The run offers exactly the closure's tool aliases through the gateway and
-- carries its composed prompt and context as instructions; a saved profile
-- may narrow neither outward. The host-approved model mapping owns the
-- model option.
local function agent_preferences(selected: Selected?, closure: agent_resolver.Closure, checked: agent_resolver.Checked,
    launch_policy: policy.Policy, profile_instructions: boolean): (placement_types.Preferences?, Reply?)
    local options: {[string]: string | number | boolean} = {}
    local saved_instructions = ""
    if selected then
        local narrowed, narrow_error = profiles.agent_preferences(selected.profile, closure.tool_names)
        if not narrowed then return nil, fail("FORBIDDEN", narrow_error or "saved profile is outside the admitted agent") end
        for name, item in pairs(narrowed.options) do options[name] = item end
        saved_instructions = narrowed.instructions
    end
    if checked.model then options.model = checked.model end
    local host_tools: {[string]: boolean} = {}
    for _, name in ipairs(launch_policy.gateway_tools) do host_tools[name] = true end
    for _, name in ipairs(closure.tool_names) do
        if not host_tools[name] then
            return nil, fail("FORBIDDEN", "host policy admits no gateway tool " .. name .. " for agent definition " .. closure.ref)
        end
    end
    local instructions = closure.instructions
    if saved_instructions ~= "" then
        if not profile_instructions then
            return nil, fail("FORBIDDEN", "profile instructions are disabled by the host policy")
        end
        instructions = instructions .. "\n\n" .. saved_instructions
    end
    if #instructions > M.MAX_AGENT_INSTRUCTIONS_BYTES then
        return nil, fail("INVALID", "agent instructions exceed " .. tostring(M.MAX_AGENT_INSTRUCTIONS_BYTES) .. " bytes for this route")
    end
    return {bee = selected and selected.profile.bee or nil, options = options, mcp_tools = closure.tool_names, instructions = instructions}, nil
end
local function resolve(pinned: catalog.Pinned, launch: definition.Definition, mode: string?, selected: Selected?, req_agent_ref: string?, req_owner_rev: integer?, req_spec_digest: string?, session_route: boolean?, placement_override: profiles.Placement?): (Plan?, Reply?, placement_types.Preferences?)
    if session_route and launch.session_profile_id then
        launch.profile_id = launch.session_profile_id
        if launch.session_credentials then launch.credentials = launch.session_credentials end
        launch.default_mode = launch.session_mode or "session"
    end
    if selected then
        local invalid = profile_validation.check(pinned, selected.profile)
        if invalid then return nil, fail("UNSUPPORTED_CAPABILITY", invalid) end
    end
    local definition_ref = launch.ref
    local chosen = launch.default_mode
    if mode and mode ~= chosen then
        if not definition.allows(launch, "mode") then return nil, fail("FORBIDDEN", "definition " .. definition_ref .. " does not allow a mode override") end
        if not bounds.member(mode, definition.MODES) then return nil, fail("INVALID", "mode must be window, session or batch") end
        chosen = mode
    end
    local snapshot, snapshot_error = catalog.read(pinned, nil)
    if not snapshot then return nil, fail("UNAVAILABLE", snapshot_error or "catalog") end
    for _, candidate in ipairs(snapshot.bindings) do
        if candidate.binding_id == launch.binding_ref and not candidate.activated then
            return nil, fail("FORBIDDEN", "binding " .. launch.binding_ref .. " is not activated")
        end
    end
    local usable, usable_error = catalog.usable(snapshot)
    if not usable then return nil, fail("UNAVAILABLE", usable_error or "catalog") end
    local binding_digest, profile_digest = "", ""
    local binding = nil
    local supported = false
    local default_private_home = true
    for _, candidate in ipairs(usable) do
        if candidate.binding_id == launch.binding_ref then
            binding = candidate
            binding_digest = candidate.binding_digest.entry
            profile_digest = candidate.profile_digest.entry
            for _, profile in ipairs(candidate.profiles) do
                if profile.id == launch.profile_id and profile.supported and profile.mode == chosen then supported = true; default_private_home = profile.private_home end
            end
        end
    end
    if binding_digest == "" then return nil, fail("UNAVAILABLE", "binding " .. launch.binding_ref .. " is not usable on this host") end
    if not supported then return nil, fail("UNSUPPORTED_CAPABILITY", "profile " .. launch.profile_id .. " of " .. launch.binding_ref .. " does not run in mode " .. chosen) end
    local policy_entry = catalog.entry(pinned, launch.policy_ref)
    if not policy_entry then return nil, fail("NOT_FOUND", "launch policy " .. launch.policy_ref .. " is not in the registry") end
    -- A framework agent route resolves its agent.gen1 closure from this same
    -- snapshot, checks the CLI parity of the selected driver, and measures
    -- the policy under the closure's exact preferences before admission. The
    -- closure's composed prompt and context travel through the profile
    -- instruction channel, so an agent route needs profile_instructions;
    -- admission supplies that text, never the caller's profile.
    local agent: agent_resolver.Closure? = nil
    local checked: agent_resolver.Checked? = nil
    local effective: placement_types.Preferences? = preference_value(selected)
    local launch_policy: policy.Policy
    local effective_agent_ref = (selected and selected.profile and selected.profile.agent_ref) or launch.agent_ref or req_agent_ref
    if selected and selected.profile and selected.profile.agent_ref then
        if launch.agent_ref and selected.profile.agent_ref ~= launch.agent_ref then
            return nil, fail("CONFLICT", "saved profile agent reference differs from launch definition")
        end
        if req_agent_ref and selected.profile.agent_ref ~= req_agent_ref then
            return nil, fail("CONFLICT", "requested agent reference differs from saved profile")
        end
    elseif launch.agent_ref and req_agent_ref and launch.agent_ref ~= req_agent_ref then
        return nil, fail("CONFLICT", "requested agent reference differs from launch definition")
    end

    local effective_owner_rev = (selected and selected.profile and selected.profile.owner_component_revision) or req_owner_rev
    if selected and selected.profile and selected.profile.owner_component_revision and req_owner_rev then
        if selected.profile.owner_component_revision ~= req_owner_rev then
            return nil, fail("CONFLICT", "requested owner component revision differs from saved profile")
        end
    end

    if effective_agent_ref then
        local host_policy, host_error = policy.decode(launch.policy_ref, policy_entry, nil, nil)
        if not host_policy then return nil, fail("NOT_FOUND", host_error or "policy") end
        local closure, closure_code, closure_error = agent_resolver.resolve(pinned, effective_agent_ref)
        if not closure then return nil, fail(closure_code or "UNAVAILABLE", closure_error or "agent definition") end
        if selected and selected.profile and selected.profile.spec_digest then
            if selected.profile.spec_digest ~= closure.digest then
                return nil, fail("CONFLICT", "saved profile spec digest differs from resolved agent closure")
            end
        end
        if req_spec_digest and req_spec_digest ~= closure.digest then
            return nil, fail("CONFLICT", "requested spec digest differs from resolved agent closure")
        end
        agent = closure
        local route, route_code, route_error = agent_resolver.check_route(pinned, closure,
            {driver_id = binding and binding.driver_id or "", model_map = host_policy.agent_model_map,
                admitted_delegates = host_policy.agent_delegates})
        if not route then return nil, fail(route_code or "UNAVAILABLE", route_error or "agent route") end
        checked = route
        local policy_data = bounds.object(policy_entry.data) or {}
        local agent_prefs, prefs_refused = agent_preferences(selected, closure, route, host_policy, policy_data.profile_instructions == true)
        if not agent_prefs then return nil, prefs_refused end
        effective = agent_prefs
        local measured, measure_error = policy.decode(launch.policy_ref, policy_entry, nil, agent_prefs)
        if not measured then
            if measure_error and measure_error:find("option model", 1, true) then
                return nil, fail("UNSUPPORTED_CAPABILITY", "host policy declares no model option for the mapped agent model")
            end
            return nil, fail("NOT_FOUND", measure_error or "policy")
        end
        launch_policy = measured
    else
        local saved_preferences: placement_types.Preferences? = nil
        if selected then
            local validated, preference_error = profiles.preferences(selected.profile)
            if not validated then return nil, fail("UNSUPPORTED_CAPABILITY", preference_error or "Profile preferences cannot be rendered") end
            saved_preferences = validated
        end
        local decoded, policy_error = policy.decode(launch.policy_ref, policy_entry, nil, saved_preferences)
        if not decoded then return nil, fail("NOT_FOUND", policy_error or "policy") end
        launch_policy = decoded
    end
    -- Resolve placement alongside the driver and policy from this immutable
    -- registry snapshot. The policy may select an implementation; absent that
    -- field the resolver's native host default is used.
    if placement_override and (not definition.allows(launch, "placement") or not bounds.member("placement", launch_policy.allowed_overrides)) then
        return nil, fail("FORBIDDEN", "The definition and host policy must both admit a placement override")
    end
    local profile_placement = placement_override or (selected and selected.profile.placement or nil)
    if placement_override then
        local stock_options: {[string]: string | number | boolean} = {}
        local stock_preferences: placement_types.Preferences = {options = stock_options, mcp_tools = launch_policy.gateway_tools, instructions = ""}
        local override_preferences: placement_types.Preferences = effective or stock_preferences
        if placement_override.kind == "native" then
            override_preferences.home = placement_override.home
            override_preferences.docker_overrides = nil
        else
            override_preferences.home = nil
            override_preferences.docker_overrides = placement_override.overrides
        end
        effective = override_preferences
    end
    local selected_profile_ref: string? = nil
    if profile_placement and profile_placement.kind == "docker" then selected_profile_ref = profile_placement.profile_ref
    elseif profile_placement then selected_profile_ref = placement_profiles.DEFAULT end
    if selected and selected.profile.driver_binding_ref ~= launch.binding_ref then return nil, fail("CONFLICT", "Profile driver binding differs from the admitted definition") end
    if profile_placement and profile_placement.kind == "native" and profile_placement.home == "machine" and not launch_policy.allow_host_home then
        return nil, fail("FORBIDDEN", "Host policy does not admit machine home")
    end
    local resolved_profile: placement_profiles.Resolved? = nil
    if selected_profile_ref then
        if not bounds.member(selected_profile_ref, launch_policy.placement_profiles) then return nil, fail("FORBIDDEN", "launch policy does not admit this placement profile") end
        local resolved, profile_error = placement_profiles.resolve(pinned, selected_profile_ref)
        if not resolved then return nil, fail("UNAVAILABLE", profile_error or "placement profile") end
        local tuned, tune_error = placement_profiles.tune(resolved, profile_placement and profile_placement.kind == "docker" and profile_placement.overrides or nil)
        if not tuned then return nil, fail("FORBIDDEN", tune_error or "Docker override is outside the host template") end
        resolved_profile = tuned
    end
    if resolved_profile and resolved_profile.profile.placement_binding == "bee.placement.docker.binding:binding" and launch.session_credentials then launch.credentials = launch.session_credentials end
    if selected and selected.profile.bee.credential_refs then
        local admitted: {string} = {}
        for _, ref in ipairs(selected.profile.bee.credential_refs) do
            if not bounds.member(ref, launch.credentials) then return nil, fail("DENIED", "bee.credential_refs: definition does not admit " .. ref) end
            admitted[#admitted + 1] = ref
        end
        launch.credentials = admitted
    end
    if selected then
        for name, value in pairs(selected.profile.provider.env or {}) do
            if value.kind == "credential" and not bounds.member(value.credential_ref, launch.credentials) then return nil, fail("DENIED", "provider.env." .. name .. ": credential reference is outside the selected definition/credential_refs") end
        end
    end
    if selected then
        for _, destination in ipairs(selected.profile.bee.workspaces or {}) do
            for _, operation in ipairs(destination.operations) do
                if not security.can("funcs.call", operation) then return nil, fail("DENIED", "bee.workspaces: host does not admit owner operation " .. operation .. " for destination " .. destination.workspace_id) end
            end
        end
    end
    local selected_binding = launch_policy.placement_binding
    if resolved_profile then selected_binding = resolved_profile.profile.placement_binding end
    local placement, placement_error = placement_resolver.resolve(pinned, selected_binding)
    if not placement then return nil, fail("UNAVAILABLE", placement_error or "placement binding") end
    if not binding then return nil, fail("UNAVAILABLE", "binding " .. launch.binding_ref .. " is not usable on this host") end
    -- A listed profile needs a host-selected executable, but this passive
    -- read cannot know the driver's eventual launch.executable. The carrier
    -- binds that prepared name to this policy's exact key before placement.
    local has_absolute_executable = false
    for _, executable in pairs(launch_policy.executables) do
        if executable:sub(1, 1) == "/" then has_absolute_executable = true end
    end
    if not has_absolute_executable and placement.placement_kind ~= "docker" then
        return nil, fail("UNAVAILABLE", "launch policy " .. launch.policy_ref .. " has no absolute executable binding")
    end
    -- Provider data selects part of the generated private-home configuration.
    -- Its exact registry entry therefore belongs to the displayed plan fence,
    -- even though the driver decodes it only after a user selects the plan.
    local provider_digest: string? = nil
    if launch_policy.provider_ref then
        local provider_entry = catalog.entry(pinned, launch_policy.provider_ref)
        if not provider_entry then return nil, fail("NOT_FOUND", "provider " .. launch_policy.provider_ref .. " is not in the registry") end
        local measured, provider_error = digest_of(provider_entry)
        if not measured then return nil, fail("INVALID", "provider " .. launch_policy.provider_ref .. ": " .. tostring(provider_error)) end
        provider_digest = measured
    end
    local overrides: {string} = {}
    for _, name in ipairs(launch.allowed_overrides) do
        if not bounds.member(name, policy.OVERRIDES) or bounds.member(name, launch_policy.allowed_overrides) then overrides[#overrides + 1] = name end
    end
    local plan_digest, digest_error = digest_of({definition = launch.digest, binding = binding_digest, profile = profile_digest, policy = launch_policy.digest,
        placement_profile_ref = resolved_profile and resolved_profile.ref or nil, placement_profile_digest = resolved_profile and resolved_profile.digest or nil,
        placement_binding_ref = placement.binding_id, placement_binding_digest = placement.binding_digest, placement_methods = placement.methods,
        provider = provider_digest, mode = chosen, saved_profile = selected, placement_override = placement_override,
        agent = agent and agent.digest or nil, agent_model = checked and checked.model or nil,
        declined_tuning = checked and checked.declined or nil,
        owner_component_revision = effective_owner_rev})
    if not plan_digest then return nil, fail("INVALID", digest_error or "plan") end
    local effective_profile: profiles.Profile = selected and assert(profiles.profile(selected.profile)) or {
        schema_revision = profiles.SCHEMA, name = launch.title, definition_ref = definition_ref,
        driver_binding_ref = launch.binding_ref, provider = {}, bee = {}}
    if placement_override then effective_profile.placement = placement_override end
    local binding_entry = catalog.entry(pinned, launch.binding_ref)
    local binding_meta = binding_entry and bounds.object(binding_entry.meta)
    local descriptor_ref = binding_meta and bounds.id(binding_meta.descriptor_ref)
    local descriptor = descriptor_ref and descriptors.load_from(pinned, descriptor_ref)
    local fields = descriptor and bounds.object(descriptor.options.fields) or {}
    for name, raw in pairs(fields) do
        local field = bounds.object(raw)
        local path = field and bounds.id(field.path)
        local value = launch_policy.prepare_options[name]
        if value == nil and field then value = field.default end
        if path and value ~= nil then
            if path == "provider.model" and type(value) == "string" then effective_profile.provider.model = value
            elseif path == "provider.effort" and type(value) == "string" then effective_profile.provider.effort = value
            elseif path == "provider.permission_mode" and type(value) == "string" then effective_profile.provider.permission_mode = value
            elseif path:match("^provider.options%.") then
                effective_profile.provider.options = effective_profile.provider.options or {}
                effective_profile.provider.options[name] = value
            end
        end
    end
    if launch_policy.instructions then effective_profile.provider.system_prompt_append = launch_policy.instructions end
    local tools: {profiles.Mcp} = {}
    for _, tool in ipairs(launch_policy.gateway_tools) do tools[#tools + 1] = {tool = tool, scope = {}} end
    if effective_profile.bee.mcp == nil then effective_profile.bee.mcp = tools end
    if bounds.member(launch_policy.permission_answers, {"provider", "ask", "deny"}) then
        if launch_policy.permission_answers == "ask" then effective_profile.bee.permission_answers = "ask"
        elseif launch_policy.permission_answers == "deny" then effective_profile.bee.permission_answers = "deny"
        else effective_profile.bee.permission_answers = "provider" end
    end
    if not effective_profile.placement then
        if resolved_profile and placement.placement_kind == "docker" then effective_profile.placement = {kind = "docker", profile_ref = resolved_profile.ref}
        else effective_profile.placement = {kind = "native", home = default_private_home and "private" or "machine"} end
    end
    if not effective_profile.presentation then effective_profile.presentation = chosen == "window" and "window" or "headless" end
    local budget_error = budgets.accounting(effective_profile.budgets, descriptor and descriptor.capabilities and descriptor.capabilities.budgets, effective_profile.presentation, descriptor and descriptor.codec)
    if budget_error then return nil, fail("UNSUPPORTED_CAPABILITY", budget_error) end
    return {budget_capabilities = descriptor and descriptor.capabilities and descriptor.capabilities.budgets, effective_profile = effective_profile,
        effective_profile_digest = digest_of(effective_profile),
        title = selected and selected.profile.name or launch.title, definition_ref = definition_ref, definition_digest = launch.digest, launch_id = launch.launch_id, binding_ref = launch.binding_ref, binding_digest = binding_digest, driver_id = binding.driver_id,
        profile_id = launch.profile_id, profile_digest = profile_digest, policy_ref = launch.policy_ref, policy_digest = launch_policy.digest, permission_answers = launch_policy.permission_answers,
        placement_profile_ref = resolved_profile and resolved_profile.ref or nil, placement_profile_digest = resolved_profile and resolved_profile.digest or nil,
        session_resource = launch.session_resource,
        placement_binding_ref = placement.binding_id, placement_binding_digest = placement.binding_digest,
        placement_methods = placement.methods, executables = launch_policy.executables,
        placement_kind = placement.placement_kind, overrides = overrides,
        catalog_generation = snapshot.generation, mode = chosen, plan_digest = plan_digest,
        saved_profile_id = selected and selected.profile_id or nil, saved_profile_revision = selected and selected.revision or nil,
        owner_component_revision = effective_owner_rev,
        agent_ref = agent and agent.ref or nil, agent_digest = agent and agent.digest or nil,
        spec_digest = agent and agent.digest or nil,
        agent_tools = agent and agent.tool_names or nil, agent_model = checked and checked.model or nil,
        declined_tuning = checked and checked.declined or nil}, nil, effective
end
-- A caller composing a larger host plan can retain the same snapshot for
-- its other declarations; this read performs no registry mutation or admission.
function M.read(pinned: catalog.Pinned, definition_ref: string, mode: string?, session_route: boolean?): (Plan?, Reply?)
    local launch, definition_error = read_definition(pinned, definition_ref)
    if not launch then return nil, fail("NOT_FOUND", definition_error or "definition") end
    local plan, refused = resolve(pinned, launch, mode, nil, nil, nil, nil, session_route)
    if not plan then return nil, refused end
    return plan, nil
end
function M.resolve(definition_ref: string, mode: string?, workspace: string?, saved_id: string?, saved_revision: integer?, agent_ref: string?, owner_component_revision: integer?, spec_digest: string?, session_route: boolean?, placement_override: profiles.Placement?): (Plan?, Reply?)
    local selected: Selected? = nil
    if saved_id or saved_revision then
        if not workspace or not saved_id or not saved_revision or saved_revision < 1 then return nil, fail("INVALID", "saved profile needs workspace, identity and revision") end
        local found, refused = selected_profile(workspace, saved_id, saved_revision, definition_ref)
        if not found then return nil, refused end
        selected = found
    end
    local pinned, pin_error = catalog.pin()
    if not pinned then return nil, fail("UNAVAILABLE", pin_error or "pin the registry") end
    local launch, definition_error = read_definition(pinned, definition_ref)
    if not launch then return nil, fail("NOT_FOUND", definition_error or "definition") end
    local plan, refused = resolve(pinned, launch, mode, selected, agent_ref, owner_component_revision, spec_digest, session_route, placement_override)
    if not plan then return nil, refused end
    return plan, nil
end
function M.decode_request(value: unknown): (Request?, string?)
    local object = bounds.object(value)
    if not object then return nil, "request must be an object" end
    local unknown_field = bounds.fields(object, {"request_id", "definition_ref", "workspace_id", "brief", "mode", "workdir", "thread_id", "thread_title", "placement", "placement_override", "expected_plan_digest", "continuation", "saved_profile_id", "saved_profile_revision", "parent_action_id", "origin_view", "agent_ref", "owner_component_revision", "spec_digest"})
    if unknown_field then return nil, unknown_field end
    local placement_override, placement_error = profiles.placement(object.placement_override)
    if placement_error then return nil, placement_error end
    local request_id, definition_ref, workspace_id = bounds.id(object.request_id), bounds.id(object.definition_ref), bounds.id(object.workspace_id)
    if not request_id then return nil, "request_id is not an identifier" end
    if not definition_ref then return nil, "definition_ref is not an identifier" end
    if not workspace_id then return nil, "workspace_id is not an identifier" end
    local saved_id, saved_revision = bounds.id(object.saved_profile_id), bounds.count(object.saved_profile_revision)
    if object.saved_profile_id ~= nil or object.saved_profile_revision ~= nil then
        if not saved_id or not saved_revision or saved_revision < 1 then return nil, "saved profile needs identity and positive revision" end
        if object.expected_plan_digest == nil then return nil, "saved profile needs the selected launch plan digest" end
    end
    local agent_ref: string? = nil
    if object.agent_ref ~= nil then
        agent_ref = bounds.id(object.agent_ref)
        if not agent_ref then return nil, "agent_ref is not an identifier" end
    end
    local owner_component_revision: integer? = nil
    if object.owner_component_revision ~= nil then
        local count = bounds.count(object.owner_component_revision)
        if not count or count < 1 then return nil, "owner_component_revision must be a positive integer" end
        owner_component_revision = count
    end
    local spec_digest: string? = nil
    if object.spec_digest ~= nil then
        local digest = bounds.text(object.spec_digest, 64)
        if not digest or #digest ~= 64 or not digest:match("^[0-9a-f]+$") then
            return nil, "spec_digest must be a lowercase SHA-256 hex digest"
        end
        spec_digest = digest
    end
    local brief = bounds.text(object.brief, M.MAX_BRIEF_BYTES)
    if not brief then return nil, "brief must be bounded text" end
    -- The causally parent action, when an agent started this launch. It is
    -- recorded on the child's admitted action and narrows nothing by itself.
    local parent_action_id: string? = nil
    if object.parent_action_id ~= nil then
        parent_action_id = bounds.id(object.parent_action_id)
        if not parent_action_id then return nil, "parent_action_id is not an identifier" end
    end
    local mode: string? = nil
    if object.mode ~= nil then
        mode = bounds.member(object.mode, definition.MODES)
        if not mode then return nil, "mode must be window, session or batch" end
    end
    local workdir: string? = nil
    if object.workdir ~= nil then
        workdir = bounds.id(object.workdir)
        if not workdir then return nil, "workdir is not an identifier" end
    end
    local thread_id: string? = nil
    if object.thread_id ~= nil then
        thread_id = bounds.id(object.thread_id)
        if not thread_id then return nil, "thread_id is not an identifier" end
    end
    -- A new thread under the caller's title, instead of an existing one.
    local thread_title: string? = nil
    if object.thread_title ~= nil then
        thread_title = bounds.line(object.thread_title, record_bounds.MAX_TITLE_BYTES)
        if not thread_title then return nil, "thread_title must be one line of bounded text" end
        if thread_id then return nil, "thread_id and thread_title are exclusive" end
    end
    local placement: string? = nil
    if object.placement ~= nil then
        placement = bounds.id(object.placement)
        if not placement then return nil, "placement is not an identifier" end
    end
    local origin_view: OriginView? = nil
    if object.origin_view ~= nil then
        local declared = bounds.object(object.origin_view)
        if not declared or bounds.fields(declared, {"view_id", "instance_id"}) then return nil, "origin_view must contain only view_id and instance_id" end
        local view_id, instance_id = bounds.id(declared.view_id), bounds.id(declared.instance_id)
        if not view_id or not instance_id then return nil, "origin_view needs view_id and instance_id identifiers" end
        origin_view = {view_id = view_id, instance_id = instance_id}
    end
    local expected_plan_digest: string? = nil
    if object.expected_plan_digest ~= nil then
        local digest = bounds.text(object.expected_plan_digest, 64)
        if not digest or #digest ~= 64 or not digest:match("^[0-9a-f]+$") then
            return nil, "expected_plan_digest must be a lowercase SHA-256 hex digest"
        end
        expected_plan_digest = digest
    end
    local previous: Continuation? = nil
    if object.continuation ~= nil then
        local source = bounds.object(object.continuation)
        if not source then return nil, "continuation must be an object" end
        local field = bounds.fields(source, {"origin_request_id", "previous_attempt_id", "thread_id", "reauthorize"})
        if field then return nil, "continuation: " .. field end
        local origin = bounds.id(source.origin_request_id)
        local attempt = bounds.id(source.previous_attempt_id)
        local thread = bounds.id(source.thread_id)
        if not origin or not attempt or not thread then return nil, "continuation needs bounded origin, attempt and thread identifiers" end
        if brief ~= "" then return nil, "window continuation cannot replay a brief" end
        if thread_id or thread_title then return nil, "continuation cannot override its thread" end
        if not expected_plan_digest then return nil, "continuation needs the saved launch plan digest" end
        if source.reauthorize ~= nil and type(source.reauthorize) ~= "boolean" then return nil, "continuation.reauthorize must be a boolean" end
        previous = {origin_request_id = origin, previous_attempt_id = attempt, thread_id = thread, reauthorize = source.reauthorize == true}
    end
    return {request_id = request_id, definition_ref = definition_ref, workspace_id = workspace_id, brief = brief, mode = mode, workdir = workdir, thread_id = thread_id,
        thread_title = thread_title, placement = placement, saved_profile_id = saved_id, saved_profile_revision = saved_revision,
        expected_plan_digest = expected_plan_digest, placement_override = placement_override, continuation = previous, parent_action_id = parent_action_id, origin_view = origin_view,
        agent_ref = agent_ref, owner_component_revision = owner_component_revision, spec_digest = spec_digest}, nil
end
-- The durable identities of a request: the same request id always names
-- the same action and attempt.
function M.overrides(plan: Plan, name: string): boolean
    return bounds.member(name, plan.overrides) ~= nil
end
function M.identities(request_id: string): {action_id: string, attempt_id: string}
    return {action_id = "action:" .. request_id, attempt_id = "attempt:" .. request_id}
end

-- Plan selection reads declarations. Placement invokes driver configuration
-- once it can supply the selected gateway and actual private HOME; a partial
-- render here would reject drivers requiring those host-owned inputs.
-- admit: for the authenticated requester, resolve the plan, settle the
-- thread, obtain the attempt-bound resource grant and credential
-- projections in the requester's own authority, and return the carrier
-- request. Every acquisition keys on the request id, so a retry replays.
local function admit_request(value: unknown, session_turn: SessionTurnContext?, session_operation_key: string?): (Admitted?, Reply?)
    local request, decode_error = M.decode_request(value)
    if not request then return nil, fail("INVALID", decode_error or "invalid request") end
    local requester = session_turn and session_turn.owner_id or actor()
    if not requester then return nil, fail("UNAUTHENTICATED", "no actor") end
    local selected: Selected? = nil
    if request.saved_profile_id and request.saved_profile_revision then
        local found, refused = selected_profile(request.workspace_id, request.saved_profile_id, request.saved_profile_revision, request.definition_ref)
        if not found then return nil, refused end
        if request.owner_component_revision and found.profile.owner_component_revision and found.profile.owner_component_revision ~= request.owner_component_revision then
            return nil, fail("CONFLICT", "saved profile owner component revision changed; select it again")
        end
        if request.spec_digest and found.profile.spec_digest and found.profile.spec_digest ~= request.spec_digest then
            return nil, fail("CONFLICT", "saved profile spec digest changed; select it again")
        end
        selected = found
    end
    local pinned, pin_error = catalog.pin()
    if not pinned then return nil, fail("UNAVAILABLE", pin_error or "pin the registry") end
    local launch, definition_error = read_definition(pinned, request.definition_ref)
    if not launch then return nil, fail("NOT_FOUND", definition_error or "definition") end
    local plan, plan_refused, preferences = resolve(pinned, launch, request.mode, selected, request.agent_ref, request.owner_component_revision, request.spec_digest, session_turn ~= nil, request.placement_override)
    if not plan then return nil, plan_refused end
    if request.expected_plan_digest and request.expected_plan_digest ~= plan.plan_digest then
        return nil, fail("CONFLICT", "the selected launch plan changed; resolve it again before starting")
    end
    if request.brief == "" and plan.mode ~= "window" then return nil, fail("INVALID", "a structured launch needs a nonempty brief") end
    if request.workdir and not M.overrides(plan, "workdir") then return nil, fail("FORBIDDEN", "the launch does not allow a workdir override") end
    local defined_thread = launch.thread_policy.kind == "named" and request.thread_id == launch.thread_policy.thread_ref
    local thread_override = not session_turn and (request.thread_title ~= nil
        or (request.thread_id ~= nil and launch.thread_policy.kind ~= "caller" and not defined_thread))
    if thread_override and not M.overrides(plan, "thread") then return nil, fail("FORBIDDEN", "the launch does not allow a thread override") end
    if request.placement and request.placement ~= plan.placement_kind then
        if not M.overrides(plan, "placement") then return nil, fail("FORBIDDEN", "the launch does not allow a placement override") end
        return nil, fail("PLACEMENT_UNAVAILABLE", "this host admits no " .. request.placement .. " placement for " .. launch.ref .. "; it places it " .. plan.placement_kind)
    end
    if plan.placement_kind == "docker" and plan.placement_profile_ref then
        local prepared, prepare_error = call("bee.placement.docker.binding:prepare_environment", {placement_profile_ref = plan.placement_profile_ref,
            workspace_id = request.workspace_id, progress_recipient = tostring(process.pid())})
        if not prepared then return nil, prepare_error end
    end
    local ids = M.identities(request.request_id)
    if session_turn then ids = {action_id = session_turn.action_id, attempt_id = session_turn.attempt_id} end
    local previous = request.continuation
    if previous and (#request.workspace_id ~= 32 or request.workspace_id:find("[^0-9a-f]")) then
        return nil, fail("CONFLICT", "saved windows belong to their canonical home workspace")
    end
    if previous and plan.mode ~= "window" then return nil, fail("INVALID", "launch continuation requires a window profile") end
    local thread_id = request.thread_id
    if session_turn then
        if not thread_id then return nil, fail("INVALID", "a session turn needs its durable thread") end
    elseif launch.thread_policy.kind == "named" and not thread_override then thread_id = launch.thread_policy.thread_ref end
    if previous then
        if thread_id and thread_id ~= previous.thread_id then return nil, fail("CONFLICT", "the saved thread differs from the launch definition") end
        thread_id = previous.thread_id
        ids.action_id = M.identities(previous.origin_request_id).action_id
    end
    if not thread_id and not request.thread_title and launch.thread_policy.kind == "caller" then return nil, fail("INVALID", "definition expects the caller's thread") end
    local workdir_name = request.workdir
    if not workdir_name and launch.workdir_policy.kind == "declared_resource" then workdir_name = launch.workdir_policy.resource_ref end
    if launch.workdir_policy.kind == "required" and not workdir_name then return nil, fail("INVALID", "definition requires a working directory resource") end
    local session_resource = launch.session_resource
    if previous and not session_resource then return nil, fail("CONFLICT", "the launch definition has no retained session resource") end
    if session_resource and workdir_name == session_resource then
        return nil, fail("INVALID", "workdir resource duplicates the session resource")
    end
    -- A caller-selected or host-named existing thread is useful for fan-out,
    -- but it must be authorized before any session, project or credential
    -- resource is acquired. Carrier commits check membership again; this
    -- earlier read prevents a refused launch from leaving admission effects.
    if thread_id and not previous and not session_turn then
        local visible, thread_refused = call(M.THREADS .. ":get", {thread_id = thread_id})
        if not visible then return nil, thread_refused or fail("DENIED", "caller is not a member of the selected thread") end
        local membership = bounds.object(visible.membership)
        -- Threads authenticates this read as the caller and may resolve an attested application family to its active member.
        if not membership or membership.active ~= true then
            return nil, fail("DENIED", "caller is not an active member of the selected thread")
        end
    end
    -- Session authority is selected by the host definition. A retained
    -- session gets one stable digest-derived identity per launch request, while the
    -- default remains ephemeral and receives no session grant.
    local interactive_session: string? = nil
    if not session_turn and plan.mode == "window" and previous then
        local attached, attach_error = call("bee.sessions.binding:attach", {definition = request.definition_ref, thread_id = thread_id,
            plan_digest = plan.plan_digest, saved_profile_id = request.saved_profile_id, saved_profile_revision = request.saved_profile_revision,
            attempt_id = previous.previous_attempt_id, operation_key = session_operation_key or "window-session:" .. previous.origin_request_id})
        if not attached then return nil, attach_error end
        interactive_session = bounds.id(attached.session)
        if not interactive_session then return nil, fail("UNAVAILABLE", "interactive session owner omitted its ref") end
    end
    local resources: {placement_types.ResourceGrant} = {}
    local session_ref: string? = session_turn and session_turn.session_ref or nil
    if session_resource then
        if not session_turn then
            local session_digest, session_error = digest_of({workspace_id = request.workspace_id,
                request_id = previous and previous.origin_request_id or request.request_id})
            if not session_digest then return nil, fail("UNAVAILABLE", tostring(session_error or "derive retained session identity")) end
            session_ref = interactive_session or "session:" .. session_digest
        end
        if previous and not session_turn then
            -- Saved references grant nothing. Existing owner operations verify
            -- membership, exact producer/session, driver pins and completed
            -- cleanup before this request obtains any fresh grants.
            local recovery_request: continuation.Request = {thread_id = previous.thread_id,
                action_id = ids.action_id, attempt_id = ids.attempt_id, previous_attempt_id = previous.previous_attempt_id,
                owner_id = requester, session_ref = assert(session_ref), binding_ref = plan.binding_ref,
                binding_digest = plan.binding_digest, profile_id = plan.profile_id, profile_digest = plan.profile_digest,
                placement_binding_ref = plan.placement_binding_ref, placement_binding_digest = plan.placement_binding_digest,
                placement_methods = plan.placement_methods, reauthorize = previous.reauthorize}
            local recovered, recovery_error = interrupted.recover(recovery_request)
            if not recovered then return nil, fail("CONFLICT", "cannot recover saved window: " .. tostring(recovery_error)) end
            local resume, resume_error = continuation.resolve_window(function(target: string, input: unknown): (unknown, string?)
                local reply, err = funcs.call(target, input)
                if err then return nil, tostring(err) end
                return reply, nil
            end, recovery_request)
            if not resume and resume_error == continuation.NO_CONVERSATION then
                return nil, fail(M.NOT_RESUMABLE, "its last session never started a conversation")
            end
            if not resume then return nil, fail("CONFLICT", "cannot resume saved window: " .. tostring(resume_error)) end
        end
        local granted, grant_refused = call(M.RESOURCES .. ":grant", {workspace_id = request.workspace_id, name = session_resource, access = "write", purpose = "session",
            audience = requester, attempt_id = ids.attempt_id, idempotency_key = "launch:" .. request.request_id .. ":session"})
        if not granted then return nil, grant_refused end
        local typed, grant_error = resource_grant(granted, request.workspace_id, session_resource, "session", requester, ids.attempt_id)
        if not typed then return nil, fail("UNAVAILABLE", grant_error or "resource grant is invalid") end
        resources[#resources + 1] = typed
    end
    for _, ref in ipairs(plan.effective_profile and plan.effective_profile.bee.approval_leases or {}) do
        local _, refused = call("bee.approvals.binding:runtime_lease", {operation = "check", lease_ref = ref, workspace_id = request.workspace_id})
        if refused then return nil, refused end
    end
    if not thread_id then
        local created, create_refused = call(M.THREADS .. ":create", {thread_id = "thread:" .. request.request_id, idempotency_key = "launch:" .. request.request_id .. ":thread", title = request.thread_title or launch.title})
        if not created then return nil, create_refused end
        thread_id = tostring(created.thread_id)
    end
    if not session_turn and plan.mode == "window" then
        local attached, attach_error = call("bee.sessions.binding:attach", {definition = request.definition_ref, thread_id = thread_id,
            plan_digest = plan.plan_digest, saved_profile_id = request.saved_profile_id, saved_profile_revision = request.saved_profile_revision,
            attempt_id = ids.attempt_id, operation_key = session_operation_key or "window-session:" .. (previous and previous.origin_request_id or request.request_id)})
        if not attached then return nil, attach_error end
        interactive_session = bounds.id(attached.session)
        if not interactive_session then return nil, fail("UNAVAILABLE", "interactive session owner omitted its ref") end
        session_ref = interactive_session
    end
    local working: string? = nil
    if workdir_name then
        local granted, grant_refused = call(M.RESOURCES .. ":grant", {workspace_id = request.workspace_id, name = workdir_name, access = "write", purpose = "project",
            audience = requester, attempt_id = ids.attempt_id, idempotency_key = "launch:" .. request.request_id .. ":workdir"})
        if not granted then return nil, grant_refused end
        local typed, grant_error = resource_grant(granted, request.workspace_id, workdir_name, "project", requester, ids.attempt_id)
        if not typed then return nil, fail("UNAVAILABLE", grant_error or "resource grant is invalid") end
        resources[#resources + 1] = typed
        working = workdir_name
    end
    local profile_grants: {carrier.ProfileGrant} = {}
    for index, file in ipairs(plan.effective_profile and plan.effective_profile.bee.files or {}) do
        local granted, refused = call(M.RESOURCES .. ":grant", {workspace_id = file.workspace_id, name = file.resource, subpath = file.subpath,
            access = file.access, purpose = "project", audience = requester, attempt_id = ids.attempt_id,
            idempotency_key = "launch:" .. request.request_id .. ":file:" .. tostring(index)})
        if not granted then return nil, refused end
        local grant_id, root = bounds.id(granted.grant_id), bounds.id(granted.root_ref)
        if not grant_id or not root or granted.subpath ~= file.subpath or granted.workspace_id ~= file.workspace_id or granted.name ~= file.resource
            or granted.access ~= file.access or granted.attempt_id ~= ids.attempt_id or granted.audience ~= requester then return nil, fail("UNAVAILABLE", "bee.files: owner returned a different grant") end
        profile_grants[#profile_grants + 1] = {workspace_id = file.workspace_id, name = file.resource, subpath = file.subpath, access = file.access, grant_ref = grant_id}
    end
    local projections: {string} = {}
    local credentials = launch.credentials
    for index, credential in ipairs(credentials) do
        local issued, issue_refused = call(M.CREDENTIALS .. ":issue_projection", {workspace_id = request.workspace_id, name = credential, audience = requester, attempt_id = ids.attempt_id,
            profile_id = plan.profile_id, profile_digest = plan.profile_digest, binding_digest = plan.binding_digest, launch_policy_digest = plan.policy_digest,
            idempotency_key = "launch:" .. request.request_id .. ":credential:" .. tostring(index)})
        if not issued then return nil, issue_refused end
        if selected then
            for name, value in pairs(selected.profile.provider.env or {}) do
                if value.kind == "credential" and value.credential_ref == credential and (issued.projection_kind ~= "environment" or issued.destination ~= name) then
                    return nil, fail("DENIED", "provider.env." .. name .. ": credential broker destination differs; references cannot retarget credentials")
                elseif value.kind == "literal" and issued.projection_kind == "environment" and issued.destination == name then
                    return nil, fail("DENIED", "provider.env." .. name .. ": literal conflicts with an admitted credential projection")
                end
            end
        end
        projections[index] = tostring(issued.projection_id)
    end
    local carrier_request: carrier.Request = {profile_grants = profile_grants, thread_id = thread_id, action_id = ids.action_id, attempt_id = ids.attempt_id, owner_id = requester, owner_incarnation = 1, parent_action_id = request.parent_action_id,
        preferences = preferences or preference_value(selected),
        binding_ref = plan.binding_ref, profile_id = plan.profile_id, brief = request.brief, policy_ref = plan.policy_ref,
        placement_profile_ref = plan.placement_profile_ref, placement_profile_digest = plan.placement_profile_digest, placement_binding_ref = plan.placement_binding_ref, placement_binding_digest = plan.placement_binding_digest, placement_methods = plan.placement_methods, resources = resources, environment = {},
        working_directory = working, projections = projections, workspace_id = request.workspace_id, session_ref = session_ref,
        previous_attempt_id = previous and previous.previous_attempt_id or nil, reauthorize = previous and previous.reauthorize or nil, origin_view = request.origin_view,
        options = launch.options}
    return {plan = plan, request = carrier_request, requester = requester, request_id = request.request_id,
        thread_id = thread_id, action_id = ids.action_id, attempt_id = ids.attempt_id, session_ref = session_ref,
        saved_profile_revision = plan.saved_profile_revision,
        owner_component_revision = plan.owner_component_revision}, nil
end
function M.admit_request(value: unknown, session_operation_key: string?): (Admitted?, Reply?)
    return admit_request(value, nil, session_operation_key)
end
-- The scheduler is the only caller of this internal admission path. Threads
-- stores the owner, workspace, session, and thread identities on the route;
-- the current turn supplies only its immutable input and attempt identity.
function M.admit_session_turn(value: unknown): (Admitted?, Reply?)
    local input = bounds.object(value)
    if not input then return nil, fail("INVALID", "session turn admission must be an object") end
    local unknown_field = bounds.fields(input, {"attempt_id", "definition_ref", "workspace_id", "owner_id", "thread_id", "session_ref",
        "action_id", "brief", "expected_plan_digest", "profile_id", "saved_profile_id", "saved_profile_revision", "workdir", "placement_override"})
    if unknown_field then return nil, fail("INVALID", "session turn admission: " .. unknown_field) end
    local attempt_id, definition_ref = bounds.id(input.attempt_id), bounds.id(input.definition_ref)
    local workspace_id, owner_id = bounds.id(input.workspace_id), bounds.id(input.owner_id)
    local thread_id, session_ref = bounds.id(input.thread_id), bounds.id(input.session_ref)
    local action_id, profile_id = bounds.id(input.action_id), bounds.id(input.profile_id)
    local brief = bounds.text(input.brief, M.MAX_BRIEF_BYTES)
    local expected_plan_digest = bounds.text(input.expected_plan_digest, 64)
    local workdir = input.workdir == nil and nil or bounds.id(input.workdir)
    if not attempt_id or not definition_ref or not workspace_id or not owner_id or not thread_id
        or not session_ref or not action_id or not profile_id or not brief
        or not expected_plan_digest or #expected_plan_digest ~= 64 or not expected_plan_digest:match("^[0-9a-f]+$")
        or (input.workdir ~= nil and not workdir) then
        return nil, fail("INVALID", "session turn admission identities are incomplete")
    end
    local request: {[string]: unknown} = {request_id = attempt_id, definition_ref = definition_ref,
        workspace_id = workspace_id, thread_id = thread_id, brief = brief,
        expected_plan_digest = expected_plan_digest}
    if input.saved_profile_id ~= nil then request.saved_profile_id = input.saved_profile_id end
    if input.placement_override ~= nil then request.placement_override = input.placement_override end
    if input.saved_profile_revision ~= nil then request.saved_profile_revision = input.saved_profile_revision end
    if workdir then request.workdir = workdir end
    local context: SessionTurnContext = {owner_id = owner_id, session_ref = session_ref,
        action_id = action_id, attempt_id = attempt_id}
    local admitted, refused = admit_request(request, context)
    if not admitted then return nil, refused end
    if admitted.plan.profile_id ~= profile_id then
        return nil, fail("CONFLICT", "the selected session profile changed since admission")
    end
    if not admitted.plan.session_resource then
        return nil, fail("UNAVAILABLE", "the selected definition has no retained session resource")
    end
    return admitted, nil
end
-- External callers keep the operation reply; local execution paths consume
-- the typed admitted request without decoding our own value a second time.
function M.admit(value: unknown): Reply
    local admitted, refused = M.admit_request(value)
    if not admitted then return refused or fail("UNAVAILABLE", "launch admission did not return a result") end
    return succeed(admitted)
end
-- start: admit, then spawn the carrier as the requester. A retry with the
-- same request id finds the attempt's checkpoint and resumes it instead of
-- opening a second one.
function M.start(value: unknown): Reply
    local linked = registry.get(M.CARRIER_HOST_REF)
    local data = linked and bounds.object(linked.data) or nil
    local host = data and bounds.id(data.host_ref) or nil
    if not host then return fail("UNAVAILABLE", "carrier process host is not linked") end
    local target = registry.get(host)
    if not target or target.kind ~= "process.host" then return fail("UNAVAILABLE", "carrier process host is unavailable") end
    local outcome, refused = M.admit_request(value)
    if not outcome then return refused or fail("UNAVAILABLE", "launch admission did not return a result") end
    local carrier_request = outcome.request
    local stored = call(M.CARRIER_OPS .. ":checkpoint", {thread_id = outcome.thread_id, attempt_id = outcome.attempt_id})
    local mode = "open"
    if stored then
        if stored.attempt_state == "ended" then
            if carrier_request.brief == "" then
                return fail("CONFLICT", "request " .. tostring(outcome.attempt_id) .. " already settled")
            end
            local grant_refs: {string} = {}
            for index, grant in ipairs(carrier_request.resources) do grant_refs[index] = grant.grant_ref end
            local admitted = carrier.admitted_action(carrier_request, outcome.plan.binding_ref,
                outcome.plan.binding_digest, outcome.plan.policy_ref, grant_refs, carrier_request.brief)
            local checked, replay_refused = call(M.THREADS .. ":admit_action", {thread_id = outcome.thread_id,
                idempotency_key = "launch:" .. outcome.attempt_id .. ":admit",
                action_id = outcome.action_id, admitted = admitted})
            if not checked then
                return replay_refused or fail("CONFLICT", "settled launch does not match this request")
            end
            outcome.mode = "settled"
            return succeed(outcome)
        end
        if stored.checkpoint ~= nil then mode = "resume" end
    end
    -- The carrier outlives this call; whoever routes the launch monitors it.
    local pid, spawn_error = process.with_context({}):spawn(M.CARRIER, host, carrier_request, mode, process.pid())
    if not pid then return fail("UNAVAILABLE", "spawn carrier: " .. tostring(spawn_error)) end
    outcome.carrier = tostring(pid)
    outcome.mode = mode
    outcome.started_at = time.now():utc():format("2006-01-02T15:04:05.000Z07:00")
    return succeed(outcome)
end
return M
