-- MIT. Grok's ACP channel decodes its own frames; every other stream goes
-- through the codec the request's descriptor selects.
local universal = require("universal")
local acp = require("acp")
local bounds = require("bounds")
local function handle(raw: unknown): unknown
    local input = bounds.object(raw)
    local context = input and bounds.object(input.context)
    local state = input and bounds.object(input.state)
    if input and ((context and context.permission_exchange == true) or (state and state.acp == true)) then
        local request: {[string]: unknown} = {}
        for key, value in pairs(input) do
            if key ~= "descriptor_ref" then request[key] = value end
        end
        return acp.normalize(request)
    end
    if input then input.context = nil end
    return universal.normalize(raw)
end
return {handle = handle}
