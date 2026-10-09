-- MIT. The approval owner: requests bound to a proposal digest under a host
-- policy, two approvers settling one decision, owner-enforced expiry, a
-- withdrawal racing a decision, unauthorized readers and approvers, a
-- changed proposal, consumption bound to one effect, the live worker
-- projecting onto a thread, and the outbox over its own store surviving a
-- crash between the thread commit and its acknowledgement.
local test = require("test")
local support = require("support")
local events = require("events")
local principals = require("principals")
local bounds = require("bounds")
local json = require("json")
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local time = require("time")
local process = require("process")
local channel = require("channel")
local sql = require("sql")
local service = require("service")
local worker = require("worker")
local resources = require("resources")
local outbox = require("outbox")
local dispatch = require("dispatch")
local demand = require("demand")
local schema = require("schema")
local thread_harness = require("thread_harness")
local TEST_STORE = "bee.approvals:test_db"
local REQUESTER, OTHER_REQUESTER, ALICE, BOB, OUTSIDER, MANAGER = "bee.test.launcher", "bee.test.other_launcher", "bee.test.alice", "bee.test.bob", "bee.test.outsider", "bee.test.manager"
local OUTBOX = "bee.test.outbox"
local POLICY = "test-owner"
local key, scope, caller = support.key, support.scope, support.caller
local requester = caller(REQUESTER, {"bee.security.approvals:approval_request_policy", "bee.security.approvals:approval_consume_policy", "bee.threads.security:create", "bee.threads.security:observe", "bee.threads.security:store"})
local launcher = thread_harness.principal(REQUESTER, thread_harness.ALL)
local stranger = thread_harness.principal("bee.test.stranger", thread_harness.ALL)
local other_requester = caller(OTHER_REQUESTER, {"bee.security.approvals:approval_request_policy"})
local alice = caller(ALICE, {"bee.security.approvals:approval_decide_policy"})
local bob = caller(BOB, {"bee.security.approvals:approval_decide_policy"})
local carol = caller("bee.test.carol", {"bee.security.approvals:approval_decide_policy"})
local outsider = caller(OUTSIDER, {})
local manager = caller(MANAGER, {"bee.approvals:manage_test_policy"})
local INBOX_ACTOR = "bee.application:0123456789abcdef0123456789abcdef:inbox-instance"
local inbox_app = caller(INBOX_ACTOR, {"bee.security.approvals:approval_decide_policy"},
    {definition_id = "bee.approvals.inbox.app:app", workspace_id = "0123456789abcdef0123456789abcdef"})
local other_app = caller("bee.application:0123456789abcdef0123456789abcdef:other-instance",
    {"bee.security.approvals:approval_decide_policy"}, {definition_id = "bee.settings.app:app"})
local owner = caller(OUTBOX, {"bee.security.approvals:approval_owner_policy", "bee.threads.security:approval", "bee.threads.security:approval_client", "bee.threads.security:store"})
local function call(client: funcs.Executor, method: string, value: unknown): service.Reply
    local reply, err = client:call("bee.approvals.binding:" .. method, value)
    if err then error(method .. ": " .. tostring(err)) end
    return principals.replayed_reply(reply)
end
local function value(reply: service.Reply): {[string]: unknown}
    if not reply.ok then error(tostring(reply.error and reply.error.code) .. ": " .. tostring(reply.error and reply.error.message)) end
    return assert(bounds.object(reply.value))
end
local function code(reply: service.Reply): string
    if reply.ok then error("expected a failure, got success") end
    return reply.error and reply.error.code or ""
end
local function await(future: funcs.Future): service.Reply
    local channel = future:response()
    local payload, open = channel:receive()
    local result, err = future:result()
    if err then error("async call: " .. tostring(err)) end
    if not open or not payload then error("async call closed without a reply") end
    local data: unknown = result:data()
    if type(data) ~= "table" then error("async call returned " .. type(data)) end
    return principals.replayed_reply(data)
end
local function open_test_store(): sql.DB
    return schema.open(TEST_STORE, "bee.approvals.migrations")
end
local function executed(result: {ok: boolean, code: string?, message: string?, value: unknown, replayed: boolean}): {[string]: unknown}
    if not result.ok then error(tostring(result.code) .. ": " .. tostring(result.message)) end
    return assert(bounds.object(result.value))
end
local function fault_value(reply: service.Reply): {[string]: unknown}
    if reply.ok then error("expected a failure, got success") end
    return assert(bounds.object(reply.value))
end
local function install_policy()
    local entry = registry.get("bee.security.approvals:approver_policies")
    if not entry then error("approver policies entry") end
    local data = assert(bounds.object(entry.data))
    local policies = principals.objects(data.policies)
    data.policies = policies
    for _, policy in ipairs(policies) do
        if policy.name == POLICY then return end
    end
    policies[#policies + 1] = {name = POLICY,
        approvers = {ALICE, BOB, "bee.test.carol", {definition_id = "bee.approvals.inbox.app:app"}}, max_ttl_ms = 60000}
    local changes = registry.snapshot():changes()
    changes:update(entry)
    local applied, err = changes:apply()
    if not applied then error("install approver policy: " .. tostring(err)) end
end
local function replace_approvers(value: {unknown})
    local entry = assert(registry.get("bee.security.approvals:approver_policies"))
    local data = assert(bounds.object(entry.data))
    local policies = principals.objects(data.policies)
    local selected: {[string]: unknown}? = nil
    for _, policy in ipairs(policies) do
        if policy.name == POLICY then selected = policy; break end
    end
    assert(selected, "test approver policy is missing")
    selected.approvers = value
    local changes = registry.snapshot():changes()
    assert(changes:update(entry))
    local applied, apply_error = changes:apply()
    if not applied then error("replace test approvers: " .. tostring(apply_error)) end
end
local function proposal(payload: {[string]: unknown}?): {[string]: unknown}
    return {kind = "operation", ref = "bee.harness.binding:start", revision = "r1", payload = payload or {profile = "claude", argv = {"--print"}}}
end
local function attempt_proposal(action_id: string?, attempt_id: string): {[string]: unknown}
    return {kind = "attempt", ref = attempt_id, revision = "r1", action_id = action_id, payload = {tool = "Bash", correlation_id = "c-1"}}
end
local function request_of(workspace: string, extra: {[string]: unknown}?): {[string]: unknown}
    local request: {[string]: unknown} = {workspace_id = workspace, idempotency_key = key(), request_kind = "permission", policy = POLICY, proposal = proposal(),
        prompt = {text = "Launch claude in " .. workspace .. "?"}}
    if extra then
        for name, item in pairs(extra) do request[name] = item end
    end
    return request
end
local function thread(): string
    local thread_id = "thread-" .. key()
    local reply, err = requester:call("bee.threads.binding:create", {thread_id = thread_id, idempotency_key = key(), title = "Approvals"})
    if err then error("create thread: " .. tostring(err)) end
    local typed = principals.replayed_reply(reply)
    if not typed.ok then error("create thread: " .. tostring(typed.error and typed.error.message)) end
    return thread_id
end
local function records_of(thread_id: string, kinds: {string}): {{[string]: unknown}}
    local reply, err = requester:call("bee.threads.binding:read_after", {thread_id = thread_id, cursor = 0, filter = {kinds = kinds}})
    if err then error("read thread: " .. tostring(err)) end
    local typed = principals.replayed_reply(reply)
    if not typed.ok then error("read thread: " .. tostring(typed.error and typed.error.message)) end
    local page = assert(bounds.object(typed.value))
    return principals.objects(page.records)
end
local function thread_records(thread_id: string): {{[string]: unknown}}
    return records_of(thread_id, {"approval.request", "approval.transition"})
