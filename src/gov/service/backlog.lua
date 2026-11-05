-- SPDX-License-Identifier: MIT
local pass = require("pass")
local service = require("service")
local seam = require("seam")
local function pending(): boolean
    if seam.call("bee.gov.service.backlog.disabled") == true then return false end
    return pass.pending() or service.following_pending()
end
return {pending = pending}
