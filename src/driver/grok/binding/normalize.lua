-- SPDX-License-Identifier: MIT
local universal = require("universal")
local acp = require("acp")
local bounds = require("bounds")
local normal = universal.normalize("bee.driver.grok.descriptor:cli")
local function handle(raw: unknown): unknown
    local input = bounds.object(raw)
    local context = input and bounds.object(input.context)
    local state = input and bounds.object(input.state)
    if (context and context.permission_exchange == true) or (state and state.acp == true) then return acp.normalize(raw) end
    if input then input.context = nil end
    return normal(raw)
end
return {handle = handle}
