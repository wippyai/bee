-- MIT. One short-lived publisher owns Bee Hub's publication name.
-- Native registration releases the name if this process dies.
local process = require("process")
local security = require("security")
local publish = require("publish")
local transaction = require("transaction")
local NAME = "bee.hub.publish_worker"
local function main(parent: string, topic: string, operation: string, request: unknown)
    if not security.can("bee.hub.execute", "bee.hub.service:publish_worker") then error("Hub publish worker is private") end
    local claimed, claim_error = process.registry.register(NAME)
    if not claimed then
        process.send(parent, topic, transaction.failure("BUSY", "another Hub publication is running: " .. tostring(claim_error)))
        return
    end
    local ok, result = pcall(function(): transaction.Result
        if operation == "plan" then
            local plan, problem = publish.plan(request)
            if not plan then return transaction.failure("INVALID", problem or "package publication plan unavailable") end
            return transaction.success(plan, false)
        elseif operation == "apply" then
            return publish.apply(request)
        end
        return transaction.failure("INVALID", "unknown Hub publication operation")
    end)
    process.registry.unregister(NAME)
    if ok then process.send(parent, topic, result)
    else process.send(parent, topic, transaction.failure("UNCERTAIN", "Hub publication interrupted; check its result")) end
end
return {main = main}
