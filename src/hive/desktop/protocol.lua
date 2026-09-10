-- MIT. Desktop operations use Hive envelopes; this module grants no authority.
local bounds = require("bounds")
local contract = require("contract")
local M = {}
M.SERVICE = "bee.desktop"
M.LIST = "bee.desktop:list"
M.ATTACH = "bee.desktop:attach"
M.DETACH = "bee.desktop:detach"
M.COPY = "bee.desktop:copy"
M.CLIENT_HOST = "bee.client:native"
type Configuration = {execution: string, expires_at: string, allowed_nodes: {string}, application: string?, local_clients: boolean?}
type DesktopInput = {execution: string, workspace_id: string?, desktop_id: string?, mode: "control" | "observe", session_id: string?}
function M.configuration(value: unknown): (Configuration?, string?)
    local object = bounds.object(value)
    if not object then return nil, "desktop configuration must be an object" end
    local fields_error = bounds.fields(object, {"execution", "expires_at", "allowed_nodes", "application", "local_clients"})
    if fields_error then return nil, fields_error end
    local execution = contract.workspace_id(object.execution)
    local expires = bounds.timestamp(object.expires_at)
    local nodes = bounds.ids(object.allowed_nodes)
    if not execution then return nil, "execution must be 32 lowercase hexadecimal characters" end
    if not expires then return nil, "expires_at must be a canonical UTC timestamp with milliseconds" end
    if not nodes then return nil, "allowed_nodes must be a bounded dense list of node identities" end
    if object.local_clients ~= nil and type(object.local_clients) ~= "boolean" then return nil, "local_clients must be boolean" end
    if (#nodes == 0 and object.local_clients ~= true) or #nodes > 64 then return nil, "allowed_nodes must contain 1 to 64 identities" end
    local seen: {[string]: boolean} = {}
    for _, node in ipairs(nodes) do if seen[node] then return nil, "allowed_nodes contains a duplicate identity" end; seen[node] = true end
    local application: string? = nil
    if object.application ~= nil then
        application = bounds.id(object.application)
        if not application then return nil, "application must be a bounded entry identity" end
    end
    return {execution = execution, expires_at = expires, allowed_nodes = nodes, application = application, local_clients = object.local_clients == true}, nil
end
function M.input(operation: string, value: unknown): DesktopInput?
    local object = bounds.object(value)
    if not object then return nil end
    local execution = contract.workspace_id(object.owner_execution)
    if not execution then return nil end
    if operation == M.LIST then
        if bounds.fields(object, {"owner_execution"}) then return nil end
        return {execution = execution, workspace_id = nil, desktop_id = nil, session_id = nil, mode = "observe"}
    end
    local workspace = contract.workspace_id(object.workspace_id)
    local desktop = contract.workspace_id(object.desktop_id)
    if not workspace or not desktop then return nil end
    if operation == M.ATTACH then
        if bounds.fields(object, {"owner_execution", "workspace_id", "desktop_id", "mode"})
            or (object.mode ~= "control" and object.mode ~= "observe") then return nil end
        return {execution = execution, workspace_id = workspace, desktop_id = desktop,
            mode = object.mode == "control" and "control" or "observe"}
    elseif operation == M.DETACH or operation == M.COPY then
        if bounds.fields(object, {"owner_execution", "workspace_id", "desktop_id", "session_id"}) then return nil end
        local session = bounds.id(object.session_id)
        if not session then return nil end
        return {execution = execution, workspace_id = workspace, desktop_id = desktop, session_id = session, mode = "observe"}
    end
    return nil
end
return M
