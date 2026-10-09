-- MIT. The host's MCP configuration and one binding's current selection.
local bounds = require("bounds")
local catalog = require("catalog")
local context = require("context")
local mcp = require("mcp")
local capability_model = require("capability_model")
local profile_access = require("profile_access")
local M = {}
M.APPLICATION_RUNTIME_TRAIT = mcp.APPLICATION_RUNTIME_TRAIT
-- The approval workspace is the binding's; a declaration names only policy and traits.
type Access = {policy: string, traits: {string}}
type Grant = context.ResourceGrant
type Surface = {authority_grant_id: string?, resource_grants: {Grant}?, profile: profile_access.Bee?, catalog: catalog.Catalog, ceiling: {string}, base_tools: {string},
    allowed_traits: {string}, fixed_context: context.Values, dynamic_keys: {string}, access: Access?}
type Selection = {active: {string}, context: context.Values}

local function decode_access(raw: unknown): (Access?, string?)
    if raw == nil then return nil, nil end
    local value = bounds.object(raw)
    if not value then return nil, "surface access must be an object" end
    local extra = bounds.fields(value, {"policy", "traits"})
    if extra then return nil, extra end
    local policy = bounds.id(value.policy)
    local traits, traits_error = bounds.ids(value.traits, true)
    if not policy or not traits then
        return nil, traits_error or "invalid surface access"
    end
    return {policy = policy, traits = traits}, nil
end

