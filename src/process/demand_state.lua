-- SPDX-License-Identifier: MIT
local M = {}
type Owner = {phase: string, pid: string?, generation: integer, drained: integer}
M.Owner = Owner
function M.new(): Owner
    return {phase = "absent", pid = nil, generation = 0, drained = -1}
end
function M.wake(owner: Owner): string
    owner.generation = owner.generation + 1
    if owner.phase == "absent" then owner.phase = "starting"; return "start" end
    return owner.phase == "ready" and "deliver" or "wait"
end
function M.ready(owner: Owner, pid: string): integer?
    if owner.phase == "stopping" then return nil end
    owner.phase, owner.pid = "ready", pid
    return owner.generation
end
function M.quiet(owner: Owner, pid: string, generation: integer): boolean
    if owner.phase ~= "ready" or owner.pid ~= pid or owner.generation ~= generation then return false end
    owner.drained, owner.phase = generation, "stopping"
    return true
end
function M.stopped(owner: Owner): string
    owner.pid = nil
    if owner.drained ~= owner.generation then owner.phase = "starting"; return "start" end
    owner.phase = "absent"
    return "wait"
end
return M
