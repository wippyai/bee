-- MIT. Spawn one admitted application execution on a broker-owned viewport.
local process = require("process")
local security = require("security")

type Launch = {
    definition_id: string,
    scope: security.Scope,
    workspace_pid: string,
    workspace_id: string,
    instance_id: string,
    view_id: string,
    definition_revision: string,
    registry_revision: string,
    launch_token: string,
    resume_schema: string,
    resume_state: string,
    arguments: {string},
}
type Result = {pid: string?, error_code: string, error: string}
local M = {}

function M.start(grant: string, launch: Launch): Result
    local pid, spawn_error = process.with_options({terminal = grant}):with_scope(launch.scope)
        :spawn_monitored(launch.definition_id, "bee:workers", {version = 1,
            broker_pid = tostring(process.pid()), workspace_pid = launch.workspace_pid,
            workspace_id = launch.workspace_id, instance_id = launch.instance_id,
            view_id = launch.view_id, definition_id = launch.definition_id,
            definition_revision = launch.definition_revision,
            registry_revision = launch.registry_revision, launch_token = launch.launch_token,
            resume_schema = launch.resume_schema, resume_state = launch.resume_state,
            arguments = launch.arguments})
    if not pid then return {error_code = "spawn_failed", error = tostring(spawn_error)} end
    return {pid = tostring(pid), error_code = "", error = ""}
end

return M
