-- SPDX-License-Identifier: MIT
-- Pure gateway address values, shared by admission and driver rendering.
-- Parsing an address grants no permission to bind or reach it.
local M = {}
function M.valid(value: unknown, allow_zero: boolean): boolean
    if type(value) ~= "string" then return false end
    local a, b, c, d, port_text = value:match("^(%d+)%.(%d+)%.(%d+)%.(%d+):(%d+)$")
    if not a or not b or not c or not d or not port_text then return false end
    for _, octet in ipairs({a, b, c, d}) do
        local number = tonumber(octet)
        if not number or number > 255 or tostring(number) ~= octet then return false end
    end
    local first, second = tonumber(a), tonumber(b)
    local private = first == 127 or first == 10 or (first == 172 and second ~= nil and second >= 16 and second <= 31)
        or (first == 192 and second == 168)
    if not private then return false end
    local port = tonumber(port_text)
    return port ~= nil and port >= (allow_zero and 0 or 1) and port <= 65535 and tostring(port) == port_text
end
function M.host_matches(value: unknown, address: string): boolean
    if not M.valid(address, false) or type(value) ~= "string" then return false end
    if value == address then return true end
    local port = address:match("^127%.0%.0%.1:(%d+)$")
    return port ~= nil and value == "localhost:" .. port
end
return M
