-- MIT. The naming rule for applications a workspace's own agents author and
-- deliver to that workspace. Pure: it derives the component, namespace,
-- application entry and overlay owner a host's workspace-application profile
-- grants from one overlay name. It reads no configuration and grants nothing;
-- the host profiles decide whether the rule applies at all.
local M = {}

M.NAMESPACE_ROOT = "app"
M.OWNER_PREFIX = "bee.governance.workspace_applications:"
M.APPLICATION_NAME = "app"
M.MAX_NAME = 48

type Identity = {name: string, namespace: string, component: string, definition_id: string, overlay_owner: string}

M.RULE = "name the overlay with lowercase letters, digits and underscores, starting with a letter (at most "
    .. tostring(M.MAX_NAME) .. " characters); put every entry in namespace " .. M.NAMESPACE_ROOT
    .. ".<overlay_id> and make the application entry " .. M.NAMESPACE_ROOT .. ".<overlay_id>:"
    .. M.APPLICATION_NAME

-- The overlay name, when it can name a workspace application.
function M.name(raw: unknown): string?
    if type(raw) ~= "string" or #raw == 0 or #raw > M.MAX_NAME or not raw:match("^[a-z][a-z0-9_]*$") then
        return nil
    end
    return raw
end

function M.identity(workspace_raw: unknown, source_workspace: unknown): (Identity?, string?)
    local name = M.name(source_workspace)
    if not name then
        return nil, "overlay " .. tostring(source_workspace) .. " cannot name a workspace application: " .. M.RULE
    end
    if type(workspace_raw) ~= "string" or #workspace_raw == 0 or #workspace_raw > 160 or workspace_raw:find("%c") then
        return nil, "workspace application destination is invalid"
    end
    local namespace = M.NAMESPACE_ROOT .. "." .. name
    return {name = name, namespace = namespace, component = namespace,
        definition_id = namespace .. ":" .. M.APPLICATION_NAME,
        overlay_owner = M.OWNER_PREFIX .. workspace_raw .. "." .. name}, nil
end

-- The overlay a workspace-application component was published from.
function M.source_of(component: unknown): string?
    if type(component) ~= "string" then return nil end
    local prefix = M.NAMESPACE_ROOT .. "."
    if component:sub(1, #prefix) ~= prefix then return nil end
    return M.name(component:sub(#prefix + 1))
end

return M
