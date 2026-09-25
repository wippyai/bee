-- MIT. Retained display lifetimes inside the existing workspace supervisor.
-- The actor owns all children and grants. This library creates no workspace host.
local process = require("process")
local security = require("security")
local channel = require("channel")
local time = require("time")
local logger = require("logger")
local log = logger:named("bee.launch.desktop")
local uuid = require("uuid")
local desktops = require("desktops")
local attachments = require("attachments")
local protocol = require("protocol")
local decode = require("decode")
local contract = require("contract")
local retained_protocol = require("retained_protocol")
local handoff = require("handoff")
type Channel = channel.Channel
type Phase = "boot" | "admit" | "running" | "render" | "save" | "exit" | "stopping" | "departing" | "replacing"
type Renderer = {pid: string, connection: string}
type Child = {id: string, resource: desktops.Desktop, phase: Phase, connection: string, pending: string,
    ready: boolean, activation: string?, deadline: Channel<time.Time>?, renderer: Renderer?, replace: boolean,
    host_replacing: boolean, restarts: integer, presentation: string?}
-- host: the workspace host desktops talk to; route: the host's owner-side
-- address for desktop admission, the host itself or the node host manager.
type State = {owner: string, host: string, route: string, workspace_id: string, default_id: string,
    resources: desktops.State, children: {[string]: Child}, scope: security.Scope, host_replacing: boolean,
    replacement_ready: boolean}
local M = {}
local function send(recipient: string, topic: string, value: unknown): boolean
    local sent, err = process.send(recipient, topic, value)
    return sent == true and err == nil
end
local function publish_attachments(child: Child)
    local observers = 0
    for _ in pairs(child.resource.grants.observers) do observers = observers + 1 end
    send(child.resource.pid, "bee.desktop.attachments", {version = 1, display_id = child.id,
        controller = child.resource.grants.controller ~= nil, observers = observers})
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
local function restart_child(state: State, child: Child)
    local pid, restart_error = desktops.restart(state.resources, child.resource)
    if not pid then
        log:error("Retained desktop restart failed", {display_id = child.id, error = restart_error})
        desktops.retire(state.resources, child.resource)
        state.children[child.id] = nil
        return
    end
    child.phase, child.connection, child.pending, child.ready = "boot", "", "", false
    child.deadline, child.renderer, child.replace, child.presentation = time.after("10s"), nil, false, nil
    child.host_replacing = false
    child.restarts = child.restarts + 1
end
-- This actor spawned the child, so its exit is a departure this owner observes
-- first hand. The host owns the display admission and accepts a release only
-- from its owner, so the departure is announced there and the display identity
-- stays held until the host reports the release.
local function depart(state: State, child: Child, replacing: boolean?)
    child.phase, child.deadline, child.ready, child.renderer, child.presentation = replacing and "replacing" or "departing", nil, false, nil, nil
    if replacing and child.host_replacing then
        child.pending = ""
        if state.replacement_ready then restart_child(state, child) end
        return
    end
    child.pending = uuid.v7()
    if not send(state.route, "bee.host.client", {version = 1, workspace_id = state.workspace_id,
        request_id = child.pending, op = "detach", recipient = child.resource.pid}) then
        child.pending = ""
    end
end
function M.request_replace(state: State, sender: string, data: unknown): boolean
    for _, child in pairs(state.children) do
        if child.resource.pid == sender then
            local saved = handoff.decode(data, tostring(process.pid()), state.host, state.workspace_id)
            if child.replace or child.host_replacing
                or (child.phase ~= "running" and child.phase ~= "render")
                or (saved and saved.display_id ~= child.id) then return true end
            -- The child saved its layout before asking. An incompatible wire
            -- checkpoint cannot grant an identity, but its authenticated PID
            -- still names this reservation; reopen that durable store.
            child.replace = true
            send(sender, "bee.client.replace_ack", {version = 1, workspace_id = state.workspace_id,
                display_id = child.id})
            return true
        end
    end
    return false
end
function M.host_replacing(state: State)
    state.host_replacing, state.replacement_ready = true, false
    for _, child in pairs(state.children) do child.host_replacing = true end
end
function M.host_replaced(state: State, host: string, route: string)
    state.host, state.route, state.replacement_ready = host, route, true
    for _, child in pairs(state.children) do
        desktops.rehost(child.resource, host)
        if child.phase == "replacing" then restart_child(state, child)
        else process.terminate(child.resource.pid) end
    end
    state.host_replacing = false
end
function M.host_upgraded(state: State)
    state.host_replacing, state.replacement_ready = false, false
    for _, child in pairs(state.children) do
        child.host_replacing = false
        if child.phase == "replacing" then restart_child(state, child) end
    end
end
local function control(state: State, child: Child, op: string): boolean
    child.pending = uuid.v7()
    child.deadline = time.after("10s")
    return send(child.resource.pid, "bee.client.control", {version = 1, workspace_id = state.workspace_id,
        request_id = child.pending, op = op})
