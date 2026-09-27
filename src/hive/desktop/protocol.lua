-- MIT. Desktop operations use Hive envelopes; this module grants no authority.
local bounds = require("bounds")
local contract = require("contract")
local arguments = require("arguments")
local workspace_query = require("workspace_query")
local M = {}
M.SERVICE = "bee.desktop"
M.LIST = "bee.desktop:list"
M.CREATE = "bee.desktop:create"
M.ATTACH = "bee.desktop:attach"
M.DETACH = "bee.desktop:detach"
M.COPY = "bee.desktop:copy"
M.LAUNCH = "bee.desktop:launch"
M.PLAN = "bee.desktop:plan"
-- The client's current session: after a switch its display shows another
-- workspace under a new session and mount.
M.CURRENT = "bee.desktop:current"
-- A display registers its lifetime with its own node before the remote
-- attach. Remote process monitors do not report individual actor exits.
M.LIFETIME = "bee.desktop.lifetime"
M.LIFETIME_REPLY = "bee.desktop.lifetime.reply."
M.LIFETIME_EXIT = "bee.desktop.lifetime.exit"
-- A catalog page holds at most this many workspaces; a cursor is at most this long.
M.MAX_PAGE = workspace_query.MAX_PAGE
M.MAX_CURSOR = workspace_query.MAX_CURSOR
M.MAX_DESKTOPS = 33
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
M.VIEW_RETRY = "bee.hive.viewer.retry"
-- folder: whether the bridge composes the owner's folder workspace; a daemon's does not.
type Configuration = {execution: string?, expires_at: string, allowed_nodes: {string}, allowed_peers: {string}, application: string?, local_clients: boolean?, folder: boolean}
type Mode = "control" | "observe"
type AutomaticPlan = {kind: "automatic", mode: Mode, desktops: {string}, excluded: {string}}
type WorkspacePlan = {kind: "workspace", workspace_id: string, mode: Mode, desktops: {string}, excluded: {string}}
type SelectionPlan = {kind: "selection", workspace_id: string, desktop_id: string, mode: Mode, desktops: {string}}
type PlanRequest = AutomaticPlan | WorkspacePlan | SelectionPlan
type PlanInput = {kind: "plan", execution: string, request: PlanRequest}
-- owner_execution is the current owner incarnation; listing may omit it to learn
-- the value minted by the owner process.
type ListInput = {kind: "list", execution: string?, query: workspace_query.Query}
type CreateInput = {kind: "create", execution: string, desktop_id: string}
type CurrentInput = {kind: "current", execution: string}
type AttachInput = {kind: "attach", execution: string, workspace_id: string, desktop_id: string, mode: Mode}
type LaunchInput = {kind: "launch", execution: string, workspace_id: string, desktop_id: string, session_id: string, mode: "control", name: string, arguments: {string}}
type DetachInput = {kind: "detach", execution: string, workspace_id: string, desktop_id: string, session_id: string, mode: "observe"}
type CopyInput = {kind: "copy", execution: string, workspace_id: string, desktop_id: string, session_id: string, mode: "observe"}
type DesktopInput = ListInput | CreateInput | CurrentInput | PlanInput | AttachInput | LaunchInput | DetachInput | CopyInput
type ChooseWorkspace = {kind: "choose_workspace"}
type AttachPlan = {kind: "attach", workspace_id: string, desktop_id: string, mode: Mode}
type AllocatePlan = {kind: "allocate", workspace_id: string}
type SessionPlan = ChooseWorkspace | AttachPlan | AllocatePlan

