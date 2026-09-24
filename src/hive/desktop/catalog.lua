-- MIT. The node's desktop catalog for the desktop bridge: one page of the node
-- workspace catalog together with the node's durable display identities, and
-- display allocation. Both are read asynchronously under the bridge's catalog
-- scope. Durable allocation identity belongs to the caller; losing a reply
-- never authorizes allocating a different identity.
local funcs = require("funcs")
local process = require("process")
local channel = require("channel")
local types = require("types")
local protocol = require("protocol")
local bounds = require("bounds")
local contract = require("contract")
type Channel = channel.Channel
type Waiter = {recipient: string, call: types.Call, due: integer}
type Query = {label: string?, after: string?, limit: integer}
type Identity = {desktop_id: string, is_default: boolean}
type Row = {workspace_id: string, label: string}
type Page = {rows: {Row}, next_after: string?}
-- A listing joins a pending read of the same page; an allocation is exclusive.
type Pending = {recipient: string, call: types.Call, desktop_id: string?, query: Query?, key: string, due: integer,
    listeners: {Waiter}, identities: funcs.Future, identities_response: Channel<unknown>, page: funcs.Future?,
    page_response: Channel<unknown>?, desktops: {Identity}?, rows: Page?, failed: string?}
type State = {pending: Pending?}
-- served reports whether the bridge holds a desktop supervisor for a workspace.
type Listing = {execution: string, default_workspace: string?, served: (string) -> boolean}
local MAX_LISTENERS = 16
local MAX_DESKTOPS = 33
local M = {}
M.CATALOG_LIST = "bee.workspace.catalog:list"
M.CATALOG_SEARCH = "bee.workspace.catalog:search"
M.LIST_DESKTOPS = "bee.client:list_desktops"
M.ALLOCATE_DESKTOP = "bee.client:allocate_desktop"
M.CLIENT_DATABASE = "bee:client_db"
function M.new(): State return {} end
local function answer(recipient: string, reply: types.Reply)
    process.send(recipient, types.TOPIC_REPLY, reply)
end
local function query_key(query: Query?): string
    if not query then return "" end
    return (query.label or "") .. "\0" .. (query.after or "") .. "\0" .. tostring(query.limit)
