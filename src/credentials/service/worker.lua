local funcs = require("funcs")
local logger = require("logger")
local worker = require("worker")
local backlog = require("backlog")
local M = {}
function M.main()
    worker.run({name = "bee.approvals.configuration_effect_worker", demand = true, pass = function(): boolean
        local problem, err = funcs.call("bee.credentials.binding:configuration_effects")
        if err or problem then logger:error("Configuration setup effect failed", {cause = tostring(err or problem)}); return false end
        return not backlog.pending()
    end})
end
return M
