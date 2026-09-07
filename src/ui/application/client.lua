-- Small application lifecycle adapter. No grants, registry access or UI framework.
local process = require("process")
local uuid = require("uuid")
local arguments = require("arguments")
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
function M.ready(launch: Launch)
    assert(process.send(launch.broker_pid, "bee.application.ready", {version = 1, instance_id = launch.instance_id,
        view_id = launch.view_id, launch_token = launch.launch_token}))
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
