-- SPDX-License-Identifier: MIT
local demand = require("demand")
local M = {}
type Message = {pid: string, topic: string, data: unknown}
M.model = false :: boolean
M.deferred = false :: boolean
M.stop_pending = false :: boolean
M.outstanding = 0 :: integer
M.revision = 1 :: integer
M.started = 1 :: integer
M.starts = 0 :: integer
M.status = "running" :: string
M.desired = "running" :: string
M.live = "old" :: string
M.messages = {} :: {Message}
M.fail_at = 0 :: integer
M.wakes = 0 :: integer
function M.launch()
    M.live = "replacement-" .. tostring(M.starts)
    M.status, M.desired = "running", "running"
    M.revision = M.revision + 1
    M.started = M.revision
end
function M.finish_stop()
    if M.live == "" and M.desired == "stopped" and (M.status == "stopped" or M.status == "exited") then
        M.stop_pending = false
        return
    end
    local revision = M.revision + 1
    M.live, M.status, M.desired = "", "stopped", "stopped"
    M.revision = revision
    M.stop_pending = false
end
function M.pump()
    if not M.deferred then return end
    if M.stop_pending then M.finish_stop()
    elseif M.outstanding > 0 and M.live == "" and (M.status == "stopped" or M.status == "exited" or M.status == "unknown") then M.launch() end
end
function M.reset()
    M.model, M.deferred, M.stop_pending = false, false, false
    M.fail_at, M.wakes = 0, 0
    M.starts, M.status, M.live, M.messages = 0, "running", "old", {}
    M.desired, M.outstanding, M.revision, M.started = "running", 0, 1, 1
end
function M.send(pid: string, topic: string, data: unknown): boolean
    if pid == "supervisor" then
        assert(data == "fixture:service")
        if topic == "service.stop" then
            if M.deferred then M.stop_pending = true else M.finish_stop() end
            return true
        end
        assert(topic == "service.start")
        M.starts = M.starts + 1
        if M.model then
            M.outstanding = M.outstanding + 1
            if not M.deferred and (M.status == "stopped" or M.status == "exited" or M.status == "unknown") then M.launch() end
        end
        return true
    end
    if topic == demand.WAKE then
        M.wakes = M.wakes + 1
        if M.wakes == M.fail_at then M.live = "" end
        if pid ~= M.live then return false end
    end
    M.messages[#M.messages + 1] = {pid = pid, topic = topic, data = data}
    return true
end
M.supervisor = {state = function(id: string): {status: string, desired: string, last_update: number, started_at: number}
    assert(id == "fixture:service")
    return {status = M.status, desired = M.desired, last_update = M.revision, started_at = M.started}
end}
M.registry = {LOCAL = "local", lookup = function(name: string, scope: string): string?
    assert(name == "fixture.owner" and scope == "local")
    return M.live ~= "" and M.live or nil
end}
function M.monitor(pid: string)
    assert(pid == M.live)
end
return M
