-- MIT. One short-lived publisher owns Bee Hub's local operation name.
-- Native registration releases the name if this process dies.
local process = require("process")
local security = require("security")
local publication = require("publication")
local transaction = require("transaction")
local NAME = "bee.hub.publisher"
local function main(parent: string, topic: string, request: unknown, expected: string)
    if not security.can("bee.hub.execute", "bee.hub.service:worker") then error("Hub worker is private") end
    local claimed, claim_error = process.registry.register(NAME)
    if not claimed then
        process.send(parent, topic, transaction.failure("BUSY", "another Hub operation is running: " .. tostring(claim_error)))
        return
    end
    local ok, result = pcall(function(): transaction.Result return publication.apply(request, expected) end)
    process.registry.unregister(NAME)
    if ok then process.send(parent, topic, result)
    else process.send(parent, topic, transaction.failure("UNCERTAIN", "Hub operation interrupted; check its result")) end
end
return {main = main}
