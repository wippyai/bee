-- Versioned application boundary. Records contain values, never terminal handles.
local arguments = require("arguments")
local thread_bounds = require("thread_bounds")
local M = {}
type ReplyOp = "open" | "close" | "closed" | "focus" | "attached" | "bind" | "unbind" | "page" | "title" | "closing" | "quit" | "shutdown"
type Reply = {version: integer, request_id: string, op: ReplyOp, id: string, instance_id: string, workspace_id: string?,
    title: string, icon: string?, mount: string, definition_id: string, thread_id: string?, resume_schema: string, restart_policy: string, resume_state: string, error: string, error_code: string, observer: boolean?}
type RequestOp = "open" | "close" | "bind" | "unbind" | "shutdown"
type Request = {version: integer, request_id: string, op: RequestOp, workspace_id: string?, id: string, instance_id: string, definition_id: string, thread_id: string?, recipient: string, restore_instance_id: string, restore_view_id: string, resume_schema: string, resume_state: string, arguments: {string}, observer: boolean?}
type Descriptor = {definition_id: string, definition_revision: string, title: string, icon: string,
    group: string, role: string, singleton: boolean, resume_schema: string, restart_policy: string}
type Binding = {definition_id: string, policies: {string}, appearance_write: boolean, application_stop: boolean, catalog_read: boolean}
local function request_op(value: unknown): RequestOp?
    if value == "open" then return "open" end
    if value == "close" then return "close" end
    if value == "bind" then return "bind" end
    if value == "unbind" then return "unbind" end
    if value == "shutdown" then return "shutdown" end
    return nil
end
function M.workspace_id(value: unknown): string?
    if type(value) == "string" and #value == 32 and not value:find("[^0-9a-f]") then return value end
    return nil
end
function M.thread_id(value: unknown): string?
    return thread_bounds.id(value)
end
function M.text(value: unknown, limit: integer): string?
    if type(value) ~= "string" or #value > limit or value:find("%c") then return nil end
    return value
end
function M.request(value: unknown): Request?
    if type(value) ~= "table" or value.version ~= 1 then return nil end
    local workspace_id = M.workspace_id(value.workspace_id)
    if value.workspace_id ~= nil and not workspace_id then return nil end
    local request_id = M.text(value.request_id, 80)
    if not request_id or request_id == "" then return nil end
    local op = request_op(value.op)
    if not op then return nil end
    local id = M.text(value.id or "", 80)
    local instance_id = M.text(value.instance_id or "", 80)
    local definition_id = M.text(value.definition_id or "", 160)
    local recipient = M.text(value.recipient or "", 160)
    if not id or not instance_id or not definition_id or not recipient then return nil end
    if op == "bind" and ((id == "") ~= (instance_id == "")) then return nil end
    if op ~= "bind" and op ~= "close" and instance_id ~= "" then return nil end
    if op == "unbind" and (recipient == "" or id ~= "") then return nil end
    if op == "open" and definition_id == "" then return nil end
    local thread_id: string? = nil
    if value.thread_id ~= nil then
        thread_id = thread_bounds.id(value.thread_id)
        if not thread_id or op ~= "open" then return nil end
    end
    if op == "close" and id == "" then return nil end
    if value.observer ~= nil and type(value.observer) ~= "boolean" then return nil end
    local observer: boolean? = nil
    if value.observer == true then observer = true end
    if op ~= "bind" and value.observer ~= nil then return nil end
    if op == "bind" and observer and (id == "" or instance_id == "") then return nil end
    local restore_instance = M.text(value.restore_instance_id or "", 80)
    local restore_view = M.text(value.restore_view_id or "", 80)
    local schema = M.text(value.resume_schema or "", 80)
    local state = value.resume_state or ""
    if not restore_instance or not restore_view or not schema or type(state) ~= "string" or #state > 65536 then return nil end
    if (restore_instance == "") ~= (restore_view == "") then return nil end
    local args = arguments.decode(value.arguments)
    if not args or (op ~= "open" and #args > 0) then return nil end
    return {version = 1, request_id = request_id, op = op, workspace_id = workspace_id, id = id, instance_id = instance_id, definition_id = definition_id, thread_id = thread_id, recipient = recipient,
        restore_instance_id = restore_instance, restore_view_id = restore_view, resume_schema = schema, resume_state = state, arguments = args, observer = observer}
end
function M.argument_fingerprint(values: {string}): string
    return arguments.fingerprint(values)
end
function M.reply(request_id: string, op: ReplyOp, code: string?, message: string?): Reply
    return {version = 1, request_id = request_id, op = op, id = "", instance_id = "", title = "", mount = "",
        error_code = code or "", error = message or "", definition_id = "", thread_id = nil, resume_schema = "", restart_policy = "never", resume_state = ""}
end
function M.descriptor(id: string, value: unknown): Descriptor?
    if type(value) ~= "table" or value.api_version ~= 1 or value.lifetime ~= "view" then return nil end
    local title, icon = M.text(value.title, 80), M.text(value.icon or "", 8)
    local revision, group, role = M.text(value.revision, 80), M.text(value.group or "", 160), M.text(value.role or "", 32)
    if not title or title == "" or not icon or not revision or revision == "" or not group or not role then return nil end
    if value.instance_policy ~= "singleton" and value.instance_policy ~= "multiple" then return nil end
    local schema = M.text(value.resume_schema or "", 80)
    local restart = value.restart_policy or "never"
    if not schema or (restart ~= "never" and restart ~= "automatic" and restart ~= "manual") then return nil end
    if restart ~= "never" and schema == "" then return nil end
    return {definition_id = id, definition_revision = revision, title = title, icon = icon, group = group,
        role = role, singleton = value.instance_policy == "singleton", resume_schema = schema, restart_policy = restart}
end
function M.binding(value: unknown): Binding?
    if type(value) ~= "table" or type(value.policies) ~= "table" then return nil end
    local id = M.text(value.definition_id, 160)
    if not id or id == "" then return nil end
    local policies: {string} = {}
    local count = 0
    for key in pairs(value.policies) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 or key > 8 then return nil end
        count = count + 1
    end
    for i = 1, count do
        local policy = M.text(value.policies[i], 160)
        if not policy or policy == "" then return nil end
        policies[#policies + 1] = policy
    end
    if value.appearance_write ~= nil and type(value.appearance_write) ~= "boolean" then return nil end
    if value.application_stop ~= nil and type(value.application_stop) ~= "boolean" then return nil end
    if value.catalog_read ~= nil and type(value.catalog_read) ~= "boolean" then return nil end
    return {definition_id = id, policies = policies, appearance_write = value.appearance_write == true,
        application_stop = value.application_stop == true, catalog_read = value.catalog_read == true}
end
return M
