-- MIT. The approval owner: requests bound to a proposal digest under a host
-- policy, two approvers settling one decision, owner-enforced expiry, a
-- withdrawal racing a decision, unauthorized readers and approvers, a
-- changed proposal, consumption bound to one effect, the live worker
-- projecting onto a thread, and the outbox over its own store surviving a
-- crash between the thread commit and its acknowledgement.
local test = require("test")
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local time = require("time")
local process = require("process")
local sql = require("sql")
local uuid = require("uuid")
local service = require("service")
local outbox = require("outbox")
local migrations = require("migrations")
local persist = require("persist")
local thread_harness = require("thread_harness")
local TEST_STORE = "bee.approvals:test_db"
local REQUESTER, OTHER_REQUESTER, ALICE, BOB, OUTSIDER, MANAGER = "bee.test.launcher", "bee.test.other_launcher", "bee.test.alice", "bee.test.bob", "bee.test.outsider", "bee.test.manager"
local OUTBOX = "bee.test.outbox"
local POLICY = "test-owner"
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
    local names: {string} = {"bee.approvals:client_test_policy"}
    for _, grant in ipairs(grants) do names[#names + 1] = grant end
    return funcs.new():with_actor(security.new_actor(id)):with_scope(scope(names))
end
local requester = caller(REQUESTER, {"bee:approval_request_policy", "bee:approval_consume_policy", "bee:thread_create_policy", "bee:thread_observe_policy", "bee:thread_storage_policy", "bee:thread_resource_policy"})
local launcher = thread_harness.principal(REQUESTER, thread_harness.ALL)
local stranger = thread_harness.principal("bee.test.stranger", thread_harness.ALL)
local other_requester = caller(OTHER_REQUESTER, {"bee:approval_request_policy"})
local alice = caller(ALICE, {"bee:approval_decide_policy"})
local bob = caller(BOB, {"bee:approval_decide_policy"})
local carol = caller("bee.test.carol", {"bee:approval_decide_policy"})
local outsider = caller(OUTSIDER, {})
local manager = caller(MANAGER, {"bee:approval_manage_policy"})
local owner = caller(OUTBOX, {"bee:approval_owner_policy", "bee:thread_approval_policy", "bee:thread_approval_client_policy", "bee:thread_storage_policy", "bee:thread_resource_policy"})
local function call(client: funcs.Executor, method: string, value: unknown): service.Reply
    local reply, err = client:call("bee.approvals:" .. method, value)
    if err then error(method .. ": " .. tostring(err)) end
    return reply :: service.Reply
end
local function value(reply: service.Reply): {[string]: unknown}
    if not reply.ok then error(tostring(reply.error and reply.error.code) .. ": " .. tostring(reply.error and reply.error.message)) end
    return reply.value :: {[string]: unknown}
end
local function code(reply: service.Reply): string
    if reply.ok then error("expected a failure, got success") end
    return reply.error and reply.error.code or ""
end
local function await(future: any): service.Reply
    local channel = future:response()
    local payload, open = channel:receive()
    local result, err = future:result()
    if err then error("async call: " .. tostring(err)) end
    if not open or not payload then error("async call closed without a reply") end
    local data: unknown = result:data()
    if type(data) ~= "table" then error("async call returned " .. type(data)) end
    return data :: service.Reply
end
local function open_test_store(): sql.DB
    local db, err = persist.open({resource = TEST_STORE, ledger = service.LEDGER, migrations = migrations.all()})
    if not db then error("open test store: " .. tostring(err)) end
    return db
end
local function executed(result: {ok: boolean, code: string?, message: string?, value: unknown, replayed: boolean}): {[string]: unknown}
    if not result.ok then error(tostring(result.code) .. ": " .. tostring(result.message)) end
    return result.value :: {[string]: unknown}
end
local function fault_value(reply: service.Reply): {[string]: unknown}
    if reply.ok then error("expected a failure, got success") end
    return reply.value :: {[string]: unknown}
end
local function install_policy()
    local entry = registry.get("bee.approvals:approver_policies")
    if not entry then error("approver policies entry") end
    local data = entry.data :: {[string]: unknown}
    local policies = data.policies :: {{[string]: unknown}}
    for _, policy in ipairs(policies) do
        if policy.name == POLICY then return end
    end
    policies[#policies + 1] = {name = POLICY, approvers = {ALICE, BOB, "bee.test.carol"}, max_ttl_ms = 60000}
    local changes = registry.snapshot():changes()
    changes:update(entry)
    local applied, err = changes:apply()
    if not applied then error("install approver policy: " .. tostring(err)) end
end
local function proposal(payload: {[string]: unknown}?): {[string]: unknown}
    return {kind = "operation", ref = "bee.harness.launch:start", revision = "r1", payload = payload or {profile = "claude", argv = {"--print"}}}
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
    local reply, err = requester:call("bee.threads.service:create", {thread_id = thread_id, idempotency_key = key(), title = "Approvals"})
    if err then error("create thread: " .. tostring(err)) end
    local typed = reply :: service.Reply
    if not typed.ok then error("create thread: " .. tostring(typed.error and typed.error.message)) end
    return thread_id
end
local function thread_records(thread_id: string): {{[string]: unknown}}
    local reply, err = requester:call("bee.threads.service:read_after", {thread_id = thread_id, cursor = 0, filter = {kinds = {"approval.request", "approval.transition"}}})
    if err then error("read thread: " .. tostring(err)) end
    local typed = reply :: service.Reply
    if not typed.ok then error("read thread: " .. tostring(typed.error and typed.error.message)) end
    local page = typed.value :: {[string]: unknown}
    return page.records :: {{[string]: unknown}}
end
local function until_records(thread_id: string, count: integer): {{[string]: unknown}}
    local records: {{[string]: unknown}} = {}
    for _ = 1, 100 do
        records = thread_records(thread_id)
        if #records >= count then return records end
        time.sleep("50ms")
    end
    return records
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
            test.eq(#(empty.events :: {unknown}), 0)
            value(call(alice, "decide", {approval_id = created.approval_id, expected_revision = created.revision,
                proposal_digest = created.proposal_digest, decision = "approved"}))
            test.eq(code(call(alice, "feed_snapshot", {workspace_id = workspace, limit = 1,
                after_key = first.next_key, expected_cursor = first.cursor, expected_scope_revision = first.scope_revision})), "RESET_REQUIRED")
            local changed = value(call(alice, "feed_read_after", {workspace_id = workspace, cursor = first.cursor,
                expected_scope_revision = first.scope_revision}))
            local events = changed.events :: {{[string]: unknown}}
            test.eq(#events, 1)
            test.eq(events[1].event_type, "approval.changed")
            test.eq(events[1].projection_key, created.approval_id)
            test.eq(code(call(alice, "feed_read_after", {workspace_id = workspace, cursor = first.cursor,
                expected_scope_revision = string.rep("0", 64)})), "RESET_REQUIRED")
            test.eq(code(call(alice, "feed_read_after", {workspace_id = workspace, cursor = first.cursor,
                expected_scope_revision = {}})), "INVALID")
            test.eq(code(call(alice, "feed_snapshot", {workspace_id = workspace, expected_scope_revision = 7})), "INVALID")
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
        test.it("fences stale authority: consumption after a restart needs revalidation under the current incarnation", function()
            local store = open_test_store()
            local before = assert(service.establish(store))
            local created = executed(service.execute(store, REQUESTER, "request", request_of("ws-" .. key()), nil, requester))
            local approval_id, digest = created.approval_id :: string, created.proposal_digest :: string
            executed(service.execute(store, ALICE, "decide", {approval_id = approval_id, expected_revision = 1, decision = "approved", proposal_digest = digest}, nil, nil))
            local after = assert(service.establish(store))
            test.eq(after, before + 1)
            local stale = service.execute(store, REQUESTER, "consume", {approval_id = approval_id, proposal_digest = digest, effect_key = "e1", owner_incarnation = before}, nil, nil)
            test.eq(stale.code, "REVALIDATE")
            test.eq((stale.value :: {[string]: unknown}).current_incarnation, after)
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
            test.eq(code(call(requester, "request", request_of(workspace, {proposal = {kind = "attempt", ref = "x", revision = "r1", payload = {big = string.rep("x", 9000)}}}))), "INVALID")
            local first_request = request_of(workspace)
            local created = value(call(requester, "request", first_request))
            test.eq(created.state, "pending")
            test.eq(created.revision, 1)
            test.eq(created.requester_id, REQUESTER)
            test.eq(#(created.proposal_digest :: string), 64)
            test.eq(created.owner_incarnation ~= nil, true)
            local replayed = call(requester, "request", first_request)
            test.eq(value(replayed).approval_id, created.approval_id)
            test.eq(replayed.replayed, true)
            first_request.prompt = {text = "changed"}
            test.eq(code(call(requester, "request", first_request)), "CONFLICT")
            local listed = value(call(requester, "list", {workspace_id = workspace}))
            test.eq(#(listed.requests :: {unknown}), 1)
            test.eq(#(value(call(other_requester, "list", {workspace_id = workspace})).requests :: {unknown}), 0)
        end)
        test.it("lets two eligible approvers race to one decision and reports every other outcome honestly", function()
            local workspace = "ws-" .. key()
            local created = value(call(requester, "request", request_of(workspace)))
            local approval_id, digest = created.approval_id :: string, created.proposal_digest :: string
            test.eq(code(call(outsider, "read", {approval_id = approval_id})), "DENIED")
            test.eq(value(call(alice, "read", {approval_id = approval_id})).approval_id, approval_id)
            test.eq(value(call(manager, "read", {approval_id = approval_id})).approval_id, approval_id)
            test.eq(code(call(outsider, "decide", {approval_id = approval_id, expected_revision = 1, decision = "approved", proposal_digest = digest})), "DENIED")
            test.eq(code(call(alice, "decide", {approval_id = approval_id, expected_revision = 1, decision = "approved", proposal_digest = string.rep("0", 64)})), "CONFLICT")
            local a = alice:async("bee.approvals:decide", {approval_id = approval_id, expected_revision = 1, decision = "approved", proposal_digest = digest})
            local b = bob:async("bee.approvals:decide", {approval_id = approval_id, expected_revision = 1, decision = "denied", proposal_digest = digest})
            local wins = 0
            for _, future in ipairs({a, b}) do
                if await(future).ok then wins = wins + 1 end
            end
            test.eq(wins, 1)
            local decided = value(call(alice, "read", {approval_id = approval_id}))
            test.eq(decided.state, "decided")
            test.eq(decided.revision, 2)
            local winner, decision = decided.decider_id :: string, decided.decision :: string
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
            local withdrawn = value(call(requester, "withdraw", {approval_id = approval_id}))
            test.eq(withdrawn.withdrawn, false)
            test.eq((withdrawn.request :: {[string]: unknown}).state, "decided")
        end)
        test.it("enforces expiry at the owner, lets only the requester withdraw and binds consumption to one effect", function()
            local workspace = "ws-" .. key()
            local short = value(call(requester, "request", request_of(workspace, {ttl_ms = 1})))
            time.sleep("5ms")
            local late = call(alice, "decide", {approval_id = short.approval_id, expected_revision = 1, decision = "approved", proposal_digest = short.proposal_digest})
            test.eq(code(late), "INVALID_STATE")
            test.eq(fault_value(late).state, "expired")
            local pending = value(call(requester, "request", request_of(workspace)))
            test.eq(code(call(other_requester, "withdraw", {approval_id = pending.approval_id})), "DENIED")
            local withdrawn = value(call(requester, "withdraw", {approval_id = pending.approval_id}))
            test.eq(withdrawn.withdrawn, true)
            test.eq((withdrawn.request :: {[string]: unknown}).state, "withdrawn")
            test.eq(code(call(bob, "decide", {approval_id = pending.approval_id, expected_revision = 1, decision = "approved", proposal_digest = pending.proposal_digest})), "INVALID_STATE")
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
            value(call(bob, "decide", {approval_id = approved.approval_id, expected_revision = 1, decision = "approved", proposal_digest = approved.proposal_digest}))
            test.eq(code(call(other_requester, "consume", {approval_id = approved.approval_id, proposal_digest = approved.proposal_digest, effect_key = "launch-1", owner_incarnation = incarnation})), "DENIED")
            test.eq(code(call(requester, "consume", {approval_id = approved.approval_id, proposal_digest = string.rep("1", 64), effect_key = "launch-1", owner_incarnation = incarnation})), "CONFLICT")
            local stale = call(requester, "consume", {approval_id = approved.approval_id, proposal_digest = approved.proposal_digest, effect_key = "launch-1", owner_incarnation = (incarnation :: number) + 1})
            test.eq(code(stale), "REVALIDATE")
            test.eq(fault_value(stale).consumed_effect, nil)
            local consumed = value(call(requester, "consume", {approval_id = approved.approval_id, proposal_digest = approved.proposal_digest, effect_key = "launch-1", owner_incarnation = incarnation}))
            test.eq(consumed.consumed_effect, "launch-1")
            test.eq(consumed.consumer_id, REQUESTER)
            test.eq(call(requester, "consume", {approval_id = approved.approval_id, proposal_digest = approved.proposal_digest, effect_key = "launch-1", owner_incarnation = incarnation}).replayed, true)
            test.eq(code(call(requester, "consume", {approval_id = approved.approval_id, proposal_digest = approved.proposal_digest, effect_key = "launch-2", owner_incarnation = incarnation})), "CONFLICT")
            local denied = value(call(requester, "request", request_of(workspace)))
            value(call(bob, "decide", {approval_id = denied.approval_id, expected_revision = 1, decision = "denied", proposal_digest = denied.proposal_digest}))
            test.eq(code(call(requester, "consume", {approval_id = denied.approval_id, proposal_digest = denied.proposal_digest, effect_key = "launch-3", owner_incarnation = incarnation})), "INVALID_STATE")
        end)
        test.it("shows approvers a bounded inbox of the requests their policy covers and nothing to anyone else", function()
            local workspace = "ws-" .. key()
            local created = value(call(requester, "request", request_of(workspace)))
            test.eq(code(call(outsider, "inbox", {workspace_id = workspace})), "DENIED")
            test.eq(code(call(alice, "inbox", {workspace_id = workspace, limit = 65})), "INVALID")
            local page = value(call(alice, "inbox", {workspace_id = workspace, limit = 1}))
            local changes = page.changes :: {{[string]: unknown}}
            test.eq(#changes, 1)
            test.eq(changes[1].approval_id, created.approval_id)
            test.eq(changes[1].revision, 1)
            value(call(carol, "decide", {approval_id = created.approval_id, expected_revision = 1, decision = "denied", proposal_digest = created.proposal_digest}))
            local rest = value(call(bob, "inbox", {workspace_id = workspace, after_seq = page.next_seq}))
            local later = rest.changes :: {{[string]: unknown}}
            test.eq(#later, 1)
            test.eq(later[1].revision, 2)
            test.eq((later[1].request :: {[string]: unknown}).decision, "denied")
        end)
        test.it("projects requests and decisions onto the thread through the worker exactly once", function()
            local workspace = "ws-" .. key()
            local thread_id = thread_harness.thread(launcher, "Approvals")
            thread_harness.value(launcher:call("admit_action", {thread_id = thread_id, idempotency_key = key(), action_id = "a1", admitted = thread_harness.admitted()}))
            thread_harness.value(launcher:call("prepare_attempt", {thread_id = thread_id, idempotency_key = key(), action_id = "a1", attempt_id = "t1", prepared = thread_harness.prepared()}))
            test.eq(code(call(requester, "request", request_of(workspace, {thread_id = thread_id, proposal = attempt_proposal(nil, "t1")}))), "INVALID")
            test.eq(code(call(requester, "request", request_of(workspace, {thread_id = thread_id, proposal = attempt_proposal("a1", "t9")}))), "INVALID")
            test.eq(code(call(requester, "request", request_of(workspace, {thread_id = thread_id, proposal = attempt_proposal("a9", "t1")}))), "INVALID")
            local created = value(call(requester, "request", request_of(workspace, {thread_id = thread_id, proposal = attempt_proposal("a1", "t1")})))
            local binding = created.binding :: {[string]: unknown}
            test.eq(binding.attempt_id, "t1")
            test.eq(binding.record_id ~= nil, true)
            local approval_id = created.approval_id :: string
            local rows = value(call(requester, "deliveries", {approval_id = approval_id})).deliveries :: {{[string]: unknown}}
            test.eq(#rows, 1)
            test.eq(rows[1].event_id, approval_id .. ":1")
            local records = until_records(thread_id, 1)
            test.eq(#records, 1)
            test.eq(records[1].kind, "approval.request")
            test.eq(records[1].attempt_id, "t1")
            test.eq((records[1].body :: {[string]: unknown}).requester_id, REQUESTER)
            value(call(alice, "decide", {approval_id = approval_id, expected_revision = 1, decision = "approved", proposal_digest = created.proposal_digest, response = {text = "go"}}))
            records = until_records(thread_id, 2)
            if #records ~= 2 then
                local pendings = value(call(requester, "deliveries", {approval_id = approval_id})).deliveries :: {{[string]: unknown}}
                error("transition not delivered: " .. tostring(pendings[2] and pendings[2].last_error) .. " attempts " .. tostring(pendings[2] and pendings[2].attempts))
            end
            local body = records[2].body :: {[string]: unknown}
            test.eq(body.state, "approved")
            test.eq(body.decider_id, ALICE)
            test.eq(body.expected_revision, 1)
            test.eq((body.response :: {[string]: unknown}).text, "go")
            local acked = value(call(requester, "deliveries", {approval_id = approval_id})).deliveries :: {{[string]: unknown}}
            test.eq(#acked, 2)
            test.eq(acked[2].acknowledged_at ~= nil, true)
            test.eq(code(call(requester, "deliveries", {approval_id = approval_id, redeliver = approval_id .. ":2"})), "DENIED")
            test.eq(code(call(manager, "deliveries", {approval_id = approval_id, redeliver = approval_id .. ":2"})), "INVALID_STATE")
            test.eq(#thread_records(thread_id), 2)
        end)
        test.it("survives a crash between the thread commit and the outbox acknowledgement without a duplicate record", function()
            local workspace = "ws-" .. key()
            local thread_id = thread()
            local db = open_test_store()
            local created = executed(service.execute(db, REQUESTER, "request", request_of(workspace, {thread_id = thread_id}), nil, requester))
            test.eq((created.binding :: {[string]: unknown}).role, "owner")
            local approval_id = created.approval_id :: string
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
            test.eq(service.execute(db, REQUESTER, "request", request_of(workspace, {thread_id = "thread-missing"}), nil, requester).code, "DENIED")
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
    end)
end
return test.run_cases(define_tests)