end
local function render_failed(state: State, child: Child, message: string)
    if not child.ready then fail(state, child, message); return end
    child.phase, child.renderer, child.presentation = "running", nil, nil
    if not control(state, child, "pause") then fail(state, child, "Desktop pause request was not accepted"); return end
    child.pending, child.deadline = "", nil
end
local function render(state: State, child: Child)
    local renderer = child.renderer
    if not renderer or child.phase ~= "running" then return end
    child.renderer = nil
    if renderer.connection ~= child.connection then return end
    child.pending, child.phase, child.deadline = uuid.v7(), "render", time.after("10s")
    if not send(state.route, "bee.host.client", {version = 1, workspace_id = state.workspace_id,
        request_id = child.pending, op = "render", recipient = child.resource.pid, renderer = renderer.pid}) then
        render_failed(state, child, "Desktop renderer request was not accepted")
    end
end
local function queue_renderer(state: State, child: Child, renderer: Renderer)
    child.renderer = renderer
    render(state, child)
end
function M.new(owner: string, host: string, route: string, workspace_id: string, default_id: string, resources: desktops.State): State
    local policies: {security.Policy} = {}
    for _, name in ipairs({"bee.security.desktop:desktop_policy", "bee.security.desktop:client_spawn_policy", "bee.security.storage:client_storage_policy", "bee.security.desktop:client_node_defaults_call_policy", "bee.security.desktop:client_node_defaults_read_policy",
        "bee.security.desktop:client_workspace_catalog_call_policy", "bee.security.storage:workspace_catalog_read_policy"}) do
        policies[#policies + 1] = assert(security.policy(name))
    end
    return {owner = owner, host = host, route = route, workspace_id = workspace_id, default_id = default_id,
        resources = resources, children = {}, scope = security.new_scope(policies),
        host_replacing = false, replacement_ready = false}
end
-- The initial display discovers the default store identity during bootstrap.
-- After readiness it follows the same lifetime as every other retained display.
function M.adopt(state: State, id: string, resource: desktops.Desktop, connection: string)
    if id ~= state.default_id or state.children[id] or connection == "" then
        error("Invalid initial retained display adoption")
    end
    state.children[id] = {id = id, resource = resource, phase = "running", connection = connection,
        pending = "", ready = true, replace = false, host_replacing = false, restarts = 0}
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
    local old = state.children[id]
    if old then
        if old.ready and old.phase ~= "stopping" and old.phase ~= "save" and old.phase ~= "exit" then answer(state, id, request, "", "")
        else answer(state, id, request, "BUSY", "Desktop activation or shutdown is pending") end
        return
    end
    local count = 0
    for _ in pairs(state.children) do count = count + 1 end
    if count >= 33 then answer(state, id, request, "BUSY", "Active desktop capacity reached"); return end
    local selected_id: string? = nil
    if id ~= state.default_id then selected_id = id end
    local resource, err = desktops.start(state.resources, {host = state.host, workspace_id = state.workspace_id,
        database = "bee.env:client_db", width = 100, height = 32,
        options = {version = 1, desktop_id = selected_id, quit_mode = "supervisor", node_defaults = true, hive_supervisor = state.owner}}, state.scope)
    if not resource then answer(state, id, request, "UNAVAILABLE", tostring(err)); return end
    state.children[id] = {id = id, resource = resource, phase = "boot", connection = "", pending = "",
        ready = false, activation = request, deadline = time.after("10s"), replace = false,
        host_replacing = false, restarts = 0}
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
-- The host answers an announced departure on its request, and answers a release
-- it started for the same client without one. Either completion frees the
-- display identity; a refusal keeps it held under the departed child.
local function departed(state: State, topic: string, sender: string, data: unknown): boolean
    if topic ~= "result" or sender ~= state.route then return false end
    local result = protocol.client_result(data, state.workspace_id)
    if not result or result.op ~= "detach" then return false end
    for id, child in pairs(state.children) do
        if (child.phase == "departing" or child.phase == "replacing") and child.resource.pid == result.recipient then
            if result.error_code == "" or result.error_code == "not_found" then
                if child.phase == "replacing" then
                    restart_child(state, child)
                else state.children[id] = nil end
            end
            return true
        end
    end
    return false
end
function M.receive(state: State, topic: string, sender: string, data: unknown): boolean
    if departed(state, topic, sender, data) then return true end
    local selected: Child? = nil
    for _, child in pairs(state.children) do
        if sender == child.resource.pid then selected = child; break end
        if sender == state.route and topic == "result" and protocol.request(data, state.workspace_id) == child.pending
            and child.pending ~= "" then selected = child; break end
    end
    local child = selected
    if not child then return false end
    if child.phase == "stopping" then return true end
    if topic == "ready" and child.phase == "boot" then
        local ready = protocol.ready(data, state.workspace_id, false)
        if not ready or ready.client_id ~= child.id then fail(state, child, "Desktop acknowledged another identity"); return true end
        child.phase, child.pending, child.deadline = "admit", uuid.v7(), time.after("10s")
        if not send(state.route, "bee.host.client", {version = 1, workspace_id = state.workspace_id,
            request_id = child.pending, op = "admit", recipient = child.resource.pid,
            permissions = {open = true, close = true, control = true, appearance = true}, display_id = child.id}) then
            fail(state, child, "Desktop admission request was not accepted")
        end
    elseif topic == "renderer" then
        local renderer = renderer_value(data, state.workspace_id)
        if renderer then queue_renderer(state, child, renderer) end
    elseif topic == "result" and sender == state.route then
        if child.phase ~= "admit" and child.phase ~= "render" then return true end
        local connection = host_connection(data)
        if not connection then
            if child.phase == "render" then render_failed(state, child, "Desktop renderer admission failed")
            else fail(state, child, "Desktop host admission failed") end
            return true
        end
        local rendered = child.phase == "render"
        local presented = child.presentation == connection
        child.connection, child.phase, child.pending, child.deadline = connection, "running", "", nil
        if rendered then
            child.ready = true
            settle(state, child, "", "")
        else child.deadline = time.after("10s") end
        render(state, child)
        if rendered and presented then
            child.presentation = nil
            send(state.owner, "bee.retained.replaced", {version = 1, workspace_id = state.workspace_id,
                display_id = child.id, pid = child.resource.pid, schema = 1})
        end
    elseif topic == "presented" and child.restarts > 0 then
        if type(data) == "table" and data.version == 1 and data.workspace_id == state.workspace_id
            and data.display_id == child.id and contract.text(data.renderer, 160)
            and contract.text(data.generation, 80) then
            local connection = contract.text(data.connection_id, 80)
            if connection and connection ~= "" then
                if child.ready and child.phase == "running" and connection == child.connection then
                    send(state.owner, "bee.retained.replaced", {version = 1, workspace_id = state.workspace_id,
                        display_id = child.id, pid = child.resource.pid, schema = 1})
                elseif child.phase == "admit" or child.phase == "render" or child.phase == "running" then
                    -- The client may present before the host's render receipt
                    -- reaches us; its exact connection waits for that fence.
                    child.presentation = connection
                end
            end
        end
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
-- A display asks to show another workspace. The request names the display
-- it came from; the desktop bridge moves the display's controlling client.
function M.switch(state: State, sender: string, value: unknown): boolean
    for id, child in pairs(state.children) do
        if child.resource.pid == sender then
            local request = retained_protocol.switch(value, state.workspace_id)
            if request and request.desktop_id == id and child.ready and child.phase == "running" then
                send(state.owner, retained_protocol.TOPIC_SWITCH, {version = 1, workspace_id = state.workspace_id, desktop_id = id,
                    request_id = request.request_id, target_workspace_id = request.target_workspace_id})
            end
            return true
        end
    end
    return false
end
-- The bridge's answer reaches the display that asked.
function M.switched(state: State, value: unknown)
    local result = retained_protocol.switch_result(value, state.workspace_id)
    if not result then return end
    local child = state.children[result.desktop_id]
    if not child then return end
    send(child.resource.pid, retained_protocol.TOPIC_SWITCHED, {version = 1, workspace_id = state.workspace_id, desktop_id = result.desktop_id,
        request_id = result.request_id, error_code = result.error_code, error = result.error})
end
function M.event(state: State, event: process.Event)
    if event.kind ~= process.event.EXIT and event.kind ~= process.event.LINK_DOWN then return end
    local sender = tostring(event.from)
    local revoked = false
    for _, child in pairs(state.children) do
        if event.kind == process.event.EXIT and sender == child.resource.pid then
            settle(state, child, "UNAVAILABLE", "Desktop exited before activation completed: " .. (decode.exit_error(event.result) or "without an error"))
            if child.replace or child.host_replacing then depart(state, child, true)
            else desktops.exited(state.resources, event); depart(state, child) end
        elseif child.phase ~= "departing" then
            local grants = child.resource.grants
            local attached = (grants.controller and grants.controller.recipient == sender) or grants.observers[sender] ~= nil
            if attached then
                local result = attachments.detach(grants, sender)
                if result.error_code ~= "" then fail(state, child, "Desktop attachment revocation failed")
                else revoked = true; publish_attachments(child) end
            end
        end
    end
    if event.kind == process.event.LINK_DOWN and revoked and sender ~= state.owner and sender ~= state.host
        and sender ~= state.route then
        local held = false
        for _, child in pairs(state.children) do
            local grants = child.resource.grants
            if (grants.controller and grants.controller.recipient == sender) or grants.observers[sender] then
                held = true; break
            end
        end
        if not held then process.unmonitor(sender) end
    end
end
function M.close(state: State)
    for _, child in pairs(state.children) do process.terminate(child.resource.pid) end
end
return M
