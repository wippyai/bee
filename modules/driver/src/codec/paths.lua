-- MIT. Read one descriptor-selected path from a provider JSON record.
local M = {}

type Object = {[string]: unknown}

function M.read(value: unknown, paths: Object?, name: string): unknown
    local raw_path = paths and paths[name] or nil
    if type(raw_path) ~= "table" then return nil end
    local path = raw_path :: {unknown}
    local current = value
    for _, segment in ipairs(path) do
        if type(segment) ~= "string" then return nil end
        if type(current) ~= "table" then return nil end
        current = (current :: Object)[segment :: string]
    end
    return current
end

return M
