-- SPDX-License-Identifier: MIT
-- The window constructor for each admitted placement binding. The Sessions
-- app and the retained presentation executor open windows through this table.
local native = require("window")
local docker = require("docker_window")
local M = {}
function M.constructors()
    return {
        ["bee.placement.native.binding:binding"] = native.open,
        ["bee.placement.docker.binding:binding"] = docker.open,
    }
end
return M
