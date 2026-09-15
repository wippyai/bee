-- SPDX-License-Identifier: MIT
-- Constructors stay in the app actor that owns the broker terminal grant.
-- The admitted placement binding selects one; the picker uses the same path.
local runtime = require("runtime")
local native = require("window")
local docker = require("docker_window")

return {main = function(value: unknown)
    return runtime.main(value, {
        ["bee.placement.native:binding"] = native.open,
        ["bee.placement.docker:binding"] = docker.open,
    })
end}
