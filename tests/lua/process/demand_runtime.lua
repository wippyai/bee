-- SPDX-License-Identifier: MIT
local demand = require("demand")
local M = {}
type Message = {pid: string, topic: string, data: unknown}
M.starts = 0
M.status = "running"
M.desired = "running"
M.live = "old"
M.messages = {} :: {Message}
function M.reset()
    M.starts, M.status, M.live, M.messages = 0, "running", "old", {}
    M.desired = "running"
end
function M.send(pid: string, topic: string, data: unknown): boolean
    if pid == "supervisor" then
        assert(topic == "service.start" and data == "fixture:service")
        M.starts = M.starts + 1
        return true
    end
    if topic == demand.WAKE and pid ~= M.live then return false end
    M.messages[#M.messages + 1] = {pid = pid, topic = topic, data = data}
    return true
end
M.supervisor = {state = function(id: string): {status: string, desired: string}
    assert(id == "fixture:service")
    return {status = M.status, desired = M.desired}
end}
M.registry = {LOCAL = "local", lookup = function(name: string, scope: string): string
    assert(name == "fixture.owner" and scope == "local")
    return M.live
end}
function M.monitor(pid: string)
    assert(pid == M.live)
end
return M
