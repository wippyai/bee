-- SPDX-License-Identifier: MIT
local funcs = require("funcs")
local bounds = require("bounds")
local M = {}
local LUA: {[string]: boolean} = {["function.lua"] = true, ["library.lua"] = true,
    ["process.lua"] = true, ["workflow.lua"] = true}

function M.check(entry: {[string]: unknown}): string?
    if type(entry.kind) ~= "string" or not LUA[entry.kind] then return nil end
    local data = bounds.object(entry.data) or entry
    if type(data.source) ~= "string" or data.source == "" then return nil end
    local result, problem = funcs.call("bee.gov.binding:source_load", {id = entry.id, source = data.source})
    if problem then return tostring(problem) end
    if type(result) == "string" then return result end
    if result ~= true then return "Lua source checker returned no verdict" end
    return nil
end

return M
