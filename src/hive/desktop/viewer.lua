-- MIT. A remote view of another node's workspace for a local application
-- window. It runs on the display client host, so the owner's bridge admits it
-- as a native display client of this node; the owner leases the workspace's
-- host and grants a mount bound to this process. The parent window receives
-- the rendered rows and sends input, and only while the view lasts. The view
-- detaches once, when the parent asks, when the parent exits or when the
-- presentation fails.
local process = require("process")
local channel = require("channel")
local time = require("time")
local uuid = require("uuid")
local types = require("types")
local client = require("client")
local protocol = require("protocol")
local contract = require("contract")
local display = require("display")
local remote = require("remote")
local delivery = require("delivery")
local input = require("input")
type Mode = "control" | "observe"
local M = {}
M.MAX_WIDTH = 400
M.MAX_HEIGHT = 200
local CALL_TIMEOUT = "10s"
local function deadline(): string
    return time.now():add(CALL_TIMEOUT):utc():format("2006-01-02T15:04:05.000Z07:00")
end
-- One call to the owner's bridge through a client that lives only for it, so
-- this process never holds two reply subscriptions.
local function call(node: string, operation: string, value: {[string]: unknown}, key: string?): types.Reply
    local handle, open_error = client.open(node)
    if not handle then return types.reply_error("", types.fault("UNAVAILABLE", open_error or "Hive client unavailable")) end
    local reply = handle:call({node_id = node, service_id = protocol.SERVICE}, {operation_ref = operation}, value,
        {idempotency_key = key, deadline = deadline(), timeout = CALL_TIMEOUT})
    handle:close()
    return reply
end
local function operations(node: string): remote.Operations
    return {
        list = function(): types.Reply return call(node, protocol.LIST, {limit = 1}, nil) end,
        create = function(execution: string, id: string): types.Reply
            return call(node, protocol.CREATE, {owner_execution = execution, desktop_id = id}, id)
        end,
        open = display.open,
        new_id = function(): string return (uuid.v4():gsub("-", "")) end,
    }
end
local function size(value: unknown, limit: integer): integer?
    if type(value) ~= "number" or value ~= math.floor(value) or value < 1 or value > limit then return nil end
    return math.floor(value)
end
local function main(parent: string, node: unknown, workspace: unknown, selected_mode: unknown, width_value: unknown, height_value: unknown)
    local workspace_id = contract.workspace_id(workspace)
    local mode: Mode? = selected_mode == "control" and "control" or (selected_mode == "observe" and "observe" or nil)
    local width, height = size(width_value, M.MAX_WIDTH), size(height_value, M.MAX_HEIGHT)
    local function state(value: {[string]: unknown})
        value.version = 1
        process.send(parent, protocol.VIEW_STATE, value)
    end
    if type(node) ~= "string" or not workspace_id or not mode or not width or not height then
        state({state = "failed", code = "INVALID_ARGUMENT", message = "Invalid remote view arguments"})
        return
    end
    local events = assert(process.events())
    local monitored, monitor_error = process.monitor(parent)
    if not monitored then error("Monitor remote view parent: " .. tostring(monitor_error)) end
    local opened, fault = remote.choose(operations(node), node, workspace_id, mode)
    if not opened then
        state({state = "failed", code = fault and fault.code or "UNAVAILABLE", message = fault and fault.message or "Remote desktop unavailable"})
        return
    end
    local handle = opened.handle
    local target = opened.target
    local session = display.session_id(handle) or ""
    state({state = "attached", session_id = session, mode = mode, workspace_id = target.workspace_id,
        desktop_id = target.desktop_id, owner_execution = target.owner_execution})
    local inputs = assert(process.listen(protocol.VIEW_INPUT, {message = true}))
    local resizes = assert(process.listen(protocol.VIEW_RESIZE, {message = true}))
    local closes = assert(process.listen(protocol.VIEW_CLOSE, {message = true}))
    local ticks = assert(time.ticker("50ms"))
    local failure: string? = nil
    if mode == "control" then
        local resized, resize_error = display.resize(handle, width, height)
        if not resized then failure = resize_error or "resize remote desktop" end
    end
    local shown = ""
    while not failure do
        local selected = channel.select({ticks:channel():case_receive(), inputs:case_receive(), resizes:case_receive(),
            closes:case_receive(), events:case_receive()})
        if not selected.ok then break end
        if selected.channel == events then
            local event = selected.value
            if event.kind == process.event.CANCEL then break end
            if (event.kind == process.event.EXIT or event.kind == process.event.LINK_DOWN) and tostring(event.from) == parent then break end
        elseif selected.channel == ticks:channel() then
            delivery.poll({session})
            local frame, frame_error = display.content(handle, width, height)
            if frame then
                local signature = table.concat(frame.rows, "\n")
                if signature ~= shown then
                    shown = signature
                    process.send(parent, protocol.VIEW_FRAME, {version = 1, rows = frame.rows, cursor = frame.cursor})
                end
            elseif frame_error and frame_error ~= "Attaching" then failure = frame_error end
        else
            local message = selected.value
            if tostring(message:from()) == parent then
                local data: unknown = message:payload():data()
                if selected.channel == closes then break
                elseif selected.channel == resizes and type(data) == "table" then
                    local next_width, next_height = size(data.width, M.MAX_WIDTH), size(data.height, M.MAX_HEIGHT)
                    if next_width and next_height then
                        width, height = next_width, next_height
                        if mode == "control" then
                            local resized, resize_error = display.resize(handle, width, height)
                            if not resized then failure = resize_error or "resize remote desktop" end
                        end
                    end
                elseif selected.channel == inputs and mode == "control" and type(data) == "table" then
                    -- Only key, mouse, paste and focus input reach the desktop;
                    -- anything else is dropped.
                    local event = input.decode(data.event)
                    if event and (event.type == "key" or event.type == "mouse" or event.type == "paste" or event.type == "focus") then
                        local sent, send_error = display.send(handle, event)
                        if sent == false then failure = send_error or "send remote desktop input" end
                    end
                end
            end
        end
    end
    ticks:stop()
    for _, subscription in ipairs({inputs, resizes, closes}) do process.unlisten(subscription) end
    local detached, detach_error = display.close(handle)
    if failure then error(failure) end
    if not detached then error(detach_error or "Detach remote desktop") end
end
M.main = main
return M
