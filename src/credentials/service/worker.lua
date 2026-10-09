local funcs = require("funcs")
local logger = require("logger")
local worker = require("worker")
local M = {}
function M.main()
    worker.run({name = "bee.approvals.configuration_effect_worker", wake = "bee.approvals.wake", pass = function(): boolean
        local problem, err = funcs.call("bee.credentials.binding:configuration_effects")
        if err or problem then logger:error("Configuration setup effect failed", {cause = tostring(err or problem)}); return false end
        return true
    end})
end
return M