-- Built-in descriptions and component descriptions share one validated
-- catalog. A component cannot shadow a built-in name.
function M.prepare(raw: unknown, builtins: {catalog.Tool}, ceiling: {string}): (Surface?, Selection?, string?)
    local value = bounds.object(raw)
    if not value then return nil, nil, "MCP surface must be an object" end
    local extra = bounds.fields(value, {"tools", "traits", "base_tools", "active_traits", "fixed_context", "dynamic_keys", "access", "profile", "resource_grants", "authority_grant_id"})
    if extra then return nil, nil, extra end
    local profile: profile_access.Bee? = nil
    if value.profile ~= nil then
        local decoded, err = profile_access.decode(value.profile)
        if not decoded then return nil, nil, err end
        profile = decoded
    end
    local grants, grant_error = context.resource_grants(value.resource_grants)
    if grant_error then return nil, nil, grant_error end
    local access, access_error = decode_access(value.access)
    if access_error then return nil, nil, access_error end
    local configured, config_error = catalog.decode({tools = value.tools, traits = {}})
    if not configured then return nil, nil, config_error end
    for _, tool in ipairs(configured.tools) do
        if mcp.is_retired_tool(tool.name) then return nil, nil, tool.name .. " is retired and cannot be redeclared" end
    end
    local combined: {catalog.Tool} = {}
    for _, tool in ipairs(builtins) do combined[#combined + 1] = tool end
    for _, tool in ipairs(configured.tools) do combined[#combined + 1] = tool end
    -- `application_open` has exactly one built-in trait.  A policy may not
    -- re-declare it through an ordinary trait or present it as a base tool.
    local declared_traits = value.traits
    if type(declared_traits) ~= "table" then return nil, nil, "expected list" end
    local consent_of: {[string]: catalog.Trait} = {}
    for _, trait in ipairs(mcp.CONSENT_TRAITS) do
        for _, name in ipairs(trait.tools) do consent_of[name] = trait end
    end
    for _, raw_trait in ipairs(declared_traits) do
        local trait = bounds.object(raw_trait)
        local trait_tools = trait and bounds.ids(trait.tools, true)
        if trait_tools then
            for _, name in ipairs(trait_tools) do
                if name == "application_open" then return nil, nil, "application_open belongs only to bee.app:runtime" end
                local consent = consent_of[name]
                if consent then return nil, nil, name .. " belongs only to " .. consent.id end
            end
        end
    end
    local has_open = false
    local consents: {catalog.Trait} = {}
    local admitted_tools: {[string]: boolean} = {}
    for _, name in ipairs(ceiling) do
        admitted_tools[name] = true
        if name == "application_open" then has_open = true end
    end
    for _, trait in ipairs(mcp.CONSENT_TRAITS) do
        local tools: {string} = {}
        for _, name in ipairs(trait.tools) do
            if admitted_tools[name] then tools[#tools + 1] = name end
        end
        if #tools > 0 then consents[#consents + 1] = {id = trait.id, title = trait.title, prompt = trait.prompt, tools = tools} end
    end
    local traits: {unknown} = {}
    for _, trait in ipairs(declared_traits) do traits[#traits + 1] = trait end
    if has_open then traits[#traits + 1] = mcp.APPLICATION_RUNTIME_TRAIT end
    for _, trait in ipairs(consents) do traits[#traits + 1] = trait end
    local complete, complete_error = catalog.decode({tools = combined, traits = traits})
    if not complete then return nil, nil, complete_error end
    local base, base_error = bounds.ids(value.base_tools, true)
    local active, active_error = bounds.ids(value.active_traits, true)
    local keys, keys_error = bounds.ids(value.dynamic_keys, true)
    if not base then return nil, nil, base_error end
    if not active then return nil, nil, active_error end
    if not keys then return nil, nil, keys_error end
    local fixed, fixed_error = context.decode(value.fixed_context)
    if not fixed then return nil, nil, fixed_error end
    local allowed: {string} = {}
    local requestable: {[string]: boolean} = {}
    if access then
        for _, id in ipairs(access.traits) do requestable[id] = true end
    end
    if has_open then
        if not access then return nil, nil, "application_open requires bee.app:runtime access" end
        local declared = false
        for _, id in ipairs(access.traits) do if id == mcp.APPLICATION_RUNTIME_TRAIT.id then declared = true end end
        if not declared then return nil, nil, "application_open requires bee.app:runtime access" end
    end
    -- A consent tool reaches an agent only through a person: the profile the
    -- person saved lists it as a base tool, or the person approves its
    -- requestable trait during the session.
    for _, trait in ipairs(consents) do
        for _, name in ipairs(trait.tools) do
            local enabled = false
            for _, base_name in ipairs(base) do if base_name == name then enabled = true end end
            if not enabled and not requestable[trait.id] then
                return nil, nil, name .. " needs a person: enable it in the profile or offer " .. trait.id .. " as requestable access"
            end
        end
    end
    local gated_tools: {[string]: boolean} = {}
    local known_traits: {[string]: catalog.Trait} = {}
    for _, trait in ipairs(complete.traits) do known_traits[trait.id] = trait end
    if access then
        for _, id in ipairs(access.traits) do
            local trait = known_traits[id]
            if not trait then return nil, nil, "access references unknown trait" end
            for _, name in ipairs(trait.tools) do gated_tools[name] = true end
        end
        for _, name in ipairs(base) do
            if gated_tools[name] then return nil, nil, "requestable trait tool is in base tools" end
        end
        for _, trait in ipairs(complete.traits) do
            if not requestable[trait.id] then
                for _, name in ipairs(trait.tools) do
                    if gated_tools[name] then return nil, nil, "requestable trait tool is in freely selectable trait" end
                end
            end
        end
    end
    for _, trait in ipairs(complete.traits) do
        if not requestable[trait.id] then allowed[#allowed + 1] = trait.id end
    end
    local selected, selection_error = catalog.select(complete, ceiling, base, allowed, active)
    if not selected then return nil, nil, selection_error end
    local checked, context_error = context.compose(fixed, {}, keys)
    if not checked then return nil, nil, context_error end
    local admitted, admitted_error = bounds.ids(ceiling, true)
    if not admitted then return nil, nil, admitted_error end
    return {authority_grant_id = bounds.id(value.authority_grant_id),resource_grants = grants, profile = profile, catalog = complete, ceiling = admitted, base_tools = base, allowed_traits = allowed,
        fixed_context = fixed, dynamic_keys = keys, access = access}, {active = active, context = {}}, nil
end

-- A request can make only explicitly host-marked traits selectable. Return a
-- new surface so a pending request never mutates the existing selection gate.
function M.grant(surface: Surface, trait_ids: unknown): (Surface?, string?)
    local requested, request_error = bounds.ids(trait_ids, true)
    if not requested then return nil, request_error end
    if not surface.access then return nil, "surface has no requestable traits" end
    local admitted = capability_model.traits("mcp.surface", surface.access.traits)
    local requested_scope = capability_model.traits("mcp.surface", requested)
    if not admitted or not requested_scope or not capability_model.contains(admitted, requested_scope) then
        return nil, "trait is not requestable"
    end
    local allowed: {string} = {}
    local selectable: {[string]: boolean} = {}
    for _, id in ipairs(surface.allowed_traits) do
        allowed[#allowed + 1] = id
        selectable[id] = true
    end
    for _, id in ipairs(requested) do
        if not selectable[id] then
            allowed[#allowed + 1] = id
            selectable[id] = true
        end
    end
    local _, select_error = catalog.select(surface.catalog, surface.ceiling, surface.base_tools, allowed, requested)
    if select_error then return nil, select_error end
    local copied_access: Access = {policy = surface.access.policy, traits = {}}
    for _, id in ipairs(surface.access.traits) do copied_access.traits[#copied_access.traits + 1] = id end
    return {authority_grant_id = surface.authority_grant_id,resource_grants = surface.resource_grants, profile = surface.profile, catalog = surface.catalog, ceiling = surface.ceiling, base_tools = surface.base_tools,
        allowed_traits = allowed, fixed_context = surface.fixed_context, dynamic_keys = surface.dynamic_keys,
        access = copied_access}, nil
end

function M.select(surface: Surface, active_value: unknown, dynamic: unknown): (Selection?, string?)
    local active, active_error = bounds.ids(active_value, true)
    if not active then return nil, active_error end
    local tools, tools_error = catalog.select(surface.catalog, surface.ceiling, surface.base_tools, surface.allowed_traits, active)
    if not tools then return nil, tools_error end
    local values, value_error = context.decode(dynamic)
    if not values then return nil, value_error end
    local merged, merge_error = context.compose(surface.fixed_context, values, surface.dynamic_keys)
    if not merged then return nil, merge_error end
    return {active = active, context = values}, nil
end
return M
