-- MIT. Supervisor-selected authority for an exact client execution.
local contract = require("contract")
type Permissions = {open: boolean, close: boolean, control: boolean}
type ControlOp = "admit" | "detach" | "render"
type Client = {recipient: string, connection_id: string, permissions: Permissions, detaching: boolean,
    renderer: string, renderer_generation: string, rendering: boolean}
type Control = {request_id: string, workspace_id: string, op: ControlOp, recipient: string, permissions: Permissions?, renderer: string}
local M = {}
local function control_op(value: unknown): ControlOp?
    if value == "admit" then return "admit" end
    if value == "detach" then return "detach" end
    if value == "render" then return "render" end
    return nil
end
function M.control(value: unknown): Control?
    if type(value) ~= "table" or value.version ~= 1 then return nil end
    local request_id = contract.text(value.request_id, 80)
    local workspace_id = contract.workspace_id(value.workspace_id)
    local recipient = contract.text(value.recipient, 160)
    if not request_id or request_id == "" or not workspace_id or not recipient or recipient == "" then return nil end
    local op = control_op(value.op)
    if not op then return nil end
    local renderer = ""
    if op == "render" then
        local selected = contract.text(value.renderer, 160)
        if not selected then return nil end
        renderer = selected
    end
    local permissions: Permissions? = nil
    if op == "admit" then
        local data = value.permissions
        if type(data) ~= "table" or type(data.open) ~= "boolean" or type(data.close) ~= "boolean"
            or type(data.control) ~= "boolean" then return nil end
        permissions = {open = data.open, close = data.close, control = data.control}
    end
    return {request_id = request_id, workspace_id = workspace_id, op = op, recipient = recipient, permissions = permissions, renderer = renderer}
end
function M.same_permissions(left: Permissions, right: Permissions): boolean
    return left.open == right.open and left.close == right.close and left.control == right.control
end
function M.allowed(client: Client, request: contract.Request): boolean
    if client.detaching then return false end
    -- Recovery/import values belong to the host, not to an attached desktop.
    if request.restore_instance_id ~= "" or request.restore_view_id ~= "" or request.resume_schema ~= "" or request.resume_state ~= "" then return false end
    if request.op == "open" then return client.permissions.open end
    if request.op == "close" then return client.permissions.close end
    if request.op == "bind" then
        return client.permissions.control and not client.rendering and client.renderer ~= "" and request.id ~= "" and request.instance_id ~= ""
            and (request.recipient == "" or request.recipient == client.recipient)
    end
    return false
end
return M
