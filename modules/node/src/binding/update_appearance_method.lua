-- SPDX-License-Identifier: MIT
local service = require("service")
local function handle(request: unknown)
    return service.update_appearance(request)
end
return {handle = handle}
