-- MIT. Shared bounded decoder for host and saved-profile instructions.
local bounds = require("bounds")
local M = {}
M.MAX_BYTES = 4096

function M.decode(value: unknown, label: string?, empty_allowed: boolean?): (string?, string?)
    if value == nil then
        if empty_allowed == true then return "", nil end
        return nil, nil
    end
    local name = label or "instructions"
    local text = bounds.text(value, M.MAX_BYTES)
    if not text or (text == "" and empty_allowed ~= true) then
        if empty_allowed == true then return nil, name .. " must contain at most " .. tostring(M.MAX_BYTES) .. " bytes" end
        return nil, name .. " must be nonempty text up to " .. tostring(M.MAX_BYTES) .. " bytes"
    end
    for index = 1, #text do
        local byte = text:byte(index)
        if (byte < 32 and byte ~= 9 and byte ~= 10 and byte ~= 13) or byte == 127 then
            return nil, name .. " contain unsupported control bytes"
        end
    end
    return text, nil
end

return M
