-- MIT. Bounded asynchronous catalog bridge. Durable allocation identity belongs
-- to the caller; losing a reply never authorizes allocating a different identity.
local process = require("process")
local uuid = require("uuid")
local types = require("types")
local protocol = require("protocol")
local bounds = require("bounds")
local contract = require("contract")
type Pending = {id: string, recipient: string, call: types.Call, desktop_id: string?, due: integer}
type State = {pending: Pending?}
type Identity = {desktop_id: string, is_default: boolean}
type Result = {code: string, message: string, desktops: {Identity}}
local M = {}
function M.new(): State return {} end
local function answer(recipient: string, reply: types.Reply)
    process.send(recipient, types.TOPIC_REPLY, reply)
end
local function uncertain(pending: Pending): types.Reply
    if pending.desktop_id then
        return types.reply_error(pending.call.request_id, types.uncertain("Desktop allocation may have committed; retry the same desktop identity",
            {operation_ref = protocol.CREATE, idempotency_key = pending.call.idempotency_key}))
    end
    return types.reply_error(pending.call.request_id, types.fault("UNAVAILABLE", "Desktop catalog did not complete"))
end
function M.request(state: State, owner: string, workspace: string, sender: string, call: types.Call, desktop: string?, due: integer)
    if state.pending then
        answer(sender, types.reply_error(call.request_id, types.fault("BUSY", "Desktop catalog request already pending")))
        return
    end
    local pending: Pending = {id = uuid.v7(), recipient = sender, call = call, desktop_id = desktop, due = due}
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
function M.result(state: State, value: unknown, workspace: string, execution: string, now: integer)
    local pending = state.pending
    -- A late reply cannot retire the next catalog request.
    if not pending or type(value) ~= "table" or value.request_id ~= pending.id then return end
    state.pending = nil
    local result = decode(value, workspace, pending)
    if now >= pending.due or not result or result.code == "UNAVAILABLE" then
        answer(pending.recipient, uncertain(pending)); return
    end
    if result.code ~= "OK" then
        local code = result.code == "CAPACITY" and "BUSY" or result.code
        answer(pending.recipient, types.reply_error(pending.call.request_id, types.fault(code, result.message)))
    elseif pending.desktop_id then
        answer(pending.recipient, types.reply_ok(pending.call.request_id, {owner_execution = execution,
            workspace_id = workspace, desktop_id = pending.desktop_id}))
    else
        answer(pending.recipient, types.reply_ok(pending.call.request_id, {owner_execution = execution,
            workspaces = {{workspace_id = workspace, desktops = result.desktops}}}))
    end
end
function M.tick(state: State, now: integer)
    local pending = state.pending
    if pending and now >= pending.due then
        state.pending = nil
        answer(pending.recipient, uncertain(pending))
    end
end
return M
