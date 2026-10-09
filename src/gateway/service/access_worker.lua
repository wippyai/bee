local worker = require("worker")
local effects = require("effects")
local M = {}
function M.main()
    worker.run({name = "bee.gateway.access", demand = true, pass = effects.drain, active = effects.pending})
end
return M
