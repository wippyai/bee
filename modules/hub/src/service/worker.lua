-- MIT. One short-lived publisher owns Bee Hub's local operation name.
-- Native registration releases the name if this process dies.
local process = require("process")
local security = require("security")
local publication = require("publication")
local bounds = require("bounds")
local transaction = require("transaction")
local NAME = "bee.hub.publisher"
local function main(parent: string, topic: string, request: unknown, expected: string)
    if not security.can("bee.hub.execute", "bee.hub.service:worker") then error("Hub worker is private") end
    local status = publication.status(expected)
    local receipt = bounds.object(status.value)
    local completed = status.ok and receipt ~= nil and receipt.state == "complete"
    if not completed then
        local claimed, claim_error = process.registry.register(NAME)
        if not claimed then
            process.send(parent, topic, transaction.failure("BUSY", "another Hub operation is running: " .. tostring(claim_error)))
            return
        end
    end
    local ok, result = pcall(function(): transaction.Result return publication.apply(request, expected) end)
    if not completed then process.registry.unregister(NAME) end
    if ok then process.send(parent, topic, result)
    else process.send(parent, topic, transaction.failure("UNCERTAIN", "Hub operation interrupted; check its result")) end
end
return {main = main}
