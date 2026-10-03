-- MIT. Host workspace-application namespace and owner values. The captured
-- artifact declares its application target through kind and metadata.
local bounds = require("bounds")
local M = {}

M.NAMESPACE_ROOT = "app"
M.OWNER_PREFIX = "bee.gov.apps:"
-- This measured owner remains in activation and grant records made by the
-- previous release. Existing work resumes under its original owner.
local PRIOR_OWNER_PREFIX = "bee.governance.workspace_applications:"
M.MAX_NAME = 48

type Identity = {name: string, namespace: string, component: string, overlay_owner: string}

M.RULE = "name the overlay with lowercase letters, digits and underscores, starting with a letter (at most "
    .. tostring(M.MAX_NAME) .. " characters); put every entry in namespace " .. M.NAMESPACE_ROOT
    .. ".<overlay_id> and declare exactly one process.lua application with meta.type bee.app"

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
        overlay_owner = M.OWNER_PREFIX .. workspace_raw .. "." .. name}, nil
end

function M.application(raw: unknown): (string?, string?)
    local entries, list_error = bounds.dense_list(raw, 512, "workspace application entries")
    if not entries then return nil, list_error end
    local selected: string? = nil
    for _, raw_entry in ipairs(entries) do
        local entry = bounds.object(raw_entry)
        local meta = entry and bounds.object(entry.meta)
        if entry and meta and meta.type == "bee.app" then
            if entry.kind ~= "process.lua" then return nil, "workspace application is not a process.lua entry" end
            local id = bounds.id(entry.id)
            if not id then return nil, "workspace application identity is invalid" end
            if selected then return nil, "workspace artifact declares multiple applications" end
            selected = id
        end
    end
    if not selected then return nil, "workspace artifact declares no application" end
    return selected, nil
end

function M.prior_owner(workspace_raw: unknown, source_workspace: unknown): string?
    local identity = M.identity(workspace_raw, source_workspace)
    return identity and PRIOR_OWNER_PREFIX .. (workspace_raw) .. "." .. identity.name or nil
end

return M
