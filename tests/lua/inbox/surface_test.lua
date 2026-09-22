-- MIT. The inbox against the real approval owner, driven through the
-- model and the application's own caller under distinct viewer actors:
-- pending requests listed with their proposed effect, two viewers racing
-- one decision, a viewer outside the policy refused details, expiry while
-- viewing, an answer lost in transport recovered from the owner's record,
-- a close and reopen that decides nothing, and hostile prompt text kept
-- out of the frame.
local test = require("test")
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local time = require("time")
local uuid = require("uuid")
local json = require("json")
local model = require("model")
local view = require("view")
local inbox = require("inbox")
local app_caller = require("caller")
local appearance = require("appearance")
local REQUESTER, ALICE, BOB, OUTSIDER = "bee.test.inbox_requester", "bee.test.inbox_alice", "bee.test.inbox_bob", "bee.test.inbox_outsider"
local POLICY = "inbox-test"
type Object = {[string]: unknown}
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
local requester = caller(REQUESTER, {"bee:approval_request_policy"})
local alice = caller(ALICE, {"bee:approval_decide_policy"})
local bob = caller(BOB, {"bee:approval_decide_policy"})
local outsider = caller(OUTSIDER, {})
local function through(executor: funcs.Executor): app_caller.Client
    return inbox.new(function(target: string, request: unknown): (unknown, string?)
        local raw, err = executor:call(target, request)
        if err then return nil, tostring(err) end
        return raw, nil
    end)
