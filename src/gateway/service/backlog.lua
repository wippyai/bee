-- SPDX-License-Identifier: MIT
local effects = require("effects")
local seam = require("seam")
local function pending(): boolean
    if seam.call("bee.gateway.service.backlog.disabled") == true then return false end
    return effects.pending()
end
return {pending = pending}
