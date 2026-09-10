-- MIT. Additional desktop lifetimes inside the existing workspace supervisor.
-- The actor owns all children and grants. This library creates no workspace host.
local process = require("process")
local security = require("security")
local channel = require("channel")
local time = require("time")
local uuid = require("uuid")
local desktops = require("desktops")
local attachments = require("attachments")
local protocol = require("protocol")
local decode = require("decode")
local contract = require("contract")
type Channel = channel.Channel
type Phase = "boot" | "admit" | "running" | "render" | "save" | "exit" | "stopping"
type Renderer = {pid: string, connection: string}
type Child = {id: string, resource: desktops.Desktop, phase: Phase, connection: string, pending: string,
    ready: boolean, activation: string?, deadline: Channel<time.Time>?, renderer: Renderer?}
type State = {owner: string, host: string, workspace_id: string, default_id: string,
    resources: desktops.State, children: {[string]: Child}, scope: security.Scope}
local M = {}
local function send(recipient: string, topic: string, value: unknown): boolean
    local sent, err = process.send(recipient, topic, value)
    return sent == true and err == nil
end
local function answer(state: State, id: string, request: string, code: string, message: string)
    send(state.owner, "bee.retained.activated", {version = 1, workspace_id = state.workspace_id,
        desktop_id = id, request_id = request, error_code = code, error = message:sub(1, 400)})
end
local function settle(state: State, child: Child, code: string, message: string)
    local request = child.activation
    child.activation = nil
    if request then answer(state, child.id, request, code, message) end
end
local function fail(state: State, child: Child, message: string)
    settle(state, child, "UNAVAILABLE", message)
    child.phase, child.deadline = "stopping", nil
    process.terminate(child.resource.pid)
    -- Keep the writer reservation until its actual EXIT, including failed stop.
end
local function control(state: State, child: Child, op: string): boolean
    child.pending = uuid.v7()
    child.deadline = time.after("10s")
    return send(child.resource.pid, "bee.client.control", {version = 1, workspace_id = state.workspace_id,
        request_id = child.pending, op = op})
end
local function render_failed(state: State, child: Child, message: string)
    if not child.ready then fail(state, child, message); return end
    child.phase, child.renderer = "running", nil
    if not control(state, child, "pause") then fail(state, child, "Desktop pause request was not accepted"); return end
    child.pending, child.deadline = "", nil
end
local function render(state: State, child: Child)
    local renderer = child.renderer
    if not renderer or child.phase ~= "running" then return end
    child.renderer = nil
    if renderer.connection ~= child.connection then return end
    child.pending, child.phase, child.deadline = uuid.v7(), "render", time.after("10s")
    if not send(state.host, "bee.host.client", {version = 1, workspace_id = state.workspace_id,
        request_id = child.pending, op = "render", recipient = child.resource.pid, renderer = renderer.pid}) then
        render_failed(state, child, "Desktop renderer request was not accepted")
    end
end
local function queue_renderer(state: State, child: Child, renderer: Renderer)
    child.renderer = renderer
    render(state, child)
