-- MIT. The host's MCP configuration and one binding's current selection.
local bounds = require("bounds")
local catalog = require("catalog")
local context = require("context")
local mcp = require("mcp")
local M = {}
M.APPLICATION_RUNTIME_TRAIT = mcp.APPLICATION_RUNTIME_TRAIT
-- The approval workspace is the binding's; a declaration names only policy and traits.
type Access = {policy: string, traits: {string}}
type Surface = {catalog: catalog.Catalog, ceiling: {string}, base_tools: {string},
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
    local extra = bounds.fields(value, {"tools", "traits", "base_tools", "active_traits", "fixed_context", "dynamic_keys", "access"})
    if extra then return nil, nil, extra end
    local access, access_error = decode_access(value.access)
    if access_error then return nil, nil, access_error end
    local configured, config_error = catalog.decode({tools = value.tools, traits = {}})
    if not configured then return nil, nil, config_error end
    local combined: {catalog.Tool} = {}
    for _, tool in ipairs(builtins) do combined[#combined + 1] = tool end
    for _, tool in ipairs(configured.tools) do combined[#combined + 1] = tool end
    -- `application_open` has exactly one built-in trait.  A policy may not
    -- re-declare it through an ordinary trait or present it as a base tool.
    local declared_traits = value.traits
    if type(declared_traits) ~= "table" then return nil, nil, "expected list" end
    for _, raw_trait in ipairs(declared_traits :: {unknown}) do
        local trait = bounds.object(raw_trait)
        local trait_tools = trait and bounds.ids(trait.tools, true)
        if trait_tools then
            for _, name in ipairs(trait_tools) do
                if name == "application_open" then return nil, nil, "application_open belongs only to bee.application:runtime" end
            end
        end
    end
    local has_open = false
    for _, name in ipairs(ceiling) do if name == "application_open" then has_open = true end end
    local traits: {unknown} = {}
    for _, trait in ipairs(declared_traits :: {unknown}) do traits[#traits + 1] = trait end
    if has_open then traits[#traits + 1] = mcp.APPLICATION_RUNTIME_TRAIT end
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
        if not access then return nil, nil, "application_open requires bee.application:runtime access" end
        local declared = false
        for _, id in ipairs(access.traits) do if id == mcp.APPLICATION_RUNTIME_TRAIT.id then declared = true end end
        if not declared then return nil, nil, "application_open requires bee.application:runtime access" end
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
    return {catalog = complete, ceiling = admitted, base_tools = base, allowed_traits = allowed,
        fixed_context = fixed, dynamic_keys = keys, access = access}, {active = active, context = {}}, nil
end

-- A request can make only explicitly host-marked traits selectable. Return a
-- new surface so a pending request never mutates the existing selection gate.
function M.grant(surface: Surface, trait_ids: unknown): (Surface?, string?)
    local requested, request_error = bounds.ids(trait_ids, true)
    if not requested then return nil, request_error end
    if not surface.access then return nil, "surface has no requestable traits" end
    local requestable: {[string]: boolean} = {}
    for _, id in ipairs(surface.access.traits) do requestable[id] = true end
    local allowed: {string} = {}
    local selectable: {[string]: boolean} = {}
    for _, id in ipairs(surface.allowed_traits) do
        allowed[#allowed + 1] = id
        selectable[id] = true
    end
    for _, id in ipairs(requested) do
        if not requestable[id] then return nil, "trait is not requestable" end
        if not selectable[id] then
            allowed[#allowed + 1] = id
            selectable[id] = true
        end
    end
    local _, select_error = catalog.select(surface.catalog, surface.ceiling, surface.base_tools, allowed, requested)
    if select_error then return nil, select_error end
    local copied_access: Access = {policy = surface.access.policy, traits = {}}
    for _, id in ipairs(surface.access.traits) do copied_access.traits[#copied_access.traits + 1] = id end
    return {catalog = surface.catalog, ceiling = surface.ceiling, base_tools = surface.base_tools,
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
