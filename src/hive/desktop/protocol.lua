-- MIT. Desktop operations use Hive envelopes; this module grants no authority.
local bounds = require("bounds")
local contract = require("contract")
local arguments = require("arguments")
local M = {}
M.SERVICE = "bee.desktop"
M.LIST = "bee.desktop:list"
M.CREATE = "bee.desktop:create"
M.ATTACH = "bee.desktop:attach"
M.DETACH = "bee.desktop:detach"
M.COPY = "bee.desktop:copy"
M.LAUNCH = "bee.desktop:launch"
-- The client's current session: after a switch its display shows another
-- workspace under a new session and mount.
M.CURRENT = "bee.desktop:current"
-- A display registers its lifetime with its own node before the remote
-- attach. Remote process monitors do not report individual actor exits.
M.LIFETIME = "bee.desktop.lifetime"
M.LIFETIME_REPLY = "bee.desktop.lifetime.reply."
M.LIFETIME_EXIT = "bee.desktop.lifetime.exit"
-- A catalog page holds at most this many workspaces; a cursor is at most this long.
M.MAX_PAGE = 50
M.MAX_CURSOR = 2200
-- A display command is a native client role, but its host is deliberately
-- separate from the retained owner and ordinary terminal applications. The
-- owner still checks the caller node against its explicit admission grant.
M.CLIENT_HOST = "bee.hive.desktop:display_host"
-- A remote view presents another node's workspace in a local application
-- window. It runs on the display client host; its parent exchanges these
-- topics with it: one state (attached or failed), then frames one way and
-- input, resize and close the other.
M.VIEWER = "bee.hive.desktop:viewer"
M.VIEW_STATE = "bee.hive.viewer.state"
M.VIEW_FRAME = "bee.hive.viewer.frame"
M.VIEW_INPUT = "bee.hive.viewer.input"
M.VIEW_RESIZE = "bee.hive.viewer.resize"
M.VIEW_CLOSE = "bee.hive.viewer.close"
-- folder: whether the bridge composes the owner's folder workspace; a daemon's does not.
type Configuration = {execution: string, expires_at: string, allowed_nodes: {string}, allowed_peers: {string}, application: string?, local_clients: boolean?, folder: boolean}
type Query = {label: string?, after: string?, limit: integer}
-- execution: the owner generation the request names; a listing may name none
-- to learn it, since its answer carries the execution it was read under.
type DesktopInput = {execution: string?, workspace_id: string?, desktop_id: string?, mode: "control" | "observe", session_id: string?, name: string?,
    arguments: {string}?, query: Query?}
