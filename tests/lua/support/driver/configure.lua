-- MIT. A shipped driver's configure method called as the host calls it: the
-- request carries the declaration of the binding's CLI descriptor.
local registry = require("registry")
local M = {}
type Object = {[string]: unknown}
type Method = {handle: (unknown) -> Object}

function M.declaration(provider: string): Object
    local entry = assert(registry.get("bee.drivers." .. provider .. ".descriptor:cli"))
    return entry.data :: Object
end

function M.of(provider: string, method: Method): Method
    return {handle = function(request: unknown): Object
        local described: Object = {}
        if type(request) == "table" then
            for key, value in pairs(request :: Object) do described[key] = value end
        end
        described.descriptor = M.declaration(provider)
        return method.handle(described)
    end}
end

return M
