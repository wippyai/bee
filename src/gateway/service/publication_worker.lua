-- SPDX-License-Identifier: MIT
local logger = require("logger")
local effect = require("publish")
local function main(): {ok: boolean, count: integer}
    local called, count, problem = pcall(effect.drain_approved)
    if called and not problem then return {ok = true, count = count} end
    logger:error("Gateway publication drain failed", {cause = tostring(called and problem or count)})
    return {ok = false, count = 0}
end

return {main = main}
