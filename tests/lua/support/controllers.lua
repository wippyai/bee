-- SPDX-License-Identifier: MIT
-- Hold specifications for bee.process:seam points whose controller opts in
-- by registering a local process name.
local process = require("process")
local M = {}

type Hold = {controller: string, report: string?, release: string, payload: unknown?}

function M.registered(name: string, release: string, report: string?, payload: unknown?): Hold?
    local controller = process.registry.lookup(name, process.registry.LOCAL)
    if not controller then return nil end
    return {controller = tostring(controller), report = report or name, release = release, payload = payload}
end

function M.notify(name: string, topic: string?, payload: unknown?)
    local observer = process.registry.lookup(name, process.registry.LOCAL)
    if observer then assert(process.send(tostring(observer), topic or name, payload or {})) end
end

return M
