-- MIT
local bounds = require("bounds")
local application = require("application")
local registry = require("registry")
local system = require("system")
local profiles = require("profiles")
local grants = require("grants")
local access = require("access")
local model = require("model")

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
    if not selected and asked then
        local configured = registry.get("bee.gov:activation_profiles")
        local configuration = configured and profiles.decode(configured.data) or nil
        local vocabulary = model.decode(registry.get("bee.capability:catalog"))
        local definitions, definitions_error = application.definitions(workspace_id)
        if not configuration or not vocabulary or not definitions then
            return nil, definitions_error or "application address admission is unavailable"
        end
        for _, ref in ipairs(definitions) do
            local binding, admission = application.admission(ref, workspace_id)
            if binding and admission and admission.source_node == asked.source_node
                and admission.source_workspace == asked.source_workspace then
                local installed = access.record(workspace_id, ref)
                if installed and installed.overlay_owner == admission.overlay_owner then
                    local stored = registry.get(assert(grants.record_id(installed.overlay_owner)))
                        or registry.get(assert(grants.prior_record_id(installed.overlay_owner)))
                    local profile = profiles.select_decoded(configuration, workspace_id, admission.source_node,
                        admission.source_workspace, assert(system.node.id()), stored, vocabulary, installed.overlay_owner)
                    if profile and profile.overlay_owner == installed.overlay_owner and profile.component == asked.component then
                        if selected then return nil, "application address is ambiguous" end
                        selected = {application = ref, overlay_owner = installed.overlay_owner, identity = asked}
                    end
                end
            end
        end
    end
    if not selected then return nil, "application address is not approved in this workspace" end
    return selected, nil
end

return M
