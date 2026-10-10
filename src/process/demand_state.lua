-- SPDX-License-Identifier: MIT
local M = {}
type Owner = {phase: string, pid: string?, generation: integer, drained: integer,
    pending: boolean, start_epoch: number?}
type Snapshot = {status: string, desired: string, started: number?, holder: string?}
M.Owner = Owner
M.Snapshot = Snapshot
function M.new(): Owner
    return {phase = "absent", pid = nil, generation = 0, drained = -1, pending = false}
end

-- Terminal snapshots acknowledge lifecycle commands; a PID's EXIT alone does
-- not acknowledge a stop or make the runtime supervisor able to accept a start.
-- started_at identifies an executed start; last_update also changes when a
-- terminal controller updates its details with a start command still queued.
function M.transition(owner: Owner, event: string, pid: string?, generation: integer?, current: Snapshot?): string
    local terminal = current and (current.status == "stopped" or current.status == "exited" or current.status == "unknown")
    if terminal then
        local completed = owner.phase == "recovering"
            or (owner.phase == "stopping" and current.desired == "stopped")
            or (owner.phase == "starting" and current.started ~= nil and current.started ~= owner.start_epoch)
            or (owner.phase == "ready" and current.holder ~= owner.pid)
        if completed then owner.phase, owner.pid = "absent", nil end
    end
    local action = "wait"
    if event == "wake" then
        owner.generation = owner.generation + 1
        owner.pending = true
        if owner.phase == "ready" then action = "deliver" end
    elseif event == "ready" then
        if owner.phase ~= "stopping" then
            owner.phase, owner.pid = "ready", pid
            action = "deliver"
        end
    elseif event == "quiet" then
        if owner.phase == "ready" and owner.pid == pid then
            if owner.generation == generation then
                owner.drained, owner.phase, owner.pending = owner.generation, "stopping", false
                action = "stop"
            else action = "deliver" end
        end
    elseif event == "exit" then
        if owner.pid == pid and owner.phase ~= "stopping" then
            owner.pid, owner.phase = nil, terminal and "absent" or "recovering"
        end
    elseif event == "failed" then
        owner.pid, owner.phase, owner.pending = nil, terminal and "absent" or "recovering", true
    elseif event == "delivered" then
        owner.pending = false
    elseif event == "batch" then
        owner.generation = owner.generation + 1
    elseif event == "stopped" then
        owner.pid, owner.phase = nil, "absent"
        owner.pending = owner.pending or owner.drained ~= owner.generation
    end
    if owner.phase == "absent" and owner.pending then
        if not current or terminal then
            owner.phase = "starting"
            owner.start_epoch = current and current.started or nil
            return "start"
        end
        owner.phase = "recovering"
    end
    return action
end
function M.wake(owner: Owner): string
    return M.transition(owner, "wake", nil, nil, nil)
end
function M.ready(owner: Owner, pid: string): integer?
    if M.transition(owner, "ready", pid, nil, nil) ~= "deliver" then return nil end
    M.transition(owner, "delivered", nil, nil, nil)
    return owner.generation
end
function M.quiet(owner: Owner, pid: string, generation: integer): boolean
    return M.transition(owner, "quiet", pid, generation, nil) == "stop"
end
function M.stopped(owner: Owner): string
    return M.transition(owner, "stopped", nil, nil, nil)
end
return M
