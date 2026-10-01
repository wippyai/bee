-- MIT. Reads only host-selected registry resources named by Hub requirements.
local registry = require("registry")
local bounds = require("bounds")
local M = {}

M.PROCESS_HOST_REF = "bee.hub:process_host_ref"
M.PUBLISH_CONFIGURATION_REF = "bee.hub:publish_configuration_ref"
M.PUBLISH_EXECUTOR_REF = "bee.hub:publish_executor_ref"
M.DEFAULT_PUBLISH_EXECUTOR = "bee.hub:publish_executor"
type PublishConfig = {organization: string, cli: string, source_roots: {string}, staging_root: string}

function M.process_host(): (string?, string?)
    local linked, link_error = registry.get(M.PROCESS_HOST_REF)
    if not linked then return nil, tostring(link_error or "Hub process host is unavailable") end
    local data = type(linked.data) == "table" and linked.data or nil
    local host = data and bounds.id(data.host_ref) or nil
    if not host then return nil, "Hub process host is not linked" end
    local target, target_error = registry.get(host)
    if not target or target.kind ~= "process.host" then return nil, tostring(target_error or "Hub process host is unavailable") end
    return host, nil
end

local function absolute_path(value: unknown): string?
    local path = bounds.text(value, 8192)
    if not path or path:sub(1, 1) ~= "/" or path:find("%z", 1, true) then return nil end
    return path
end

-- The person's one-time Hub publication selection: the organization every
-- publication must belong to, the uploader CLI the worker runs, the source
-- roots it may pack and the worker-owned staging root holding sealed pack
-- files. An absent link fails closed.
function M.publish_config(): (PublishConfig?, string?)
    local linked, link_error = registry.get(M.PUBLISH_CONFIGURATION_REF)
    if not linked then return nil, tostring(link_error or "Hub publication is not configured") end
    local data = type(linked.data) == "table" and linked.data or nil
    local target = data and bounds.id(data.resource_ref) or nil
    if not target then return nil, "Hub publication configuration is not linked" end
    local entry = registry.get(target)
    local config = entry and type(entry.data) == "table" and entry.data or nil
    local organization = config and bounds.line(config.organization, 128) or nil
    if not organization or not organization:match("^[a-z0-9][a-z0-9._-]*$") then
        return nil, "Hub publication names no publishing organization"
    end
    local cli = config and absolute_path(config.cli) or nil
    if not cli then return nil, "Hub publication names no uploader executable" end
    local roots: {string} = {}
    local source_roots = config and bounds.array(config.source_roots, 64) or nil
    if source_roots then
        for _, raw in ipairs(source_roots) do
            local root = absolute_path(raw)
            if not root then return nil, "Hub publication source root is not an absolute directory" end
            roots[#roots + 1] = root
        end
    end
    if #roots == 0 then return nil, "Hub publication admits no source root" end
    local staging = config and absolute_path(config.staging_root) or nil
    if not staging then return nil, "Hub publication names no snapshot staging root" end
    return {organization = organization, cli = cli, source_roots = roots, staging_root = staging}, nil
end

function M.publish_executor(): (string?, string?)
    local linked, link_error = registry.get(M.PUBLISH_EXECUTOR_REF)
    if link_error then return nil, tostring(link_error) end
    local data = linked and type(linked.data) == "table" and linked.data or nil
    local ref = data and bounds.id(data.resource_ref) or nil
    if ref then return ref, nil end
    if linked then return nil, "Hub publisher executor is not linked" end
    return M.DEFAULT_PUBLISH_EXECUTOR, nil
end

return M
