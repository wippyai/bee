-- SPDX-License-Identifier: MIT
-- Host-staged, fixed documents. No paths or registry references come from MCP.
local registry = require("registry")
local function handle(value: unknown): {[string]: unknown}
    if type(value) ~= "table" or type(value.topic) ~= "string" then error("expected a document topic") end
    for key in pairs(value) do if key ~= "topic" then error("unknown document argument") end end
    local entry = registry.get("bee.agent.app.probe:material")
    if not entry or type(entry.data) ~= "table" then error("authoring material unavailable") end
    local content = entry.data[value.topic]
    if type(content) ~= "string" then error("unknown authoring document") end
    return {ok = true, value = {topic = value.topic, content = content}}
end
return {handle = handle}
