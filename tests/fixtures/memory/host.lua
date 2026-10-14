local funcs = require("funcs")
local owner_observer = require("owner_observer")
local approval_effect = require("approval_effect")
local json = require("json")
local http_client = require("http_client")
local security = require("security")
local bounds = require("bounds")
local gateway = require("gateway")
local traits = require("traits")
local harness = require("harness")
local app_identity = require("app_identity")
local configuration = require("configuration")
local system = require("system")
local events = require("events")
local channel = require("channel")
local time = require("time")
local process = require("process")
local sql = require("sql")
local M = {}
M.WORKSPACE = string.rep("e", 32)
M.TRAIT = "bee.tests.memory:trait"
M.APP = "bee.tests.memory:app"

type Session = {session: string, thread: string, binding: gateway.Binding, owner: harness.Client, grant_id: string, approval_id: string, trait_id: string?}
function M.value(raw: unknown): {[string]: unknown}
    local reply = assert(bounds.object(raw))
    if reply.ok ~= true then
        local fault = bounds.object(reply.error)
        error(tostring(reply.code or (fault and fault.code)) .. ": " .. tostring(reply.message or (fault and fault.message)))
    end
    return assert(bounds.object(reply.value))
end
local function host(): funcs.Executor
    return funcs.new():with_actor(security.new_actor("memory-fixture-host", {workspace_id = M.WORKSPACE}))
end
function M.call(target: string, request: unknown): {[string]: unknown}
    local raw, err = host():call(target, request)
    assert(not err, tostring(err))
    return M.value(raw)
