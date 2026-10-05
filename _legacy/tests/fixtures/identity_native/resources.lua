-- MIT. The fixture host selects the executor used by the production library.
local M = {}
function M.executor(): (string?, string?)
    return "bee.identity.probe:executor", nil
end
return M
