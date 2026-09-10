-- MIT. Supervisor-selected authority for an exact client execution.
local contract = require("contract")
local decode = require("decode")
local inventory = require("inventory")
local appearance = require("appearance")
type Result = {version: integer, reply: contract.Reply, views: inventory.Views}
type Permissions = {open: boolean, close: boolean, control: boolean, appearance: boolean?, workspace_appearance: boolean?}
type ControlOp = "admit" | "detach" | "render"
type Client = {recipient: string, connection_id: string, permissions: Permissions, detaching: boolean,
    renderer: string, renderer_generation: string, rendering: boolean}
type Control = {request_id: string, workspace_id: string, op: ControlOp, recipient: string, permissions: Permissions?, renderer: string}
type AppearanceOp = "state" | "set"
type AppearanceRequest = {version: integer, request_id: string, op: "appearance", action: AppearanceOp,
    recipient: string, theme: string, background: string, taskbar: string}
type ClientAppearanceRequest = {version: integer, request_id: string, action: AppearanceOp,
    workspace_id: string, connection_id: string, renderer: string, renderer_generation: string,
    theme: string, background: string, taskbar: string}
type AppearanceResult = {version: integer, request_id: string, action: AppearanceOp,
    workspace_id: string, connection_id: string, renderer: string, renderer_generation: string,
    revision: integer, theme: string, background: string, taskbar: string, error_code: string, error: string}
local M = {}
-- A bounded full snapshot makes an operation result self-contained even when
-- its independent inventory channel is consumed before or after the result.
function M.result(value: unknown): Result?
    if type(value) ~= "table" or value.version ~= 1 then return nil end
    local reply, views = decode.reply(value.reply), inventory.views(value.views)
    if not reply or not views or reply.workspace_id ~= views.workspace_id then return nil end
    return {version = 1, reply = reply, views = views}
end
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
        if data.appearance ~= nil and type(data.appearance) ~= "boolean" then return nil end
        if data.workspace_appearance ~= nil and type(data.workspace_appearance) ~= "boolean" then return nil end
        if data.workspace_appearance == true and data.appearance ~= true then return nil end
        permissions = {open = data.open, close = data.close, control = data.control,
            appearance = data.appearance == true, workspace_appearance = data.workspace_appearance == true}
    end
    return {request_id = request_id, workspace_id = workspace_id, op = op, recipient = recipient, permissions = permissions, renderer = renderer}
end
function M.same_permissions(left: Permissions, right: Permissions): boolean
    return left.open == right.open and left.close == right.close and left.control == right.control
        and left.appearance == right.appearance and left.workspace_appearance == right.workspace_appearance
end
function M.allowed(client: Client, request: contract.Request): boolean
    if client.detaching then return false end
    -- Recovery/import values belong to the host, not to an attached desktop.
    if request.restore_instance_id ~= "" or request.restore_view_id ~= "" or request.resume_schema ~= "" or request.resume_state ~= "" then return false end
    if request.op == "open" then return client.permissions.open end
    if request.op == "close" then return client.permissions.close and request.id ~= "" and request.instance_id ~= "" end
    if request.op == "bind" then
        return not client.rendering and client.renderer ~= "" and request.id ~= "" and request.instance_id ~= ""
            and (request.recipient == "" or request.recipient == client.recipient)
    end
    return false
end

local function action(value: unknown): AppearanceOp?
    if value == "state" then return "state" end
    if value == "set" then return "set" end
    return nil
end

local function preferences(value: table): appearance.Preferences?
    return appearance.decode({theme = value.theme, background = value.background, taskbar = value.taskbar})
end

-- Broker-to-host appearance requests carry the recipient derived from the
-- broker's live attachment record. An empty recipient is the legacy combined
-- launcher path and is intentionally left for the workspace owner.
function M.appearance(value: unknown): AppearanceRequest?
    if type(value) ~= "table" or value.version ~= 1 or value.op ~= "appearance" then return nil end
    local request_id = contract.text(value.request_id, 80)
    local recipient = contract.text(value.recipient or "", 160)
    local selected = action(value.action or "set")
    local prefs = preferences(value)
    if not request_id or request_id == "" or not recipient or not selected or not prefs then return nil end
    return {version = 1, request_id = request_id, op = "appearance", action = selected, recipient = recipient,
        theme = prefs.theme, background = prefs.background, taskbar = prefs.taskbar or "labels"}
end

-- Host-to-client appearance requests include every live admission identity.
-- The stable client owner is the message recipient; the renderer fields fence
-- a request that raced a presenter replacement.
function M.client_appearance(value: unknown): ClientAppearanceRequest?
    if type(value) ~= "table" or value.version ~= 1 then return nil end
    local request_id = contract.text(value.request_id, 80)
    local workspace_id = contract.workspace_id(value.workspace_id)
    local connection_id = contract.text(value.connection_id, 80)
    local renderer = contract.text(value.renderer, 160)
    local renderer_generation = contract.text(value.renderer_generation, 80)
    local selected = action(value.action)
    local prefs = preferences(value)
    if not request_id or request_id == "" or not workspace_id or not connection_id or connection_id == ""
        or not renderer or renderer == "" or not renderer_generation or renderer_generation == ""
        or not selected or not prefs then return nil end
    return {version = 1, request_id = request_id, action = selected, workspace_id = workspace_id,
        connection_id = connection_id, renderer = renderer, renderer_generation = renderer_generation,
        theme = prefs.theme, background = prefs.background, taskbar = prefs.taskbar or "labels"}
end

function M.appearance_result(value: unknown): AppearanceResult?
    if type(value) ~= "table" or value.version ~= 1 then return nil end
    local request_id = contract.text(value.request_id, 80)
    local workspace_id = contract.workspace_id(value.workspace_id)
    local connection_id = contract.text(value.connection_id, 80)
    local renderer = contract.text(value.renderer, 160)
    local renderer_generation = contract.text(value.renderer_generation, 80)
    local selected = action(value.action)
    local revision = value.revision
    local prefs = preferences(value)
    local error_code = contract.text(value.error_code, 80)
    local error_text = value.error
    if not request_id or request_id == "" then return nil end
    if not workspace_id then return nil end
    if not connection_id or connection_id == "" then return nil end
    if not renderer or renderer == "" then return nil end
    if not renderer_generation or renderer_generation == "" then return nil end
    if not selected then return nil end
    if type(revision) ~= "number" then return nil end
    if revision < 0 or revision > 9007199254740990 or revision ~= math.floor(revision) then return nil end
    if not prefs or not error_code then return nil end
    if type(error_text) ~= "string" then return nil end
    if #error_text > 4096 then return nil end
    local checked: appearance.Preferences = prefs
    local checked_revision: integer = math.floor(revision)
    return {version = 1, request_id = request_id, action = selected, workspace_id = workspace_id,
        connection_id = connection_id, renderer = renderer, renderer_generation = renderer_generation,
        revision = checked_revision, theme = checked.theme, background = checked.background,
        taskbar = checked.taskbar or "labels", error_code = error_code, error = error_text}
end
return M
