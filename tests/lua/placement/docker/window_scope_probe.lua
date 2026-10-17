-- SPDX-License-Identifier: MIT
local profile_home = require("profile_home")
local exec = require("exec")
local M = {}
function M.run(_: unknown): {[string]: unknown}
    local ref, err = profile_home.executor("bee.tests.placement.docker:executor", "bee-home-window-scope")
    if not ref then return {error = err} end
    local executor, executor_error = exec.get(ref)
    if not executor then return {error = "Docker executor unavailable: " .. tostring(executor_error)} end
    return {ref = ref}
end
return M
