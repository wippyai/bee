-- SPDX-License-Identifier: MIT
-- The gateway reads the instant a suite pins in bee.tests.gateway:fixture_instant.
local registry = require("registry")
local time = require("time")
local hub_override = require("hub_override")
local M: {[string]: (unknown?) -> unknown} = {}
M["bee.gateway.security.publish_hub"] = function(): unknown return hub_override.publish end
M["bee.gateway.security.installation_hub"] = function(): unknown return hub_override.installation end
M["bee.gateway.binding.clock"] = function(): unknown
    local entry, problem = registry.get("bee.tests.gateway:fixture_instant")
    if not entry then error("gateway fixture instant: " .. tostring(problem)) end
    local value: unknown = entry.data
    assert(type(value) == "table", "gateway fixture instant")
    if value.at == nil then return nil end
    assert(type(value.at) == "string", "gateway fixture instant")
    return assert(time.parse("2006-01-02T15:04:05.000Z07:00", value.at)):unix_nano()
end

M["bee.gateway.service.external.drain_disabled"] = function(): unknown return true end
M["bee.gateway.service.backlog.disabled"] = function(): unknown return true end

return M
