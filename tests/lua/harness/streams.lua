-- MIT. Carrier output collection for protocol assertions.
local M = {}
function M.read_all(stream): string
    local content = ""
    while true do
        local chunk: unknown = stream:read(65536)
        if type(chunk) ~= "string" or chunk == "" then break end
        content = content .. (chunk)
    end
    return content
end
return M