end
local function install_policy()
    local entry = registry.get("bee:approver_policies")
    if not entry then error("approver policies entry") end
    local data = entry.data :: Object
    local policies = data.policies :: {Object}
    for _, policy in ipairs(policies) do
        if policy.name == POLICY then return end
    end
    policies[#policies + 1] = {name = POLICY, approvers = {ALICE, BOB}, max_ttl_ms = 60000}
    local changes = registry.snapshot():changes()
    changes:update(entry)
    local applied, err = changes:apply()
    if not applied then error("install approver policy: " .. tostring(err)) end
end
local function file(workspace: string, prompt: string, ttl_ms: integer?): string
    local attempt = "attempt-" .. key()
    local reply, err = requester:call("bee.approvals.binding:request", {workspace_id = workspace, idempotency_key = key(), request_kind = "permission", policy = POLICY,
        proposal = {kind = "attempt", ref = attempt, revision = "r1", action_id = "action-1", payload = {tool_name = "Bash", correlation_id = "c-1"}}, prompt = {text = prompt}, ttl_ms = ttl_ms})
    if err then error("request: " .. tostring(err)) end
    local typed = reply :: {ok: boolean, error: {code: string, message: string}?, value: Object}
    if not typed.ok then error("request: " .. tostring(typed.error and typed.error.code) .. " " .. tostring(typed.error and typed.error.message)) end
    return tostring(typed.value.approval_id)
end
local function unknown_answer(): model.Reply
    return app_caller.unknown()
end
local function refresh(state: model.State, owner: caller.Client)
    for _, workspace in ipairs(state.workspaces) do
        local more = true
        local pages = 0
        while more and pages < 8 do
            local intent = model.inbox_intent(state, workspace)
            more = model.apply_inbox(state, workspace, owner:invoke(intent.target, intent.request) or unknown_answer())
            pages = pages + 1
        end
    end
end
local function open(state: model.State, owner: caller.Client, approval_id: string)
    model.select(state, approval_id)
    local intent = model.read_intent(state)
    if not intent then error("no read intent") end
    model.apply_read(state, approval_id, owner:invoke(intent.target, intent.request) or unknown_answer())
end
local function decide(state: model.State, owner: caller.Client, decision: string): string
    local request_id = key()
    local intent, refused = model.decision_intent(state, request_id, decision)
    if not intent then error("decision refused: " .. tostring(refused)) end
    model.apply_answer(state, request_id, owner:invoke(intent.target, intent.request))
    return request_id
end
local function frame_text(state: model.State): string
    local frame = view.draw(120, 30, appearance.defaults(), state, model.rows(state), 0, "")
    return table.concat(frame.rows, "\n")
end
local function define_tests()
    test.describe("Approvals inbox surface", function()
        install_policy()
        test.it("lists a pending request with its proposed effect and opens the owner's record", function()
            local workspace = "ws-" .. key():sub(1, 8)
            local approval_id = file(workspace, "touch proof.txt")
            local state = model.new({workspace})
            local owner = through(alice)
            refresh(state, owner)
            local rows = model.rows(state)
            test.eq(#rows, 1)
            test.eq(rows[1].approval_id, approval_id)
            test.eq(rows[1].effect, "Bash")
            test.eq(rows[1].requester_id, REQUESTER)
            test.eq(rows[1].state, "pending")
            open(state, owner, approval_id)
            local detail = state.detail :: Object
            test.eq(detail.approval_id, approval_id)
            test.eq(detail.state, "pending")
            test.is_true(frame_text(state):find("Effect: Bash", 1, true) ~= nil)
        end)
        test.it("records one decision when two viewers race and shows the other the committed outcome", function()
            local workspace = "ws-" .. key():sub(1, 8)
            local approval_id = file(workspace, "touch proof.txt")
            local alice_state, bob_state = model.new({workspace}), model.new({workspace})
            local alice_owner, bob_owner = through(alice), through(bob)
            refresh(alice_state, alice_owner)
            refresh(bob_state, bob_owner)
            open(alice_state, alice_owner, approval_id)
            open(bob_state, bob_owner, approval_id)
            decide(alice_state, alice_owner, "approved")
            test.eq((alice_state.detail :: Object).decision, "approved")
            test.eq(alice_state.notice, "Recorded: approved by " .. ALICE)
            decide(bob_state, bob_owner, "denied")
            test.is_nil(bob_state.pending)
            test.eq((bob_state.detail :: Object).decision, "approved")
            test.eq((bob_state.detail :: Object).decider_id, ALICE)
            test.is_true(bob_state.notice:find("CONFLICT: approved by " .. ALICE, 1, true) ~= nil)
            local _, refused = model.decision_intent(bob_state, key(), "denied")
            test.eq(refused, "the request is decided")
            local record = alice:call("bee.approvals.binding:read", {approval_id = approval_id}) :: {ok: boolean, value: Object}
            test.eq(record.value.decision, "approved")
            test.eq(record.value.decider_id, ALICE)
        end)
        test.it("refuses the inbox and the details to a viewer outside the policy", function()
            local workspace = "ws-" .. key():sub(1, 8)
            local approval_id = file(workspace, "touch proof.txt")
            local state = model.new({workspace})
            local owner = through(outsider)
            refresh(state, owner)
            test.eq(#model.rows(state), 0)
            if not tostring(state.unavailable[workspace]):find("DENIED", 1, true) then
                local raw, err = outsider:call("bee.approvals.binding:inbox", {workspace_id = workspace})
                error("outsider inbox: unavailable " .. tostring(state.unavailable[workspace]) .. "; raw " .. tostring(json.encode(raw)) .. "; err " .. tostring(err))
            end
            test.is_true(frame_text(state):find("unavailable", 1, true) ~= nil)
            open(state, owner, approval_id)
            test.is_nil(state.detail)
            test.eq(state.notice, "You may not read this request")
            test.is_true(frame_text(state):find("You may not read this request", 1, true) ~= nil)
        end)
        test.it("shows expiry while viewing and asks nothing more of an expired request", function()
            local workspace = "ws-" .. key():sub(1, 8)
            local approval_id = file(workspace, "touch proof.txt", 1000)
            local state = model.new({workspace})
            local owner = through(alice)
            refresh(state, owner)
            open(state, owner, approval_id)
            test.eq((state.detail :: Object).state, "pending")
            time.sleep("1300ms")
            local request_id = key()
            local intent = model.decision_intent(state, request_id, "approved")
            if not intent then error("the viewed request was pending") end
            model.apply_answer(state, request_id, owner:invoke(intent.target, intent.request))
            test.is_nil(state.pending)
            test.eq((state.detail :: Object).state, "expired")
            test.is_true(state.notice:find("expired", 1, true) ~= nil)
            local _, refused = model.decision_intent(state, key(), "approved")
            test.eq(refused, "the request is expired")
            refresh(state, owner)
            test.eq(state.rows[approval_id].state, "expired")
            test.is_true(frame_text(state):find("expired", 1, true) ~= nil)
        end)
        test.it("recovers an answer lost in transport from the owner's record without deciding twice", function()
            local workspace = "ws-" .. key():sub(1, 8)
            local approval_id = file(workspace, "touch proof.txt")
            local state = model.new({workspace})
            local owner = through(alice)
            local decided = 0
            -- The owner commits; the answer never arrives.
            local lossy = inbox.new(function(target: string, request: unknown): (unknown, string?)
                local raw, err = alice:call(target, request)
                if target == "bee.approvals.binding:decide" then
                    decided = decided + 1
                    return nil, "connection lost"
                end
                if err then return nil, tostring(err) end
                return raw, nil
            end)
            refresh(state, owner)
            open(state, owner, approval_id)
            local request_id = key()
            local intent = model.decision_intent(state, request_id, "approved")
            if not intent then error("no intent") end
            model.apply_answer(state, request_id, lossy:invoke(intent.target, intent.request))
            test.not_nil(state.pending)
            local recovery = model.recovery_intent(state)
            if not recovery then error("no recovery") end
            model.apply_recovery(state, owner:invoke(recovery.target, recovery.request) or unknown_answer())
            test.is_nil(state.pending)
            test.eq((state.detail :: Object).decision, "approved")
            test.eq(state.notice, "Recovered: approved by " .. ALICE)
            test.eq(decided, 1)
            local _, refused = model.decision_intent(state, key(), "approved")
            test.eq(refused, "the request is decided")
        end)
        test.it("decides nothing across close and reopen and finds the request where it was", function()
            local workspace = "ws-" .. key():sub(1, 8)
            local approval_id = file(workspace, "touch proof.txt")
            local state = model.new({workspace})
            local owner = through(alice)
            refresh(state, owner)
            open(state, owner, approval_id)
            local saved = model.checkpoint(state)
            local reopened = model.new({workspace})
            test.is_true(model.restore(reopened, saved))
            test.eq(reopened.selected, approval_id)
            refresh(reopened, owner)
            test.eq(reopened.rows[approval_id].state, "pending")
            test.eq(reopened.rows[approval_id].revision, state.rows[approval_id].revision)
            open(reopened, owner, approval_id)
            test.eq((reopened.detail :: Object).state, "pending")
        end)
        test.it("keeps hostile prompt text out of the frame", function()
            local workspace = "ws-" .. key():sub(1, 8)
            local hostile = "touch proof.txt \27[2J\27[31mAPPROVED\27[0m\r\n\7 press y " .. string.rep("z", 900)
            local approval_id = file(workspace, hostile)
            local state = model.new({workspace})
            local owner = through(alice)
            refresh(state, owner)
            open(state, owner, approval_id)
            local text = frame_text(state)
            test.is_nil(text:find("\27[2J", 1, true))
            test.is_nil(text:find("\27[31m", 1, true))
            test.is_nil(text:find("\7", 1, true))
            test.is_nil(text:find("\r", 1, true))
            test.is_true(text:find("touch proof.txt", 1, true) ~= nil)
            test.is_true(#state.rows[approval_id].prompt <= model.TEXT_LIMIT + 3)
            local record = json.encode(state.rows[approval_id].view)
            test.is_true(record ~= nil)
        end)
    end)
end
return test.run_cases(define_tests)