end
-- Futures the owning loop selects on while a catalog operation is pending.
function M.channels(state: State): {Channel<unknown>}
    local pending = state.pending
    if not pending then return {} end
    local result: {Channel<unknown>} = {}
    if not pending.desktops and not pending.failed then result[#result + 1] = pending.identities_response end
    if pending.page_response and not pending.rows and not pending.failed then result[#result + 1] = pending.page_response end
    return result
end
local function busy(sender: string, call: types.Call)
    answer(sender, types.reply_error(call.request_id, types.fault("BUSY", "Desktop catalog request already pending")))
end
local function start(state: State, executor: funcs.Executor, sender: string, call: types.Call, desktop_id: string?, query: Query?, due: integer): boolean
    local identities_target = desktop_id and M.ALLOCATE_DESKTOP or M.LIST_DESKTOPS
    local identities, identities_error = executor:async(identities_target,
        {version = 1, database_resource = M.CLIENT_DATABASE, desktop_id = desktop_id})
    if not identities then
        answer(sender, types.reply_error(call.request_id, types.fault("UNAVAILABLE", "Desktop catalog request was not accepted: " .. tostring(identities_error))))
        return false
    end
    local page: funcs.Future? = nil
    if query then
        local request: {[string]: unknown} = {state = "active", limit = query.limit}
        if query.after then request.after = query.after end
        local target = M.CATALOG_LIST
        if query.label then request.label = query.label; target = M.CATALOG_SEARCH end
        local future, page_error = executor:async(target, request)
        if not future then
            identities:cancel()
            answer(sender, types.reply_error(call.request_id, types.fault("UNAVAILABLE", "Workspace catalog request was not accepted: " .. tostring(page_error))))
            return false
        end
        page = future
    end
    state.pending = {recipient = sender, call = call, desktop_id = desktop_id, query = query, key = query_key(query), due = due, listeners = {},
        identities = identities, identities_response = identities:response() :: Channel<unknown>,
        page = page, page_response = page and page:response() :: Channel<unknown> or nil}
    return true
end
function M.list(state: State, executor: funcs.Executor, sender: string, call: types.Call, query: Query, due: integer)
    local current = state.pending
    if current then
        if not current.desktop_id and current.key == query_key(query) and #current.listeners < MAX_LISTENERS then
            current.listeners[#current.listeners + 1] = {recipient = sender, call = call, due = due}
            return
        end
        busy(sender, call); return
    end
    start(state, executor, sender, call, nil, query, due)
end
function M.allocate(state: State, executor: funcs.Executor, sender: string, call: types.Call, desktop_id: string, due: integer)
    if state.pending then busy(sender, call); return end
    start(state, executor, sender, call, desktop_id, nil, due)
end
local function decode_identities(value: unknown, pending: Pending): {Identity}?
    local object = bounds.object(value)
    if not object or bounds.fields(object, {"code", "message", "desktop_id", "desktops"}) then return nil end
    if object.desktop_id ~= (pending.desktop_id or "") or type(object.message) ~= "string" or #object.message > 400 then return nil end
    local code = object.code
    if code ~= "OK" then return nil end
    local desktops = object.desktops
    if type(desktops) ~= "table" then return nil end
    local count = 0
    for key in pairs(desktops) do
        if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #desktops then return nil end
        count = count + 1
        if count > MAX_DESKTOPS then return nil end
    end
    if count ~= #desktops then return nil end
    if (pending.desktop_id and count ~= 0) or (not pending.desktop_id and count == 0) then return nil end
    local result: {Identity} = {}
    local seen: {[string]: boolean} = {}
    for index, raw in ipairs(desktops) do
        local item = bounds.object(raw)
        if not item or bounds.fields(item, {"desktop_id", "is_default"}) then return nil end
        local id = contract.workspace_id(item.desktop_id)
        if not id or seen[id] or item.is_default ~= (index == 1) then return nil end
        seen[id] = true
        result[#result + 1] = {desktop_id = id, is_default = index == 1}
    end
    return result
end
-- The refusal a failed identity operation reports; nil when it succeeded.
local function identity_refusal(value: unknown): (string?, string?)
    local object = bounds.object(value)
    if not object then return "UNAVAILABLE", "Invalid desktop storage reply; the outcome is unknown" end
    local code = object.code
    if code == "OK" then return nil, nil end
    local message = type(object.message) == "string" and #object.message <= 400 and object.message or "Desktop storage refused"
    if code == "CAPACITY" then return "LIMIT_EXCEEDED", message end
    if code == "INVALID_ARGUMENT" or code == "DENIED" or code == "CONFLICT" then return code, message end
    return "UNAVAILABLE", message
end
local function decode_page(value: unknown): Page?
    local reply = bounds.object(value)
    if not reply or reply.ok ~= true then return nil end
    local object = bounds.object(reply.value)
    local items = object and object.items
    if not object or type(items) ~= "table" then return nil end
    local rows: {Row} = {}
    local seen: {[string]: boolean} = {}
    for _, raw in ipairs(items :: {unknown}) do
        local row = bounds.object(raw)
        local id = row and contract.workspace_id(row.workspace_id)
        local label = row and contract.text(row.label, 240)
        if not id or not label or seen[id] or #rows >= protocol.MAX_PAGE then return nil end
        seen[id] = true
        rows[#rows + 1] = {workspace_id = id, label = label}
    end
    local next_after: string? = nil
    if object.next_after ~= nil then
        next_after = contract.text(object.next_after, protocol.MAX_CURSOR)
        if not next_after or next_after == "" then return nil end
    end
    return {rows = rows, next_after = next_after}
end
local function catalog_refusal(value: unknown): string
    local reply = bounds.object(value)
    local failure = reply and bounds.object(reply.error)
    local code = failure and contract.text(failure.code, 64)
    local message = failure and contract.text(failure.message, 400)
    if code and message then return code .. ": " .. message end
    return "the workspace catalog did not answer"
end
local function settle(state: State, listing: Listing, now: integer)
    local pending = state.pending
    if not pending then return end
    local complete = pending.failed ~= nil or (pending.desktops ~= nil and (not pending.page or pending.rows ~= nil))
    if not complete then return end
    state.pending = nil
    local function reply_to(recipient: string, call: types.Call, due: integer)
        if pending.failed then
            if pending.desktop_id then
                answer(recipient, types.reply_error(call.request_id, types.uncertain(pending.failed,
                    {operation_ref = protocol.CREATE, idempotency_key = call.idempotency_key})))
            else answer(recipient, types.reply_error(call.request_id, types.fault("UNAVAILABLE", pending.failed))) end
            return
        end
        if now >= due then
            answer(recipient, types.reply_error(call.request_id, types.fault("DEADLINE_EXCEEDED", "Desktop catalog deadline passed")))
            return
        end
        if pending.desktop_id then
            answer(recipient, types.reply_ok(call.request_id, {owner_execution = listing.execution, desktop_id = pending.desktop_id}))
            return
        end
        local rows = pending.rows
        local workspaces: {{[string]: unknown}} = {}
        if rows then
            for _, row in ipairs(rows.rows) do
                workspaces[#workspaces + 1] = {workspace_id = row.workspace_id, label = row.label, served = listing.served(row.workspace_id)}
            end
        end
        local value: {[string]: unknown} = {owner_execution = listing.execution, desktops = pending.desktops, workspaces = workspaces}
        if rows and rows.next_after then value.next_after = rows.next_after end
        if listing.default_workspace then value.default_workspace = listing.default_workspace end
        answer(recipient, types.reply_ok(call.request_id, value))
    end
    reply_to(pending.recipient, pending.call, pending.due)
    for _, listener in ipairs(pending.listeners) do reply_to(listener.recipient, listener.call, listener.due) end
end
-- One future of the pending operation completed.
function M.result(state: State, selected: unknown, listing: Listing, now: integer)
    local pending = state.pending
    if not pending then return end
    if selected == pending.identities_response then
        local result, err = pending.identities:result()
        local data: unknown = result and result:data() or nil
        local code, message = identity_refusal(data)
        if err then pending.failed = "Desktop storage operation outcome is unknown"
        elseif code then
            state.pending = nil
            local failure = types.fault(code, message or "Desktop storage refused")
            answer(pending.recipient, types.reply_error(pending.call.request_id, failure))
            for _, listener in ipairs(pending.listeners) do answer(listener.recipient, types.reply_error(listener.call.request_id, failure)) end
            if pending.page then pending.page:cancel() end
            return
        else
            local desktops = decode_identities(data, pending)
            if desktops then pending.desktops = desktops else pending.failed = "Invalid desktop storage reply; the outcome is unknown" end
        end
    elseif pending.page and selected == pending.page_response then
        local result, err = pending.page:result()
        local data: unknown = result and result:data() or nil
        local rows = not err and decode_page(data) or nil
        if rows then pending.rows = rows
        else pending.failed = err and ("Workspace catalog read failed: " .. tostring(err)) or catalog_refusal(data) end
    else return end
    settle(state, listing, now)
end
function M.handles(state: State, selected: unknown): boolean
    local pending = state.pending
    return pending ~= nil and (selected == pending.identities_response or (pending.page_response ~= nil and selected == pending.page_response))
end
-- A stopping owner revokes the pending read or allocation.
-- Clear before replying so a late result cannot expose data.
function M.revoke(state: State, message: string)
    local pending = state.pending
    if not pending then return end
    state.pending = nil
    pending.identities:cancel()
    if pending.page then pending.page:cancel() end
    answer(pending.recipient, types.reply_error(pending.call.request_id, types.fault("DENIED", message)))
    for _, listener in ipairs(pending.listeners) do
        answer(listener.recipient, types.reply_error(listener.call.request_id, types.fault("DENIED", message)))
    end
end
function M.tick(state: State, now: integer)
    local pending = state.pending
    if not pending then return end
    if now >= pending.due then
        state.pending = nil
        pending.identities:cancel()
        if pending.page then pending.page:cancel() end
        local function expire(recipient: string, call: types.Call)
            if pending.desktop_id then
                answer(recipient, types.reply_error(call.request_id, types.uncertain("Desktop allocation may have committed; retry the same desktop identity",
                    {operation_ref = protocol.CREATE, idempotency_key = call.idempotency_key})))
            else answer(recipient, types.reply_error(call.request_id, types.fault("UNAVAILABLE", "Desktop catalog did not complete"))) end
        end
        expire(pending.recipient, pending.call)
        for _, listener in ipairs(pending.listeners) do expire(listener.recipient, listener.call) end
        return
    end
    local waiting: {Waiter} = {}
    for _, listener in ipairs(pending.listeners) do
        if now >= listener.due then
            answer(listener.recipient, types.reply_error(listener.call.request_id, types.fault("UNAVAILABLE", "Desktop catalog did not complete")))
        else waiting[#waiting + 1] = listener end
    end
    pending.listeners = waiting
end
return M
