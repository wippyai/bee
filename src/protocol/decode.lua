local contract = require("contract")
local M = {}
-- Native process EXIT carries runtime.Result under event.result. A successful
-- result.value is not a failure, even when the returned application value has
-- an error-shaped field of its own.
function M.exit_error(result: unknown): string?
    if type(result) ~= "table" or result.error == nil then return nil end
    return tostring(result.error)
end
type Reply = contract.Reply
local function reply_op(value: unknown): contract.ReplyOp?
    if value == "open" then return "open" end
    if value == "close" then return "close" end
    if value == "closed" then return "closed" end
    if value == "focus" then return "focus" end
    if value == "attached" then return "attached" end
    if value == "bind" then return "bind" end
    if value == "unbind" then return "unbind" end
    if value == "page" then return "page" end
    if value == "title" then return "title" end
    if value == "closing" then return "closing" end
    if value == "quit" then return "quit" end
    if value == "shutdown" then return "shutdown" end
    if value == "fence" then return "fence" end
    return nil
end
function M.reply(value: unknown): Reply?
    if type(value) ~= "table" or value.version ~= 1 then return nil end
    local workspace_id = contract.workspace_id(value.workspace_id)
    if value.workspace_id ~= nil and not workspace_id then return nil end
    local op = reply_op(value.op)
    if not op then return nil end
    local request_id, id = contract.text(value.request_id, 80), contract.text(value.id, 80)
    local instance, title = contract.text(value.instance_id, 80), contract.text(value.title, 80)
    local mount, code = contract.text(value.mount, 1024), contract.text(value.error_code, 80)
    if not request_id or not id or not instance or not title or not mount or not code
        or type(value.error) ~= "string" or #value.error > 4096 then return nil end
    local notice = contract.text(value.notice, 160)
    if value.notice ~= nil and not notice then return nil end
    local icon = contract.text(value.icon, 8)
    if value.icon ~= nil and not icon then return nil end
    local thread_id: string? = nil
    if value.thread_id ~= nil then
        thread_id = contract.thread_id(value.thread_id)
        if not thread_id then return nil end
    end
    if value.observer ~= nil and type(value.observer) ~= "boolean" then return nil end
    local observer: boolean? = nil
    if value.observer == true then observer = true end
    return {version = 1, request_id = request_id, op = op, id = id, instance_id = instance, workspace_id = workspace_id, icon = icon, thread_id = thread_id,
        title = title, notice = notice, mount = mount, error_code = code, error = value.error,
        definition_id = contract.text(value.definition_id, 160) or "", resume_schema = contract.text(value.resume_schema, 80) or "",
        restart_policy = contract.text(value.restart_policy, 16) or "never",
        resume_state = type(value.resume_state) == "string" and #value.resume_state <= 65536 and value.resume_state or "",
        observer = observer}
end
function M.belongs(reply: Reply, workspace_id: string): boolean
    return reply.workspace_id == workspace_id and contract.workspace_id(workspace_id) ~= nil
end
return M
