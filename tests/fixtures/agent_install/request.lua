-- MIT. The agent's attempt asks the person to install one Hub package.
local logger = require("logger")
local time = require("time")
local agent = require("agent")

local function run()
    local suffix = tostring(time.now():unix_nano())
    local thread = agent.call("bee.threads.service:create", {thread_id = "install-" .. suffix,
        idempotency_key = "create-" .. suffix, title = "Agent installation"}).thread_id :: string
    local attempt = "attempt-" .. suffix
    local action = "action-" .. suffix
    agent.call("bee.threads.service:admit_action", {thread_id = thread, action_id = action, idempotency_key = "admit-" .. suffix,
        admitted = {request_id = "request-" .. suffix, principal_id = agent.SUBJECT, binding_ref = "probe-binding",
            binding_digest = "probe-digest", grant_refs = {}, budget_ref = "probe-budget", input = {text = "install"}}})
    agent.call("bee.threads.service:prepare_attempt", {thread_id = thread, action_id = action, attempt_id = attempt,
        idempotency_key = "prepare-" .. suffix, prepared = {binding_ref = "probe-binding", binding_digest = "probe-digest",
            profile_id = "probe-profile", profile_digest = "probe-profile-digest", placement_binding = "probe-placement",
            placement_attempt_id = attempt, plan_digest = "probe-plan"}})
    agent.await_listener()
    local tools = {"install_request", "uninstall_request", "install_status"}
    local admitted = agent.call("bee.gateway.binding:admit", {subject = agent.SUBJECT, action_id = action,
        attempt_id = attempt, thread_id = thread, owner_incarnation = 1, carrier_epoch = 1, tools = tools,
        ttl_ms = 3600000, idempotency_key = "binding-" .. suffix, workspace_id = agent.WORKSPACE,
        surface = {tools = {}, traits = {}, base_tools = tools, active_traits = {}, fixed_context = {}, dynamic_keys = {}}})
    local binding_id = (admitted.binding :: {[string]: unknown}).binding_id :: string
    local requested = agent.call("bee.gateway.binding:install_request", {binding_id = binding_id, component = "bee/agent-tool"})
    logger:info("AGENT_INSTALL_REQUESTED", {binding_id = binding_id, request_id = requested.request_id,
        status = requested.status, version = requested.version, action = requested.action})
end

-- A failed call is logged before the process exits nonzero, so the
-- acceptance shows the owner's refusal.
local function main()
    local ok, failure = pcall(run)
    if not ok then
        logger:error("AGENT_INSTALL_REQUEST_FAILED", {error = tostring(failure)})
        error(failure)
    end
end

return {main = main}