local function id_list(value: unknown, allow_empty: boolean): {string}?
    if type(value) ~= "table" then return nil end
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > M.MAX_DESKTOPS then return nil end
        count = count + 1
    end
    if count ~= #value or count > M.MAX_DESKTOPS or (count == 0 and not allow_empty) then return nil end
    local result: {string} = {}
    local seen: {[string]: boolean} = {}
    for _, raw in ipairs(value) do
        local id = contract.workspace_id(raw)
        if not id or seen[id] then return nil end
        seen[id] = true
        result[#result + 1] = id
    end
    return result
end

local function plan_request(value: unknown): PlanRequest?
    local object = bounds.object(value)
    if not object then return nil end
    local mode: Mode? = nil
    if object.mode == "control" then mode = "control"
    elseif object.mode == "observe" then mode = "observe" end
    if not mode then return nil end
    local desktops = id_list(object.desktops, false)
    if not desktops then return nil end
    if object.kind == "automatic" or object.kind == "workspace" then
        if bounds.fields(object, {"kind", "mode", "desktops", "excluded", "workspace_id"}) then return nil end
        local excluded = id_list(object.excluded, true)
        if not excluded then return nil end
        local listed: {[string]: boolean} = {}
        for _, desktop in ipairs(desktops) do listed[desktop] = true end
        for _, desktop in ipairs(excluded) do if not listed[desktop] then return nil end end
        if object.kind == "automatic" then
            if object.workspace_id ~= nil then return nil end
            return {kind = "automatic", mode = mode, desktops = desktops, excluded = excluded}
        end
        local workspace = contract.workspace_id(object.workspace_id)
        if not workspace then return nil end
        return {kind = "workspace", workspace_id = workspace, mode = mode, desktops = desktops, excluded = excluded}
    end
    if object.kind == "selection" then
        if bounds.fields(object, {"kind", "mode", "desktops", "workspace_id", "desktop_id"}) then return nil end
        local workspace = contract.workspace_id(object.workspace_id)
        local desktop = contract.workspace_id(object.desktop_id)
        if not workspace or not desktop then return nil end
        local listed = false
        for _, id in ipairs(desktops) do if id == desktop then listed = true; break end end
        if not listed then return nil end
        return {kind = "selection", workspace_id = workspace, desktop_id = desktop, mode = mode, desktops = desktops}
    end
    return nil
end

function M.configuration(value: unknown): (Configuration?, string?)
    local object = bounds.object(value)
    if not object then return nil, "desktop configuration must be an object" end
    -- Native hosts select the incarnation before boot so rendezvous and the
    -- desktop service share one value. Other hosts may leave it empty; then
    -- the desktop owner mints an incarnation at startup.
    local fields_error = bounds.fields(object, {"execution", "expires_at", "allowed_nodes", "allowed_peers", "application", "local_clients", "folder"})
    if fields_error then return nil, fields_error end
    local execution: string? = nil
    if object.execution ~= nil then
        execution = contract.workspace_id(object.execution)
        if not execution then return nil, "execution must be 32 lowercase hexadecimal characters" end
    end
    local expires = bounds.timestamp(object.expires_at)
    local nodes = bounds.ids(object.allowed_nodes)
    local peers = object.allowed_peers == nil and {} or bounds.ids(object.allowed_peers)
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
        local query = workspace_query.decode(object, {"owner_execution"})
        if not query then return nil end
        return {kind = "list", execution = execution, query = query}
    end
    if operation == M.PLAN then
        if bounds.fields(object, {"owner_execution", "request"}) then return nil end
        local request = plan_request(object.request)
        if not execution or not request then return nil end
        return {kind = "plan", execution = execution, request = request}
    end
    if not execution then return nil end
    if operation == M.CURRENT then
        if bounds.fields(object, {"owner_execution"}) then return nil end
        return {kind = "current", execution = execution}
    end
    local desktop = contract.workspace_id(object.desktop_id)
    if operation == M.CREATE then
        -- Displays belong to the node, so allocation names no workspace.
        if not desktop or bounds.fields(object, {"owner_execution", "desktop_id"}) then return nil end
        return {kind = "create", execution = execution, desktop_id = desktop}
    end
    local workspace = contract.workspace_id(object.workspace_id)
    if not workspace or not desktop then return nil end
    if operation == M.ATTACH then
        if bounds.fields(object, {"owner_execution", "workspace_id", "desktop_id", "mode"})
            or (object.mode ~= "control" and object.mode ~= "observe") then return nil end
        return {kind = "attach", execution = execution, workspace_id = workspace, desktop_id = desktop,
            mode = object.mode == "control" and "control" or "observe"}
    elseif operation == M.LAUNCH then
        if bounds.fields(object, {"owner_execution", "workspace_id", "desktop_id", "session_id", "name", "arguments"}) then return nil end
        local session = bounds.id(object.session_id)
        local name = contract.text(object.name, 40)
        if not session then return nil end
        if not name then return nil end
        if not name:match("^[a-z][a-z0-9_-]*$") or object.arguments == nil then return nil end
        local values = arguments.decode(object.arguments)
        if not values then return nil end
        return {kind = "launch", execution = execution, workspace_id = workspace, desktop_id = desktop, session_id = session,
            mode = "control", name = name, arguments = values}
    elseif operation == M.DETACH or operation == M.COPY then
        if bounds.fields(object, {"owner_execution", "workspace_id", "desktop_id", "session_id"}) then return nil end
        local session = bounds.id(object.session_id)
        if not session then return nil end
        if operation == M.DETACH then
            return {kind = "detach", execution = execution, workspace_id = workspace, desktop_id = desktop, session_id = session, mode = "observe"}
        end
        return {kind = "copy", execution = execution, workspace_id = workspace, desktop_id = desktop, session_id = session, mode = "observe"}
    end
    return nil
end
return M
