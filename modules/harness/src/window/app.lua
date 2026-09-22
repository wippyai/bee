-- SPDX-License-Identifier: MIT
-- Constructors stay in the app actor that owns the broker terminal grant.
-- The admitted placement binding selects one; the picker uses the same path.
local runtime = require("runtime")
local native = require("window")

return {main = function(value: unknown)
    return runtime.main(value, {
        ["bee.placement.native:binding"] = native.open,
    })
end}
