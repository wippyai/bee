-- MIT. Host-owned client admissions, request correlation and renderer grants.
-- Runs in the host actor; database and application lifecycle remain with it.
local process = require("process")
local uuid = require("uuid")
local hash = require("hash")
local clients = require("clients")
local contract = require("contract")
local inventory = require("inventory")
type Route = {recipient: string, connection_id: string, request_id: string, op: contract.RequestOp, completed: boolean, renderer_generation: string}
type ChangeOp = "render" | "detach"
type Change = {op: ChangeOp, recipient: string, connection_id: string, request_id: string, renderer: string}
type State = {owner: string, broker: string, workspace_id: string, self: string,
    inventory: inventory.State,
    admitted: {[string]: clients.Client}, count: integer, routes: {[string]: Route}, route_count: integer,
    completed: {string}, changes: {[string]: Change}, queued_detaches: {[string]: string}}
local M = {}
function M.new(owner: string, broker: string, workspace_id: string): State
    return {owner = owner, broker = broker, workspace_id = workspace_id, self = tostring(process.pid()),
        inventory = inventory.new(workspace_id),
        admitted = {}, count = 0, routes = {}, route_count = 0, completed = {}, changes = {}, queued_detaches = {}}
end
local function result(state: State, id: string, op: string, recipient: string, connection_id: string, code: string, message: string)
    assert(process.send(state.owner, "bee.host.client_result", {version = 1, request_id = id, op = op,
        workspace_id = state.workspace_id, recipient = recipient, connection_id = connection_id, error_code = code, error = message}))
end
local function pending(state: State, client: clients.Client): Change?
    for _, change in pairs(state.changes) do if change.connection_id == client.connection_id then return change end end
    return nil
end
local function change(state: State, client: clients.Client, op: ChangeOp, request_id: string, renderer: string)
    local id = uuid.v7()
    state.changes[id] = {op = op, request_id = request_id, renderer = renderer, recipient = client.recipient, connection_id = client.connection_id}
    assert(process.send(state.broker, "bee.app.request", {version = 1, request_id = id, workspace_id = state.workspace_id,
        op = "unbind", recipient = client.renderer ~= "" and client.renderer or client.recipient}))
end
local function detach(state: State, client: clients.Client, request_id: string)
    client.detaching = true
    local previous = pending(state, client)
    if previous then
        if previous.op == "render" and state.queued_detaches[client.connection_id] == nil then
            state.queued_detaches[client.connection_id] = request_id
        elseif request_id ~= "" then
            result(state, request_id, "detach", client.recipient, client.connection_id, "busy", "Detach is pending")
        end
        return
    end
    change(state, client, "detach", request_id, "")
end
local function presentation(state: State, client: clients.Client, code: string, message: string): (boolean, string?)
    local sent, err = process.send(client.recipient, "bee.host.presentation", {version = 1, workspace_id = state.workspace_id,
        connection_id = client.connection_id, renderer = client.renderer, generation = client.renderer_generation,
        pending = client.rendering, error_code = code, error = message})
    return sent == true, err and tostring(err) or nil
end
local function render(state: State, client: clients.Client, renderer: string, request_id: string)
    if client.renderer == renderer and not client.rendering then
        local sent, err = presentation(state, client, "", "")
        if not sent then detach(state, client, "") end
        result(state, request_id, "render", client.recipient, client.connection_id, sent and "" or "delivery_failed", err or "")
        return
    end
    client.rendering = true
    client.renderer_generation = uuid.v7()
    change(state, client, "render", request_id, renderer)
end
local function reserved(state: State, recipient: string, except: string): boolean
    if recipient == "" then return false end
    if recipient == state.owner or recipient == state.broker or recipient == state.self then return true end
    for _, client in pairs(state.admitted) do
        if client.connection_id ~= except and (client.recipient == recipient or client.renderer == recipient) then return true end
    end
    for _, value in pairs(state.changes) do
        if value.connection_id ~= except and value.renderer == recipient then return true end
    end
    return false
