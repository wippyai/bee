-- SPDX-License-Identifier: MIT
local runner = require("eval_runner")
local bounds = require("bounds")
local function check(raw: unknown): unknown
    local entry = bounds.object(raw)
    if not entry or type(entry.id) ~= "string" or type(entry.source) ~= "string" then
        return "Lua source check identity is invalid"
    end
    local program, problem = runner.compile(entry.source, "")
    if program then return true end
    local message = tostring(problem)
    local id: string = entry.id
    message = message:gsub("eval:(%d+):(%d+):", function(line: string, column: string): string
        return id .. ":" .. line .. ":" .. column .. ":"
    end)
    if message:find("eval at EOF:", 1, true) then
        local line = 1
        for _ in entry.source:gmatch("\n") do line = line + 1 end
        local tail = entry.source:match("[^\n]*$") or ""
        local location = id .. ":" .. tostring(line) .. ":" .. tostring(#tail + 1) .. ":"
        message = message:gsub("eval at EOF:", function(): string return location end)
    end
    return message
end
return {check = check}
