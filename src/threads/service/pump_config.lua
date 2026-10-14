-- MIT. The pumping choice a Threads owner entry declares.
local registry = require("registry")

local M = {}

-- Forwarding pumps run unless an owner entry declares pump: false.
function M.enabled(): (boolean?, string?)
    local owners, find_error = registry.find({["meta.type"] = "bee.threads.owner"})
    if not owners then return nil, "read threads owner configuration: " .. tostring(find_error) end
    for _, entry in ipairs(owners) do
        if type(entry.meta) == "table" and entry.meta.pump == false then return false, nil end
    end
    return true, nil
end

return M
