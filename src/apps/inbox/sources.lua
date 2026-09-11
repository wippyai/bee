-- MIT. Host-selected inbox source identities.  This is deliberately pure: it
-- qualifies remote rows for the local model but does not grant an owner call.
local hash = require("hash")
local bounds = require("bounds")
local M = {}
type Source = {id: string, node_id: string, workspace_id: string, local_owner: boolean, feed: string}
type Config = {workspaces: {string}, sources: {[string]: Source}}
local function digest(value: string): string
    local measured, measure_error = hash.sha256(value)
    if not measured then error("hash inbox source: " .. tostring(measure_error)) end
    return measured
end
-- A remote owner never leaks its native request identifier into the local
-- model.  The deterministic qualified ID is also the key of its route.
function M.remote_id(source_id: string, approval_id: string): string
    return "remote:" .. digest(source_id .. "\n" .. approval_id)
end
function M.configure(local_node: string, local_workspaces: {string}, raw_sources: unknown): (Config?, string?)
    local configured: Config = {workspaces = {}, sources = {}}
    local function add(node: string, workspace: string): string?
        local local_owner = node == local_node
        local id = local_owner and workspace or "source:" .. digest(node .. "\n" .. workspace)
        if configured.sources[id] then return nil end
        if #configured.workspaces >= 16 then return "inbox exceeds 16 admitted sources" end
        configured.sources[id] = {id = id, node_id = node, workspace_id = workspace, local_owner = local_owner,
            feed = "approvals." .. digest(workspace)}
        configured.workspaces[#configured.workspaces + 1] = id
        return nil
    end
    for _, workspace in ipairs(local_workspaces) do
        local add_error = add(local_node, workspace)
        if add_error then return nil, add_error end
    end
    if raw_sources == nil then return configured, nil end
    if type(raw_sources) ~= "table" then return nil, "inbox sources must be a list" end
    local count = 0
    for key in pairs(raw_sources) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return nil, "inbox sources must be a dense list" end
        count = count + 1
    end
    if count > 16 then return nil, "inbox exceeds 16 sources" end
    for index = 1, count do
        local item = bounds.object(raw_sources[index])
        if not item then return nil, "inbox source must be an object" end
        local extra = bounds.fields(item, {"node_id", "workspace_id"})
        local node, workspace = bounds.id(item.node_id), bounds.id(item.workspace_id)
        if extra or not node or not workspace then return nil, extra or "invalid inbox source identity" end
        local add_error = add(node, workspace)
        if add_error then return nil, add_error end
    end
    return configured, nil
end
return M
