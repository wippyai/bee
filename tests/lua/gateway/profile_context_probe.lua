-- SPDX-License-Identifier: MIT
local ctx = require("ctx")
local bounds = require("bounds")
local function handle(): {[string]: unknown}
    return assert(bounds.object(ctx.get("bee.gateway.binding")))
end
return {handle = handle}
