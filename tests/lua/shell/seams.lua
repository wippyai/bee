-- SPDX-License-Identifier: MIT
local process = require("process")
local controllers = require("controllers")

return {
    ["bee.shell.jobs.operation"] = function(payload)
        local request = payload :: {op: string, id: unknown}
        return controllers.registered("bee.test.retired." .. request.op, "bee.test.retired.release", "bee.test.retired.held")
    end,
    ["bee.shell.shell.node_event"] = function(payload)
        if (payload :: {kind: string}).kind ~= "closed" then return nil end
        controllers.notify("bee.test.retired.closed")
        return process.registry.lookup("bee.test.retired.drop", process.registry.LOCAL) ~= nil
    end,
    ["bee.shell.shell.applied"] = function(kind)
        if kind == "failed" or kind == "retired" or kind == "done" then
            controllers.notify("bee.test.retired.applied", nil, {kind = kind})
        end
        return nil
    end,
}
