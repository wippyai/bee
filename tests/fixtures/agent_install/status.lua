-- MIT. The same attempt polls its request after the person decided it.
local logger = require("logger")
local agent = require("agent")

local function run()
    local request = {binding_id = agent.setting("bee.hub.install.probe:binding"),
        request_id = agent.setting("bee.hub.install.probe:request_id")}
    local first = agent.call("bee.gateway.binding:install_status", request)
    local second = agent.call("bee.gateway.binding:install_status", request)
    logger:info("AGENT_INSTALL_STATUS", {status = first.status, message = first.message, code = first.code,
        replayed_status = second.status, component = first.component, version = first.version})
end

-- A failed call is logged before the process exits nonzero, so the
-- acceptance shows the owner's refusal.
local function main()
    local ok, failure = pcall(run)
    if not ok then
        logger:error("AGENT_INSTALL_STATUS_FAILED", {error = tostring(failure)})
        error(failure)
    end
end

return {main = main}
