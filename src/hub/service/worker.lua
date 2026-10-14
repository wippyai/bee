-- MIT. One short-lived publisher owns Bee Hub's local operation name and
-- returns the operation result as its exit value. Native registration
-- releases the name if this process dies.
local process = require("process")
local security = require("security")
local publication = require("publication")
local bounds = require("bounds")
local hub_result = require("hub_result")
local NAME = "bee.hub.publisher"
local function main(request: unknown, expected: string): hub_result.Result
    if not security.can("bee.hub.execute", "bee.hub.service:worker") then error("Hub worker is private") end
    local status = publication.status(expected)
    local receipt = bounds.object(status.value)
    local completed = status.ok and receipt ~= nil and receipt.state == "complete"
    if not completed then
        local claimed, claim_error = process.registry.register(NAME)
        if not claimed then return hub_result.failure("BUSY", "another Hub operation is running: " .. tostring(claim_error)) end
    end
    local ok, result = pcall(function(): hub_result.Result return publication.apply(request, expected) end)
    if not completed then process.registry.unregister(NAME) end
    if ok then return result end
    return hub_result.failure("UNCERTAIN", "Hub operation interrupted; check its result")
end
return {main = main}
