-- MIT. Built-in gateway tools that one tool with an operation argument
-- carries. A saved selection, binding or grant that names a folded tool moves
-- to its carrier, restricted to the operations it named; a move never widens
-- what the selection admits.
local bounds = require("bounds")
local canonical = require("canonical")
local M = {}
type Object = {[string]: unknown}
type Fold = {tool: string, operation: string}
type Group = {position: integer, scope: Object, encoded: string, operations: {string}}
local FOLDS: {[string]: Fold} = {
    session_close = {tool = "session_manage", operation = "close"},
    session_remove = {tool = "session_manage", operation = "remove"},
    session_rename = {tool = "session_manage", operation = "rename"},
    profile_get = {tool = "profile", operation = "get"},
    profile_list = {tool = "profile", operation = "list"},
    profile_put = {tool = "profile", operation = "put"},
    request_capability = {tool = "elevation", operation = "request"},
    capability_status = {tool = "elevation", operation = "status"},
    install_request = {tool = "hub_install", operation = "install"},
    uninstall_request = {tool = "hub_install", operation = "uninstall"},
    install_status = {tool = "hub_install", operation = "status"},
    publish_request = {tool = "hub_publish", operation = "publish"},
    publish_status = {tool = "hub_publish", operation = "status"},
}
-- The operations each carrier takes, in published order.
local OPERATIONS: {[string]: {string}} = {
    session_manage = {"close", "remove", "rename"},
    profile = {"get", "list", "put"},
    elevation = {"request", "status"},
    hub_install = {"install", "uninstall", "status"},
    hub_publish = {"publish", "status"},
}
M.OPERATIONS = OPERATIONS

function M.fold(name: string): Fold?
    return FOLDS[name]
end

-- names: the list with each folded name replaced by its carrier, each
-- carrier once at the position of its first member.
function M.names(names: {string}): {string}
    local result: {string} = {}
    local seen: {[string]: boolean} = {}
    for _, name in ipairs(names) do
        local fold = FOLDS[name]
        local target = fold and fold.tool or name
        if not seen[target] then
            seen[target] = true
            result[#result + 1] = target
        end
    end
    return result
end

-- selection: saved MCP entries {tool, scope} with each folded group moved to
-- its carrier. The carrier keeps the scope of the group's first member and
-- the members sharing that exact scope; a partial group restricts the
-- carrier to its members' operations. A member whose scope already bounds
-- operations named nothing the folded tool accepted and is dropped.
function M.selection(entries: {unknown}): {unknown}
    local result: {unknown} = {}
    local groups: {[string]: Group} = {}
    local order: {string} = {}
    for _, raw in ipairs(entries) do
        local entry = bounds.object(raw)
        local name = entry and bounds.id(entry.tool)
        local fold = name and FOLDS[name] or nil
        if not entry or not fold then
            result[#result + 1] = raw
        else
            local scope = bounds.object(entry.scope) or {}
            local encoded = canonical.encode(scope) or ""
            if scope.operations == nil then
                local group = groups[fold.tool]
                if not group then
                    result[#result + 1] = false
                    group = {position = #result, scope = scope, encoded = encoded, operations = {}}
                    groups[fold.tool] = group
                    order[#order + 1] = fold.tool
                end
                if group.encoded == encoded then group.operations[#group.operations + 1] = fold.operation end
            end
        end
    end
    for _, tool in ipairs(order) do
        local group = groups[tool]
        local scope: Object = {}
        for key, value in pairs(group.scope) do scope[key] = value end
        local all = OPERATIONS[tool] or {}
        local kept: {string} = {}
        for _, operation in ipairs(all) do
            if bounds.member(operation, group.operations) then kept[#kept + 1] = operation end
        end
        if #kept < #all then scope.operations = kept end
        result[group.position] = {tool = tool, scope = scope}
    end
    return result
end

-- any: whether a name list names a folded tool.
function M.any(names: {string}): boolean
    for _, name in ipairs(names) do if FOLDS[name] then return true end end
    return false
end

-- profile: a saved profile or its draft with its MCP selection and tool list
-- moved to the carriers; true when anything moved.
function M.profile(value: Object): boolean
    local moved = false
    for _, holder in ipairs({value, bounds.object(value.draft) or {}}) do
        local bee = bounds.object(holder.bee)
        local entries = bee and bounds.array(bee.mcp, 64)
        if bee and entries then
            local names: {string} = {}
            for _, raw in ipairs(entries) do
                local entry = bounds.object(raw)
                local name = entry and bounds.id(entry.tool)
                if name then names[#names + 1] = name end
            end
            if M.any(names) then
                bee.mcp = M.selection(entries)
                moved = true
            end
        end
        local listed = bounds.ids(holder.mcp_tools, true)
        if listed and M.any(listed) then
            holder.mcp_tools = M.names(listed)
            moved = true
        end
    end
    return moved
end

-- declaration: a trait declaration with its tools moved to the carriers;
-- true when anything moved.
function M.declaration(value: Object): boolean
    local listed = bounds.ids(value.tools, true)
    if not listed or not M.any(listed) then return false end
    value.tools = M.names(listed)
    return true
end

return M
