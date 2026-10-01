-- MIT. The local approvals presentation under interruption, against the
-- real owner and thread: one decision survives an interrupted delivery and
-- a restarted owner and inbox with the delivery replayed once; a page that
-- never arrived advances no cursor and a replayed page repeats nothing;
-- execution authority revoked after approval is refused without rewriting
-- the decision; and a headless owner restart with no inbox open recovers
-- requests, decisions and pending delivery on its own.
local test = require("test")
local principals = require("principals")
local bounds = require("bounds")
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local process = require("process")
local channel = require("channel")
local time = require("time")
local uuid = require("uuid")
local model = require("model")
local inbox = require("inbox")
local app_caller = require("caller")
local thread_harness = require("thread_harness")
local REQUESTER, ALICE = "bee.test.inbox_requester", "bee.test.inbox_alice"
local POLICY = "inbox-test"
local AUTHORITY, WORKER = "bee.approvals.authority", "bee.approvals.outbox"
type Object = {[string]: unknown}
type Reply = app_caller.Envelope
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
    local names: {string} = {"bee.approvals.inbox:client_test_policy"}
    for _, grant in ipairs(grants) do names[#names + 1] = grant end
    return funcs.new():with_actor(security.new_actor(id)):with_scope(scope(names))
end
local requester = caller(REQUESTER, {"bee.security.approvals:approval_request_policy", "bee.security.approvals:approval_consume_policy", "bee.security.threads:thread_create_policy", "bee.security.threads:thread_observe_policy", "bee.security.threads:thread_storage_policy", "bee.security.threads:thread_resource_policy"})
local unconsuming = caller(REQUESTER, {"bee.security.approvals:approval_request_policy"})
local alice = caller(ALICE, {"bee.security.approvals:approval_decide_policy"})
local launcher = thread_harness.principal(REQUESTER, thread_harness.ALL)
local function through(executor: funcs.Executor): app_caller.Client
    return inbox.new(function(target: string, request: unknown): (unknown, string?)
        local raw, err = executor:call(target, request)
        if err then return nil, tostring(err) end
        return raw, nil
    end)
end
local function call(executor: funcs.Executor, target: string, request: unknown): Reply
    local raw, err = executor:call(target, request)
    if err then error(target .. ": " .. tostring(err)) end
    return assert(app_caller.envelope(raw))
end
local function value(reply: Reply): Object
    if not reply.ok then error(tostring(reply.error and reply.error.code) .. ": " .. tostring(reply.error and reply.error.message)) end
    return assert(bounds.object(reply.value))
end
local function install_policy()
    local entry = registry.get("bee:approver_policies")
    if not entry then error("approver policies entry") end
    local data = assert(bounds.object(entry.data))
    local policies = principals.objects(data.policies)
    data.policies = policies
    for _, policy in ipairs(policies) do
        if policy.name == POLICY then return end
    end
    policies[#policies + 1] = {name = POLICY, approvers = {ALICE, "bee.test.inbox_bob"}, max_ttl_ms = 60000}
    local changes = registry.snapshot():changes()
    changes:update(entry)
    local applied, err = changes:apply()
    if not applied then error("install approver policy: " .. tostring(err)) end
end
-- A request bound to a prepared attempt on a thread, so the owner projects
-- it and its decision onto that thread.
local function file_on_thread(workspace: string): (string, string, string)
    local thread_id = thread_harness.thread(launcher, "Approvals")
    local action_id, attempt_id = "a-" .. key():sub(1, 8), "t-" .. key():sub(1, 8)
    thread_harness.value(launcher:call("admit_action", {thread_id = thread_id, idempotency_key = key(), action_id = action_id, admitted = thread_harness.admitted()}))
    thread_harness.value(launcher:call("prepare_attempt", {thread_id = thread_id, idempotency_key = key(), action_id = action_id, attempt_id = attempt_id, prepared = thread_harness.prepared()}))
    local created = value(call(requester, "bee.approvals.binding:request", {workspace_id = workspace, idempotency_key = key(), request_kind = "permission", policy = POLICY, thread_id = thread_id,
        proposal = {kind = "attempt", ref = attempt_id, revision = "r1", action_id = action_id, payload = {tool_name = "Bash", correlation_id = "c-1"}}, prompt = {text = "touch proof.txt"}}))
    return tostring(created.approval_id), tostring(created.proposal_digest), thread_id
end
local function thread_records(thread_id: string): {Object}
    local page = value(call(requester, "bee.threads.service:read_after", {thread_id = thread_id, cursor = 0, filter = {kinds = {"approval.request", "approval.transition"}}}))
    return principals.objects(page.records)
end
local function delivery_status(approval_id: string): string
    local deliveries = principals.objects(value(call(requester, "bee.approvals.binding:deliveries", {approval_id = approval_id})).deliveries)
    local summaries: {string} = {}
    for _, delivery in ipairs(deliveries) do
        summaries[#summaries + 1] = tostring(delivery.kind) .. " thread=" .. tostring(delivery.thread_id) .. " attempts=" .. tostring(delivery.attempts) ..
            " acknowledged=" .. tostring(delivery.acknowledged_at ~= nil) .. " last_error=" .. tostring(delivery.last_error)
    end
    return table.concat(summaries, "; ")
end
local function until_records(thread_id: string, count: integer, approval_id: string): {Object}
    local cursor = 0
    local collected: {Object} = {}
    local deadline_ms = math.floor(time.now():unix_nano() / 1000000) + 30000
    while true do
        local page = value(call(requester, "bee.threads.service:read_after", {thread_id = thread_id, cursor = cursor, limit = 64,
            filter = {kinds = {"approval.request", "approval.transition"}}}))
        local records = principals.objects(page.records)
        for _, record in ipairs(records) do collected[#collected + 1] = record end
        if #collected >= count then return collected end
        local remaining = deadline_ms - math.floor(time.now():unix_nano() / 1000000)
        if remaining <= 0 then
            local page = value(call(requester, "bee.threads.service:read_after", {thread_id = thread_id, cursor = 0, limit = 64}))
            local observed: {string} = {}
            for _, record in ipairs(principals.objects(page.records)) do
                observed[#observed + 1] = tostring(record.sequence) .. ":" .. tostring(record.kind)
            end
            local filtered = value(call(requester, "bee.threads.service:read_after", {thread_id = thread_id, cursor = 0, limit = 64,
                filter = {kinds = {"approval.request", "approval.transition"}}}))
            local matching = principals.objects(filtered.records)
            error("thread records did not arrive; matching=" .. tostring(#matching) .. " scanned=" .. tostring(filtered.scanned_through) ..
                " observed=" .. table.concat(observed, ",") .. " outbox: " .. delivery_status(approval_id))
        end
        cursor = math.floor(tonumber(page.scanned_through) or cursor)
        if page.has_more ~= true then
            value(call(requester, "bee.threads.delivery:watch", {thread_id = thread_id, after_sequence = cursor, wait_ms = remaining}))
        end
    end
    error("record wait ended")
end
local function await_exit(events: Channel<process.Event>, pid: string, label: string)
    local deadline = time.after("30s")
    while true do
        local selected = channel.select({events = events:case_receive(), deadline = deadline:case_receive()})
        if not selected.ok or selected.channel == deadline then error(label .. " did not exit") end
        local event = selected.value
        if event.kind == process.event.EXIT and tostring(event.from) == pid then return end
    end
end
local function restart(name: string)
    local before = process.registry.lookup(name)
    if not before then error(name .. " is not registered") end
    local before_id = tostring(before)
    local events = assert(process.events())
    local monitored, monitor_error = process.monitor(before_id)
    if not monitored then error("monitor " .. name .. ": " .. tostring(monitor_error)) end
    local terminated, terminate_error = process.terminate(before_id)
    if not terminated then error("terminate " .. name .. ": " .. tostring(terminate_error)) end
    await_exit(events, before_id, name)
    local ticker = time.ticker("50ms")
    local deadline = time.after("30s")
    while true do
        local now = process.registry.lookup(name)
        if now and tostring(now) ~= before_id then return end
        local selected = channel.select({ticker = ticker:channel():case_receive(), deadline = deadline:case_receive()})
        if not selected.ok or selected.channel == deadline then error(name .. " did not come back") end
    end
end
local function stop(name: string)
    local pid = process.registry.lookup(name)
    if not pid then error(name .. " is not registered") end
    local pid_id = tostring(pid)
    local events = assert(process.events())
    local monitored, monitor_error = process.monitor(pid_id)
    if not monitored then error("monitor " .. name .. ": " .. tostring(monitor_error)) end
    local terminated, terminate_error = process.terminate(pid_id)
    if not terminated then error("terminate " .. name .. ": " .. tostring(terminate_error)) end
    await_exit(events, pid_id, name)
end
local function wait_for_no_more_records(thread_id: string, expected: integer)
    local page = value(call(requester, "bee.threads.service:read_after", {thread_id = thread_id, cursor = 0, limit = 64,
        filter = {kinds = {"approval.request", "approval.transition"}}}))
    local cursor = math.floor(tonumber(page.scanned_through) or 0)
    local deadline_ms = math.floor(time.now():unix_nano() / 1000000) + 300
    while true do
        local remaining = deadline_ms - math.floor(time.now():unix_nano() / 1000000)
        if remaining <= 0 then break end
        local watched = value(call(requester, "bee.threads.delivery:watch", {thread_id = thread_id, after_sequence = cursor, wait_ms = remaining}))
        page = value(call(requester, "bee.threads.service:read_after", {thread_id = thread_id, cursor = cursor, limit = 64,
            filter = {kinds = {"approval.request", "approval.transition"}}}))
        cursor = math.floor(tonumber(page.scanned_through) or cursor)
        if watched.status == "timeout" then break end
    end
    test.eq(#thread_records(thread_id), expected)
end
local function unknown_answer(): model.Reply
    return model.unknown_reply()
end
local function refresh(state: model.State, owner: app_caller.Client)
    for _, workspace in ipairs(state.workspaces) do
        local more = true
        local pages = 0
        while more and pages < 8 do
            local intent = model.inbox_intent(state, workspace)
            more = model.apply_inbox(state, workspace, model.decode_reply(owner:invoke(intent.target, intent.request)) or unknown_answer())
            pages = pages + 1
        end
    end
end
local function open(state: model.State, owner: app_caller.Client, approval_id: string)
    model.select(state, approval_id)
    local intent = model.read_intent(state)
    if not intent then error("no read intent") end
    model.apply_read(state, approval_id, model.decode_reply(owner:invoke(intent.target, intent.request)) or unknown_answer())
end
local function decide(state: model.State, owner: app_caller.Client, decision: string)
    local request_id = key()
    local intent, refused = model.decision_intent(state, request_id, decision)
    if not intent then error("decision refused: " .. tostring(refused)) end
    model.apply_answer(state, request_id, model.decode_reply(owner:invoke(intent.target, intent.request)))
end
local function define_tests()
    test.describe("Approvals inbox recovery", function()
        install_policy()
        test.it("keeps one decision through an interrupted delivery and a restarted owner and inbox, replaying the delivery once", function()
            local workspace = "ws-" .. key():sub(1, 8)
            local approval_id, _, thread_id = file_on_thread(workspace)
            test.eq(#until_records(thread_id, 1), 1)
            local owner = through(alice)
            local state = model.new({workspace})
            refresh(state, owner)
            open(state, owner, approval_id)
            -- The delivery worker is gone when the decision commits.
            stop(WORKER)
            decide(state, owner, "approved")
            test.eq((assert(bounds.object(state.detail))).decision, "approved")
            test.eq(#thread_records(thread_id), 1)
            -- The owner authority and the inbox both restart.
            restart(AUTHORITY)
            local reopened = model.new({workspace})
            refresh(reopened, owner)
            open(reopened, owner, approval_id)
            local detail = assert(bounds.object(reopened.detail))
            test.eq(detail.state, "decided")
            test.eq(detail.decision, "approved")
            test.eq(detail.decider_id, ALICE)
            test.eq(detail.revision, (assert(bounds.object(state.detail))).revision)
            local records = until_records(thread_id, 2, approval_id)
            test.eq(#records, 2)
            test.eq((assert(bounds.object(records[2].body))).state, "approved")
            local _, refused = model.decision_intent(reopened, key(), "denied")
            test.eq(refused, "the request is decided")
            wait_for_no_more_records(thread_id, 2)
            restart(WORKER)
        end)
        test.it("advances no cursor past a page that never arrived and repeats nothing on replayed pages", function()
            local workspace = "ws-" .. key():sub(1, 8)
            local approval_id, _, thread_id = file_on_thread(workspace)
            local lost = true
            local flaky = inbox.new(function(target: string, request: unknown): (unknown, string?)
                if target == "bee.approvals.binding:inbox" and lost then return nil, "disconnected" end
                local raw, err = alice:call(target, request)
                if err then return nil, tostring(err) end
                return raw, nil
            end)
            local state = model.new({workspace})
            refresh(state, flaky)
            test.eq(#model.rows(state), 0)
            test.eq(model.inbox_intent(state, workspace).request.after_seq, 0)
            lost = false
            refresh(state, flaky)
            test.eq(#model.rows(state), 1)
            local advanced = model.inbox_intent(state, workspace).request.after_seq
            test.is_true(advanced >= 1)
            open(state, flaky, approval_id)
            decide(state, flaky, "approved")
            -- The same pages delivered again change nothing.
            model.reset_cursor(state, workspace)
            refresh(state, flaky)
            test.eq(#model.rows(state), 1)
            test.eq(state.rows[approval_id].decision, "approved")
            test.eq(model.inbox_intent(state, workspace).request.after_seq >= advanced, true)
            local _, refused = model.decision_intent(state, key(), "approved")
            test.eq(refused, "the request is decided")
            test.eq(#until_records(thread_id, 2, approval_id), 2)
            model.reset_cursor(state, workspace)
            refresh(state, flaky)
            wait_for_no_more_records(thread_id, 2)
        end)
        test.it("refuses execution whose authority was revoked after approval without rewriting the decision", function()
            local workspace = "ws-" .. key():sub(1, 8)
            local approval_id, digest = file_on_thread(workspace)
            local owner = through(alice)
            local state = model.new({workspace})
            refresh(state, owner)
            open(state, owner, approval_id)
            decide(state, owner, "approved")
            local incarnation = math.floor(tonumber((assert(bounds.object(state.detail))).owner_incarnation) or 0)
            local revoked = call(unconsuming, "bee.approvals.binding:consume", {approval_id = approval_id, proposal_digest = digest, effect_key = "e1", owner_incarnation = incarnation})
            test.is_false(revoked.ok)
            test.eq(revoked.error and revoked.error.code, "DENIED")
            refresh(state, owner)
            open(state, owner, approval_id)
            local detail = assert(bounds.object(state.detail))
            test.eq(detail.decision, "approved")
            test.eq(detail.decider_id, ALICE)
            test.is_nil(detail.consumer_id)
            local consumed = value(call(requester, "bee.approvals.binding:consume", {approval_id = approval_id, proposal_digest = digest, effect_key = "e1", owner_incarnation = incarnation}))
            test.eq(consumed.consumed_effect, "e1")
            open(state, owner, approval_id)
            test.eq((assert(bounds.object(state.detail))).consumer_id, REQUESTER)
        end)
        test.it("recovers requests, decisions and pending delivery after a headless owner restart with no inbox open", function()
            local workspace = "ws-" .. key():sub(1, 8)
            stop(WORKER)
            local approval_id, digest, thread_id = file_on_thread(workspace)
            test.eq(#thread_records(thread_id), 0)
            restart(AUTHORITY)
            local records = until_records(thread_id, 1, approval_id)
            test.eq(#records, 1)
            test.eq(records[1].kind, "approval.request")
            local owner = through(alice)
            local state = model.new({workspace})
            refresh(state, owner)
            open(state, owner, approval_id)
            local detail = assert(bounds.object(state.detail))
            test.eq(detail.state, "pending")
            test.eq(detail.revision, 1)
            decide(state, owner, "approved")
            local stale = call(requester, "bee.approvals.binding:consume", {approval_id = approval_id, proposal_digest = digest, effect_key = "e1", owner_incarnation = math.floor(tonumber(detail.owner_incarnation) or 0)})
            test.eq(stale.error and stale.error.code, "REVALIDATE")
            local current = math.floor(tonumber((assert(bounds.object(stale.value))).current_incarnation) or 0)
            value(call(requester, "bee.approvals.binding:revalidate", {approval_id = approval_id, proposal_digest = digest, owner_incarnation = current}))
            test.eq(value(call(requester, "bee.approvals.binding:consume", {approval_id = approval_id, proposal_digest = digest, effect_key = "e1", owner_incarnation = current})).consumed_effect, "e1")
            test.eq(#until_records(thread_id, 2, approval_id), 2)
            restart(WORKER)
        end)
    end)
end
return test.run_cases(define_tests)
