-- MIT. Approval service notifications.
local test = require("test")
local events = require("events")
local bounds = require("bounds")
local time = require("time")
local channel = require("channel")
local service = require("service")
local dispatch = require("dispatch")
local thread_harness = require("thread_harness")
local fixture = require("fixture").new()
type Object = {[string]: unknown}
local ALICE = fixture.ALICE
local POLICY = fixture.POLICY
local key = fixture.key
local caller = fixture.caller
local requester = fixture.requester
local alice = fixture.alice
local owner = fixture.owner
local call = fixture.call
local value = fixture.value
local open_test_store = fixture.open_test_store
local executed = fixture.executed
local install_policy = fixture.install_policy
local proposal = fixture.proposal
local request_of = fixture.request_of
local thread = fixture.thread
local retire_owned_effects = fixture.retire_owned_effects

local function define_tests()
    test.describe("Approval owner notifications", function()
        fixture.setup("bee.tests.approvals:service_notifications_db", true)
        test.after_all(retire_owned_effects)
        test.it("acknowledges compound revocation event ids for session requesters", function()
            install_policy()
            local workspace = string.rep("d", 32)
            local journal = thread_harness.session_owner(workspace)
            local opened = thread_harness.value(journal:call("session_create", {operation_key = key(), route = {delivery = "hook", definition = "bee.harness.app:app"}}))
            local agent = caller(tostring(opened.session), {"bee.security.approvals:approval_request_policy"}, {workspace_id = workspace})
            local created = value(call(agent, "request", {workspace_id = workspace, idempotency_key = key(), policy = POLICY,
                request_kind = "permission", proposal = proposal(), prompt = {text = "Review this session?"}}))
            value(call(alice, "decide", {approval_id = created.approval_id, expected_revision = 1, decision = "approved",
                proposal_digest = created.proposal_digest, reviewed_digest = created.reviewed_digest}))
            local grant = assert(bounds.object(value(call(alice, "grant", {operation = "read", grant_id = tostring(created.approval_id) .. ":grant"})).grant))
            value(call(alice, "grant", {operation = "revoke", grant_id = grant.grant_id, expected_revision = grant.revision}))
            local page = value(call(agent, "events", {}))
            local ids: {string} = {}
            local longest = 0
            for _, raw in ipairs(assert(bounds.array(page.events, 64))) do
                local id = assert(bounds.line(assert(bounds.object(raw)).event_id, 512))
                longest = math.max(longest, #id)
                ids[#ids + 1] = id
            end
            test.is_true(longest > bounds.MAX_ID_BYTES)
            value(call(agent, "events", {acknowledge = ids}))
            local acknowledged = value(call(agent, "events", {}))
            for _, raw in ipairs(assert(bounds.array(acknowledged.events, 64))) do test.not_nil(assert(bounds.object(raw)).acknowledged_at) end
        end)
        test.it("queues each terminal outcome in the requesting agent session without polling", function()
            install_policy()
            local workspace = string.rep("c", 32)
            local journal = thread_harness.session_owner(workspace)
            local opened = thread_harness.value(journal:call("session_create", {operation_key = key(), route = {delivery = "hook", definition = "bee.harness.app:app"}}))
            local session = assert(bounds.id(opened.session))
            local stored = thread_harness.value(journal:call("session_describe", {session = session}))
            local thread = assert(bounds.id(stored.thread_ref))
            local agent = caller(session, {"bee.security.approvals:approval_request_policy", "bee.threads.security:observe"}, {workspace_id = workspace})
            local db = assert(service.open())
            local commits = thread_harness.committed(thread)
            local changes = commits.changes
            local replay_worker = caller(service.WORKER_NAME, {"bee.security.approvals:approval_owner_policy", "bee.security.approvals:delivery_workspace_identity_policy", "bee.security.approvals:approval_store_policy", "bee.threads.security:approval", "bee.threads.security:approval_client"})
            local ok, problem = pcall(function()
                local queued = 0
                for _, outcome in ipairs({"approved", "denied", "expired"}) do
                    local bound_thread: string? = nil
                    if outcome ~= "denied" then bound_thread = thread end
                    local created = value(call(agent, "request", {workspace_id = workspace, idempotency_key = key(), policy = POLICY,
                        request_kind = "permission", proposal = proposal(), prompt = {text = "Use Hub and Library?"}, thread_id = bound_thread, ttl_ms = 60000}))
                    test.eq(created.thread_id, bound_thread)
                    local id = assert(bounds.id(created.approval_id))
                    if outcome == "expired" then
                        assert(db:execute("UPDATE bee_approval_requests SET expires_ms = 0 WHERE approval_id = ?", {id}))
                        value(call(owner, "reconcile", {}))
                    else value(call(alice, "decide", {approval_id = id, expected_revision = 1, decision = outcome, proposal_digest = created.proposal_digest, reviewed_digest = created.reviewed_digest})) end
                    local deadline = time.after("10s")
                    local history: Object? = nil
                    while not history do
                        local page = thread_harness.value(journal:call("work_history", {session = session}))
                        for _, raw in ipairs(assert(bounds.array(page.items, 64))) do
                            local item = assert(bounds.object(raw))
                            if tostring(item.input):find(outcome, 1, true) then history = page end
                        end
                        if not history then
                            local selected = channel.select({changes:case_receive(), deadline:case_receive()})
                            test.eq(selected.channel, changes, "decision reached the thread but did not queue session input")
                        end
                    end
                    queued = queued + 1
                    test.eq(#assert(bounds.array(history.items, 64)), queued)
                    local _, reset_error = db:execute("UPDATE bee_approval_events SET acknowledged_at = NULL WHERE approval_id = ? AND destination = ? AND kind <> 'approval.requested'", {id, "requester:" .. session})
                    test.is_nil(reset_error)
                    local replay, replay_error = replay_worker:call("bee.tests.approvals:notice_probe", {})
                    test.is_nil(replay_error)
                    local answer = assert(bounds.object(replay))
                    test.is_true(answer.ok == true, tostring(answer.error))
                    local again = thread_harness.value(journal:call("work_history", {session = session}))
                    test.eq(#assert(bounds.array(again.items, 64)), queued, "outbox replay queued duplicate work")
                end
            end)
            commits:close(); db:release()
            assert(ok, tostring(problem))
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
        test.it("delivers and acknowledges a compound completion event beyond the principal ID bound", function()
            local workspace = string.rep("d", 32)
            local journal = thread_harness.session_owner(workspace)
            local session = thread_harness.value(journal:call("session_create", {operation_key = key(), route = {delivery = "hook", definition = "bee.harness.app:app"}})).session
            local db = open_test_store()
            local created = executed(service.execute(db, "bee.gov.activation", "request", request_of(workspace,
                {proposal = {kind = "operation", ref = "bee.gov:establish-overlay", revision = "1", payload = {}},
                    origin = {session_id = session}, continuation = {destination = "gov.activation", effect_id = "long-result-" .. key(), context = {}},
                    prompt = {text = "Install Fixture Status 1.0.1?"}}), 1000, nil))
            executed(service.execute(db, ALICE, "decide", {approval_id = created.approval_id, expected_revision = 1,
                proposal_digest = created.proposal_digest, reviewed_digest = created.reviewed_digest, decision = "allow_once"}, 1001, nil))
            local effect = assert(bounds.object(created.effect)).effect_id
            executed(service.execute(db, "bee.gov.activation", "effect", {operation = "claim", approval_id = created.approval_id,
                proposal_digest = created.proposal_digest, effect_key = effect, owner_incarnation = created.owner_incarnation}, 1002, nil))
            executed(service.execute(db, "bee.gov.activation", "effect", {operation = "complete", approval_id = created.approval_id,
                proposal_digest = created.proposal_digest, effect_key = effect, state = "succeeded", result = {ok = true, outcome = "applied"}}, 1003, nil))
            local event_id = tostring(created.approval_id) .. ":completed:" .. string.rep("event", 40)
            assert(#event_id > bounds.MAX_ID_BYTES)
            assert(db:execute("UPDATE bee_approval_events SET acknowledged_at = 'already-delivered' WHERE kind <> 'effect.completed'"))
            assert(db:execute("UPDATE bee_approval_events SET event_id = ? WHERE kind = 'effect.completed' AND destination = ?", {event_id, "requester:" .. tostring(session)}))
            test.is_nil(dispatch.notify_sessions(db))
            local page = thread_harness.value(journal:call("work_history", {session = session}))
            test.contains(tostring(assert(bounds.object(assert(bounds.array(page.items, 64))[1])).input), "Installed Fixture Status 1.0.1")
            test.is_nil(dispatch.notify_sessions(db))
            local replay = thread_harness.value(journal:call("work_history", {session = session}))
            test.eq(#assert(bounds.array(replay.items, 64)), 1)
            local events = assert(db:query("SELECT acknowledged_at FROM bee_approval_events WHERE event_id = ?", {event_id}))
            test.not_nil(events[1].acknowledged_at)
            db:release()
        end)
        test.it("tells the requesting agent the installation outcome and preserves its reason", function()
            test.contains(dispatch.message({approval_id = "install", state = "succeeded", result = {outcome = "applied"}},
                {text = "Install Fixture Status 1.0.1? It adds: Read workspace files under testdata."}), "Installed Fixture Status 1.0.1")
            test.contains(dispatch.message({approval_id = "install", state = "failed", result = {outcome = "failed", error = "app.fixtures:status:5:19: syntax error"}},
                {text = "Install Fixture Status 1.0.0?"}), "Installation failed: app.fixtures:status:5:19: syntax error")
        end)
        test.it("records the failed effect and its error for the originating agent session once", function()
            local db = open_test_store()
            local created = executed(service.execute(db, "bee.gov.activation", "request", request_of("ws-result-" .. key(),
                {proposal = {kind = "operation", ref = "bee.gov:establish-overlay", revision = "1", payload = {}},
                    origin = {session_id = "bs:requesting-agent"},
                    continuation = {destination = "gov.activation", effect_id = "result-" .. key(), context = {}}}), 1000, nil))
            executed(service.execute(db, ALICE, "decide", {approval_id = created.approval_id, expected_revision = 1,
                proposal_digest = created.proposal_digest, reviewed_digest = created.reviewed_digest, decision = "allow_once"}, 1001, nil))
            local effect_id = assert(bounds.object(created.effect)).effect_id
            executed(service.execute(db, "bee.gov.activation", "effect", {operation = "claim", approval_id = created.approval_id,
                proposal_digest = created.proposal_digest, effect_key = effect_id, owner_incarnation = created.owner_incarnation}, 1002, nil))
            local receipt = {operation = "complete", approval_id = created.approval_id, proposal_digest = created.proposal_digest,
                effect_key = effect_id, state = "failed", result = {ok = false, error = "app.fixtures:status:5:19: syntax error"}}
            local completed = executed(service.execute(db, "bee.gov.activation", "effect", receipt, 1003, nil))
            test.eq(completed.revision, 3)
            local changes = assert(db:query("SELECT revision FROM bee_approval_inbox WHERE approval_id = ? ORDER BY seq DESC LIMIT 1", {created.approval_id}))
            test.eq(changes[1].revision, completed.revision)
            test.eq(service.execute(db, "bee.gov.activation", "effect", receipt, 1004, nil).replayed, true)
            local notifications = assert(db:query("SELECT body_json FROM bee_approval_events WHERE approval_id = ? AND destination = 'requester:bs:requesting-agent' AND kind = 'effect.completed'", {created.approval_id}))
            test.eq(#notifications, 1)
            test.contains(tostring(notifications[1].body_json), "app.fixtures:status:5:19")
            db:release()
        end)
        test.it("announces a failed installation receipt through the shell attention path", function()
            local workspace = "ws-failed-attention-" .. key()
            local created = value(call(requester, "request", request_of(workspace,
                {proposal = {kind = "operation", ref = "bee.gov:establish-overlay", revision = "1", payload = {}},
                    continuation = {destination = "gov.activation", effect_id = "failed-attention-" .. key(), context = {}}})))
            value(call(alice, "decide", {approval_id = created.approval_id, expected_revision = 1,
                proposal_digest = created.proposal_digest, reviewed_digest = created.reviewed_digest, decision = "allow_once"}))
            local effect_id = assert(bounds.object(created.effect)).effect_id
            value(call(requester, "effect", {operation = "claim", approval_id = created.approval_id,
                proposal_digest = created.proposal_digest, effect_key = effect_id, owner_incarnation = created.owner_incarnation}))
            local subscription = assert(events.subscribe(service.ATTENTION, "approval.failed"))
            value(call(requester, "effect", {operation = "complete", approval_id = created.approval_id,
                proposal_digest = created.proposal_digest, effect_key = effect_id, state = "failed",
                result = {ok = false, error = "app.fixtures:status:5:19: syntax error"}}))
            local selected = channel.select({subscription:channel():case_receive(), time.after("1s"):case_receive()})
            subscription:close()
            test.eq(selected.channel, subscription:channel())
            local body = assert(bounds.object(selected.value.data))
            test.eq(body.approval_id, created.approval_id)
            test.eq(body.count, 0)
            test.eq(body.failed, true)
            test.contains(tostring(body.title), "app.fixtures:status:5:19")
        end)
    end)
end
return test.run_cases(define_tests)
