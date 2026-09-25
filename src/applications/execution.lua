-- MIT. Spawn and stop admitted application executions on broker-owned viewports.
local process = require("process")
local security = require("security")
local channel = require("channel")
local time = require("time")

type Launch = {
    definition_id: string,
    scope: security.Scope,
    actor: security.Actor,
    workspace_pid: string,
    workspace_id: string,
    instance_id: string,
    view_id: string,
    thread_id: string?,
    execution_generation: integer,
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
    local pid, spawn_error = process.with_options({terminal = grant}):with_actor(launch.actor):with_scope(launch.scope)
        :spawn_monitored(launch.definition_id, "bee:workers", {version = 1,
            broker_pid = tostring(process.pid()), workspace_pid = launch.workspace_pid,
            workspace_id = launch.workspace_id, instance_id = launch.instance_id,
            view_id = launch.view_id, definition_id = launch.definition_id, thread_id = launch.thread_id,
            execution_generation = launch.execution_generation,
            definition_revision = launch.definition_revision,
            registry_revision = launch.registry_revision, launch_token = launch.launch_token,
            resume_schema = launch.resume_schema, resume_state = launch.resume_state,
            arguments = launch.arguments})
    if not pid then return {error_code = "spawn_failed", error = tostring(spawn_error)} end
    return {pid = tostring(pid), error_code = "", error = ""}
end

-- stop ends monitored executions whose EXIT has not yet been received on
-- events. Each receives CANCEL first, so it can stop what it owns, such as a
-- PTY child it must reap. An execution still running after grace is
-- terminated. EXIT events alone decide completion; stop returns once every
-- pid has one. Missing authority to cancel or terminate is a defect of the
-- caller's policy and raises.
function M.stop(pids: {string}, events: Channel<process.Event>, grace: string)
    local live: {[string]: boolean} = {}
    local remaining = 0
    for _, pid in ipairs(pids) do
        if not live[pid] then
            live[pid] = true
            remaining = remaining + 1
            -- A cancel that reaches no process finds one whose EXIT is pending.
            local _, cancel_error = process.cancel(pid, "owner stopping")
            if cancel_error and cancel_error:kind() == errors.PERMISSION_DENIED then
                error("Stop execution " .. pid .. ": " .. tostring(cancel_error))
            end
        end
    end
    local deadline = time.after(grace)
    local escalated = false
    while remaining > 0 do
        local cases = {events:case_receive()}
        if not escalated then cases[2] = deadline:case_receive() end
        local selected = channel.select(cases)
        if not selected.ok then error("Execution events closed while stopping") end
        if selected.channel == events then
            local event = selected.value :: process.Event
            local from = tostring(event.from)
            if event.kind == process.event.EXIT and live[from] then
                live[from] = nil
                remaining = remaining - 1
            end
        else
            escalated = true
            for pid in pairs(live) do
                local _, terminate_error = process.terminate(pid)
                if terminate_error and terminate_error:kind() == errors.PERMISSION_DENIED then
                    error("Terminate execution " .. pid .. ": " .. tostring(terminate_error))
                end
            end
        end
    end
end

return M
