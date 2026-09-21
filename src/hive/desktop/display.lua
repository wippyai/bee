-- MIT. Ephemeral terminal presentation of one admitted retained desktop.
--
-- This is deliberately a client of the Hive owner. It owns only its local
-- mount wrapper and terminal surface; it neither starts owners nor opens their
-- state. The receipt binds every mount capability to this exact process.
local tty = require("tty")
local channel = require("channel")
local time = require("time")
local process = require("process")
local bounds = require("bounds")
local client = require("client")
local protocol = require("protocol")
local contract = require("contract")
local delivery = require("delivery")
local input = require("input")

type Mode = "control" | "observe"
type Target = {node_id: string, owner_execution: string, workspace_id: string, desktop_id: string, mode: Mode}
type Receipt = {owner_execution: string, workspace_id: string, desktop_id: string, session_id: string, recipient: string, mode: string, mount_ref: string}
type Fault = {code: string, message: string}
type Session = {target: Target, receipt: Receipt, client: client.Client, closed: boolean}
-- A local caller carries only this opaque session reference. The client handle,
-- receipt and mount stay in this module's private table.
type Handle = {id: string}
type Content = {rows: {string}, cursor: {x: integer, y: integer, visible: boolean}?}

local M = {}
local MAX_MOUNT_BYTES = 4096
local DEFAULT_TIMEOUT = "10s"
local sessions: {[string]: Session} = {}

local function deadline(): string
    return time.now():add(DEFAULT_TIMEOUT):utc():format("2006-01-02T15:04:05.000Z07:00")
end

local function fault(code: string, message: string): Fault
    return {code = code, message = message}
end

local function mode(value: unknown): Mode?
    if value == "control" then return "control" end
    if value == "observe" then return "observe" end
    return nil
end

-- Decode a capability receipt only in the context that requested it. A valid
-- Hive envelope does not make a substituted session, recipient or mount safe.
function M.receipt(value: unknown, target: Target, recipient: string): (Receipt?, string?)
    local object = bounds.object(value)
    if not object then return nil, "desktop attachment receipt must be an object" end
    local fields_error = bounds.fields(object, {"owner_execution", "workspace_id", "desktop_id", "session_id", "recipient", "mode", "mount_ref", "expires_at"})
    if fields_error then return nil, fields_error end
    if object.owner_execution ~= target.owner_execution or object.workspace_id ~= target.workspace_id
        or object.desktop_id ~= target.desktop_id then return nil, "desktop attachment receipt identity changed" end
    if object.recipient ~= recipient then return nil, "desktop attachment receipt names another recipient" end
    local session_id = bounds.id(object.session_id)
    local selected = mode(object.mode)
    local mount_ref = bounds.line(object.mount_ref, MAX_MOUNT_BYTES)
    if not session_id then return nil, "desktop attachment receipt session_id is invalid" end
    if selected ~= target.mode then return nil, "desktop attachment receipt mode changed" end
    if not mount_ref then return nil, "desktop attachment receipt mount_ref is invalid" end
    return {owner_execution = target.owner_execution, workspace_id = target.workspace_id, desktop_id = target.desktop_id,
        session_id = session_id, recipient = recipient, mode = target.mode, mount_ref = mount_ref}, nil
end

function M.target(node_id: unknown, execution: unknown, workspace_id: unknown, desktop_id: unknown, selected_mode: unknown): (Target?, string?)
    local node = bounds.id(node_id)
    local owner_execution = contract.workspace_id(execution)
    local workspace = contract.workspace_id(workspace_id)
    local desktop = contract.workspace_id(desktop_id)
    local selected: Mode? = selected_mode == nil and "control" or mode(selected_mode)
    if not node then return nil, "node_id must be an identifier" end
    if not owner_execution or not workspace or not desktop then return nil, "execution, workspace_id and desktop_id must be 32 lowercase hexadecimal identities" end
    if not selected then return nil, "mode must be control or observe" end
    return {node_id = node, owner_execution = owner_execution, workspace_id = workspace, desktop_id = desktop, mode = selected}, nil
end

local function detach(target: Target, receipt: Receipt, handle: client.Client): (boolean, string?)
    local reply = handle:call({node_id = target.node_id, service_id = protocol.SERVICE}, {operation_ref = protocol.DETACH}, {
        owner_execution = receipt.owner_execution, workspace_id = receipt.workspace_id,
        desktop_id = receipt.desktop_id, session_id = receipt.session_id,
    }, {idempotency_key = receipt.session_id, deadline = deadline(), timeout = DEFAULT_TIMEOUT})
    if not reply.ok then return false, reply.error and reply.error.message or "desktop detach refused" end
    return true, nil
end

function M.open(target: Target): (Handle?, Fault?)
    local handle, open_error = client.open(target.node_id)
    if not handle then return nil, fault("UNAVAILABLE", open_error or "Hive client unavailable") end
    local recipient = tostring(process.pid())
    local reply = handle:call({node_id = target.node_id, service_id = protocol.SERVICE}, {operation_ref = protocol.ATTACH}, {
        owner_execution = target.owner_execution, workspace_id = target.workspace_id, desktop_id = target.desktop_id, mode = target.mode,
    }, {deadline = deadline(), timeout = DEFAULT_TIMEOUT})
    if not reply.ok then
        handle:close()
        return nil, fault(reply.error and reply.error.code or "UNAVAILABLE", reply.error and reply.error.message or "desktop attach refused")
    end
    local accepted, receipt_error = M.receipt(reply.value, target, recipient)
    if not accepted then
        handle:close()
        return nil, fault("INVALID_STATE", receipt_error or "invalid desktop attachment receipt")
    end
    if sessions[accepted.session_id] then
        handle:close()
        return nil, fault("CONFLICT", "Desktop session is already attached by this client")
    end
    local mounted, mount_error = delivery.attach(accepted.session_id, accepted.mount_ref, accepted.mode == "observe")
    if not mounted then
        -- A successful owner receipt created a live session even if this local
        -- wrapper cannot consume its mount. Retire it once; never retry an
        -- uncertain detach.
        detach(target, accepted, handle)
        handle:close()
        return nil, fault("UNAVAILABLE", mount_error or "attach desktop mount")
    end
    sessions[accepted.session_id] = {target = target, receipt = accepted, client = handle, closed = false}
    return {id = accepted.session_id}, nil
