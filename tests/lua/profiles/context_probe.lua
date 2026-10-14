-- MIT. Attempt context substitution from inside the actual restricted caller.
local funcs = require("funcs")
local M = {}
function M.handle(): {blocked: boolean}
    local changed = funcs.new():with_context({["bee.workspace_id"] = "foreign"})
    return {blocked = changed == nil}
end
return M