end
local function await_records(thread_id: string, kinds: {string}, count: integer): {{[string]: unknown}}
    local guard_ms = math.floor(time.now():unix_nano() / 1000000) + 120000
    local records: {{[string]: unknown}} = {}
    local cursor = 0
    while #records < count do
        local reply, err = requester:call("bee.threads.binding:read_after", {thread_id = thread_id, cursor = cursor,
            limit = 64, filter = {kinds = kinds}})
        if err then error("read thread: " .. tostring(err)) end
        local page = value(principals.replayed_reply(reply))
        for _, item in ipairs(principals.objects(page.records)) do records[#records + 1] = item end
        cursor = math.floor(tonumber(page.scanned_through) or cursor)
        if #records >= count then break end
        if page.has_more ~= true then
            local remaining = guard_ms - math.floor(time.now():unix_nano() / 1000000)
            if remaining <= 0 then error("thread " .. thread_id .. " retained only " .. tostring(#records) .. " of " .. tostring(count) .. " records") end
            local watched, watch_error = requester:call("bee.threads.binding:watch", {thread_id = thread_id,
                after_sequence = cursor, wait_ms = remaining})
            if watch_error then error("watch thread: " .. tostring(watch_error)) end
            value(principals.replayed_reply(watched))
        end
    end
    return records
end
local function until_records(thread_id: string, count: integer): {{[string]: unknown}}
    return await_records(thread_id, {"approval.request", "approval.transition"}, count)
end
local function until_notices(thread_id: string, count: integer): {{[string]: unknown}}
    return await_records(thread_id, {"message"}, count)
end
local function effect_wake(approval_id: string, destination: string, name: string, mutate: () -> ())
    local wakes = assert(process.listen("bee.test.effect_delivery", {message = true}))
    assert(process.registry.register("bee.test.effect_delivery"))
    local ok, problem = pcall(function()
        mutate()
        local deadline = time.after("1s")
        while true do
            local selected = channel.select({wakes:case_receive(), deadline:case_receive()})
            test.eq(selected.ok, true)
            test.eq(selected.channel, wakes, "committed approval wake is not delivered")
            local supervisor = assert(process.registry.lookup(demand.SUPERVISOR, process.registry.LOCAL))
            test.eq(tostring(selected.value:from()), tostring(supervisor))
            local delivered = assert(bounds.object(selected.value:payload():data()))
            for _, raw in ipairs(assert(bounds.array(delivered.requests, 64))) do
                local request = assert(bounds.object(raw))
                local data = assert(bounds.object(request.data))
                local effect = bounds.object(data.effect)
                if effect and effect.approval_id == approval_id then
                    test.eq(delivered.name, name)
                    test.is_true(type(delivered.pid) == "string")
                    test.is_true(assert(bounds.integer(delivered.generation)) > 0)
                    test.eq(data.topic, service.TOPIC_WAKE)
                    test.eq(data.request_id, effect.event_id)
                    test.eq(effect.contract_version, 2)
                    test.eq(effect.revision, 2)
                    test.eq(effect.destination, destination)
                    return
                end
            end
        end
    end)
    process.registry.unregister("bee.test.effect_delivery")
    process.unlisten(wakes)
    if not ok then error(tostring(problem)) end
end
local function define_tests()
    test.describe("Approval owner", function()
        install_policy()
        test.it("exports pinned snapshots and scoped catch-up from the existing approval ledger", function()
            local workspace = "ws-feed-" .. key()
            local created = value(call(requester, "request", request_of(workspace)))
            value(call(requester, "request", request_of(workspace)))
            test.eq(code(call(outsider, "feed_snapshot", {workspace_id = workspace})), "DENIED")
            local first = value(call(alice, "feed_snapshot", {workspace_id = workspace, limit = 1}))
            test.eq(first.schema, "bee.sync-snapshot@1")
            test.eq(first.complete, false)
            test.eq(first.reset_required, false)
            local tail = value(call(alice, "feed_snapshot", {workspace_id = workspace, limit = 1,
                after_key = first.next_key, expected_cursor = first.cursor, expected_scope_revision = first.scope_revision}))
            test.eq(tail.complete, true)
            test.eq(tail.reset_required, false)
            local empty = value(call(alice, "feed_read_after", {workspace_id = workspace, cursor = first.cursor,
                expected_scope_revision = first.scope_revision}))
            test.eq(#(principals.items(empty.events)), 0)
            value(call(alice, "decide", {approval_id = created.approval_id, expected_revision = created.revision,
                proposal_digest = created.proposal_digest, reviewed_digest = created.reviewed_digest, decision = "approved"}))
            test.eq(code(call(alice, "feed_snapshot", {workspace_id = workspace, limit = 1,
                after_key = first.next_key, expected_cursor = first.cursor, expected_scope_revision = first.scope_revision})), "RESET_REQUIRED")
            local changed = value(call(alice, "feed_read_after", {workspace_id = workspace, cursor = first.cursor,
                expected_scope_revision = first.scope_revision}))
            local events = principals.objects(changed.events)
            test.eq(#events, 1)
            test.eq(events[1].event_type, "approval.changed")
            test.eq(events[1].projection_key, created.approval_id)
            test.eq(code(call(alice, "feed_read_after", {workspace_id = workspace, cursor = first.cursor,
                expected_scope_revision = string.rep("0", 64)})), "RESET_REQUIRED")
            test.eq(code(call(alice, "feed_read_after", {workspace_id = workspace, cursor = first.cursor,
                expected_scope_revision = {}})), "INVALID_ARGUMENT")
            test.eq(code(call(alice, "feed_snapshot", {workspace_id = workspace, expected_scope_revision = 7})), "INVALID_ARGUMENT")
        end)
        test.it("serves request, read and consume to an executor scoped like the activation owner", function()
            local activation = funcs.new():with_actor(security.new_actor("bee.gov.activation"))
                :with_scope(scope({"bee.security.approvals:approval_request_policy", "bee.security.approvals:approval_consume_policy"}))
            local workspace = "ws-activation-scope-" .. key()
            local created = value(call(activation, "request", request_of(workspace)))
            test.eq(value(call(activation, "read", {approval_id = created.approval_id})).state, "pending")
        end)
        test.it("admits grant administration only for the issuer with workspace decision authority", function()
            local workspace = "ws-window-admission-" .. key()
            local created = value(call(requester, "request", request_of(workspace)))
            local granted = value(call(alice, "decide", {approval_id = created.approval_id, expected_revision = created.revision,
                proposal_digest = created.proposal_digest, reviewed_digest = created.reviewed_digest, decision = "approved", window_ttl_ms = 60000}))
            local grant = assert(bounds.object(granted.window_grant))
            test.eq(code(call(outsider, "grant_window", {operation = "list", workspace_id = workspace})), "DENIED")
            local owned = value(call(alice, "grant_window", {operation = "list", workspace_id = workspace}))
            test.eq(#principals.items(owned.grants), 1)
            test.eq(#principals.items(value(call(bob, "grant_window", {operation = "list", workspace_id = workspace})).grants), 0)
            test.eq(code(call(bob, "grant_window", {operation = "revoke", grant_id = grant.grant_id})), "DENIED")
            test.eq(code(call(alice, "grant_window", {operation = "revoke", grant_id = grant.grant_id, workspace_id = "another-workspace"})), "DENIED")
            value(call(alice, "grant_window", {operation = "revoke", grant_id = grant.grant_id}))
            test.eq(value(call(requester, "request", request_of(workspace))).state, "pending")
        end)
        test.it("decides several requests of one requester as one batch", function()
            local workspace = "ws-batch-" .. key()
            local first = value(call(requester, "request", request_of(workspace)))
            local second = value(call(requester, "request", request_of(workspace)))
            local changed = assert(events.subscribe(service.ATTENTION, "approval.changed"))
            local settled = value(call(alice, "decide_batch", {decisions = {
                {approval_id = first.approval_id, expected_revision = first.revision, proposal_digest = first.proposal_digest, reviewed_digest = first.reviewed_digest, decision = "approved"},
                {approval_id = second.approval_id, expected_revision = second.revision, proposal_digest = second.proposal_digest, reviewed_digest = second.reviewed_digest, decision = "denied"}}}))
            local views = principals.objects(settled.decisions)
            test.eq(#views, 2)
            test.eq(views[1].decision, "approved")
            test.eq(views[2].decision, "denied")
            local update = channel.select({changed:channel():case_receive(), time.after("1s"):case_receive()})
            changed:close()
            test.eq(update.channel, changed:channel())
            test.eq(assert(bounds.object(update.value.data)).count, 0)
            test.eq(value(call(alice, "read", {approval_id = first.approval_id})).state, "decided")
        end)
        test.it("refuses a batch across requesters or with a stale item without deciding any", function()
            local workspace = "ws-batch-mixed-" .. key()
            local mine = value(call(requester, "request", request_of(workspace)))
            local theirs = value(call(other_requester, "request", request_of(workspace)))
            local item = function(view: {[string]: unknown}, revision: integer?): {[string]: unknown}
                return {approval_id = view.approval_id, expected_revision = revision or view.revision,
                    proposal_digest = view.proposal_digest, reviewed_digest = view.reviewed_digest, decision = "approved"}
            end
            test.eq(code(call(alice, "decide_batch", {decisions = {item(mine), item(theirs)}})), "INVALID_ARGUMENT")
            test.eq(code(call(alice, "decide_batch", {decisions = {item(mine), item(mine)}})), "INVALID_ARGUMENT")
            local sibling = value(call(requester, "request", request_of(workspace)))
            test.eq(code(call(alice, "decide_batch", {decisions = {item(mine), item(sibling, 9)}})), "CONFLICT")
            test.eq(value(call(alice, "read", {approval_id = mine.approval_id})).state, "pending")
            test.eq(code(call(outsider, "decide_batch", {decisions = {item(mine)}})), "DENIED")
        end)
        test.it("wakes the Gateway owner for installation when an approval decision commits", function()
            local workspace = "ws-effect-wake-" .. key()
            local created = value(call(requester, "request", request_of(workspace, {proposal = {kind = "operation", ref = "bee.hub:apply", revision = "1", payload = {}}})))
            effect_wake(assert(bounds.id(created.approval_id)), "gateway.installation", "bee.gateway.external", function()
                value(call(alice, "decide", {approval_id = created.approval_id, expected_revision = created.revision,
                    proposal_digest = created.proposal_digest, reviewed_digest = created.reviewed_digest, decision = "approved"}))
            end)
        end)
        test.it("wakes the Gateway owner for publication when an approval decision commits", function()
            local workspace = "ws-publish-wake-" .. key()
            local created = value(call(requester, "request", request_of(workspace, {proposal = {kind = "operation", ref = "bee.hub:publish", revision = "1", payload = {}}})))
            effect_wake(assert(bounds.id(created.approval_id)), "gateway.publication", "bee.gateway.external", function()
                value(call(alice, "decide", {approval_id = created.approval_id, expected_revision = created.revision,
                    proposal_digest = created.proposal_digest, reviewed_digest = created.reviewed_digest, decision = "approved"}))
            end)
        end)
        test.it("wakes the activation worker and lists an approved activation until it is consumed", function()
            local workspace = "ws-activation-" .. key()
            local activation = {kind = "operation", ref = "bee.gov:establish-overlay", revision = "r1", payload = {source_workspace = "todo"}}
            local created = value(call(requester, "request", request_of(workspace, {proposal = activation})))
            local unrelated = value(call(requester, "request", request_of(workspace)))
            local worker = caller("bee.test.activation_worker", {"bee.security.approvals:approval_activation_effects_policy"})
            local function listed(): {[string]: boolean}
                local found: {[string]: boolean} = {}
                for _, item in ipairs(value(call(worker, "effect_queue", {destination = "gov.activation", phase = "ready", limit = 64})).effects :: {unknown}) do
                    found[tostring((item :: {[string]: unknown}).approval_id)] = true
                end
                return found
            end
            test.is_nil(listed()[tostring(created.approval_id)])
            effect_wake(assert(bounds.id(created.approval_id)), "gov.activation", "bee.gov.activation_worker", function()
                for _, request in ipairs({created, unrelated}) do
                    value(call(alice, "decide", {approval_id = request.approval_id, expected_revision = request.revision,
                        proposal_digest = request.proposal_digest, reviewed_digest = request.reviewed_digest, decision = "approved"}))
                end
            end)
            local approved = listed()
            test.is_true(approved[tostring(created.approval_id)])
            test.is_nil(approved[tostring(unrelated.approval_id)])
            local effect_id = assert(bounds.id(assert(bounds.object(created.effect)).effect_id))
            value(call(requester, "effect", {operation = "claim", approval_id = created.approval_id, proposal_digest = created.proposal_digest,
                effect_key = effect_id, owner_incarnation = created.owner_incarnation}))
            test.is_true(listed()[tostring(created.approval_id)])
            value(call(requester, "effect", {operation = "complete", approval_id = created.approval_id,
                proposal_digest = created.proposal_digest, effect_key = effect_id, result = {ok = true}}))
            test.is_nil(listed()[tostring(created.approval_id)])
            test.eq(code(call(outsider, "effect_queue", {destination = "gov.activation", phase = "ready"})), "DENIED")
        end)
        test.it("lists an activation that ended without approval until its requester closes it", function()
            local workspace = "ws-closure-" .. key()
            local activation = {kind = "operation", ref = "bee.gov:establish-overlay", revision = "r1", payload = {source_workspace = "todo"}}
            local denied = value(call(requester, "request", request_of(workspace, {proposal = activation})))
            local expired = value(call(requester, "request", request_of(workspace, {proposal = activation, ttl_ms = 1})))
            local withdrawn = value(call(requester, "request", request_of(workspace, {proposal = activation})))
            local approved = value(call(requester, "request", request_of(workspace, {proposal = activation})))
            local unrelated = value(call(requester, "request", request_of(workspace)))
            value(call(alice, "decide", {approval_id = denied.approval_id, expected_revision = denied.revision,
                proposal_digest = denied.proposal_digest, reviewed_digest = denied.reviewed_digest, decision = "denied"}))
            value(call(alice, "decide", {approval_id = approved.approval_id, expected_revision = approved.revision,
                proposal_digest = approved.proposal_digest, reviewed_digest = approved.reviewed_digest, decision = "approved"}))
            value(call(alice, "decide", {approval_id = unrelated.approval_id, expected_revision = unrelated.revision,
                proposal_digest = unrelated.proposal_digest, reviewed_digest = unrelated.reviewed_digest, decision = "denied"}))
            value(call(requester, "withdraw", {approval_id = withdrawn.approval_id, expected_revision = withdrawn.revision, proposal_digest = withdrawn.proposal_digest}))
            time.sleep("5ms")
            local store = open_test_store()
            executed(service.execute(store, OUTBOX, "reconcile", {}, nil, nil))
            store:release()
            local worker = caller("bee.test.activation_worker", {"bee.security.approvals:approval_activation_effects_policy"})
            local function listed(): {[string]: string}
                local found: {[string]: string} = {}
                for _, item in ipairs(value(call(worker, "effect_queue", {destination = "gov.activation", phase = "ended", limit = 64})).effects :: {unknown}) do
                    local row = assert(bounds.object(item))
                    found[tostring(row.approval_id)] = tostring(row.state) .. ":" .. tostring(row.decision)
                end
                return found
            end
            local ended = listed()
            test.eq(ended[tostring(denied.approval_id)], "decided:denied")
            test.eq(ended[tostring(expired.approval_id)], "expired:nil")
            test.eq(ended[tostring(withdrawn.approval_id)], "withdrawn:nil")
            test.is_nil(ended[tostring(approved.approval_id)])
            test.is_nil(ended[tostring(unrelated.approval_id)])
            test.eq(code(call(other_requester, "effect", {operation = "complete", result = {closed = true}, approval_id = denied.approval_id,
                proposal_digest = denied.proposal_digest})), "DENIED")
            test.eq(code(call(requester, "effect", {operation = "complete", result = {closed = true}, approval_id = approved.approval_id,
                proposal_digest = approved.proposal_digest})), "CONFLICT")
            value(call(requester, "effect", {operation = "complete", result = {closed = true}, approval_id = denied.approval_id, proposal_digest = denied.proposal_digest}))
            test.eq(call(requester, "effect", {operation = "complete", result = {closed = true}, approval_id = denied.approval_id,
                proposal_digest = denied.proposal_digest}).replayed, true)
            local remaining = listed()
            test.is_nil(remaining[tostring(denied.approval_id)])
            test.eq(remaining[tostring(expired.approval_id)], "expired:nil")
            test.eq(code(call(outsider, "effect_queue", {destination = "gov.activation", phase = "ended"})), "DENIED")
        end)
        test.it("announces a request waiting for the person on the node attention events", function()
            local workspace = "ws-attention-" .. key()
            local subscription = assert(events.subscribe(service.ATTENTION, "approval.requested"))
            local created = value(call(requester, "request", request_of(workspace)))
            local announced: {[string]: unknown}? = nil
            while not announced do
                local selected = channel.select({subscription:channel():case_receive(), time.after("1s"):case_receive()})
                if selected.channel ~= subscription:channel() then break end
                local event = selected.value
                if event.path == workspace then announced = event end
            end
            subscription:close()
            local event = assert(announced)
            test.eq(event.kind, "approval.requested")
            local data = assert(bounds.object(event.data))
            test.eq(data.approval_id, created.approval_id)
            test.eq(data.count, 1)
            test.eq(data.title, assert(bounds.object(created.prompt)).text)
            local sibling = value(call(requester, "request", request_of(workspace, {prompt = {text = "Review the remaining request"}})))
            local changed = assert(events.subscribe(service.ATTENTION, "approval.changed"))
            value(call(requester, "withdraw", {approval_id = created.approval_id, expected_revision = created.revision, proposal_digest = created.proposal_digest}))
            local update = channel.select({changed:channel():case_receive(), time.after("1s"):case_receive()})
            changed:close()
            test.eq(update.channel, changed:channel())
            local remaining = assert(bounds.object(update.value.data))
            test.eq(remaining.count, 1)
            test.eq(remaining.approval_id, sibling.approval_id)
            test.eq(remaining.title, "Review the remaining request")
        end)
        test.it("serves no request before the authority establishes its incarnation and advances it per start", function()
            local store = open_test_store()
            local before = service.execute(store, REQUESTER, "request", request_of("ws-" .. key()), nil, requester)
            test.eq(before.ok, false)
            test.eq(before.code, "UNAVAILABLE")
            test.eq(assert(service.establish(store)), 1)
            test.eq(assert(service.establish(store)), 2)
            local created = executed(service.execute(store, REQUESTER, "request", request_of("ws-" .. key()), nil, requester))
            test.eq(created.owner_incarnation, 2)
            store:release()
            local pid = process.registry.lookup(service.AUTHORITY_NAME)
            test.eq(pid ~= nil, true)
        end)
        test.it("fails closed on a corrupt authority incarnation for requests and restart", function()
            local store = open_test_store()
            local owner_node, node_error = service.node()
            if not owner_node then error("read native node identity: " .. tostring(node_error)) end
            local rows, read_error = store:query("SELECT incarnation FROM bee_approval_authority WHERE owner_node = ?", {owner_node})
            if read_error or not rows or #rows == 0 then error("read authority incarnation: " .. tostring(read_error)) end
            local previous = rows[1].incarnation
            local _, corrupt_error = store:execute("UPDATE bee_approval_authority SET incarnation = 'broken' WHERE owner_node = ?", {owner_node})
            test.eq(corrupt_error, nil)
            local request = service.execute(store, REQUESTER, "request", request_of("ws-" .. key()), nil, requester)
            test.eq(request.ok, false)
            test.eq(request.code, "STORAGE")
            local established, establish_error = service.establish(store)
            test.eq(established, nil)
            test.is_true((establish_error or ""):find("corrupt", 1, true) ~= nil)
            local _, restore_error = store:execute("UPDATE bee_approval_authority SET incarnation = ? WHERE owner_node = ?", {previous, owner_node})
            test.eq(restore_error, nil)
            store:release()
        end)
        test.it("rejects corrupt persisted approval effect metadata", function()
            local store = open_test_store()
            local created = executed(service.execute(store, REQUESTER, "request", request_of("ws-" .. key()), nil, requester))
            local _, corrupt_error = store:execute("UPDATE bee_approval_requests SET validated_incarnation = 'broken' WHERE approval_id = ?", {created.approval_id})
            test.eq(corrupt_error, nil)
            local result = service.execute(store, REQUESTER, "read", {approval_id = created.approval_id}, nil, nil)
            test.eq(result.ok, false)
            test.eq(result.code, "STORAGE")
            local _, restore_error = store:execute("UPDATE bee_approval_requests SET validated_incarnation = NULL WHERE approval_id = ?", {created.approval_id})
            test.eq(restore_error, nil)
            local _, version_error = store:execute("UPDATE bee_approval_requests SET contract_version = 99 WHERE approval_id = ?", {created.approval_id})
            test.eq(version_error, nil)
            test.eq(service.execute(store, REQUESTER, "read", {approval_id = created.approval_id}, nil, nil).code, "STORAGE")
            local _, reset_error = store:execute("UPDATE bee_approval_requests SET contract_version = ? WHERE approval_id = ?", {created.contract_version, created.approval_id})
            test.eq(reset_error, nil)
            store:release()
        end)
        test.it("fences stale authority: consumption after a restart needs revalidation under the current incarnation", function()
            local store = open_test_store()
            local before = assert(service.establish(store))
            local created = executed(service.execute(store, REQUESTER, "request", request_of("ws-" .. key()), nil, requester))
            local approval_id, digest = created.approval_id, created.proposal_digest
            executed(service.execute(store, ALICE, "decide", {approval_id = approval_id, expected_revision = 1, decision = "approved", proposal_digest = digest}, nil, nil))
            local after = assert(service.establish(store))
            test.eq(after, before + 1)
            local stale = service.execute(store, REQUESTER, "consume", {approval_id = approval_id, proposal_digest = digest, effect_key = "e1", owner_incarnation = before}, nil, nil)
            test.eq(stale.code, "REVALIDATE")
            test.eq((assert(bounds.object(stale.value))).current_incarnation, after)
            local unvalidated = service.execute(store, REQUESTER, "consume", {approval_id = approval_id, proposal_digest = digest, effect_key = "e1", owner_incarnation = after}, nil, nil)
            test.eq(unvalidated.code, "REVALIDATE")
            test.eq(service.execute(store, REQUESTER, "revalidate", {approval_id = approval_id, proposal_digest = digest, owner_incarnation = before}, nil, nil).code, "REVALIDATE")
            local validated = executed(service.execute(store, REQUESTER, "revalidate", {approval_id = approval_id, proposal_digest = digest, owner_incarnation = after}, nil, nil))
            test.eq(validated.validated_incarnation, after)
            test.eq(validated.validated_by, REQUESTER)
            test.eq(service.execute(store, REQUESTER, "revalidate", {approval_id = approval_id, proposal_digest = digest, owner_incarnation = after}, nil, nil).replayed, true)
            local consumed = executed(service.execute(store, REQUESTER, "consume", {approval_id = approval_id, proposal_digest = digest, effect_key = "e1", owner_incarnation = after}, nil, nil))
            test.eq(consumed.consumed_effect, "e1")
            local again = assert(service.establish(store))
            local fenced = service.execute(store, REQUESTER, "consume", {approval_id = approval_id, proposal_digest = digest, effect_key = "e1", owner_incarnation = again}, nil, nil)
            test.eq(fenced.code, "REVALIDATE")
            store:release()
        end)
        test.it("binds a request to its proposal digest under the host policy and replays or conflicts on its key", function()
            local workspace = "ws-" .. key()
            test.eq(code(call(outsider, "request", request_of(workspace))), "DENIED")
            test.eq(code(call(requester, "request", request_of(workspace, {policy = "nope"}))), "NOT_FOUND")
            test.eq(code(call(requester, "request", request_of(workspace, {ttl_ms = 60001}))), "FORBIDDEN")
            test.eq(code(call(requester, "request", request_of(workspace, {proposal = {kind = "attempt", ref = "x", revision = "r1", payload = {big = string.rep("x", 9000)}}}))), "INVALID_ARGUMENT")
            local first_request = request_of(workspace)
            local created = value(call(requester, "request", first_request))
            test.eq(created.state, "pending")
            test.eq(created.revision, 1)
            test.eq(created.requester_id, REQUESTER)
            test.eq(#(created.proposal_digest), 64)
            test.eq(created.owner_incarnation ~= nil, true)
            local replayed = call(requester, "request", first_request)
            test.eq(value(replayed).approval_id, created.approval_id)
            test.eq(replayed.replayed, true)
            first_request.prompt = {text = "changed"}
            test.eq(code(call(requester, "request", first_request)), "CONFLICT")
            local listed = value(call(requester, "list", {workspace_id = workspace}))
            test.eq(#(principals.items(listed.requests)), 1)
            test.eq(#(principals.items(value(call(other_requester, "list", {workspace_id = workspace})).requests)), 0)
        end)
        test.it("replays upgraded callers against unchanged legacy authority without recreating requests", function()
            local db = open_test_store()
            local asked = request_of("ws-legacy-replay-" .. key(), {ttl_ms = 10,
                proposal = {kind = "operation", ref = "bee.test:effect", revision = "1", payload = {target = "same"}}})
            local created = executed(service.execute(db, REQUESTER, "request", asked, 1000, nil))
            local _, legacy_error = db:execute([[UPDATE bee_approval_requests SET contract_version = 1,
                reviewed_digest = proposal_digest, effect_admission_ms = expires_ms,
                contract_json = json_set(contract_json, '$.provenance', json_object('kind','legacy'))
                WHERE approval_id = ?]], {created.approval_id})
            test.eq(legacy_error, nil)
            asked.contract_version = 2
            asked.subject = {principal_id = REQUESTER}
            asked.origin = {action_id = "legacy-action"}
            asked.continuation = {destination = "fixture.effect", effect_id = "upgraded-effect", context = {}}
            local replay = service.execute(db, REQUESTER, "request", asked, 1001, nil)
            local original = executed(replay)
            test.eq(replay.replayed, true)
            test.eq(original.approval_id, created.approval_id)
            test.eq(original.request_digest, created.request_digest)
            test.eq(original.contract_version, 1)
            test.eq(original.effect_admission_ms, 1010)
            test.eq(assert(bounds.object(original.effect)).effect_id, assert(bounds.object(created.effect)).effect_id)
            asked.subject = {principal_id = OTHER_REQUESTER}
            test.eq(service.execute(db, REQUESTER, "request", asked, 1001, nil).code, "CONFLICT")
            asked.subject = {principal_id = REQUESTER}
            asked.scope = {type = "exact", parameters = {target = "different"}}
            test.eq(service.execute(db, REQUESTER, "request", asked, 1001, nil).code, "CONFLICT")
            asked.scope = nil
            asked.evidence = {{ref = "test:preflight", digest = string.rep("a",64)}}
            test.eq(service.execute(db, REQUESTER, "request", asked, 1001, nil).code, "CONFLICT")
            asked.evidence = nil
            asked.effect_admission_ms = 1011
            test.eq(service.execute(db, REQUESTER, "request", asked, 1001, nil).code, "CONFLICT")
            test.eq(assert(db:query("SELECT COUNT(*) AS count FROM bee_approval_requests WHERE requester_key = ?", {asked.idempotency_key}))[1].count, 1)
            db:release()
        end)
        test.it("serializes identical request creation and a decision racing fenced withdrawal", function()
            local workspace = "ws-races-" .. key()
            local asked = request_of(workspace)
            local first = requester:async("bee.approvals.binding:request", asked)
            local second = requester:async("bee.approvals.binding:request", asked)
            local a, b = await(first), await(second)
            local created = value(a)
            test.eq(value(b).approval_id, created.approval_id)
            test.eq((a.replayed and 1 or 0) + (b.replayed and 1 or 0), 1)
            local decision = alice:async("bee.approvals.binding:decide", {approval_id = created.approval_id,
                expected_revision = 1, proposal_digest = created.proposal_digest, reviewed_digest = created.reviewed_digest,
                decision = "approved"})
            local withdrawal = requester:async("bee.approvals.binding:withdraw", {approval_id = created.approval_id,
                expected_revision = 1, proposal_digest = created.proposal_digest, reviewed_digest = created.reviewed_digest})
            local decided, withdrawn = await(decision), await(withdrawal)
            local actual = value(call(requester, "read", {approval_id = created.approval_id}))
            test.eq(actual.revision, 2)
            test.eq(actual.state == "decided" or actual.state == "withdrawn", true)
            test.eq(value(withdrawn).withdrawn, actual.state == "withdrawn")
            test.eq(decided.ok, actual.state == "decided")
            local replay = call(requester, "request", asked)
            test.eq(replay.replayed, true)
            test.eq(value(replay).approval_id, created.approval_id)
        end)
        test.it("routes a third-party continuation using registry metadata and fences its stable identity", function()
            local db = open_test_store()
            local created = executed(service.execute(db, REQUESTER, "request", request_of("ws-extension-" .. key(),
                {proposal = {kind = "operation", ref = "bee.test:effect", revision = "1", payload = {}},
                    continuation = {destination = "fixture.effect", effect_id = "fixture-" .. key(), context = {target = "test"}}}), 1000, nil))
            executed(service.execute(db, ALICE, "decide", {approval_id = created.approval_id, expected_revision = 1,
                proposal_digest = created.proposal_digest, reviewed_digest = created.reviewed_digest, decision = "allow_once"}, 1001, nil))
            local queued = executed(service.execute(db, OUTBOX, "effect_queue", {destination = "fixture.effect"}, 1002, nil))
            test.eq(#assert(bounds.array(queued.effects, 64)), 1)
            test.eq(service.execute(db, REQUESTER, "effect", {operation = "claim", approval_id = created.approval_id,
                proposal_digest = created.proposal_digest, effect_key = "different", owner_incarnation = created.owner_incarnation}, 1003, nil).code, "CONFLICT")
            local effect = assert(bounds.object(created.effect))
            local claimed = executed(service.execute(db, REQUESTER, "effect", {operation = "claim", approval_id = created.approval_id,
                proposal_digest = created.proposal_digest, effect_key = effect.effect_id, owner_incarnation = created.owner_incarnation}, 1003, nil))
            local after = assert(service.establish(db))
            local current_effect = assert(bounds.object(claimed.effect))
            local start = {operation = "start", approval_id = created.approval_id, proposal_digest = created.proposal_digest,
                effect_key = effect.effect_id, expected_revision = current_effect.revision, owner_incarnation = after}
            test.eq(service.execute(db, REQUESTER, "effect", start, 1004, nil).code, "REVALIDATE")
            executed(service.execute(db, REQUESTER, "revalidate", {approval_id = created.approval_id,
                proposal_digest = created.proposal_digest, owner_incarnation = after}, 1004, nil))
            local started = executed(service.execute(db, REQUESTER, "effect", start, 1005, nil))
            test.eq(assert(bounds.object(started.effect)).state, "started")
            executed(service.execute(db, REQUESTER, "effect", {operation = "complete", approval_id = created.approval_id,
                proposal_digest = created.proposal_digest, effect_key = effect.effect_id, result = {ok = true}}, 1006, nil))
            db:release()
        end)
        test.it("lets two eligible approvers race to one decision and reports every other outcome honestly", function()
            local workspace = "ws-" .. key()
            local created = value(call(requester, "request", request_of(workspace)))
            local approval_id, digest = created.approval_id, created.proposal_digest
            test.eq(code(call(outsider, "read", {approval_id = approval_id})), "DENIED")
            test.eq(value(call(alice, "read", {approval_id = approval_id})).approval_id, approval_id)
            test.eq(value(call(manager, "read", {approval_id = approval_id})).approval_id, approval_id)
            test.eq(code(call(outsider, "decide", {approval_id = approval_id, expected_revision = 1, decision = "approved", proposal_digest = digest})), "DENIED")
            test.eq(code(call(alice, "decide", {approval_id = approval_id, expected_revision = 1, decision = "approved", proposal_digest = string.rep("0", 64)})), "CONFLICT")
            local a = alice:async("bee.approvals.binding:decide", {approval_id = approval_id, expected_revision = 1, decision = "approved", proposal_digest = digest})
            local b = bob:async("bee.approvals.binding:decide", {approval_id = approval_id, expected_revision = 1, decision = "denied", proposal_digest = digest})
            local wins = 0
            for _, future in ipairs({a, b}) do
                if await(future).ok then wins = wins + 1 end
            end
            test.eq(wins, 1)
            local decided = value(call(alice, "read", {approval_id = approval_id}))
            test.eq(decided.state, "decided")
            test.eq(decided.revision, 2)
            local winner, decision = decided.decider_id, decided.decision
            local winner_client = alice
            local loser_client = bob
            local loser_decision = "denied"
            if winner == BOB then
                winner_client, loser_client, loser_decision = bob, alice, "approved"
            end
            local retry = call(winner_client, "decide", {approval_id = approval_id, expected_revision = 1, decision = decision, proposal_digest = digest})
            test.eq(retry.replayed, true)
            local conflict = call(loser_client, "decide", {approval_id = approval_id, expected_revision = 1, decision = loser_decision, proposal_digest = digest})
            test.eq(code(conflict), "CONFLICT")
            test.eq(fault_value(conflict).decision, decision)
            local withdrawn = value(call(requester, "withdraw", {approval_id = approval_id, expected_revision = 1, proposal_digest = digest}))
            test.eq(withdrawn.withdrawn, false)
            test.eq((assert(bounds.object(withdrawn.request))).state, "decided")
        end)
        test.it("admits a host-selected application definition while retaining its private actor", function()
            local workspace = "ws-" .. key()
            local created = value(call(requester, "request", request_of(workspace, {
                proposal = proposal({definition_id = "bee.approvals.inbox.app:app"})})))
            local approval_id, digest = created.approval_id, created.proposal_digest
            test.eq(code(call(other_app, "read", {approval_id = approval_id})), "DENIED")
            test.eq(value(call(inbox_app, "read", {approval_id = approval_id})).approval_id, approval_id)
            local decided = value(call(inbox_app, "decide", {approval_id = approval_id,
                expected_revision = 1, decision = "approved", proposal_digest = digest}))
            test.eq(decided.decider_id, INBOX_ACTOR)
            test.eq(decided.state, "decided")
        end)
        test.it("rejects malformed application definition selectors", function()
            local valid: {unknown} = {ALICE, BOB, "bee.test.carol", {definition_id = "bee.approvals.inbox.app:app"}}
            for _, invalid in ipairs({{{}}, {{definition_id = ""}},
                    {{definition_id = "bee.approvals.inbox.app:app", extra = true}}}) do
                replace_approvers(principals.items(invalid))
                local decoded, decode_error = resources.policies()
                test.eq(decoded, nil)
                test.eq(type(decode_error), "string")
            end
            replace_approvers(valid)
            local decoded, decode_error = resources.policies()
            test.eq(decode_error, nil)
            test.eq(decoded ~= nil, true)
        end)
        test.it("rejects malformed policy envelopes, sparse lists, duplicate names and fractional TTLs", function()
            local entry = assert(registry.get("bee.security.approvals:approver_policies"))
            local original, encode_error = json.encode(entry.data)
            if not original then error("encode approver policy fixture: " .. tostring(encode_error)) end
            local function write(data: {[string]: unknown})
                local current = assert(registry.get("bee.security.approvals:approver_policies"))
                current.data = data
                local changes = registry.snapshot():changes()
                assert(changes:update(current))
                local applied, apply_error = changes:apply()
                if not applied then error("write approver policy fixture: " .. tostring(apply_error)) end
            end
            local function mutated(change: ({[string]: unknown}) -> ())
                local data = assert(bounds.object(json.decode(original)))
                change(data)
                write(data)
                local policies, decode_error = resources.policies()
                test.eq(policies, nil)
                test.eq(type(decode_error), "string")
            end
            mutated(function(data)
                data.unexpected = true
            end)
            mutated(function(data)
                local policies = principals.objects(data.policies)
                data.policies = policies
                local selected: {[string]: unknown}? = nil
                for _, policy in ipairs(policies) do
                    if policy.name == POLICY then selected = policy; break end
                end
                assert(selected)
                local invalid: unknown = {[1] = ALICE, [3] = BOB}
                selected.approvers = invalid
            end)
            mutated(function(data)
                local policies = principals.objects(data.policies)
                data.policies = policies
                local selected: {[string]: unknown}? = nil
                for _, policy in ipairs(policies) do
                    if policy.name == POLICY then selected = policy; break end
                end
                assert(selected)
                local duplicate: {[string]: unknown} = {}
                for name, value in pairs(selected) do duplicate[name] = value end
                policies[#policies + 1] = duplicate
            end)
            mutated(function(data)
                local policies = principals.objects(data.policies)
                for _, policy in ipairs(policies) do
                    if policy.name == POLICY then policy.max_ttl_ms = 1.5; break end
                end
            end)
            write(assert(bounds.object(json.decode(original))))
            local decoded, decode_error = resources.policies()
            test.eq(decode_error, nil)
            test.eq(decoded ~= nil, true)
        end)
        test.it("fences reservations on revocation and preserves already admitted effect receipts", function()
            local db = open_test_store()
            local function allowed(): {[string]: unknown}
                local created = executed(service.execute(db, REQUESTER, "request", request_of("ws-grant-" .. key()), 1000, nil))
                return executed(service.execute(db, ALICE, "decide", {approval_id = created.approval_id,
                    expected_revision = 1, proposal_digest = created.proposal_digest, decision = "allow_once"}, 1001, nil))
            end
            local approved = allowed()
            local contract = assert(bounds.object(approved.contract))
            local grant: {[string]: unknown} = {operation = "reserve", grant_id = tostring(approved.approval_id) .. ":grant",
                expected_revision = 1, subject = contract.subject, scope = contract.scope, effect_key = "reserved-use"}
            local reserved = executed(service.execute(db, REQUESTER, "grant", grant, 1002, nil))
            test.eq(reserved.revision, 2)
            local reservation = executed(service.execute(db,REQUESTER,"grant",{operation = "read",grant_id = grant.grant_id},1002,nil))
            test.eq(assert(bounds.object(reservation.grant)).reserved,1)
            test.eq(assert(bounds.object(reservation.grant)).used,0)
            test.eq(service.execute(db, REQUESTER, "effect", {operation = "claim", approval_id = approved.approval_id,
                proposal_digest = approved.proposal_digest, effect_key = "different-use", owner_incarnation = approved.owner_incarnation}, 1003, nil).code, "CONFLICT")
            grant.operation, grant.expected_revision, grant.owner_incarnation = "admit", 1, approved.owner_incarnation
            test.eq(service.execute(db, REQUESTER, "grant", grant, 1003, nil).code, "CONFLICT")
            executed(service.execute(db, REQUESTER, "grant", {operation = "revoke", grant_id = grant.grant_id, expected_revision = 2}, 1003, nil))
            test.eq(service.execute(db, REQUESTER, "effect", {operation = "claim", approval_id = approved.approval_id,
                proposal_digest = approved.proposal_digest, effect_key = "reserved-use", owner_incarnation = approved.owner_incarnation}, 1004, nil).code, "INVALID_STATE")
            local admitted = allowed()
            executed(service.execute(db, REQUESTER, "effect", {operation = "claim", approval_id = admitted.approval_id,
                proposal_digest = admitted.proposal_digest, effect_key = "admitted-use", owner_incarnation = admitted.owner_incarnation}, 1002, nil))
            local revoked = executed(service.execute(db, REQUESTER, "grant", {operation = "revoke",
                grant_id = tostring(admitted.approval_id) .. ":grant", expected_revision = 2}, 1003, nil))
            test.eq(revoked.already_admitted, true)
            local receipt = {operation = "complete", approval_id = admitted.approval_id, proposal_digest = admitted.proposal_digest,
                effect_key = "admitted-use", result = {ok = true}}
            executed(service.execute(db, REQUESTER, "effect", receipt, 1004, nil))
            test.eq(service.execute(db, REQUESTER, "effect", receipt, 100000, nil).replayed, true)
            db:release()
        end)
        test.it("redelivers every terminal effect event and idempotent receipt completion stops further wakes", function()
            local db = open_test_store()
            local targets: {[string]: {[string]: unknown}} = {}
            local ids: {string} = {}
            for _, outcome in ipairs({"approved", "denied", "expired", "withdrawn", "superseded", "invalidated"}) do
                local created = executed(service.execute(db, REQUESTER, "request", request_of("ws-dispatch-" .. key(),
                    {ttl_ms = 10, proposal = {kind = "operation", ref = "bee.gov:establish-overlay", revision = "1", payload = {}}}), 1000, nil))
                local id = tostring(created.approval_id)
                targets[id] = created; ids[#ids + 1] = id
                local fence: {[string]: unknown} = {approval_id = id, expected_revision = 1,
                    proposal_digest = created.proposal_digest, reviewed_digest = created.reviewed_digest}
                if outcome == "approved" or outcome == "denied" then
                    fence.decision = outcome; executed(service.execute(db, ALICE, "decide", fence, 1005, nil))
                elseif outcome == "expired" then executed(service.execute(db, OUTBOX, "reconcile", {}, 1011, nil))
                elseif outcome == "withdrawn" then executed(service.execute(db, REQUESTER, "withdraw", fence, 1005, nil))
                else fence.outcome = outcome; executed(service.execute(db, REQUESTER, "end_request", fence, 1005, nil)) end
            end
            local deliveries: {[string]: integer} = {}
            local function send(worker_name: string, topic: string, body: {[string]: unknown}): (boolean, string?)
                test.eq(topic, service.TOPIC_WAKE)
                local id = tostring(body.approval_id)
                if targets[id] then
                    test.eq(worker_name, "bee.gov.activation_worker")
                    test.eq(body.destination, "gov.activation")
                    deliveries[id] = (deliveries[id] or 0) + 1
                end
                return true, nil
            end
            assert(dispatch.deliver(db, send))
            assert(dispatch.deliver(db, send))
            local applied = 0
            for _, id in ipairs(ids) do
                test.eq(deliveries[id], 2)
                local created = targets[id]
                local current = executed(service.execute(db, REQUESTER, "read", {approval_id = id}, 1012, nil))
                local receipt: {[string]: unknown} = {operation = "complete", approval_id = id,
                    proposal_digest = created.proposal_digest, result = {closed = true}}
                if current.decision == "approved" then
                    local claim: {[string]: unknown} = {operation = "claim", approval_id = id,
                        proposal_digest = created.proposal_digest, owner_incarnation = created.owner_incarnation,
                        effect_key = id}
                    executed(service.execute(db, REQUESTER, "effect", claim, 1012, nil))
                    test.eq(service.execute(db, REQUESTER, "effect", claim, 1012, nil).replayed, true)
                    receipt.effect_key, receipt.result = id, {ok = true}
                    applied = applied + 1
                end
                executed(service.execute(db, REQUESTER, "effect", receipt, 1013, nil))
                test.eq(service.execute(db, REQUESTER, "effect", receipt, 1014, nil).replayed, true)
                receipt.result = {different = true}
                test.eq(service.execute(db, REQUESTER, "effect", receipt, 1015, nil).code, "CONFLICT")
            end
            assert(dispatch.deliver(db, send))
            for _, id in ipairs(ids) do test.eq(deliveries[id], 2) end
            test.eq(applied, 1)
            db:release()
        end)
        test.it("durably notifies every terminal outcome without a thread and closes waiting effects", function()
            local db = open_test_store()
            local expected = {approved = "approval.decided", denied = "approval.denied", expired = "approval.expired",
                withdrawn = "approval.withdrawn", superseded = "approval.superseded", invalidated = "approval.invalidated"}
            for outcome, event_kind in pairs(expected) do
                local created = executed(service.execute(db, REQUESTER, "request", request_of("ws-terminal-" .. key(), {ttl_ms = 10}), 1000, nil))
                local fence: {[string]: unknown} = {approval_id = created.approval_id, expected_revision = 1, proposal_digest = created.proposal_digest}
                if outcome == "approved" or outcome == "denied" then
                    fence.decision = outcome
                    executed(service.execute(db, ALICE, "decide", fence, 1005, nil))
                elseif outcome == "expired" then executed(service.execute(db, OUTBOX, "reconcile", {}, 1011, nil))
                elseif outcome == "withdrawn" then executed(service.execute(db, REQUESTER, "withdraw", fence, 1005, nil))
                else fence.outcome = outcome; executed(service.execute(db, REQUESTER, "end_request", fence, 1005, nil)) end
                local events = assert(db:query("SELECT * FROM bee_approval_events WHERE approval_id = ? ORDER BY seq", {created.approval_id}))
                test.eq(#events, 2)
                test.eq(events[2].kind, event_kind)
                test.eq(events[2].acknowledged_at, nil)
                local read = executed(service.execute(db, REQUESTER, "read", {approval_id = created.approval_id}, 1012, nil))
                test.eq(assert(bounds.object(read.effect)).state, outcome == "approved" and "authorized" or "canceled")
                executed(service.execute(db, REQUESTER, "events", {acknowledge = {events[2].event_id}}, 1013, nil))
                executed(service.execute(db, REQUESTER, "events", {acknowledge = {events[2].event_id}}, 1014, nil))
                local acknowledged = assert(db:query("SELECT acknowledged_at FROM bee_approval_events WHERE event_id = ?", {events[2].event_id}))
                test.eq(acknowledged[1].acknowledged_at ~= nil, true)
            end
            db:release()
        end)
        test.it("binds subject, scope and reviewed evidence to an immutable request", function()
            local db = open_test_store()
            local asked = request_of("ws-contract-" .. key(), {contract_version = 2, subject = {principal_id = "subject-test"},
                scope = {type = "exact", parameters = {target = "one"}}, presentation = "inline",
                evidence = {{ref = "test:preflight", digest = string.rep("a", 64)}}})
            local created = executed(service.execute(db, REQUESTER, "request", asked, 1000, nil))
            test.eq(created.contract_version, 2)
            local contract = assert(bounds.object(created.contract))
            test.eq(assert(bounds.object(contract.requester)).actor_id, REQUESTER)
            test.eq(assert(bounds.object(contract.subject)).principal_id, "subject-test")
            test.eq(service.execute(db, REQUESTER, "withdraw", {approval_id = created.approval_id, expected_revision = 1,
                proposal_digest = created.proposal_digest}, 1001, nil).code, "CONFLICT")
            local fence: {[string]: unknown} = {approval_id = created.approval_id, expected_revision = 1, proposal_digest = created.proposal_digest,
                reviewed_digest = string.rep("0", 64), decision = "approved"}
            test.eq(service.execute(db, ALICE, "decide", fence, 1001, nil).code, "CONFLICT")
            fence.reviewed_digest = created.reviewed_digest
            executed(service.execute(db, ALICE, "decide", fence, 1001, nil))
            asked.evidence = {{ref = "test:preflight", digest = string.rep("b", 64)}}
            test.eq(service.execute(db, REQUESTER, "request", asked, 1002, nil).code, "CONFLICT")
            local records = assert(db:query("SELECT kind, reviewed_digest FROM bee_approval_decisions WHERE approval_id = ?", {created.approval_id}))
            test.eq(records[1].kind, "allow_once")
            test.eq(records[1].reviewed_digest, created.reviewed_digest)
            db:release()
        end)
        test.it("keeps uncertain effects queued until their receipt is reconciled", function()
            local db = open_test_store()
            local created = executed(service.execute(db, REQUESTER, "request", request_of("ws-uncertain-" .. key(),
                {proposal = {kind = "operation", ref = "bee.test:effect", revision = "1", payload = {}},
                    continuation = {destination = "fixture.effect", effect_id = "uncertain-" .. key(), context = {}}}), 1000, nil))
            executed(service.execute(db, ALICE, "decide", {approval_id = created.approval_id, expected_revision = 1,
                proposal_digest = created.proposal_digest, reviewed_digest = created.reviewed_digest, decision = "allow_once"}, 1001, nil))
            local effect_id = assert(bounds.object(created.effect)).effect_id
            executed(service.execute(db, REQUESTER, "effect", {operation = "claim", approval_id = created.approval_id,
                proposal_digest = created.proposal_digest, effect_key = effect_id, owner_incarnation = created.owner_incarnation}, 1002, nil))
            local receipt = {operation = "complete", approval_id = created.approval_id, proposal_digest = created.proposal_digest,
                effect_key = effect_id, state = "uncertain", result = {ok = false, outcome = "uncertain"}}
            local uncertain = executed(service.execute(db, REQUESTER, "effect", receipt, 1003, nil))
            test.eq(uncertain.effect_completed_at, nil)
            test.eq(service.execute(db, REQUESTER, "effect", receipt, 1004, nil).replayed, true)
            local queue = executed(service.execute(db, OUTBOX, "effect_queue", {destination = "fixture.effect"}, 1004, nil))
            local found = false
            for _, raw in ipairs(assert(bounds.array(queue.effects, 64))) do
                if assert(bounds.object(raw)).approval_id == created.approval_id then found = true end
            end
            test.eq(found, true)
            receipt.state, receipt.result = "succeeded", {ok = true}
            executed(service.execute(db, REQUESTER, "effect", receipt, 1005, nil))
            test.eq(service.execute(db, REQUESTER, "effect", receipt, 1006, nil).replayed, true)
            db:release()
        end)
        test.it("keeps the answer on its separate decision record", function()
            local db = open_test_store()
            local created = executed(service.execute(db, REQUESTER, "request", request_of("ws-answer-" .. key(),
                {request_kind = "question"}), 1000, nil))
            executed(service.execute(db, ALICE, "decide", {approval_id = created.approval_id, expected_revision = 1,
                proposal_digest = created.proposal_digest, decision = "answer", response = {text = "continue"}}, 1001, nil))
            local records = assert(db:query("SELECT kind, response_json FROM bee_approval_decisions WHERE approval_id = ?", {created.approval_id}))
            test.eq(records[1].kind, "answer")
            test.eq(assert(bounds.object(json.decode(records[1].response_json))).text, "continue")
            db:release()
        end)
        test.it("separates the decision deadline from effect admission and keeps completed receipt replay", function()
            local db = open_test_store()
            local created = executed(service.execute(db, REQUESTER, "request", request_of("ws-deadline-" .. key(),
                {ttl_ms = 10, effect_admission_ms = 2000}), 1000, requester))
            executed(service.execute(db, ALICE, "decide", {approval_id = created.approval_id,
                expected_revision = 1, proposal_digest = created.proposal_digest, reviewed_digest = created.reviewed_digest, decision = "approved"}, 1005, nil))
            local claim = {approval_id = created.approval_id, proposal_digest = created.proposal_digest,
                effect_key = "deadline-effect", owner_incarnation = created.owner_incarnation}
            local consumed = executed(service.execute(db, REQUESTER, "consume", claim, 1500, nil))
            test.eq(consumed.consumed_effect, "deadline-effect")
            test.eq(service.execute(db, REQUESTER, "consume", claim, 3000, nil).replayed, true)
            db:release()
        end)
        test.it("fences withdrawal against the reviewed revision and digest and reports the committed race winner", function()
            local created = value(call(requester, "request", request_of("ws-withdraw-" .. key())))
            test.eq(code(call(requester, "withdraw", {approval_id = created.approval_id,
                expected_revision = 2, proposal_digest = created.proposal_digest})), "CONFLICT")
            test.eq(code(call(requester, "withdraw", {approval_id = created.approval_id,
                expected_revision = 1, proposal_digest = string.rep("0", 64)})), "CONFLICT")
            value(call(alice, "decide", {approval_id = created.approval_id, expected_revision = 1,
                proposal_digest = created.proposal_digest, reviewed_digest = created.reviewed_digest, decision = "approved"}))
            local raced = value(call(requester, "withdraw", {approval_id = created.approval_id,
                expected_revision = 1, proposal_digest = created.proposal_digest}))
            test.eq(raced.withdrawn, false)
            test.eq(assert(bounds.object(raced.request)).decision, "approved")
        end)
        test.it("enforces expiry at the owner, lets only the requester withdraw and binds consumption to one effect", function()
            local workspace = "ws-" .. key()
            local short = value(call(requester, "request", request_of(workspace, {ttl_ms = 1})))
            time.sleep("5ms")
            local late = call(alice, "decide", {approval_id = short.approval_id, expected_revision = 1, decision = "approved", proposal_digest = short.proposal_digest, reviewed_digest = short.reviewed_digest})
            test.eq(code(late), "INVALID_STATE")
            test.eq(fault_value(late).state, "expired")
            local pending = value(call(requester, "request", request_of(workspace)))
            test.eq(code(call(other_requester, "withdraw", {approval_id = pending.approval_id, expected_revision = pending.revision, proposal_digest = pending.proposal_digest})), "DENIED")
            local withdrawn = value(call(requester, "withdraw", {approval_id = pending.approval_id, expected_revision = pending.revision, proposal_digest = pending.proposal_digest}))
            test.eq(withdrawn.withdrawn, true)
            test.eq((assert(bounds.object(withdrawn.request))).state, "withdrawn")
            test.eq(code(call(bob, "decide", {approval_id = pending.approval_id, expected_revision = 1, decision = "approved", proposal_digest = pending.proposal_digest, reviewed_digest = pending.reviewed_digest})), "INVALID_STATE")
            test.eq(code(call(outsider, "reconcile", {})), "DENIED")
            local store = open_test_store()
            local due = executed(service.execute(store, REQUESTER, "request", request_of(workspace, {ttl_ms = 1}), nil, requester))
            time.sleep("5ms")
            local reconciled = executed(service.execute(store, OUTBOX, "reconcile", {}, nil, nil))
            test.eq(reconciled.expired, 1)
            test.eq(executed(service.execute(store, REQUESTER, "read", {approval_id = due.approval_id}, nil, nil)).state, "expired")
            test.eq(executed(service.execute(store, OUTBOX, "reconcile", {}, nil, nil)).expired, 0)
            store:release()
            local approved = value(call(requester, "request", request_of(workspace)))
            local incarnation = approved.owner_incarnation
            test.eq(code(call(requester, "consume", {approval_id = approved.approval_id, proposal_digest = approved.proposal_digest, effect_key = "launch-1", owner_incarnation = incarnation})), "INVALID_STATE")
            value(call(bob, "decide", {approval_id = approved.approval_id, expected_revision = 1, decision = "approved", proposal_digest = approved.proposal_digest, reviewed_digest = approved.reviewed_digest}))
            test.eq(code(call(other_requester, "consume", {approval_id = approved.approval_id, proposal_digest = approved.proposal_digest, effect_key = "launch-1", owner_incarnation = incarnation})), "DENIED")
            test.eq(code(call(requester, "consume", {approval_id = approved.approval_id, proposal_digest = string.rep("1", 64), effect_key = "launch-1", owner_incarnation = incarnation})), "CONFLICT")
            local stale = call(requester, "consume", {approval_id = approved.approval_id, proposal_digest = approved.proposal_digest, effect_key = "launch-1", owner_incarnation = assert(bounds.integer(incarnation)) + 1})
            test.eq(code(stale), "REVALIDATE")
            test.eq(fault_value(stale).consumed_effect, nil)
            local consumed = value(call(requester, "consume", {approval_id = approved.approval_id, proposal_digest = approved.proposal_digest, effect_key = "launch-1", owner_incarnation = incarnation}))
            test.eq(consumed.consumed_effect, "launch-1")
            test.eq(consumed.consumer_id, REQUESTER)
            test.eq(call(requester, "consume", {approval_id = approved.approval_id, proposal_digest = approved.proposal_digest, effect_key = "launch-1", owner_incarnation = incarnation}).replayed, true)
            test.eq(code(call(requester, "consume", {approval_id = approved.approval_id, proposal_digest = approved.proposal_digest, effect_key = "launch-2", owner_incarnation = incarnation})), "CONFLICT")
            local denied = value(call(requester, "request", request_of(workspace)))
            value(call(bob, "decide", {approval_id = denied.approval_id, expected_revision = 1, decision = "denied", proposal_digest = denied.proposal_digest, reviewed_digest = denied.reviewed_digest}))
            test.eq(code(call(requester, "consume", {approval_id = denied.approval_id, proposal_digest = denied.proposal_digest, effect_key = "launch-3", owner_incarnation = incarnation})), "INVALID_STATE")
        end)
        test.it("shows approvers a bounded inbox of the requests their policy covers and nothing to anyone else", function()
            local workspace = "ws-" .. key()
            local created = value(call(requester, "request", request_of(workspace)))
            test.eq(code(call(outsider, "inbox", {workspace_id = workspace})), "DENIED")
            test.eq(code(call(alice, "inbox", {workspace_id = workspace, limit = 65})), "INVALID_ARGUMENT")
            local page = value(call(alice, "inbox", {workspace_id = workspace, limit = 1}))
            local changes = principals.objects(page.changes)
            test.eq(#changes, 1)
            test.eq(changes[1].approval_id, created.approval_id)
            test.eq(changes[1].revision, 1)
            value(call(carol, "decide", {approval_id = created.approval_id, expected_revision = 1, decision = "denied", proposal_digest = created.proposal_digest, reviewed_digest = created.reviewed_digest}))
            local rest = value(call(bob, "inbox", {workspace_id = workspace, after_seq = page.next_seq}))
            local later = principals.objects(rest.changes)
            test.eq(#later, 1)
            test.eq(later[1].revision, 2)
            test.eq((assert(bounds.object(later[1].request))).decision, "denied")
        end)
        test.it("counts node pending approvals through the public binding without granting request access", function()
            local reader = caller("node-summary-reader", {"bee.approvals:summary_test_policy"})
            test.eq(code(call(outsider, "node_summary", {})), "DENIED")
            local before = value(call(reader, "node_summary", {}))
            local baseline = before.pending_approvals
            if type(baseline) ~= "number" then error("invalid pending approval count") end
            local created = value(call(requester, "request", request_of("summary-" .. key())))
            test.eq(code(call(reader, "read", {approval_id = created.approval_id})), "DENIED")
            local pending = value(call(reader, "node_summary", {}))
            test.eq(pending.pending_approvals, baseline + 1)
            test.eq(pending.items, nil)
            test.eq(pending.requests, nil)
            test.eq(code(call(reader, "node_summary", {workspace_id = "not-admitted"})), "INVALID_ARGUMENT")
            value(call(alice, "decide", {approval_id = created.approval_id, expected_revision = 1,
                decision = "denied", proposal_digest = created.proposal_digest, reviewed_digest = created.reviewed_digest}))
            test.eq(value(call(reader, "node_summary", {})).pending_approvals, before.pending_approvals)
            value(call(requester, "request", request_of("summary-expiry-" .. key(), {ttl_ms = 1})))
            time.sleep("5ms")
            test.eq(value(call(reader, "node_summary", {})).pending_approvals, before.pending_approvals)
        end)
        test.it("projects requests and decisions onto the thread through the worker exactly once", function()
            local workspace = "ws-" .. key()
            local thread_id = thread_harness.thread(launcher, "Approvals")
            thread_harness.value(launcher:call("admit_action", {thread_id = thread_id, idempotency_key = key(), action_id = "a1", admitted = thread_harness.admitted()}))
            thread_harness.value(launcher:call("prepare_attempt", {thread_id = thread_id, idempotency_key = key(), action_id = "a1", attempt_id = "t1", prepared = thread_harness.prepared()}))
            test.eq(code(call(requester, "request", request_of(workspace, {thread_id = thread_id, proposal = attempt_proposal(nil, "t1")}))), "INVALID_ARGUMENT")
            test.eq(code(call(requester, "request", request_of(workspace, {thread_id = thread_id, proposal = attempt_proposal("a1", "t9")}))), "INVALID_ARGUMENT")
            test.eq(code(call(requester, "request", request_of(workspace, {thread_id = thread_id, proposal = attempt_proposal("a9", "t1")}))), "INVALID_ARGUMENT")
            local created = value(call(requester, "request", request_of(workspace, {thread_id = thread_id, proposal = attempt_proposal("a1", "t1")})))
            local binding = assert(bounds.object(created.binding))
            test.eq(binding.attempt_id, "t1")
            test.eq(binding.record_id ~= nil, true)
            local approval_id = created.approval_id
            local rows = principals.objects(value(call(requester, "deliveries", {approval_id = approval_id})).deliveries)
            test.eq(#rows, 1)
            test.eq(rows[1].event_id, approval_id .. ":1")
            local records = until_records(thread_id, 1)
            test.eq(#records, 1)
            test.eq(records[1].kind, "approval.request")
            test.eq(records[1].attempt_id, "t1")
            test.eq((assert(bounds.object(records[1].body))).requester_id, REQUESTER)
            value(call(alice, "decide", {approval_id = approval_id, expected_revision = 1, decision = "approved", proposal_digest = created.proposal_digest, reviewed_digest = created.reviewed_digest, response = {text = "go"}}))
            records = until_records(thread_id, 2)
            if #records ~= 2 then
                local pendings = principals.objects(value(call(requester, "deliveries", {approval_id = approval_id})).deliveries)
                error("transition not delivered: " .. tostring(pendings[2] and pendings[2].last_error) .. " attempts " .. tostring(pendings[2] and pendings[2].attempts))
            end
            local body = assert(bounds.object(records[2].body))
            test.eq(body.state, "approved")
            test.eq(body.decider_id, ALICE)
            test.eq(body.expected_revision, 1)
            test.eq((assert(bounds.object(body.response))).text, "go")
            -- The transition record owes nobody anything, so the outcome is
            -- also addressed to the requester: the obligation it creates is
            -- what the delivery layer carries to the waiting agent.
            local notices = until_notices(thread_id, 1)
            test.eq(#notices, 1)
            local acked = principals.objects(value(call(requester, "deliveries", {approval_id = approval_id})).deliveries)
            test.eq(#acked, 3)
            test.eq(acked[2].acknowledged_at ~= nil, true)
            test.eq(acked[3].event_id, approval_id .. ":2:notice")
            test.eq(acked[3].kind, "message")
            test.eq(code(call(requester, "deliveries", {approval_id = approval_id, redeliver = approval_id .. ":2"})), "DENIED")
            test.eq(code(call(manager, "deliveries", {approval_id = approval_id, redeliver = approval_id .. ":2"})), "INVALID_STATE")
            test.eq(#thread_records(thread_id), 2)
            local notice = assert(bounds.object(notices[1].body))
            test.eq(notice.message_kind, "notification")
            test.eq(notice.sender_id, service.WORKER_NAME)
            test.eq((principals.strings(notice.recipient_ids))[1], REQUESTER)
            test.eq((assert(bounds.object(notice.content))).text, "Approval " .. approval_id .. " is approved.")
            local claimed = thread_harness.value(launcher:call("claim", {thread_id = thread_id, idempotency_key = key(), consumer_id = "inbox", limit = 4}))
            local pending = principals.objects(claimed.deliveries)
            test.eq(#pending, 1)
            test.eq(pending[1].message_id, notice.message_id)
            -- A refusal is announced on the same path: what leaves an agent
            -- waiting is the silence, not the answer.
            local refused = value(call(requester, "request", request_of(workspace, {thread_id = thread_id})))
            local refused_id = refused.approval_id
            value(call(alice, "decide", {approval_id = refused_id, expected_revision = 1, decision = "denied", proposal_digest = refused.proposal_digest, reviewed_digest = refused.reviewed_digest}))
            local both = until_notices(thread_id, 2)
            test.eq(#both, 2)
            local denial = assert(bounds.object(both[2].body))
            test.eq((assert(bounds.object(denial.content))).text, "Approval " .. refused_id .. " is denied.")
        end)
        test.it("survives a crash between the thread commit and the outbox acknowledgement without a duplicate record", function()
            local workspace = "ws-" .. key()
            local thread_id = thread()
            local db = open_test_store()
            local created = executed(service.execute(db, REQUESTER, "request", request_of(workspace, {thread_id = thread_id}), nil, requester))
            test.eq((assert(bounds.object(created.binding))).role, "owner")
            local approval_id = created.approval_id
            local honest = outbox.thread_sender(owner)
            local sent = 0
            local report = assert(outbox.drain(db, "holder", function(delivery): (boolean, string?)
                sent = sent + 1
                local ok, err = honest(delivery)
                if not ok then return false, err end
                return false, "transport lost before acknowledgement"
            end))
            test.eq(report.claimed, 1)
            test.eq(report.failed, 1)
            test.eq(sent, 1)
            test.eq(#thread_records(thread_id), 1)
            local unacked = assert(outbox.deliveries(db, approval_id))[1]
            test.eq(unacked.attempts, 1)
            test.eq(unacked.acknowledged_at, nil)
            test.eq(unacked.last_error, "transport lost before acknowledgement")
            local idle = assert(outbox.drain(db, "holder", honest))
            test.eq(idle.claimed, 0)
            local _, reset_error = db:execute("UPDATE bee_approval_outbox SET next_attempt_ms = 0 WHERE event_id = ?", {approval_id .. ":1"})
            test.eq(reset_error, nil)
            local again = assert(outbox.drain(db, "holder", honest))
            test.eq(again.delivered, 1)
            local records = thread_records(thread_id)
            test.eq(#records, 1)
            test.eq(records[1].kind, "approval.request")
            local acked = assert(outbox.deliveries(db, approval_id))[1]
            test.eq(acked.acknowledged_at ~= nil, true)
            local repeated = assert(outbox.drain(db, "holder", honest))
            test.eq(repeated.claimed, 0)
            test.eq(service.execute(db, REQUESTER, "request", request_of(workspace, {thread_id = "thread-missing"}), nil, requester).code, "NOT_FOUND")
            local foreign = thread_harness.thread(stranger, "Foreign")
            test.eq(service.execute(db, REQUESTER, "request", request_of(workspace, {thread_id = foreign}), nil, requester).code, "DENIED")
            local later = executed(service.execute(db, REQUESTER, "request", request_of(workspace, {thread_id = thread_id}), nil, requester))
            local delivered_later = assert(outbox.drain(db, "holder", honest))
            test.eq(delivered_later.delivered, 1)
            test.eq(#thread_records(thread_id), 2)
            db:release()
        end)
        test.it("runs the owner worker under its own actor", function()
            local pid = process.registry.lookup(service.WORKER_NAME)
            test.eq(pid ~= nil, true)
            local capabilities = value(call(outsider, "capabilities", {}))
            test.eq(capabilities.projection, "thread_outbox_at_least_once")
            test.eq(capabilities.expiry, "owner_reconcile")
            test.eq(capabilities.dedupe_horizon, "retention_after_expiry")
        end)
        test.it("keeps reconciliation and outbox drain failures diagnosable", function()
            local reconcile_error = worker.run_pass(function(): service.Reply
                return {ok = false, error = {code = "STORAGE", message = "authority store is corrupt"}, value = nil, replayed = false}
            end, function(): string?
                error("drain must not run after reconciliation fails")
            end)
            test.eq(reconcile_error, "STORAGE: authority store is corrupt")
            local drain_error = worker.run_pass(function(): service.Reply
                return {ok = true, error = nil, value = nil, replayed = false}
            end, function(): string?
                return "database busy"
            end)
            test.eq(drain_error, "drain approval outbox: database busy")
        end)
    end)
end
return test.run_cases(define_tests)