end

local function session(value: unknown): Session?
    local handle = bounds.object(value)
    local id = handle and bounds.id(handle.id)
    return id and sessions[id] or nil
end

function M.content(handle: unknown, width: integer, height: integer): (Content?, string?)
    local session = session(handle)
    if not session then return nil, "Desktop session is closed" end
    if session.closed then return nil, "Desktop session is closed" end
    return delivery.content(session.receipt.session_id, width, height)
end

function M.send(handle: unknown, event: unknown): (boolean, string?)
    local session = session(handle)
    if not session then return false, "Desktop session is closed" end
    if session.closed then return false, "Desktop session is closed" end
    if session.receipt.mode ~= "control" then return false, "View is read-only" end
    local decoded = input.decode(event)
    if not decoded then return false, "Invalid desktop input" end
    if decoded.type == "key" then
        return delivery.send(session.receipt.session_id, {type = "key", key = decoded.key, key_type = decoded.key_type,
            action = decoded.action, ctrl = decoded.ctrl == true, alt = decoded.alt == true, shift = decoded.shift == true})
    elseif decoded.type == "mouse" then
        return delivery.send(session.receipt.session_id, {type = "mouse", x = decoded.x, y = decoded.y, button = decoded.button,
            action = decoded.action, ctrl = decoded.ctrl == true, alt = decoded.alt == true, shift = decoded.shift == true})
    elseif decoded.type == "paste" then
        return delivery.send(session.receipt.session_id, {type = "paste", text = decoded.text})
    elseif decoded.type == "focus" then
        return delivery.send(session.receipt.session_id, {type = "focus", focused = decoded.focused})
    end
    return false, "Desktop input is not forwardable"
end

function M.resize(handle: unknown, width: integer, height: integer): (boolean, string?)
    local session = session(handle)
    if not session then return false, "Desktop session is closed" end
    if session.closed then return false, "Desktop session is closed" end
    if session.receipt.mode ~= "control" then return false, "View is read-only" end
    return delivery.resize(session.receipt.session_id, width, height)
end

-- Exactly one detach is attempted for every successful attachment receipt.
-- The local mount is retired first, so no input survives a close race.
function M.close(handle: unknown): (boolean, string?)
    local session = session(handle)
    if not session then return true, nil end
    if session.closed then return true, nil end
    session.closed = true
    sessions[session.receipt.session_id] = nil
    delivery.close(session.receipt.session_id)
    local detached, detach_error = detach(session.target, session.receipt, session.client)
    session.client:close()
    return detached, detach_error
end

function M.session_id(handle: unknown): string?
    local active = session(handle)
    return active and active.receipt.session_id or nil
end

local function present(handle: Handle)
    assert(tty.start())
    local output = assert(tty.surface({alternate_screen = true, hide_cursor = true, synchronized_output = true}))
    local events = assert(tty.events())
    local ticks = assert(time.ticker("33ms")):channel()
    assert(tty.mouse(true))
    local width, height = tty.screen_size()
    local failure: string? = nil
    local active = session(handle)
    if not active then error("Desktop session is closed") end
    if active.receipt.mode == "control" then
        local resized, resize_error = M.resize(handle, width, height)
        if not resized then failure = resize_error or "resize desktop" end
    end
    while not failure do
        local selected = channel.select({events:case_receive(), ticks:case_receive()})
        if not selected.ok then break end
        if selected.channel == ticks then
            delivery.poll({active.receipt.session_id})
            local frame, frame_error = M.content(handle, width, height)
            if frame then output:present(frame.rows, {cursor = frame.cursor})
            elseif frame_error and frame_error ~= "Attaching" then failure = frame_error end
        else
            local event = input.decode(selected.value)
            if event then
                if event.type == "close" then break end
                if event.type == "resize" then
                    width, height = event.width, event.height
                    if active.receipt.mode == "control" then
                        local resized, resize_error = M.resize(handle, width, height)
                        if not resized then failure = resize_error or "resize desktop" end
                    end
                elseif active.receipt.mode == "control" then
                    local sent, send_error = M.send(handle, event)
                    if sent == false then failure = send_error or "send desktop input" end
                end
            end
        end
    end
    output:close()
    tty.stop()
    if failure then error(failure) end
end

function M.command(node_id: unknown, execution: unknown, workspace_id: unknown, desktop_id: unknown)
    local target, target_error = M.target(node_id, execution, workspace_id, desktop_id, nil)
    if not target then error(target_error or "Invalid bee-display arguments") end
    local handle, open_error = M.open(target)
    if not handle then error(open_error and open_error.message or "Attach desktop") end
    local ran, run_error = pcall(present, handle)
    local detached, detach_error = M.close(handle)
    if not ran then error(tostring(run_error)) end
    if not detached then error(detach_error or "Detach desktop") end
end

return M
