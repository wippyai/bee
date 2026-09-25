-- MIT. One bounded asynchronous storage operation inside the retained supervisor.
-- Only the authenticated bootstrap owner may reach this adapter. It owns no SQL.
local funcs = require("funcs")
local channel = require("channel")
local time = require("time")
local contract = require("contract")
type Channel = channel.Channel
type Request = {request_id: string, op: "list" | "allocate", desktop_id: string?}
type Identity = {desktop_id: string, is_default: boolean}
type Reply = {code: string, message: string, desktop_id: string, desktops: {Identity}}
type Pending = {request: Request, future: funcs.Future, response: Channel<unknown>, deadline: Channel<time.Time>}
local M = {}
function M.request(value: unknown, workspace_id: string): Request?
    if type(value) ~= "table" or value.version ~= 1 or value.workspace_id ~= workspace_id then return nil end
    for key in pairs(value) do
        if key ~= "version" and key ~= "workspace_id" and key ~= "request_id" and key ~= "op" and key ~= "desktop_id" then return nil end
    end
    local op: "list" | "allocate" = "list"
    local desktop_id: string? = nil
    if value.op == "allocate" then
        desktop_id = contract.workspace_id(value.desktop_id)
        if not desktop_id then return nil end
        op = "allocate"
    elseif value.op ~= "list" or value.desktop_id ~= nil then return nil end
    local id = contract.text(value.request_id, 80)
    if not id or id == "" then return nil end
    return {request_id = id, op = op, desktop_id = desktop_id}
end
function M.failure(request: Request, code: string, message: string): Reply
    return {code = code, message = message, desktop_id = request.desktop_id or "", desktops = {}}
end
local function decode(value: unknown, request: Request): Reply?
    if type(value) ~= "table" then return nil end
    for key in pairs(value) do
        if key ~= "code" and key ~= "message" and key ~= "desktop_id" and key ~= "desktops" then return nil end
    end
    local code = value.code
    if code ~= "OK" and code ~= "INVALID_ARGUMENT" and code ~= "DENIED" and code ~= "UNAVAILABLE"
        and code ~= "CAPACITY" and code ~= "CONFLICT" then return nil end
    if type(value.message) ~= "string" or #value.message > 400 or type(value.desktops) ~= "table"
        or value.desktop_id ~= (request.desktop_id or "") then return nil end
    local identities: {Identity} = {}
    local seen: {[string]: boolean} = {}
    local count = 0
    for key in pairs(value.desktops) do
        if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #value.desktops then return nil end
        count = count + 1
        if count > 33 then return nil end
    end
    if count ~= #value.desktops then return nil end
    for index, item in ipairs(value.desktops) do
        if type(item) ~= "table" then return nil end
        for key in pairs(item) do if key ~= "desktop_id" and key ~= "is_default" then return nil end end
        local id = contract.workspace_id(item.desktop_id)
        if not id or seen[id] or item.is_default ~= (index == 1) then return nil end
        seen[id] = true
        identities[#identities + 1] = {desktop_id = id, is_default = index == 1}
    end
    if code ~= "OK" or request.op == "allocate" then
        if count ~= 0 then return nil end
    elseif count == 0 then return nil end
    if code == "OK" and value.message ~= "" then return nil end
    return {code = code, message = value.message, desktop_id = request.desktop_id or "", desktops = identities}
end
function M.start(request: Request): (Pending?, string?)
    local target = request.op == "list" and "bee.client:list_desktops" or "bee.client:allocate_desktop"
    local future, err = funcs.async(target, {version = 1, database_resource = "bee.env:client_db", desktop_id = request.desktop_id})
    if not future then return nil, tostring(err) end
    -- The pinned manifest exposes this native response channel as any. Its
    -- payload remains unknown until complete validates the function reply.
    return {request = request, future = future, response = future:response() :: Channel<unknown>, deadline = time.after("5s")}
end
function M.complete(pending: Pending): Reply
    local result, err = pending.future:result()
    if err or not result then return M.failure(pending.request, "UNAVAILABLE", "Desktop storage operation outcome is unknown") end
    local reply = decode(result:data(), pending.request)
    return reply or M.failure(pending.request, "UNAVAILABLE", "Invalid desktop storage reply; operation outcome is unknown")
end
function M.cancel(pending: Pending): Reply
    pending.future:cancel()
    return M.failure(pending.request, "UNAVAILABLE", "Desktop storage operation outcome is unknown; retain the allocation identity")
end
return M