end
local function forget(state: State, connection_id: string)
    for id, route in pairs(state.routes) do
        if route.connection_id == connection_id then state.routes[id] = nil; state.route_count = state.route_count - 1 end
    end
    local retained: {string} = {}
    for _, id in ipairs(state.completed) do if state.routes[id] then retained[#retained + 1] = id end end
    state.completed = retained
end
function M.control(state: State, caller: string, data: unknown, ready: boolean): string?
    if caller ~= state.owner then return nil end
    local control = clients.control(data)
    if not control then return nil end
    local joined_recipient: string? = nil
    local client = state.admitted[control.recipient]
    local code, failure = "", ""
    if control.workspace_id ~= state.workspace_id then code, failure = "workspace_mismatch", "Foreign workspace"
    elseif not ready then code, failure = "busy", "Host is not accepting clients"
    elseif control.recipient == state.owner or control.recipient == state.self or control.recipient == state.broker then
        code, failure = "invalid_argument", "Core owners cannot be desktop clients"
    elseif control.op == "detach" then
        if client then detach(state, client, control.request_id); return nil end
        code, failure = "not_found", "Client is not admitted"
    elseif control.op == "render" then
        if not client then code, failure = "not_found", "Client is not admitted"
        elseif client.detaching or pending(state, client) then code, failure = "busy", "Client grants are changing"
        elseif not client.permissions.control then code, failure = "permission_denied", "Client control is not granted"
        elseif reserved(state, control.renderer, client.connection_id) then code, failure = "permission_denied", "Renderer belongs to another owner"
        else render(state, client, control.renderer, control.request_id); return nil end
    elseif control.permissions then
        if client and (client.detaching or not clients.same_permissions(client.permissions, control.permissions)) then
            code, failure = "busy", "Detach the current admission before replacing its permissions"
        elseif not client and (state.count >= 8 or reserved(state, control.recipient, "")) then
            code, failure = "busy", "Client recipient or capacity is unavailable"
        else
            if not client then
                local monitored, monitor_error = process.monitor(control.recipient)
                if not monitored then code, failure = "unavailable", tostring(monitor_error)
                else
                    local joined: clients.Client = {recipient = control.recipient, connection_id = uuid.v7(),
                        permissions = control.permissions, detaching = false, renderer = control.recipient,
                        renderer_generation = uuid.v7(), rendering = false}
                    client = joined
                    state.admitted[control.recipient] = joined
                    state.count = state.count + 1
                end
            end
            if client and code == "" then
                local sent, send_error = process.send(client.recipient, "bee.host.admitted", {version = 1,
                    workspace_id = state.workspace_id, connection_id = client.connection_id, permissions = client.permissions,
                    renderer = client.renderer, renderer_generation = client.renderer_generation, renderer_pending = client.rendering})
                if not sent then code, failure = "delivery_failed", tostring(send_error); detach(state, client, "")
                else joined_recipient = client.recipient end
            end
        end
    end
    result(state, control.request_id, control.op, control.recipient, client and client.connection_id or "", code, failure)
    return joined_recipient
end
function M.publish(state: State, value: inventory.State, kind: "catalog" | "views", recipient: string?)
    if value.workspace_id ~= state.workspace_id then error("Foreign workspace inventory") end
    state.inventory = value
    for _, client in pairs(state.admitted) do
        if not client.detaching and (recipient == nil or recipient == client.recipient) then
            local sent = false
            if kind == "catalog" then
                sent = process.send(client.recipient, "bee.host.catalog", inventory.catalog_message(value, client.connection_id)) == true
            else
                sent = process.send(client.recipient, "bee.host.views", inventory.views_message(value, client.connection_id)) == true
            end
            if not sent then detach(state, client, "") end
        end
    end
end
local function deliver_reply(state: State, client: clients.Client, reply: contract.Reply)
    if not process.send(client.recipient, "bee.host.reply", {version = 1, reply = reply,
        views = inventory.views_message(state.inventory, client.connection_id)}) then detach(state, client, "") end
end
local function reject(state: State, client: clients.Client, request: contract.Request, reason: string, message: string)
    local reply = contract.reply(request.request_id, request.op, reason, message)
    reply.workspace_id = state.workspace_id
    deliver_reply(state, client, reply)
end
function M.request(state: State, caller: string, request: contract.Request, data: unknown, ready: boolean): boolean
    local client = state.admitted[caller]
    if not client then return false end
    local code = ""
    if type(data) ~= "table" or data.connection_id ~= client.connection_id or client.detaching then code = "permission_denied"
    elseif request.op == "bind" and client.permissions.control and data.renderer_generation ~= client.renderer_generation then code = "stale_renderer"
    elseif request.op == "bind" and client.permissions.control and client.rendering then code = "busy"
    elseif request.op == "bind" and client.permissions.control and client.renderer == "" then code = "unavailable"
    elseif not clients.allowed(client, request) then code = "permission_denied"
    elseif request.workspace_id ~= state.workspace_id then code = "workspace_mismatch"
    elseif not ready then code = "busy" end
    if code ~= "" then reject(state, client, request, code, "Client request rejected"); return true end
    local generation = request.op == "bind" and client.renderer_generation or ""
    local internal, hash_error = hash.sha256(client.connection_id .. "\0" .. generation .. "\0" .. request.request_id)
    if not internal then error(tostring(hash_error)) end
    if not state.routes[internal] then
        while state.route_count >= 128 and #state.completed > 0 do
            local oldest = table.remove(state.completed, 1)
            if state.routes[oldest] then state.routes[oldest] = nil; state.route_count = state.route_count - 1 end
        end
        if state.route_count >= 128 then reject(state, client, request, "busy", "Client request capacity reached"); return true end
        state.routes[internal] = {recipient = client.recipient, connection_id = client.connection_id, request_id = request.request_id,
            op = request.op, completed = false, renderer_generation = generation}
        state.route_count = state.route_count + 1
    end
    request.request_id = internal
    if request.op == "bind" then request.recipient = client.renderer end
    assert(process.send(state.broker, "bee.app.request", request))
    return true
end
local function release_renderer(client: clients.Client): (boolean, string?)
    if client.renderer ~= "" and client.renderer ~= client.recipient then
        local released, err = process.unmonitor(client.renderer)
        if not released then return false, tostring(err) end
    end
    client.renderer = ""
    return true, nil
end
function M.reply(state: State, reply: contract.Reply, current: inventory.State): boolean
    if current.workspace_id ~= state.workspace_id then error("Foreign workspace result inventory") end
    state.inventory = current
    local changed = state.changes[reply.request_id]
    if changed and reply.op == "unbind" then
        state.changes[reply.request_id] = nil
        local client = state.admitted[changed.recipient]
        if not client or client.connection_id ~= changed.connection_id then return true end
        local delivery_failed = false
        if reply.error_code == "" then
            local released, release_error = release_renderer(client)
            if not released then reply.error_code, reply.error = "unmonitor_failed", release_error or "Renderer monitor removal failed" end
        end
        if changed.op == "detach" then
            if reply.error_code == "" then
                local unmonitored, err = process.unmonitor(client.recipient)
                if not unmonitored then reply.error_code, reply.error = "unmonitor_failed", tostring(err)
                else
                    forget(state, client.connection_id)
                    state.admitted[client.recipient] = nil
                    state.count = state.count - 1
                    process.send(client.recipient, "bee.host.detached", {version = 1, workspace_id = state.workspace_id, connection_id = client.connection_id})
                end
            end
        else
            if reply.error_code == "" then
                local renderer = client.detaching and "" or changed.renderer
                if client.detaching then reply.error_code, reply.error = "cancelled", "Renderer replacement superseded by client detach" end
                if renderer ~= "" and renderer ~= client.recipient then
                    local monitored, err = process.monitor(renderer)
                    if not monitored then reply.error_code, reply.error = "unavailable", tostring(err); renderer = "" end
                end
                client.renderer, client.rendering = renderer, false
            end
            local sent, err = presentation(state, client, reply.error_code, reply.error)
            if not sent then
                delivery_failed = true
                if reply.error_code == "" then reply.error_code, reply.error = "delivery_failed", err or "Client presentation delivery failed" end
            end
        end
        result(state, changed.request_id, changed.op, client.recipient, client.connection_id, reply.error_code, reply.error)
        local queued = state.queued_detaches[client.connection_id]
        if queued ~= nil or delivery_failed then state.queued_detaches[client.connection_id] = nil; detach(state, client, queued or "") end
        return true
    end
    local route = state.routes[reply.request_id]
    if not route then return false end
    if not route.completed and (reply.op == route.op or (route.op == "open" and reply.op == "focus")
        or (reply.error_code ~= "" and reply.op ~= "attached" and reply.op ~= "closing")) then
        route.completed = true
        state.completed[#state.completed + 1] = reply.request_id
    end
    local client = state.admitted[route.recipient]
    if client and not client.detaching and client.connection_id == route.connection_id
        and (route.op ~= "bind" or (not client.rendering and route.renderer_generation == client.renderer_generation)) then
        reply.request_id, reply.resume_state = route.request_id, ""
        if reply.op ~= "attached" then reply.mount = "" end
        deliver_reply(state, client, reply)
    end
    return true
end
function M.exited(state: State, pid: string)
    local client = state.admitted[pid]
    if client then detach(state, client, ""); return end
    for _, item in pairs(state.admitted) do
        if item.renderer == pid and not pending(state, item) then
            if item.detaching then detach(state, item, "") else render(state, item, "", "") end
        end
    end
end
return M
