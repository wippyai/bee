-- MIT. Bounded asynchronous catalog bridge. Durable allocation identity belongs
-- to the caller; losing a reply never authorizes allocating a different identity.
local process = require("process")
local uuid = require("uuid")
local types = require("types")
local protocol = require("protocol")
local bounds = require("bounds")
local contract = require("contract")
type Waiter = {recipient: string, call: types.Call, due: integer}
-- listeners are further listings answered by this same catalog read.
type Pending = {id: string, recipient: string, call: types.Call, desktop_id: string?, due: integer, listeners: {Waiter}}
type State = {pending: Pending?}
type Identity = {desktop_id: string, is_default: boolean}
type Result = {code: string, message: string, desktops: {Identity}}
local MAX_LISTENERS = 16
local M = {}
function M.new(): State return {} end
local function answer(recipient: string, reply: types.Reply)
    process.send(recipient, types.TOPIC_REPLY, reply)
end
local function uncertain(pending: Pending, call: types.Call): types.Reply
    if pending.desktop_id then
        return types.reply_error(call.request_id, types.uncertain("Desktop allocation may have committed; retry the same desktop identity",
            {operation_ref = protocol.CREATE, idempotency_key = call.idempotency_key}))
    end
    return types.reply_error(call.request_id, types.fault("UNAVAILABLE", "Desktop catalog did not complete"))
end
function M.request(state: State, owner: string, workspace: string, sender: string, call: types.Call, desktop: string?, due: integer)
    local current = state.pending
    if current then
        -- A listing is a read: another listing joins the pending read. An
        -- allocation stays exclusive, and so does any request during one.
        if not desktop and not current.desktop_id and #current.listeners < MAX_LISTENERS then
            current.listeners[#current.listeners + 1] = {recipient = sender, call = call, due = due}
            return
        end
        answer(sender, types.reply_error(call.request_id, types.fault("BUSY", "Desktop catalog request already pending")))
        return
    end
    local pending: Pending = {id = uuid.v7(), recipient = sender, call = call, desktop_id = desktop, due = due, listeners = {}}
    state.pending = pending
    local sent, err = process.send(owner, "bee.retained.desktops", {version = 1, workspace_id = workspace,
        request_id = pending.id, op = desktop and "allocate" or "list", desktop_id = desktop})
    if not sent or err then
        state.pending = nil
        answer(sender, types.reply_error(call.request_id, types.fault("UNAVAILABLE", "Desktop catalog request was not accepted")))
    end
end
local function decode(value: unknown, workspace: string, pending: Pending): Result?
    local object = bounds.object(value)
    if not object or bounds.fields(object, {"version", "workspace_id", "request_id", "desktop_id", "code", "message", "desktops"})
        or object.version ~= 1 or object.workspace_id ~= workspace or object.request_id ~= pending.id
        or object.desktop_id ~= (pending.desktop_id or "") then return nil end
    local message = contract.text(object.message, 400)
    if not message then return nil end
    local code = contract.text(object.code, 80)
    if not code then return nil end
    if code ~= "OK" and code ~= "INVALID_ARGUMENT" and code ~= "DENIED" and code ~= "UNAVAILABLE"
        and code ~= "CAPACITY" and code ~= "CONFLICT" and code ~= "BUSY" then return nil end
    if type(object.message) ~= "string" or #object.message > 400 or type(object.desktops) ~= "table" then return nil end
    local count = 0
    for key in pairs(object.desktops) do
        if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #object.desktops then return nil end
        count = count + 1
        if count > 33 then return nil end
    end
    if count ~= #object.desktops then return nil end
    local identities: {Identity} = {}
    local seen: {[string]: boolean} = {}
    for index, item in ipairs(object.desktops) do
        local record = bounds.object(item)
        if not record or bounds.fields(record, {"desktop_id", "is_default"}) then return nil end
        local id = contract.workspace_id(record.desktop_id)
        if not id or seen[id] or record.is_default ~= (index == 1) then return nil end
        seen[id] = true
        identities[#identities + 1] = {desktop_id = id, is_default = index == 1}
    end
    if code ~= "OK" or pending.desktop_id then
        if count ~= 0 then return nil end
    elseif count == 0 then return nil end
    if code == "OK" and object.message ~= "" then return nil end
    return {code = code, message = message, desktops = identities}
end
-- The owner may revoke an execution-local reader while its storage query is
-- pending. Clear before replying so a late storage result cannot expose data.
function M.revoke(state: State, message: string)
    local pending = state.pending
    if not pending then return end
    state.pending = nil
    answer(pending.recipient, types.reply_error(pending.call.request_id, types.fault("DENIED", message)))
    for _, listener in ipairs(pending.listeners) do
        answer(listener.recipient, types.reply_error(listener.call.request_id, types.fault("DENIED", message)))
    end
end
function M.result(state: State, value: unknown, workspace: string, execution: string, now: integer)
    local pending = state.pending
    -- A late reply cannot retire the next catalog request.
    if not pending or type(value) ~= "table" or value.request_id ~= pending.id then return end
    state.pending = nil
    local result = decode(value, workspace, pending)
    local function settle(recipient: string, call: types.Call, due: integer)
        if now >= due or not result or result.code == "UNAVAILABLE" then
            answer(recipient, uncertain(pending, call)); return
        end
        if result.code ~= "OK" then
            local code = result.code == "CAPACITY" and "LIMIT_EXCEEDED" or result.code
            answer(recipient, types.reply_error(call.request_id, types.fault(code, result.message)))
        elseif pending.desktop_id then
            answer(recipient, types.reply_ok(call.request_id, {owner_execution = execution,
                workspace_id = workspace, desktop_id = pending.desktop_id}))
        else
            answer(recipient, types.reply_ok(call.request_id, {owner_execution = execution,
                workspaces = {{workspace_id = workspace, desktops = result.desktops}}}))
        end
    end
    settle(pending.recipient, pending.call, pending.due)
    for _, listener in ipairs(pending.listeners) do settle(listener.recipient, listener.call, listener.due) end
end
function M.tick(state: State, now: integer)
    local pending = state.pending
    if not pending then return end
    if now >= pending.due then
        state.pending = nil
        answer(pending.recipient, uncertain(pending, pending.call))
        for _, listener in ipairs(pending.listeners) do answer(listener.recipient, uncertain(pending, listener.call)) end
        return
    end
    local waiting: {Waiter} = {}
    for _, listener in ipairs(pending.listeners) do
        if now >= listener.due then answer(listener.recipient, uncertain(pending, listener.call))
        else waiting[#waiting + 1] = listener end
    end
    pending.listeners = waiting
end
return M