function M.configuration(value: unknown): (Configuration?, string?)
    local object = bounds.object(value)
    if not object then return nil, "desktop configuration must be an object" end
    local fields_error = bounds.fields(object, {"execution", "expires_at", "allowed_nodes", "allowed_peers", "application", "local_clients", "folder"})
    if fields_error then return nil, fields_error end
    local execution = contract.workspace_id(object.execution)
    local expires = bounds.timestamp(object.expires_at)
    local nodes = bounds.ids(object.allowed_nodes)
    local peers = object.allowed_peers == nil and {} or bounds.ids(object.allowed_peers)
    if not execution then return nil, "execution must be 32 lowercase hexadecimal characters" end
    if not expires then return nil, "expires_at must be a canonical UTC timestamp with milliseconds" end
    if not nodes then return nil, "allowed_nodes must be a bounded dense list of node identities" end
    if not peers then return nil, "allowed_peers must be a bounded dense list of node identities" end
    if object.local_clients ~= nil and type(object.local_clients) ~= "boolean" then return nil, "local_clients must be boolean" end
    if object.folder ~= nil and type(object.folder) ~= "boolean" then return nil, "folder must be boolean" end
    if (#nodes + #peers == 0 and object.local_clients ~= true) or #nodes + #peers > 64 then return nil, "desktop node grants must contain 1 to 64 identities" end
    local seen: {[string]: boolean} = {}
    for _, node in ipairs(nodes) do if seen[node] then return nil, "allowed_nodes contains a duplicate identity" end; seen[node] = true end
    for _, peer in ipairs(peers) do if seen[peer] then return nil, "allowed_peers contains a duplicate or statically allowed identity" end; seen[peer] = true end
    local application: string? = nil
    if object.application ~= nil then
        application = bounds.id(object.application)
        if not application then return nil, "application must be a bounded entry identity" end
    end
    return {execution = execution, expires_at = expires, allowed_nodes = nodes, allowed_peers = peers, application = application, local_clients = object.local_clients == true,
        folder = object.folder ~= false}, nil
end
function M.input(operation: string, value: unknown): DesktopInput?
    local object = bounds.object(value)
    if not object then return nil end
    local execution = contract.workspace_id(object.owner_execution)
    if not execution and (operation ~= M.LIST or object.owner_execution ~= nil) then return nil end
    if operation == M.LIST then
        -- One page of the node's workspaces: a label prefix, a cursor and a size.
        if bounds.fields(object, {"owner_execution", "label", "after", "limit"}) then return nil end
        local query: Query = {label = nil, after = nil, limit = M.MAX_PAGE}
        if object.label ~= nil then
            local label = contract.text(object.label, 240)
            if not label or label == "" then return nil end
            query.label = label
        end
        if object.after ~= nil then
            local after = contract.text(object.after, M.MAX_CURSOR)
            if not after or after == "" then return nil end
            query.after = after
        end
        if object.limit ~= nil then
            local limit: unknown = object.limit
            if type(limit) ~= "number" then return nil end
            local count = limit :: number
            if count ~= math.floor(count) or count < 1 or count > M.MAX_PAGE then return nil end
            query.limit = math.floor(count)
        end
        return {execution = execution, workspace_id = nil, desktop_id = nil, session_id = nil, mode = "observe", name = nil, arguments = nil, query = query}
    end
    if not execution then return nil end
    if operation == M.CURRENT then
        if bounds.fields(object, {"owner_execution"}) then return nil end
        return {execution = execution, workspace_id = nil, desktop_id = nil, mode = "observe", session_id = nil, name = nil, arguments = nil, query = nil}
    end
    local desktop = contract.workspace_id(object.desktop_id)
    if operation == M.CREATE then
        -- Displays belong to the node, so allocation names no workspace.
        if not desktop or bounds.fields(object, {"owner_execution", "desktop_id"}) then return nil end
        return {execution = execution, workspace_id = nil, desktop_id = desktop, mode = "control", session_id = nil, name = nil, arguments = nil, query = nil}
    end
    local workspace = contract.workspace_id(object.workspace_id)
    if not workspace or not desktop then return nil end
    if operation == M.ATTACH then
        if bounds.fields(object, {"owner_execution", "workspace_id", "desktop_id", "mode"})
            or (object.mode ~= "control" and object.mode ~= "observe") then return nil end
        return {execution = execution, workspace_id = workspace, desktop_id = desktop,
            mode = object.mode == "control" and "control" or "observe", name = nil, arguments = nil, query = nil}
    elseif operation == M.LAUNCH then
        if bounds.fields(object, {"owner_execution", "workspace_id", "desktop_id", "session_id", "name", "arguments"}) then return nil end
        local session = bounds.id(object.session_id)
        local name = contract.text(object.name, 40)
        if not session or not name or not name:match("^[a-z][a-z0-9_-]*$") or object.arguments == nil then return nil end
        local values = arguments.decode(object.arguments)
        if not values then return nil end
        return {execution = execution, workspace_id = workspace, desktop_id = desktop, session_id = session,
            mode = "control", name = name, arguments = values, query = nil}
    elseif operation == M.DETACH or operation == M.COPY then
        if bounds.fields(object, {"owner_execution", "workspace_id", "desktop_id", "session_id"}) then return nil end
        local session = bounds.id(object.session_id)
        if not session then return nil end
        return {execution = execution, workspace_id = workspace, desktop_id = desktop, session_id = session, mode = "observe", name = nil, arguments = nil, query = nil}
    end
    return nil
end
return M
