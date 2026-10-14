-- SPDX-License-Identifier: MIT
local service = require("service")
local function handle(request: unknown): service.Reply
    return service.runtime_lease(request)
end
return {handle = handle}
