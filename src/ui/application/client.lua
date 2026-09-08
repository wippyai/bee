-- Small application lifecycle adapter. No grants, registry access or UI framework.
local process = require("process")
local uuid = require("uuid")
local arguments = require("arguments")
local interaction = require("interaction")
local M = {}
type Launch = {version: integer, broker_pid: string, workspace_pid: string, instance_id: string,
    view_id: string, definition_id: string, definition_revision: string, registry_revision: string, launch_token: string, resume_schema: string, resume_state: string, arguments: {string}}
local function field(value: unknown, size: integer): string?
    if type(value) ~= "string" or value == "" or #value > size or value:find("%c") then return nil end
    return value
end
function M.launch(value: unknown): Launch?
    if type(value) ~= "table" or value.version ~= 1 then return nil end
    local broker, workspace = field(value.broker_pid, 160), field(value.workspace_pid, 160)
    local instance, view = field(value.instance_id, 80), field(value.view_id, 80)
    local definition, revision = field(value.definition_id, 160), field(value.definition_revision, 80)
    local registry_revision, token = field(value.registry_revision, 160), field(value.launch_token, 80)
    if not broker or not workspace or not instance or not view or not definition or not revision or not registry_revision or not token then return nil end
    local schema = type(value.resume_schema) == "string" and value.resume_schema or ""
    local state = type(value.resume_state) == "string" and value.resume_state or ""
    if #schema > 80 or #state > 65536 then return nil end
    local args = arguments.decode(value.arguments)
    if not args then return nil end
    return {version = 1, broker_pid = broker, workspace_pid = workspace, instance_id = instance,
        view_id = view, definition_id = definition, definition_revision = revision, registry_revision = registry_revision, launch_token = token, resume_schema = schema, resume_state = state, arguments = args}
end
type ReadyOptions = {negotiate_close: boolean?}
function M.ready(launch: Launch, options: ReadyOptions?)
    assert(process.send(launch.broker_pid, "bee.application.ready", {version = 1, instance_id = launch.instance_id,
        view_id = launch.view_id, launch_token = launch.launch_token, negotiate_close = options and options.negotiate_close == true or false}))
end
-- True means queued; it is not a persistence or presentation acknowledgement.
function M.title(launch: Launch, title: string): (boolean, string?)
    if #title > 80 or title:find("%c") then return false, "Invalid application title" end
    local sent, err = process.send(launch.broker_pid, "bee.application.title", {version = 1,
        instance_id = launch.instance_id, id = launch.view_id, launch_token = launch.launch_token, title = title})
    if not sent then return false, tostring(err) end
    return true, nil
end
type CloseRequest = {request_id: string}
function M.close_request(launch: Launch, sender: string, value: unknown): CloseRequest?
    if sender ~= launch.broker_pid or type(value) ~= "table" or value.version ~= 1
        or value.id ~= launch.view_id or value.instance_id ~= launch.instance_id then return nil end
    local request_id = field(value.request_id, 80)
    if not request_id then return nil end
    return {request_id = request_id}
end
function M.close_result(launch: Launch, sender: string, value: unknown): CloseRequest?
    if type(value) ~= "table" or value.action ~= "cancel" then return nil end
    return M.close_request(launch, sender, value)
end
type CloseDecision = {action: "accept" | "cancel" | "confirm", title: string?, message: string?, accept: string?}
function M.close_reply(launch: Launch, request_id: string, decision: CloseDecision): (boolean, string?)
    if not field(request_id, 80) then return false, "Invalid close request" end
    local title, message, accept = decision.title or "Close application?", decision.message or "", decision.accept or "Close"
    if decision.action == "confirm" and not interaction.spec({version = 1, request_id = request_id,
        id = launch.view_id, instance_id = launch.instance_id, kind = "confirm", title = title, message = message,
        accept = accept, initial = ""}) then return false, "Invalid confirmation" end
    local sent, err = process.send(launch.broker_pid, "bee.application.close.reply", {version = 1,
        request_id = request_id, id = launch.view_id, instance_id = launch.instance_id, launch_token = launch.launch_token,
        action = decision.action, title = title, message = message, accept = accept})
    if not sent then return false, tostring(err) end
    return true, nil
end
type Query = {kind: interaction.Kind, title: string, message: string?, accept: string?, initial: string?}
-- Listen for bee.application.query.result before sending; success means queued.
function M.query(launch: Launch, options: Query): (string?, string?)
    local request_id = uuid.v7()
    local spec = interaction.spec({version = 1, request_id = request_id, id = launch.view_id,
        instance_id = launch.instance_id, kind = options.kind, title = options.title,
        message = options.message or "", accept = options.accept or "Continue", initial = options.initial or ""})
    if not spec then return nil, "Invalid interaction" end
    local sent, err = process.send(launch.broker_pid, "bee.application.query", {version = 1,
        launch_token = launch.launch_token, request_id = request_id, id = spec.id, instance_id = spec.instance_id,
        kind = spec.kind, title = spec.title, message = spec.message, accept = spec.accept, initial = spec.initial})
    if not sent then return nil, tostring(err) end
    return request_id, nil
end
type QueryResult = {request_id: string, action: "accept" | "cancel", value: string, error: string}
function M.query_result(launch: Launch, sender: string, value: unknown): QueryResult?
    if sender ~= launch.broker_pid or type(value) ~= "table" then return nil end
    local response = interaction.response(value)
    if not response or response.id ~= launch.view_id or response.instance_id ~= launch.instance_id then return nil end
    local error_code = value.error
    if error_code ~= "" and error_code ~= "busy" then return nil end
    return {request_id = response.request_id, action = response.action, value = response.value, error = error_code}
end
function M.checkpoint(launch: Launch, state: string): (string?, string?)
    if launch.resume_schema == "" or #state > 65536 then return nil, "Checkpoint unsupported or too large" end
    local request_id = uuid.v7()
    local sent, err = process.send(launch.broker_pid, "bee.application.checkpoint", {version = 1, request_id = request_id,
        instance_id = launch.instance_id, id = launch.view_id, launch_token = launch.launch_token,
        resume_schema = launch.resume_schema, resume_state = state})
    if not sent then return nil, tostring(err) end
    return request_id, nil
end
return M