end
function M.new(owner: string, host: string, workspace_id: string, default_id: string, resources: desktops.State): State
    local policies: {security.Policy} = {}
    for _, name in ipairs({"bee:desktop_policy", "bee:client_spawn_policy", "bee:client_storage_policy"}) do
        policies[#policies + 1] = assert(security.policy(name))
    end
    return {owner = owner, host = host, workspace_id = workspace_id, default_id = default_id,
        resources = resources, children = {}, scope = security.new_scope(policies)}
end
-- The caller authenticates state.owner before this decoder. The record must
-- already exist: the child opens that exact identity and never allocates a new one.
function M.activate(state: State, value: unknown)
    if type(value) ~= "table" or value.version ~= 1 or value.workspace_id ~= state.workspace_id then return end
    for key in pairs(value) do
        if key ~= "version" and key ~= "workspace_id" and key ~= "desktop_id" and key ~= "request_id" then return end
    end
    local id = contract.workspace_id(value.desktop_id)
    local request = contract.text(value.request_id, 80)
    if not id or not request or request == "" then return end
    if id == state.default_id then answer(state, id, request, "", ""); return end
    local old = state.children[id]
    if old then
        if old.ready and old.phase ~= "stopping" and old.phase ~= "save" and old.phase ~= "exit" then answer(state, id, request, "", "")
        else answer(state, id, request, "BUSY", "Desktop activation or shutdown is pending") end
        return
    end
    local count = 0
    for _ in pairs(state.children) do count = count + 1 end
    if count >= 32 then answer(state, id, request, "BUSY", "Active desktop capacity reached"); return end
    local resource, err = desktops.start(state.resources, {host = state.host, workspace_id = state.workspace_id,
        database = "bee:client_db", width = 100, height = 32,
        options = {version = 1, desktop_id = id, quit_mode = "supervisor", workspace_appearance = false}}, state.scope)
    if not resource then answer(state, id, request, "UNAVAILABLE", tostring(err)); return end
    state.children[id] = {id = id, resource = resource, phase = "boot", connection = "", pending = "",
        ready = false, activation = request, deadline = time.after("10s")}
end
function M.find(state: State, id: string): desktops.Desktop?
    local child = state.children[id]
    if not child or not child.ready or child.phase == "stopping" or child.phase == "save" or child.phase == "exit" then return nil end
    return child.resource
end
function M.deadlines(state: State): {Channel<time.Time>}
    local result: {Channel<time.Time>} = {}
    for _, child in pairs(state.children) do if child.deadline then result[#result + 1] = child.deadline end end
    return result
end
function M.timeout(state: State, selected: unknown): boolean
    for _, child in pairs(state.children) do
        if child.deadline and child.deadline == selected then
            if child.phase == "render" then render_failed(state, child, "Desktop renderer admission timed out")
            else fail(state, child, "Desktop timed out during " .. child.phase) end
            return true
        end
    end
    return false
end
local function renderer_value(data: unknown, workspace_id: string): Renderer?
    if type(data) ~= "table" or data.version ~= 1 or data.workspace_id ~= workspace_id then return nil end
    local pid = contract.text(data.renderer, 160)
    local connection = contract.text(data.connection_id, 80)
    if not pid or pid == "" then return nil end
    if not connection or connection == "" then return nil end
    return {pid = pid, connection = connection}
end
local function host_connection(data: unknown): string?
    if type(data) ~= "table" or data.error_code ~= "" then return nil end
    local connection = contract.text(data.connection_id, 80)
    if not connection or connection == "" then return nil end
    return connection
end
function M.receive(state: State, topic: string, sender: string, data: unknown): boolean
    local selected: Child? = nil
    for _, child in pairs(state.children) do
        if sender == child.resource.pid then selected = child; break end
        if sender == state.host and topic == "result" and protocol.request(data, state.workspace_id) == child.pending
            and child.pending ~= "" then selected = child; break end
    end
    local child = selected
    if not child then return false end
    if child.phase == "stopping" then return true end
    if topic == "ready" and child.phase == "boot" then
        local ready = protocol.ready(data, state.workspace_id, false)
        if not ready or ready.client_id ~= child.id then fail(state, child, "Desktop acknowledged another identity"); return true end
        child.phase, child.pending, child.deadline = "admit", uuid.v7(), time.after("10s")
        if not send(state.host, "bee.host.client", {version = 1, workspace_id = state.workspace_id,
            request_id = child.pending, op = "admit", recipient = child.resource.pid,
            permissions = {open = true, close = true, control = true, appearance = true, workspace_appearance = false}}) then
            fail(state, child, "Desktop admission request was not accepted")
        end
    elseif topic == "renderer" then
        local renderer = renderer_value(data, state.workspace_id)
        if renderer then queue_renderer(state, child, renderer) end
    elseif topic == "result" and sender == state.host then
        if child.phase ~= "admit" and child.phase ~= "render" then return true end
        local connection = host_connection(data)
        if not connection then
            if child.phase == "render" then render_failed(state, child, "Desktop renderer admission failed")
            else fail(state, child, "Desktop host admission failed") end
            return true
        end
        local rendered = child.phase == "render"
        child.connection, child.phase, child.pending, child.deadline = connection, "running", "", nil
        if rendered then child.ready = true; settle(state, child, "", "")
        else child.deadline = time.after("10s") end
        render(state, child)
    elseif topic == "quit" and protocol.quit(data, state.workspace_id) and child.phase == "running" then
        child.phase = "save"
        if not control(state, child, "save") then fail(state, child, "Desktop save request was not accepted") end
    elseif topic == "saved" and child.phase == "save" and protocol.request(data, state.workspace_id) == child.pending then
        child.phase = "exit"
        if not control(state, child, "exit") then fail(state, child, "Desktop exit request was not accepted") end
    elseif topic == "finished" and child.phase == "exit" and protocol.request(data, state.workspace_id) == child.pending then
        child.phase, child.deadline = "stopping", time.after("10s")
    end
    return true
end
function M.event(state: State, event: process.Event)
    if event.kind ~= process.event.EXIT and event.kind ~= process.event.LINK_DOWN then return end
    local sender = tostring(event.from)
    for id, child in pairs(state.children) do
        if event.kind == process.event.EXIT and sender == child.resource.pid then
            settle(state, child, "UNAVAILABLE", "Desktop exited before activation completed: " .. (decode.exit_error(event.result) or "without an error"))
            desktops.exited(state.resources, event)
            state.children[id] = nil
        else
            local result = attachments.detach(child.resource.grants, sender)
            if result.error_code ~= "" then fail(state, child, "Desktop attachment revocation failed") end
        end
    end
end
function M.close(state: State)
    for _, child in pairs(state.children) do process.terminate(child.resource.pid) end
end
return M
