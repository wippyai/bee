local worker = require("worker")
local logger = require("logger")
local effects = require("effects")
local M = {}
function M.main()
    worker.run({name = "bee.gateway.access", demand = true, pass = function(): boolean
        local ok, result = pcall(effects.drain)
        if not ok then logger:error("Access effect failed", {cause = tostring(result)}); error(tostring(result)) end
        return result == true
    end, active = effects.pending})
end
return M
