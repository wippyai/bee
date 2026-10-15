-- MIT. Validated actor and native node identities for authority boundaries.
local security = require("security")
local system = require("system")
local bounds = require("bounds")
local M = {}
function M.actor(): string?
    local current = security.actor()
    if not current then return nil end
    return bounds.id(current:id())
end
function M.node(): (string?, string?)
    local id, err = system.node.id()
    if err then return nil, "node identity is unavailable" end
    local decoded = bounds.id(id)
    if not decoded then return nil, "node identity is invalid" end
    return decoded, nil
end
return M
