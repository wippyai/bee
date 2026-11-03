-- MIT. A shipped driver's methods called as a host calls them: the binding's
-- declared method, with a request that names the binding's descriptor, and
-- configure receiving the descriptor's declaration.
local registry = require("registry")
local funcs = require("funcs")
local M = {}
type Object = {[string]: unknown}

function M.ref(provider: string): string
    return "bee.drivers." .. provider .. ".descriptor:cli"
end

local function target(provider: string, method: string): string
    local binding = assert(registry.get("bee.drivers." .. provider .. ".binding:binding"))
    for _, raw in ipairs((binding.data :: Object).contracts :: {Object}) do
        local methods = raw.methods :: {[string]: string}
        if methods[method] then return methods[method] end
    end
    error("bee.drivers." .. provider .. " binds no " .. method)
end

local function with(request: unknown, name: string, value: unknown): Object
    local copy: Object = {}
    if type(request) == "table" then
        for key, item in pairs(request :: Object) do copy[key] = item end
    end
    copy[name] = value
    return copy
end

function M.declaration(provider: string): Object
    local entry = assert(registry.get(M.ref(provider)))
    return entry.data :: Object
end

local function method(provider: string, name: string, field: string, value: () -> unknown): {handle: (unknown) -> any}
    return {handle = function(request: unknown): any
        local reply, err = funcs.call(target(provider, name), with(request, field, value()))
        if err then error(tostring(err)) end
        return reply
    end}
end

function M.prepare(provider: string): {handle: (unknown) -> any}
    return method(provider, "prepare", "descriptor_ref", function(): unknown return M.ref(provider) end)
end

function M.dispatch(provider: string): {handle: (unknown) -> any}
    return method(provider, "dispatch", "descriptor_ref", function(): unknown return M.ref(provider) end)
end

function M.normalize(provider: string): {handle: (unknown) -> any}
    return method(provider, "normalize", "descriptor_ref", function(): unknown return M.ref(provider) end)
end

function M.configure(provider: string): {handle: (unknown) -> any}
    return method(provider, "configure", "descriptor", function(): unknown return M.declaration(provider) end)
end

return M
