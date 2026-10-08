-- MIT
local bounds = require("bounds")
local application = require("application")

local M = {}
M.TYPE = "bee.hive.application_address"
type Identity = {source_node: string, source_workspace: string, component: string}
type Resolved = {application: string, overlay_owner: string?, identity: Identity?}

local function identity(raw: unknown): Identity?
    local value = bounds.object(raw)
    if not value or bounds.fields(value, {"source_node", "source_workspace", "component"}) then return nil end
    local node, workspace, component = bounds.id(value.source_node), bounds.id(value.source_workspace), bounds.line(value.component, 160)
    if not node or not workspace or not component then return nil end
    return {source_node = node, source_workspace = workspace, component = component}
end

local function same(left: Identity, right: Identity): boolean
    return left.source_node == right.source_node and left.source_workspace == right.source_workspace
        and left.component == right.component
end

function M.resolve(raw: unknown, workspace_id: string): (Resolved?, string?)
    if type(raw) == "string" then
        local ref = bounds.id(raw)
        if ref then return {application = ref}, nil end
    end
    local value = bounds.object(raw)
    local asked = identity(raw)
    local alias: string? = nil
    if value and not bounds.fields(value, {"alias"}) then alias = bounds.line(value.alias, 64) end
    if not asked and not alias then return nil, "application address requires a source identity or approved alias" end
    local selected: Resolved? = nil
    for _, entry in ipairs(application.host_entries(M.TYPE)) do
        local data = bounds.object(entry.data)
        if data and data.workspace_id == workspace_id then
            local source = identity(data.identity)
            local ref, owner = bounds.id(data.application), bounds.id(data.overlay_owner)
            local raw_aliases: unknown = data.aliases
            if raw_aliases == nil then raw_aliases = {} end
            local aliases = bounds.dense_list(raw_aliases, 32, "application aliases")
            if entry.kind ~= "registry.entry" or not source or not ref or not owner or not aliases
                or bounds.fields(data, {"workspace_id", "application", "overlay_owner", "identity", "aliases"}) then
                return nil, "host application address is malformed"
            end
            local matches = asked and same(asked, source) or false
            local seen: {[string]: boolean} = {}
            for _, raw_alias in ipairs(aliases) do
                local named = bounds.line(raw_alias, 64)
                if not named or seen[named] then return nil, "host application address aliases are malformed" end
                seen[named] = true
                if alias == named then matches = true end
            end
            if matches then
                if selected then return nil, "application address is ambiguous" end
                selected = {application = ref, overlay_owner = owner, identity = source}
            end
        end
    end
    if not selected then return nil, "application address is not approved in this workspace" end
    return selected, nil
end

return M
