-- MIT. Pure decoder for host-selected publication profiles. An explicit row
-- names one destination workspace, source overlay, component and overlay
-- owner; `workspace_applications` lets a workspace publish the overlays its
-- own agents authored under the workspace-application naming rule.
local bounds = require("bounds")
local workspace_applications = require("workspace_applications")

local M = {}
local MAX_PROFILES = 64
type Profile = {workspace_id: string, source_workspace: string, component: string, overlay_owner: string}
type Configuration = {profiles: {Profile}, workspace_applications: boolean}
type Refusal = {message: string, remedy: string}

function M.decode(raw: unknown): (Configuration?, string?)
    local value = bounds.object(raw)
    local rows = value and value.profiles
    if not value or bounds.fields(value, {"profiles", "workspace_applications"}) or type(rows) ~= "table" then
        return nil, "publication profiles must be an object with a profile list"
    end
    local enabled = value.workspace_applications
    if enabled ~= nil and type(enabled) ~= "boolean" then
        return nil, "publication workspace_applications must be a boolean"
    end
    local source = rows :: table
    local count = 0
    for key in pairs(source) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return nil, "publication profiles must be a dense list" end
        count = count + 1
    end
    if count > MAX_PROFILES then return nil, "publication profile capacity is exceeded" end
    local profiles: {Profile} = {}
    local seen: {[string]: boolean} = {}
    for index = 1, count do
        local item = bounds.object(source[index])
        if not item or bounds.fields(item, {"workspace_id", "source_workspace", "component", "overlay_owner"}) then
            return nil, "publication profile is malformed"
        end
        local workspace_id, source_workspace = bounds.id(item.workspace_id), bounds.id(item.source_workspace)
        local component = bounds.text(item.component, 160)
        local overlay_owner = bounds.id(item.overlay_owner)
        if not workspace_id or not source_workspace or not component or component == "" or not overlay_owner then
            return nil, "publication profile identity is invalid"
        end
        local key = workspace_id .. "\n" .. component
        if seen[key] then return nil, "publication profile identity is duplicated" end
        seen[key] = true
        profiles[#profiles + 1] = {workspace_id = workspace_id, source_workspace = source_workspace,
            component = component, overlay_owner = overlay_owner}
    end
    return {profiles = profiles, workspace_applications = enabled == true}, nil
end

local function derived(configuration: Configuration, workspace_id: string, source_workspace: string): (Profile?, string?)
    if not configuration.workspace_applications then return nil, nil end
    local identity, identity_error = workspace_applications.identity(workspace_id, source_workspace)
    if not identity then return nil, identity_error end
    return {workspace_id = workspace_id, source_workspace = identity.name, component = identity.component,
        overlay_owner = identity.overlay_owner}, nil
end

local function refusal(configuration: Configuration, source_workspace: string, reason: string?): Refusal
    local configure = "a host adds a publication profile for it to bee.env:gov_publication_profiles"
        .. " and an activation profile to bee.env:gov_activation_profiles"
    return {message = reason or ("this workspace has no publication profile for overlay " .. source_workspace),
        remedy = configuration.workspace_applications and (workspace_applications.RULE .. "; or " .. configure)
            or configure}
end

-- The profile that publishes one authored overlay into one workspace.
function M.for_source(configuration: Configuration, workspace_id: string,
    source_workspace: string): (Profile?, Refusal?)
    for _, item in ipairs(configuration.profiles) do
        if item.workspace_id == workspace_id and item.source_workspace == source_workspace then return item, nil end
    end
    local profile, reason = derived(configuration, workspace_id, source_workspace)
    if profile then return profile, nil end
    return nil, refusal(configuration, source_workspace, reason)
end

-- The profile that publishes one component into one workspace.
function M.for_component(configuration: Configuration, workspace_id: string,
    component: string): (Profile?, Refusal?)
    for _, item in ipairs(configuration.profiles) do
        if item.workspace_id == workspace_id and item.component == component then return item, nil end
    end
    local source_workspace = workspace_applications.source_of(component)
    if source_workspace then
        local profile = derived(configuration, workspace_id, source_workspace)
        if profile then return profile, nil end
    end
    return nil, refusal(configuration, component, "this workspace has no publication profile for component " .. component)
end

return M
