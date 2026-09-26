-- MIT. The agent side of the installation acceptance: one admitted attempt
-- with its gateway binding, calling the gateway methods its MCP tools reach
-- as its bound subject.
local funcs = require("funcs")
local security = require("security")
local system = require("system")
local time = require("time")
local env = require("env")
local M = {}
M.SUBJECT = "bee.hub.install.agent"
M.WORKSPACE = "fedcba9876543210fedcba9876543210"
type Object = {[string]: unknown}
local SCOPE = {"bee.hub.install.probe:probe_policy",
    "bee.security.gateway:gateway_admit_policy", "bee.security.threads:thread_create_policy",
    "bee.security.threads:thread_lifecycle_policy", "bee.security.threads:thread_observe_policy"}

function M.call(target: string, request: Object): Object
    local policies: {security.Policy} = {}
    for _, id in ipairs(SCOPE) do
        local policy, policy_error = security.policy(id)
        if not policy then error("policy " .. id .. ": " .. tostring(policy_error)) end
        policies[#policies + 1] = policy
    end
    local actor = security.new_actor(M.SUBJECT, {workspace_id = M.WORKSPACE})
    local raw, err = funcs.new():with_actor(actor):with_scope(security.new_scope(policies)):call(target, request)
    if err then error(target .. ": " .. tostring(err)) end
    local reply = raw :: Object
    if reply.ok ~= true then
        local fault = (reply.error or {}) :: Object
        error(target .. ": " .. tostring(fault.code) .. ": " .. tostring(fault.message))
    end
    return reply.value :: Object
end

-- A command process starts beside the host services; admission records the
-- native listener, so the probe first waits for it to report its address.
function M.await_listener()
    local deadline = time.now():unix() + 30
    while time.now():unix() < deadline do
        local state = system.supervisor.state("bee:gateway_listener")
        if state and state.status == "running" and state.details then return end
        time.sleep("100ms")
    end
    error("gateway listener did not start")
end

function M.setting(name: string): string
    local value = env.get(name)
    if type(value) ~= "string" or value == "" then error(name .. " is not set") end
    return value
end

return M
