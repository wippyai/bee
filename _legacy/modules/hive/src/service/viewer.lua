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
local bounds = require("bounds")
local client = require("client")
local protocol = require("protocol")
local contract = require("contract")
local clock = require("clock")
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
    return clock.deadline(CALL_TIMEOUT)
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
        open = function(target: display.Target, idempotency_key: string): (display.Handle?, display.Fault?)
            return display.open(target, idempotency_key)
        end,
        new_id = function(): string return (uuid.v4():gsub("-", "")) end,
    }
end
local function size(value: unknown, limit: integer): integer?
    if type(value) ~= "number" or value ~= math.floor(value) or value < 1 or value > limit then return nil end
    return math.floor(value)
end
local function main(parent: string, node: unknown, workspace: unknown, selected_mode: unknown, idempotency_value: unknown,
    width_value: unknown, height_value: unknown)
    local workspace_id = contract.workspace_id(workspace)
    local mode: Mode? = selected_mode == "control" and "control" or (selected_mode == "observe" and "observe" or nil)
    local idempotency_key: string? = nil
    if type(idempotency_value) == "string" then idempotency_key = idempotency_value end
    local width, height = size(width_value, M.MAX_WIDTH), size(height_value, M.MAX_HEIGHT)
    local function state(value: {[string]: unknown})
        value.version = 1
        process.send(parent, protocol.VIEW_STATE, value)
    end
    if type(node) ~= "string" then
        state({state = "failed", code = "INVALID_ARGUMENT", message = "Invalid remote view arguments"})
        return
    end
    if not workspace_id then
        state({state = "failed", code = "INVALID_ARGUMENT", message = "Invalid remote view arguments"})
        return
    end
    if not mode then
        state({state = "failed", code = "INVALID_ARGUMENT", message = "Invalid remote view arguments"})
        return
    end
    if not idempotency_key then
        state({state = "failed", code = "INVALID_ARGUMENT", message = "Invalid remote view arguments"})
        return
    end
    if idempotency_key == "" or #idempotency_key > 160 or idempotency_key:find("%c") then
        state({state = "failed", code = "INVALID_ARGUMENT", message = "Invalid remote view arguments"})
        return
    end
    if not width or not height then
        state({state = "failed", code = "INVALID_ARGUMENT", message = "Invalid remote view arguments"})
        return
    end
    local events = assert(process.events())
    local monitored, monitor_error = process.monitor(parent)
    if not monitored then error("Monitor remote view parent: " .. tostring(monitor_error)) end
    local retry = assert(process.listen(protocol.VIEW_RETRY, {message = true}))
    local closes = assert(process.listen(protocol.VIEW_CLOSE, {message = true}))
    local ops = operations(node)
    local confirmed_workspace: string = workspace_id
    local confirmed_key: string = idempotency_key
    local confirmed_mode: Mode = mode
    local confirmed_width: integer = width
    local confirmed_height: integer = height
    local opened: {handle: display.Handle, target: display.Target}?
    local pending_target: display.Target? = nil
    local function attach(target: display.Target?): string
        if target then
            local handle, failure = ops.open(target, confirmed_key)
            if handle then opened = {handle = handle, target = target}; pending_target = nil; return "" end
            local fault = failure or {code = "UNAVAILABLE", message = "Remote desktop unavailable"}
            if fault.code == "UNCERTAIN" then pending_target = target end
            return fault.message
        end
        local result, failure, uncertain_target = remote.choose(ops, node, confirmed_workspace, confirmed_mode, confirmed_key)
        if result then opened = result; pending_target = nil; return "" end
        local fault = failure or {code = "UNAVAILABLE", message = "Remote desktop unavailable"}
        if fault.code == "UNCERTAIN" then pending_target = uncertain_target end
        return fault.message
    end
    local attach_error = attach(nil)
    while not opened do
        state({state = pending_target and "uncertain" or "failed", code = pending_target and "UNCERTAIN" or "UNAVAILABLE", message = attach_error})
        if not pending_target then
            process.unlisten(retry)
            process.unlisten(closes)
            return
        end
        local wait_for = channel.select({retry:case_receive(), closes:case_receive(), events:case_receive()})
        if not wait_for.ok then break end
        if wait_for.channel == events then
            local event = wait_for.value
            if event.kind == process.event.CANCEL or ((event.kind == process.event.EXIT or event.kind == process.event.LINK_DOWN)
                and tostring(event.from) == parent) then break end
        elseif tostring(wait_for.value:from()) == parent then
            if wait_for.channel == closes then break end
            local data: unknown = wait_for.value:payload():data()
            local request = bounds.object(data)
            if request and bounds.fields(request, {"version", "idempotency_key"}) == nil
                and request.version == 1 and request.idempotency_key == idempotency_key then
                attach_error = attach(pending_target)
            end
        end
    end
    process.unlisten(retry)
    if not opened then process.unlisten(closes); return end
    local handle = opened.handle
    local target = opened.target
    local session = display.session_id(handle) or ""
    state({state = "attached", session_id = session, mode = mode, workspace_id = target.workspace_id,
        desktop_id = target.desktop_id, owner_execution = target.owner_execution})
    local inputs = assert(process.listen(protocol.VIEW_INPUT, {message = true}))
    local resizes = assert(process.listen(protocol.VIEW_RESIZE, {message = true}))
    local retries = assert(process.listen(protocol.VIEW_RETRY, {message = true}))
    local delivery_updates = delivery.updates()
    local failure: string? = nil
    if confirmed_mode == "control" then
        local resized, resize_error = display.resize(handle, confirmed_width, confirmed_height)
        if not resized then failure = resize_error or "resize remote desktop" end
    end
    local shown = ""
    while not failure do
        local selected = channel.select({delivery_updates.channel:case_receive(), inputs:case_receive(), resizes:case_receive(),
            closes:case_receive(), retries:case_receive(), events:case_receive()})
        if not selected.ok then break end
        if selected.channel == events then
            local event = selected.value
            if event.kind == process.event.CANCEL then break end
            if (event.kind == process.event.EXIT or event.kind == process.event.LINK_DOWN) and tostring(event.from) == parent then break end
        elseif selected.channel == delivery_updates.channel then
            if delivery.poll({session}) then
                local frame, frame_error = display.content(handle, confirmed_width, confirmed_height)
                if frame then
                    local signature = table.concat(frame.rows, "\n")
                    if signature ~= shown then
                        shown = signature
                        process.send(parent, protocol.VIEW_FRAME, {version = 1, rows = frame.rows, cursor = frame.cursor})
                    end
                elseif frame_error and frame_error ~= "Attaching" then failure = frame_error end
            end
        else
            local message = selected.value
            if tostring(message:from()) == parent then
                local data: unknown = message:payload():data()
                if selected.channel == closes then break
                elseif selected.channel == retries then
                    local request = bounds.object(data)
                    if request and bounds.fields(request, {"version", "idempotency_key"}) == nil
                        and request.version == 1 and request.idempotency_key == confirmed_key then
                        state({state = "attached", session_id = session, mode = confirmed_mode, workspace_id = target.workspace_id,
                            desktop_id = target.desktop_id, owner_execution = target.owner_execution})
                    end
                elseif selected.channel == resizes and type(data) == "table" then
                    local next_width, next_height = size(data.width, M.MAX_WIDTH), size(data.height, M.MAX_HEIGHT)
                    if next_width and next_height then
                        confirmed_width, confirmed_height = next_width, next_height
                        if confirmed_mode == "control" then
                            local resized, resize_error = display.resize(handle, confirmed_width, confirmed_height)
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
    for _, subscription in ipairs({inputs, resizes, retries, closes}) do process.unlisten(subscription) end
    local detached, detach_error = display.close(handle)
    if failure then error(failure) end
    if not detached then error(detach_error or "Detach remote desktop") end
end
M.main = main
return M
