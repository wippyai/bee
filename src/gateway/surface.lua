-- MIT. The host's MCP configuration and one binding's current selection.
local bounds = require("bounds")
local catalog = require("catalog")
local context = require("context")
local M = {}
type Surface = {catalog: catalog.Catalog, ceiling: {string}, base_tools: {string},
    allowed_traits: {string}, fixed_context: context.Values, dynamic_keys: {string}}
type Selection = {active: {string}, context: context.Values}
-- Built-in descriptions and component descriptions share one validated
-- catalog. A component cannot shadow a built-in name.
function M.prepare(raw: unknown, builtins: {catalog.Tool}, ceiling: {string}): (Surface?, Selection?, string?)
    local value = bounds.object(raw)
    if not value then return nil, nil, "MCP surface must be an object" end
    local extra = bounds.fields(value, {"tools", "traits", "base_tools", "active_traits", "fixed_context", "dynamic_keys"})
    if extra then return nil, nil, extra end
    local configured, config_error = catalog.decode({tools = value.tools, traits = {}})
    if not configured then return nil, nil, config_error end
    local combined: {catalog.Tool} = {}
    for _, tool in ipairs(builtins) do combined[#combined + 1] = tool end
    for _, tool in ipairs(configured.tools) do combined[#combined + 1] = tool end
    local complete, complete_error = catalog.decode({tools = combined, traits = value.traits})
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
    for _, trait in ipairs(complete.traits) do allowed[#allowed + 1] = trait.id end
    local selected, selection_error = catalog.select(complete, ceiling, base, allowed, active)
    if not selected then return nil, nil, selection_error end
    local checked, context_error = context.compose(fixed, {}, keys)
    if not checked then return nil, nil, context_error end
    local admitted, admitted_error = bounds.ids(ceiling, true)
    if not admitted then return nil, nil, admitted_error end
    return {catalog = complete, ceiling = admitted, base_tools = base, allowed_traits = allowed,
        fixed_context = fixed, dynamic_keys = keys}, {active = active, context = {}}, nil
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
