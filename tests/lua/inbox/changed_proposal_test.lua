-- MIT. An approval binds the exact proposal it was given: a changed input
-- or a revised operation is another proposal with its own approval
-- identity, the approved decision stays as committed and authorizes
-- nothing else, and the inbox shows precisely what was approved, from the
-- owner's record, never the latest action definition.
local test = require("test")
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local uuid = require("uuid")
local model = require("model")
local inbox = require("inbox")
local app_caller = require("caller")
local REQUESTER, ALICE = "bee.test.inbox_requester", "bee.test.inbox_alice"
local POLICY = "inbox-test"
type Object = {[string]: unknown}
type Reply = app_caller.Reply
local function key(): string
    local id, err = uuid.v4()
    if err or not id then error("uuid: " .. tostring(err)) end
    return id
end
local function scope(names: {string}): security.Scope
    local policies: {security.Policy} = {}
    for index, name in ipairs(names) do
        local policy, err = security.policy(name)
        if err or not policy then error("policy " .. name .. ": " .. tostring(err)) end
        policies[index] = policy
    end
    return security.new_scope(policies)
end
local function caller(id: string, grants: {string}): funcs.Executor
    local names: {string} = {"bee.inbox:client_test_policy"}
    for _, grant in ipairs(grants) do names[#names + 1] = grant end
    return funcs.new():with_actor(security.new_actor(id)):with_scope(scope(names))
end
local requester = caller(REQUESTER, {"bee:approval_request_policy", "bee:approval_consume_policy"})
local alice = caller(ALICE, {"bee:approval_decide_policy"})
local function call(executor: funcs.Executor, target: string, request: unknown): Reply
    local raw, err = executor:call(target, request)
    if err then error(target .. ": " .. tostring(err)) end
    return raw :: Reply
end
local function value(reply: Reply): Object
    if not reply.ok then error(tostring(reply.error and reply.error.code) .. ": " .. tostring(reply.error and reply.error.message)) end
    return reply.value :: Object
end
local function code(reply: Reply): string
    if reply.ok then error("expected a failure, got success") end
    return reply.error and reply.error.code or ""
end
local function install_policy()
    local entry = registry.get("bee.approvals:approver_policies")
    if not entry then error("approver policies entry") end
    local data = entry.data :: Object
    local policies = data.policies :: {Object}
    for _, policy in ipairs(policies) do
        if policy.name == POLICY then return end
    end
    policies[#policies + 1] = {name = POLICY, approvers = {ALICE, "bee.test.inbox_bob"}, max_ttl_ms = 60000}
    local changes = registry.snapshot():changes()
    changes:update(entry)
    local applied, err = changes:apply()
    if not applied then error("install approver policy: " .. tostring(err)) end
end
local function file(workspace: string, proposal: Object): Object
    return value(call(requester, "bee.approvals:request", {workspace_id = workspace, idempotency_key = key(), request_kind = "permission", policy = POLICY, proposal = proposal, prompt = {text = "run it"}}))
end
local function through(executor: funcs.Executor): app_caller.Client
    return inbox.new(function(target: string, request: unknown): (unknown, string?)
        local raw, err = executor:call(target, request)
        if err then return nil, tostring(err) end
        return raw, nil
    end)
end
local function unknown_answer(): model.Reply
    return app_caller.unknown()
end
local function refresh(state: model.State, owner: app_caller.Client)
    for _, workspace in ipairs(state.workspaces) do
        local intent = model.inbox_intent(state, workspace)
        model.apply_inbox(state, workspace, owner:invoke(intent.target, intent.request) or unknown_answer())
    end
end
local function open(state: model.State, owner: app_caller.Client, approval_id: string)
    model.select(state, approval_id)
    local intent = model.read_intent(state)
    if not intent then error("no read intent") end
    model.apply_read(state, approval_id, owner:invoke(intent.target, intent.request) or unknown_answer())
end
local function decide(state: model.State, owner: app_caller.Client, decision: string)
    local request_id = key()
    local intent, refused = model.decision_intent(state, request_id, decision)
    if not intent then error("decision refused: " .. tostring(refused)) end
    model.apply_answer(state, request_id, owner:invoke(intent.target, intent.request))
end
local function lines_have(view: Object, needle: string): boolean
    for _, line in ipairs(model.payload_lines(view)) do
        if line:find(needle, 1, true) then return true end
    end
    return false
end
local function define_tests()
    test.describe("Approval bound to its proposal", function()
        install_policy()
        test.it("refuses a changed input at consumption, keeps the decision as committed and needs a new approval for the change", function()
            local workspace = "ws-" .. key():sub(1, 8)
            local attempt = "attempt-" .. key():sub(1, 8)
            local original = file(workspace, {kind = "attempt", ref = attempt, revision = "r1", action_id = "a-1", payload = {tool_name = "Bash", input_digest = "d-touch", command = "touch proof.txt"}})
            local changed = file(workspace, {kind = "attempt", ref = attempt, revision = "r1", action_id = "a-1", payload = {tool_name = "Bash", input_digest = "d-rm", command = "rm -rf proof"}})
            test.neq(original.approval_id, changed.approval_id)
            test.neq(original.proposal_digest, changed.proposal_digest)
            local owner = through(alice)
            local state = model.new({workspace})
            refresh(state, owner)
            open(state, owner, tostring(original.approval_id))
            decide(state, owner, "approved")
            local incarnation = math.floor(tonumber((state.detail :: Object).owner_incarnation) or 0)
            -- The approved decision authorizes only the proposal it was given.
            local crossed = call(requester, "bee.approvals:consume", {approval_id = original.approval_id, proposal_digest = changed.proposal_digest, effect_key = "e1", owner_incarnation = incarnation})
            test.eq(code(crossed), "CONFLICT")
            local undecided = call(requester, "bee.approvals:consume", {approval_id = changed.approval_id, proposal_digest = changed.proposal_digest, effect_key = "e1", owner_incarnation = incarnation})
            test.is_false(undecided.ok)
            -- The decision and its proposal stand as committed; the inbox shows them, not the changed definition.
            refresh(state, owner)
            open(state, owner, tostring(original.approval_id))
            local detail = state.detail :: Object
            test.eq(detail.state, "decided")
            test.eq(detail.decision, "approved")
            test.eq(detail.revision, 2)
            test.eq(detail.proposal_digest, original.proposal_digest)
            test.is_true(lines_have(detail, "command: touch proof.txt"))
            test.is_false(lines_have(detail, "rm -rf"))
            test.is_nil(detail.consumer_id)
            test.eq(state.rows[tostring(changed.approval_id)].state, "pending")
            -- The original proposal still consumes once under its own digest.
            local consumed = value(call(requester, "bee.approvals:consume", {approval_id = original.approval_id, proposal_digest = original.proposal_digest, effect_key = "e1", owner_incarnation = incarnation}))
            test.eq(consumed.consumed_effect, "e1")
            test.eq(code(call(requester, "bee.approvals:consume", {approval_id = original.approval_id, proposal_digest = original.proposal_digest, effect_key = "e2", owner_incarnation = incarnation})), "CONFLICT")
        end)
        test.it("treats a revised operation as another proposal with its own pending approval", function()
            local workspace = "ws-" .. key():sub(1, 8)
            local first = file(workspace, {kind = "operation", ref = "bee.harness.launch:start", revision = "r1", payload = {profile = "batch", policy_ref = "bee.host:policy-a"}})
            local revised = file(workspace, {kind = "operation", ref = "bee.harness.launch:start", revision = "r2", payload = {profile = "batch", policy_ref = "bee.host:policy-a"}})
            local repolicied = file(workspace, {kind = "operation", ref = "bee.harness.launch:start", revision = "r1", payload = {profile = "batch", policy_ref = "bee.host:policy-b"}})
            test.neq(first.proposal_digest, revised.proposal_digest)
            test.neq(first.proposal_digest, repolicied.proposal_digest)
            local owner = through(alice)
            local state = model.new({workspace})
            refresh(state, owner)
            open(state, owner, tostring(first.approval_id))
            decide(state, owner, "approved")
            test.eq(code(call(alice, "bee.approvals:decide", {approval_id = revised.approval_id, expected_revision = 1, decision = "approved", proposal_digest = first.proposal_digest})), "CONFLICT")
            refresh(state, owner)
            test.eq(state.rows[tostring(first.approval_id)].state, "decided")
            test.eq(state.rows[tostring(revised.approval_id)].state, "pending")
            test.eq(state.rows[tostring(repolicied.approval_id)].state, "pending")
            open(state, owner, tostring(revised.approval_id))
            test.eq((state.detail :: Object).state, "pending")
            test.is_true(lines_have(state.detail :: Object, "policy_ref: bee.host:policy-a"))
        end)
    end)
end
return test.run_cases(define_tests)