end
function M.approve(binding: gateway.Binding, approval: string?, trait_id: string?, extra_trait: string?): (string, string, {[string]: unknown})
    local id = approval
    if not id then
        local selected = {trait_id or M.TRAIT}
        if extra_trait then selected[#selected + 1] = extra_trait end
        local requested = M.value(gateway.request_access(binding, {idempotency_key = harness.key(), traits = selected, reason = "Remember facts from this session."}))
        id = assert(bounds.id(requested.approval_id))
    end
    local person = funcs.new():with_actor(security.new_actor("bee.application:" .. (workspace or M.WORKSPACE) .. ":needs-you", {workspace_id = workspace or M.WORKSPACE, definition_id = "bee.approvals.inbox.app:app"}))
    local question = approval_effect.decide(person, id, "approved")
    assert(assert(bounds.object(question.effect)).destination == "gateway.access", "approval has no durable access continuation")
    return id .. ":grant", id, question
end
function M.bind(owner: harness.Client, session: string, thread: string, trait_id: string, seed: boolean?, prior: gateway.Binding?, action_id: string?, omit_hooks: boolean?): (gateway.Binding, {[string]: unknown})
    local carrier = harness.principal("sessions-owner", harness.ALL, M.WORKSPACE)
    local attempt = prior and prior.attempt_id or ("attempt-" .. harness.key())
    local action = action_id or (prior and prior.action_id) or session
    if not prior then harness.value(carrier:call("prepare_attempt", {thread_id = thread, action_id = action, attempt_id = attempt, prepared = harness.prepared(), idempotency_key = harness.key()})) end
    local declared = assert(traits.load(trait_id))
    local events: {string} = {}
    local points = { ["session.start"] = "SessionStart", ["prompt.submit"] = "UserPromptSubmit", ["tool.before"] = "PreToolUse", ["tool.after"] = "PostToolUse" }
    if not omit_hooks then
        for _, point in ipairs(declared.hooks or {}) do events[#events + 1] = assert(points[point]) end
    end
    local declarations = {declared}
    local offered = {trait_id}
    if trait_id == "bee.tests.memory:hooks_a" or trait_id == "bee.tests.memory:hooks_b" then
        local other = trait_id == "bee.tests.memory:hooks_a" and "bee.tests.memory:hooks_b" or "bee.tests.memory:hooks_a"
        declarations[#declarations + 1] = assert(traits.load(other))
        offered[#offered + 1] = other
        declarations[#declarations + 1] = assert(traits.load(M.TRAIT))
        offered[#offered + 1] = M.TRAIT
    end
    local admitted = M.call("bee.gateway.binding:admit", {subject = session, action_id = action, attempt_id = attempt,
        thread_id = thread, workspace_id = M.WORKSPACE, owner_incarnation = 1, carrier_epoch = prior and prior.carrier_epoch + 1 or 1, tools = {"thread_read", "capabilities"}, hooks = events,
        surface = {tools = {}, traits = declarations, base_tools = {"capabilities"}, active_traits = seed and {trait_id} or {}, fixed_context = {}, dynamic_keys = {}, access = {policy = "agent-access", traits = offered}}})
    local binding, err = gateway.managed_binding(assert(bounds.id(assert(bounds.object(admitted.binding)).binding_id)))
    if not binding then error(tostring(err and err.error and err.error.message)) end
    local db = assert(sql.get("bee.tests.support.hygiene:db"))
    assert(db:execute("INSERT OR IGNORE INTO bee_test_memory_sessions VALUES (?, ?, ?)", {session, owner.id, M.WORKSPACE}))
    assert(db:execute("INSERT OR IGNORE INTO bee_test_memory_bindings VALUES (?, ?)", {binding.binding_id, session}))
    db:release()
    return binding, admitted
end
function M.transport(session: Session): (string, string, string?)
    local binding = session.binding
    local input = {attempt_id = binding.attempt_id, carrier_epoch = binding.carrier_epoch, binding_id = binding.binding_id}
    local permitted = M.call("bee.gateway.binding:authorize_materialization", input)
    local issued = M.call("bee.gateway.binding:materialize", {attempt_id = binding.attempt_id, carrier_epoch = binding.carrier_epoch,
        binding_id = binding.binding_id, materialization_key = permitted.materialization_key})
    session.binding = assert((gateway.managed_binding(binding.binding_id)))
    return assert(bounds.text(issued.token, 128)), assert(configuration.current()).address, bounds.text(issued.hook_token, 128)
end
function M.rpc(session: Session, token: string, endpoint: string, method: string, params: {[string]: unknown}, rpc_failure: boolean?): {[string]: unknown}
    local response, err = http_client.post("http://" .. endpoint .. "/mcp/" .. session.binding.action_id, {headers = {
        ["Content-Type"] = "application/json", Authorization = "Bearer " .. token},
        body = assert(json.encode({jsonrpc = "2.0", id = 1, method = method, params = params})), timeout = 30})
    assert(response and not err, "fixture MCP request failed")
    local reply = assert(bounds.object(json.decode(tostring(response.body))))
    assert(response.status_code == 200, "fixture MCP request refused")
    if rpc_failure then return assert(bounds.object(reply.error), "fixture MCP must refuse the call") end
    return assert(bounds.object(reply.result), "fixture MCP " .. method .. " returned an RPC error: " .. assert(json.encode(reply.error)))
end
function M.reattach(session: Session): gateway.Binding
    session.binding = (M.bind(session.owner, session.session, session.thread, session.trait_id or M.TRAIT, nil, session.binding))
    return session.binding
end
function M.open(seed: boolean?, trait_id: string?, provider: string?, managed: boolean?, omit_hooks: boolean?): (Session, {[string]: unknown})
    M.call("bee.gateway.binding:open", {address = assert(configuration.current()).address})
    local owner = harness.session_owner(M.WORKSPACE)
    local opened = harness.value(owner:call("session_create", {operation_key = harness.key(), route = {provider = provider or "wippy", delivery = provider and not managed and "hook" or nil}}))
    local session = assert(bounds.id(opened.session))
    local db = assert(sql.get("bee.tests.support.hygiene:db"))
    assert(db:execute("INSERT INTO bee_test_memory_sessions VALUES (?, ?, ?)", {session, owner.id, M.WORKSPACE}))
    db:release()
    local described = harness.value(owner:call("session_describe", {session = session}))
    local thread = assert(bounds.id(described.thread_ref))
    local carrier = harness.principal("sessions-owner", harness.ALL, M.WORKSPACE)
    local admitted_action = harness.admitted(); admitted_action.principal_id = session
    local action = managed and ("action-" .. harness.key()) or session
    harness.value(carrier:call("admit_action", {thread_id = thread, action_id = action, admitted = admitted_action, idempotency_key = harness.key()}))
    local binding, admitted = M.bind(owner, session, thread, trait_id or M.TRAIT, seed, nil, action, omit_hooks)
    local grant, approval, question = M.approve(binding, bounds.id(admitted.trait_approval_id), trait_id)
    return {session = session, thread = thread, binding = binding, owner = owner, grant_id = grant, approval_id = approval, trait_id = trait_id}, question
end
local function revoke_grant(grant_id: string, workspace: string?)
    local person = funcs.new():with_actor(security.new_actor("bee.application:" .. (workspace or M.WORKSPACE) .. ":needs-you", {workspace_id = workspace or M.WORKSPACE, definition_id = "bee.approvals.inbox.app:app"}))
    local raw, err = person:call("bee.approvals.binding:grant", {operation = "read", grant_id = grant_id})
    assert(not err, tostring(err))
    local grant = assert(bounds.object(M.value(raw).grant))
    raw, err = person:call("bee.approvals.binding:grant", {operation = "revoke", grant_id = grant_id, expected_revision = grant.revision})
    assert(not err, tostring(err)); M.value(raw)
end
function M.close_all()
    local updates = assert(events.subscribe("supervisor", "service.update"))
    local tracking = assert(sql.get("bee.tests.support.hygiene:db"))
    local allocated = assert(tracking:query("SELECT session, owner, workspace FROM bee_test_memory_sessions"))
    local bindings = assert(tracking:query("SELECT binding_id FROM bee_test_memory_bindings"))
    tracking:release()
    for _, owned in ipairs(allocated) do
        local session = assert(bounds.id(owned.session))
        local owner_id = assert(bounds.id(owned.owner))
        local workspace = assert(bounds.id(owned.workspace))
        local owner = harness.principal(owner_id, {"bee.threads.security:sessions_owner"}, workspace)
        local carrier = harness.principal(owner_id, harness.ALL, workspace)
        local described = harness.value(owner:call("session_describe", {session = session}))
        local db = assert(sql.get("bee:db"))
        local grants = assert(db:query("SELECT DISTINCT grant_id FROM bee_session_traits WHERE session_ref=?", {session}))
        for _, grant in ipairs(grants) do revoke_grant(assert(bounds.id(grant.grant_id)), workspace) end
        db:release()
        local requester = funcs.new():with_actor(security.new_actor(session, {workspace_id = workspace}))
        local cursor: integer = 0
        local acknowledged: {string} = {}
        repeat
            local raw, event_error = requester:call("bee.approvals.binding:events", {cursor = cursor, acknowledge = acknowledged})
            assert(not event_error, tostring(event_error))
            local page = M.value(raw)
            local notifications = assert(bounds.array(page.events, 64))
            cursor = assert(bounds.count(page.cursor))
            acknowledged = {}
            for _, notification in ipairs(notifications) do
                acknowledged[#acknowledged + 1] = assert(bounds.line(assert(bounds.object(notification)).event_id, 512))
            end
        until #acknowledged == 0
        harness.close_subscriptions(carrier, {assert(bounds.id(described.thread_ref))})
        if described.state ~= "closed" then
        local cursor: unknown = nil
        repeat
            local page = harness.value(owner:call("work_history", {session = session, cursor = cursor}))
            for _, raw in ipairs(assert(bounds.array(page.items, 64))) do
                local work = assert(bounds.object(raw)).work
                local state = harness.value(owner:call("work_describe", {work = work}))
                harness.value(owner:call("work_cancel", {work = work, operation_key = harness.key(), reason = "fixture suite complete"}))
                if state.phase == "reserved" or state.phase == "accepted" then
                    if state.phase == "reserved" then
                        local pulled = harness.value(owner:call("turn_pull", {turn = state.turn, claim = state.claim}))
                        harness.value(owner:call("turn_accept", {turn = state.turn, claim = state.claim,
                            input_digest = pulled.input_digest, checkpoint = {}, operation_key = harness.key()}))
                    end
                    harness.value(owner:call("work_settle", {turn = state.turn, claim = state.claim,
                        result = {state = "cancelled", error = {code = "CANCELLED", message = "fixture suite complete"},
                            artifacts = {"simulated CLI fixture retired"}}, operation_key = harness.key()}))
                end
            end
            cursor = page.next
        until cursor == nil
        harness.value(owner:call("session_transition", {session = session, state = "closing", operation_key = harness.key()}))
        harness.value(owner:call("session_transition", {session = session, state = "closed", operation_key = harness.key()}))
        end

    end
    for _, binding in ipairs(bindings) do M.call("bee.gateway.binding:revoke", {binding_id = binding.binding_id}) end
    tracking = assert(sql.get("bee.tests.support.hygiene:db"))
    assert(tracking:execute("DELETE FROM bee_test_memory_sessions"))
    assert(tracking:execute("DELETE FROM bee_test_memory_bindings"))
    tracking:release()
    owner_observer.stopped("bee.gateway.service:access_service", "bee.gateway.access", updates)
    updates:close()
end

function M.revoke(session: Session)
    revoke_grant(session.grant_id)
end
function M.client(instance: string, workspace: string?, revision: string?, definition: string?, forwarded: boolean?): funcs.Executor
    local home = workspace or M.WORKSPACE
    local app = definition or M.APP
    local id = forwarded and ("bee.hive.member.peer." .. instance) or ("bee.application:" .. home .. ":" .. instance)
    if not forwarded then
        local stable = assert(app_identity.stable(home, app))
        M.call("bee.threads.binding:register_app_alias", {stable = stable.id, instance = id, workspace_id = home, definition_id = app})
    end
    local policy = assert(security.policy("bee.tests.memory:client_policy"))
    return funcs.new():with_actor(security.new_actor(id, {workspace_id = home, definition_id = app, definition_revision = revision or "1"})):with_scope(security.new_scope({policy, assert(security.policy("bee.tests.memory:index_policy"))}))
end
function M.receive(client: funcs.Executor, operation: string, request: unknown): {[string]: unknown}
    local raw, err = client:call("bee.threads.binding:" .. operation, request)
    assert(not err, tostring(err))
    return assert(bounds.object(raw))
end
function M.turn(session: Session, text: string, observations: {{[string]: unknown}}?): {[string]: unknown}
    harness.value(session.owner:call("work_send", {session = session.session, input = text, operation_key = harness.key()}))
    local reserved = harness.value(session.owner:call("turn_reserve", {session = session.session, operation_key = harness.key()}))
    local pulled = harness.value(session.owner:call("turn_pull", {turn = reserved.turn, claim = reserved.claim}))
    harness.value(session.owner:call("turn_accept", {turn = reserved.turn, claim = reserved.claim, input_digest = pulled.input_digest, checkpoint = {}, operation_key = harness.key()}))
    for _, data in ipairs(observations or {}) do
        harness.value(session.owner:call("turn_observation", {turn = reserved.turn, claim = reserved.claim, operation_key = harness.key(),
            observation = {type = data.type, event_key = harness.key(), data = data}}))
    end
    return harness.value(session.owner:call("work_settle", {turn = reserved.turn, claim = reserved.claim, result = {state = "succeeded", schema = "bee:Text@1", value = {text = text}}, operation_key = harness.key()}))
end
function M.endpoint(): string
    local reference = "bee.tests.driver.wippy:mock_listener"
    local subscription = assert(events.subscribe("supervisor", "service.update"))
    local deadline = time.after("30s")
    while true do
        local state = assert(system.supervisor.state(reference))
        if state.status == "running" then
            local address = assert(state.details):match("^service listening on ([%d%.]+:%d+)$")
            subscription:close()
            return "http://" .. assert(address) .. "/v1"
        end
        local selected = channel.select({subscription:channel():case_receive(), deadline:case_receive()})
        if selected.channel == deadline or not selected.ok then subscription:close(); error("fixture model listener unavailable") end
    end
end
function M.native(session: Session, prompt: string): {[string]: unknown}
    local raw, err = funcs.new():with_actor(security.new_actor(session.session, {workspace_id = M.WORKSPACE})):call("bee.driver.wippy.binding:run", {operation = "run", thread_id = session.thread,
        action_id = session.session, attempt_id = session.binding.attempt_id, workspace_id = M.WORKSPACE,
        agent_ref = "bee.tests.memory:test_agent", brief = prompt, host_config = {endpoint = M.endpoint()}})
    assert(not err, tostring(err))
    return assert(bounds.object(raw))
end

function M.cli_hook(session: Session, event: string, fields: {[string]: unknown}, token: string, endpoint: string, mcp: boolean?): {[string]: unknown}
    fields.event, fields.session_id = event, session.session
    local body: {[string]: unknown} = fields
    if mcp then body = {jsonrpc = "2.0", id = 1, method = "tools/call", params = {name = "hook", arguments = fields, _meta = {threadId = session.session}}} end
    local response, err = http_client.post("http://" .. endpoint .. "/hook/" .. session.binding.action_id .. (mcp and "/mcp" or ""),
        {headers = {["Content-Type"] = "application/json", Authorization = "Bearer " .. token}, body = assert(json.encode(body)), timeout = 5})
    assert(response and not err, "fixture hook transport failed")
    assert(response.status_code == 200 or response.status_code == 202, "fixture hook transport refused: " .. tostring(response.body))
    if response.body == nil or response.body == "" then return {} end
    local reply = assert(bounds.object(json.decode(tostring(response.body))))
    if mcp then
        assert(not reply.error, "fixture MCP hook error: " .. assert(json.encode(reply.error)))
        local result = assert(bounds.object(reply.result))
        local content = assert(bounds.array(result.content, 8))
        if #content == 0 then return {} end
        return assert(bounds.object(json.decode(assert(bounds.text(assert(bounds.object(content[1])).text)))))
    end
    return reply
end

return M
