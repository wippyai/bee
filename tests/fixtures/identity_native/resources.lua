-- MIT. The fixture host selects the executor used by the production library.
local M = {}
function M.executor(): (string?, string?)
    return "bee.identity_probe:executor", nil
end
return M
