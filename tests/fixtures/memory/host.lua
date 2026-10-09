local funcs = require("funcs")
local security = require("security")
local bounds = require("bounds")
local gateway = require("gateway")
local traits = require("traits")
local harness = require("harness")
local app_identity = require("app_identity")
local configuration = require("configuration")
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
function M.approve(binding: gateway.Binding, approval: string?, trait_id: string?): (string, string, {[string]: unknown})
    local id = approval
    if not id then
        local requested = M.value(gateway.request_access(binding, {idempotency_key = harness.key(), traits = {trait_id or M.TRAIT}, reason = "Remember facts from this session."}))
        id = assert(bounds.id(requested.approval_id))
    end
    local person = funcs.new():with_actor(security.new_actor("bee.application:" .. M.WORKSPACE .. ":needs-you", {workspace_id = M.WORKSPACE, definition_id = "bee.approvals.inbox.app:app"}))
    local raw, err = person:call("bee.approvals.binding:read", {approval_id = id})
    assert(not err, tostring(err))
    local question = M.value(raw)
    raw, err = person:call("bee.approvals.binding:decide", {approval_id = id, decision = "approved", expected_revision = question.revision,
        proposal_digest = question.proposal_digest, reviewed_digest = question.reviewed_digest})
    assert(not err, tostring(err)); M.value(raw)
    M.value(gateway.access_status(binding, id))
    return id .. ":grant", id, question
end
function M.bind(owner: harness.Client, session: string, thread: string, trait_id: string, seed: boolean?, prior: gateway.Binding?): (gateway.Binding, {[string]: unknown})
    local carrier = harness.principal("sessions-owner", harness.ALL, M.WORKSPACE)
    local attempt = prior and prior.attempt_id or ("attempt-" .. harness.key())
    if not prior then harness.value(carrier:call("prepare_attempt", {thread_id = thread, action_id = session, attempt_id = attempt, prepared = harness.prepared(), idempotency_key = harness.key()})) end
    local declared = assert(traits.load(trait_id))
    local admitted = M.call("bee.gateway.binding:admit", {subject = session, action_id = session, attempt_id = attempt,
        thread_id = thread, workspace_id = M.WORKSPACE, owner_incarnation = 1, carrier_epoch = prior and prior.carrier_epoch + 1 or 1, tools = {"thread_read"}, hooks = {},
        surface = {tools = {}, traits = {declared}, base_tools = {}, active_traits = seed and {trait_id} or {}, fixed_context = {}, dynamic_keys = {}, access = {policy = "agent-access", traits = {trait_id}}}})
    local binding, err = gateway.managed_binding(assert(bounds.id(assert(bounds.object(admitted.binding)).binding_id)))
    if not binding then error(tostring(err and err.error and err.error.message)) end
    return binding, admitted
end
function M.reattach(session: Session): gateway.Binding
    session.binding = (M.bind(session.owner, session.session, session.thread, session.trait_id or M.TRAIT, nil, session.binding))
    return session.binding
end
function M.open(seed: boolean?, trait_id: string?): (Session, {[string]: unknown})
    M.call("bee.gateway.binding:open", {address = assert(configuration.current()).address})
    local owner = harness.session_owner(M.WORKSPACE)
    local opened = harness.value(owner:call("session_create", {operation_key = harness.key()}))
    local session = assert(bounds.id(opened.session))
    local described = harness.value(owner:call("session_describe", {session = session}))
    local thread = assert(bounds.id(described.thread_ref))
    local carrier = harness.principal("sessions-owner", harness.ALL, M.WORKSPACE)
    local admitted_action = harness.admitted(); admitted_action.principal_id = session
    harness.value(carrier:call("admit_action", {thread_id = thread, action_id = session, admitted = admitted_action, idempotency_key = harness.key()}))
    local binding, admitted = M.bind(owner, session, thread, trait_id or M.TRAIT, seed)
    local grant, approval, question = M.approve(binding, bounds.id(admitted.trait_approval_id), trait_id)
    return {session = session, thread = thread, binding = binding, owner = owner, grant_id = grant, approval_id = approval, trait_id = trait_id}, question
end
function M.revoke(session: Session)
    local person = funcs.new():with_actor(security.new_actor("bee.application:" .. M.WORKSPACE .. ":needs-you", {workspace_id = M.WORKSPACE, definition_id = "bee.approvals.inbox.app:app"}))
    local raw, err = person:call("bee.approvals.binding:grant", {operation = "read", grant_id = session.grant_id})
    assert(not err, tostring(err))
    local grant = assert(bounds.object(M.value(raw).grant))
    raw, err = person:call("bee.approvals.binding:grant", {operation = "revoke", grant_id = session.grant_id, expected_revision = grant.revision})
    assert(not err, tostring(err)); M.value(raw)
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
return M
