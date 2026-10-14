-- MIT. One pass of the activation worker, which the suites run themselves
-- while the worker service stays stopped.
local pass = require("pass")

local function drain(): {pass.Outcome}
    local outcomes, pass_error = pass.run()
    if not outcomes then error(tostring(pass_error)) end
    return outcomes
end

return {drain = drain, pending = pass.pending}
