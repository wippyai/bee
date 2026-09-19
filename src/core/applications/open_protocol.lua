-- MIT. The bounded bridge between an admitted agent open call and the
-- existing workspace host/broker request path.
local arguments = require("arguments")
local decode = require("decode")
local contract = require("contract")
local M = {}
type OriginView = {view_id: string, instance_id: string}
type Request = {version: integer, workspace_id: string, request_id: string, definition_id: string, arguments: {string}, caller_token: string, origin_view: OriginView?}
type Reply = {request_id: string, reply: contract.Reply, display_id: string?}

local function text(value: unknown, limit: integer): string?
    if type(value) ~= "string" or value == "" or #value > limit or value:find("%c") then return nil end
    return value
end

function M.origin(value: unknown): OriginView?
    if type(value) ~= "table" then return nil end
    for key in pairs(value) do if key ~= "view_id" and key ~= "instance_id" then return nil end end
    local view_id, instance_id = text(value.view_id, 80), text(value.instance_id, 80)
    if not view_id or not instance_id then return nil end
    return {view_id = view_id, instance_id = instance_id}
end

function M.request(value: unknown, workspace_id: string): Request?
    if type(value) ~= "table" or value.version ~= 1 or value.workspace_id ~= workspace_id then return nil end
    for key in pairs(value) do
        if key ~= "version" and key ~= "workspace_id" and key ~= "request_id"
            and key ~= "definition_id" and key ~= "arguments" and key ~= "caller_token" and key ~= "origin_view" then return nil end
    end
    local request_id = text(value.request_id, 80)
    local definition_id = text(value.definition_id, 160)
    local caller_token = text(value.caller_token, 160)
    local args = arguments.decode(value.arguments)
    if not request_id or not definition_id or not caller_token or not args then return nil end
    if not caller_token:match("^bee%.application%.open/[0-9a-f-]+$") then return nil end
    local origin = M.origin(value.origin_view)
    if value.origin_view ~= nil and not origin then return nil end
    return {version = 1, workspace_id = workspace_id, request_id = request_id,
        definition_id = definition_id, arguments = args, caller_token = caller_token, origin_view = origin}
end

-- The host forwards the broker's typed application reply and adds only the
-- workspace/request identity needed to route it back to the exact caller.
function M.reply(value: unknown, workspace_id: string): Reply?
    if type(value) ~= "table" or value.version ~= 1 or value.workspace_id ~= workspace_id then return nil end
    for key in pairs(value) do
        if key ~= "version" and key ~= "workspace_id" and key ~= "request_id" and key ~= "reply" and key ~= "display_id" then return nil end
    end
    local request_id = text(value.request_id, 80)
    local reply = type(value.reply) == "table" and decode.reply(value.reply) or nil
    if not request_id or not reply or reply.request_id ~= request_id or reply.workspace_id ~= workspace_id then return nil end
    local display_id = text(value.display_id, 160)
    if value.display_id ~= nil and not display_id then return nil end
    return {request_id = request_id, reply = reply, display_id = display_id}
end

return M
