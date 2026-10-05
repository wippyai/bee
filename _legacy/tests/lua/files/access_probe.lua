-- MIT. Exercise filesystem acquisition inside a caller-selected test scope.
local fs = require("fs")
local function acquire(resource: string): boolean
    local volume = fs.get(resource)
    return volume ~= nil
end
return {acquire = acquire}
