-- MIT. Recovery launch behaviour.
local test = require("test")
local completion = require("completion")
local cdc = require("cdc")
local carrier_fixtures = require("carrier_fixtures")
local orphan_gate = require("orphan_gate")
local principals = require("principals")
local funcs = require("funcs")
local process = require("process")
local channel = require("channel")
local registry = require("registry")
local env = require("env")
local time = require("time")
local machine = require("machine")
local placement_store = require("placement_store")
local bounds = require("bounds")
local fixture = require("fixture")
local REQUESTER = fixture.REQUESTER
local DEFINITION = fixture.DEFINITION
local RETAINED_DEFINITION = fixture.RETAINED_DEFINITION
local POLICY = fixture.POLICY
local fresh = fixture.fresh
local workspace_id = fixture.workspace_id
local scope = fixture.scope
local call = fixture.call
local value = fixture.value
local code = fixture.code
local apply = fixture.apply
local with_entry = fixture.with_entry
local carrier_io = fixture.carrier_io
local await_settled = fixture.await_settled
local kinds = fixture.kinds
local count = fixture.count
local function define_tests()
    test.describe("Launch recovery", function()
        local workspace = fixture.prepare()
        test.it("reconciles a prepared and claimed attempt after its carrier disappears", function()
            local admitted = value(call("bee.tests.harness.launch:admit", {request_id = fresh("orphan-prestart"),
                definition_ref = DEFINITION, workspace_id = workspace, brief = "fail during placement preparation"}))
            with_entry(POLICY, function(changed)
                changed.placement_binding = "bee.placement.native.binding:binding"
                changed.placement_options = {}
            end, function()
                local io = carrier_io(workspace)
                local planned, plan_error = machine.plan(io, carrier_fixtures.request(admitted.request))
                if not planned then error(tostring(plan_error)) end
                local prepared, preparation_error, failed = machine.prepare_attempt(io, planned)
                test.is_nil(prepared)
                test.is_true(tostring(preparation_error):find("native placement does not support placement_options", 1, true) ~= nil)
                test.not_nil(failed)
                test.not_nil(failed and failed.epoch)
                local db = assert(placement_store.open())
                local row = placement_store.row(db, assert(bounds.id(admitted.attempt_id)))
                db:release()
                test.is_nil(row)

                local reply, call_error = funcs.new():with_actor(principals.actor(REQUESTER, workspace))
                    :with_scope(scope()):call("bee.tests.harness:managed_run_probe", {operation = "wait",
                        thread_id = admitted.thread_id, attempt_id = admitted.attempt_id, wait_ms = 0})
                if call_error then error("reconcile wait: " .. tostring(call_error)) end
                local settled = value(principals.reply(reply))
                test.eq(settled.state, "ended")
                test.eq(settled.outcome, "failed")
                local failure = bounds.object(settled.error)
                test.not_nil(failure)
                test.is_true(tostring(failure and failure.message):find("carrier exited during launch preparation", 1, true) ~= nil)
            end)
        end)
        test.it("keeps a lost running attempt live until placement finishes draining, then settles it", function()
            local request_id = fresh("orphan-running")
            local fixture_bin = assert(env.get("bee.tests.harness:fixture_bin"))
            local release = fixture_bin .. "/" .. fresh("lost-carrier-child")
            orphan_gate.create(release)
            local retention = assert(process.listen("bee.test.retention.armed", {message = true}))
            with_entry(POLICY, function(changed)
                local environment = assert(bounds.object(changed.environment))
                environment.BEE_FIXTURE_LINGER_FIFO = release
                environment.BEE_TEST_RETENTION_CONTROLLER = tostring(process.pid())
                changed.environment = environment
            end, function()
                local admitted = value(call("bee.tests.harness.launch:admit", {request_id = request_id,
                    definition_ref = DEFINITION, workspace_id = workspace, brief = "prove lost carrier recovery"}))
                local carrier_request = assert(bounds.object(admitted.request))
                local spawner = process.with_context({}):with_actor(principals.actor(REQUESTER, workspace)):with_scope(scope())
                local lost_pid, spawn_error = spawner:spawn_monitored("bee.tests.harness:carrier_faulted", "bee:workers",
                    carrier_request, "open", process.pid(), "attempt_started")
                if not lost_pid then error("spawn faulted carrier: " .. tostring(spawn_error)) end
                local events = assert(process.events())
                local crashed = false
                while not crashed do
                    local selected = channel.select({events:case_receive()})
                    assert(selected.ok, "carrier supervision closed")
                    local event = selected.value
                    if event.kind == process.event.EXIT and tostring(event.from) == tostring(lost_pid) then
                        local result = event.result or {}
                        test.is_true(tostring(result.error):find("crash after attempt_started", 1, true) ~= nil)
                        crashed = true
                    end
                end

                local thread_id, attempt_id = tostring(admitted.thread_id), tostring(admitted.attempt_id)
                local current = value(call("bee.tests.harness:managed_run_probe", {operation = "status",
                    thread_id = thread_id, attempt_id = attempt_id}))
                test.eq(current.state, "running", "placement still owns a live runner and recovery remains possible")
                test.eq(count(kinds(thread_id), "receipt"), 0, "a missing carrier alone is not terminal")

                local db = assert(placement_store.open())
                local row = assert(placement_store.row(db, attempt_id))
                db:release()
                local runner = assert(row.runner_pid)
                local completion = assert(cdc.stream("bee:changes", {tables = {"bee_placement_evidence"}, ops = {"insert"}}))
                orphan_gate.release(release)
                local armed = assert((retention:receive()))
                test.eq(tostring(armed:from()), runner)
                test.eq(assert(bounds.object(armed:payload():data())).attempt_id, attempt_id)
                assert(process.send(runner, "bee.test.retention.expire", {}))
                while true do
                    db = assert(placement_store.open())
                    row = assert(placement_store.row(db, attempt_id))
                    local evidence = assert(placement_store.evidence(db, attempt_id, 0, 64))
                    db:release()
                    local finished = false
                    for _, item in ipairs(evidence.evidence) do
                        if item.kind == "runner.finished" then finished = true end
                    end
                    if finished and row.execution_state == "exited" then break end
                    assert((completion:channel():receive()), "runner completion stream closed")
                end
                completion:close()
                process.unlisten(retention)
                db = assert(placement_store.open())
                row = assert(placement_store.row(db, attempt_id))
                local evidence = assert(placement_store.evidence(db, attempt_id, 0, 64))
                local finished = false
                for _, item in ipairs(evidence.evidence) do
                    if item.kind == "runner.finished" then finished = true end
                end
                test.is_true(finished, "runner completion is durable")
                test.eq(row.execution_state, "exited")
                test.is_nil(row.runner_pid, "runner.finished clears its process identity")
                local _, stale_error = db:execute(
                    "UPDATE bee_placement_attempts SET runner_pid = ? WHERE attempt_id = ?",
                    {"999999999", attempt_id})
                db:release()
                assert(not stale_error, tostring(stale_error))

                current = value(call("bee.tests.harness:managed_run_probe", {operation = "status",
                    thread_id = thread_id, attempt_id = attempt_id}))
                test.eq(current.outcome, "uncertain")
                local failure = bounds.object(current.error)
                test.eq(failure and failure.code, "carrier_lost")
                local records = kinds(thread_id)
                test.eq(count(records, "turn.end"), 1)
                test.eq(count(records, "receipt"), 1)
                local db = assert(placement_store.open())
                local row = placement_store.row(db, attempt_id)
                db:release()
                test.not_nil(row)
                test.eq(row and row.runner_pid, "999999999", "legacy runner identity remains available for inspection")
            end)
        end)
        test.it("refuses caller-selected session identities and resources before creating work", function()
            for _, field in ipairs({"session_ref", "session_resource"}) do
                local request_id = fresh("session-injection")
                local request: {[string]: unknown} = {request_id = request_id, definition_ref = RETAINED_DEFINITION,
                    workspace_id = workspace, brief = "ping"}
                request[field] = "caller-selected"
                test.eq(code(call("bee.tests.harness.launch:admit", request)), "INVALID")
                test.eq(code(call("bee.threads.binding:get", {thread_id = "thread:" .. request_id})), "NOT_FOUND")
            end
        end)
        test.it("uses a host-selected retained session resource with a retry-stable identity", function()
            local request_id = fresh("retained")
            local admitted = value(call("bee.tests.harness.launch:admit", {request_id = request_id, definition_ref = RETAINED_DEFINITION, workspace_id = workspace, brief = "ping"}))
            test.is_true(type(admitted.session_ref) == "string" and (admitted.session_ref):match("^session:[0-9a-f]+$") ~= nil)
            local carrier_request = assert(bounds.object(admitted.request))
            test.eq(carrier_request.session_ref, admitted.session_ref)
            local resources = principals.objects(carrier_request.resources)
            test.eq(#resources, 2)
            local session_grant = nil
            for _, resource in ipairs(resources) do
                if resource.purpose == "session" then session_grant = resource end
            end
            if not session_grant then error("retained session grant missing") end
            test.eq(session_grant.name, "session")
            test.eq(session_grant.access, "write")
            local replay = value(call("bee.tests.harness.launch:admit", {request_id = request_id, definition_ref = RETAINED_DEFINITION, workspace_id = workspace, brief = "ping"}))
            test.eq(replay.session_ref, admitted.session_ref)
            local replay_resources = principals.objects((assert(bounds.object(replay.request))).resources)
            local replay_grant = nil
            for _, resource in ipairs(replay_resources) do
                if resource.purpose == "session" then replay_grant = resource end
            end
            test.eq(replay_grant and replay_grant.grant_ref, session_grant.grant_ref)
            local other = value(call("bee.tests.harness.launch:admit", {request_id = fresh("retained"), definition_ref = RETAINED_DEFINITION, workspace_id = workspace, brief = "ping"}))
            test.neq(other.session_ref, admitted.session_ref)
        end)
        test.it("refuses a host definition whose retained resource is unavailable before creating a thread", function()
            local entry = assert(registry.get(RETAINED_DEFINITION))
            local original = entry.data
            local changed: {[string]: unknown} = {}
            for key, item in pairs(assert(bounds.object(original))) do changed[key] = item end
            changed.session_resource = "missing-session"
            local request_id = fresh("retained-denied")
            local ok, failure = pcall(function()
                entry.data = changed
                apply(entry)
                local refused = call("bee.tests.harness.launch:admit", {request_id = request_id, definition_ref = RETAINED_DEFINITION, workspace_id = workspace, brief = "ping"})
                test.eq(code(refused), "NOT_FOUND")
                test.eq(code(call("bee.threads.binding:get", {thread_id = "thread:" .. request_id})), "NOT_FOUND")
            end)
            entry.data = original
            apply(entry)
            if not ok then error(tostring(failure)) end
        end)
        test.it("recovers a start that failed after placement intent and before the first checkpoint", function()
            local request_id = fresh("request")
            local admitted = value(call("bee.tests.harness.launch:admit", {request_id = request_id, definition_ref = DEFINITION, workspace_id = workspace, brief = "ping"}))
            local carrier_request = assert(bounds.object(admitted.request))
            local spawner = process.with_context({}):with_actor(principals.actor(REQUESTER, workspace)):with_scope(scope())
            local crashed_pid, spawn_error = spawner:spawn_monitored("bee.tests.harness:carrier_faulted", "bee:workers", carrier_request, "open", process.pid(), "placement_intent")
            if not crashed_pid then error("spawn faulted carrier: " .. tostring(spawn_error)) end
            local events = assert(process.events())
            local deadline = time.after("30s")
            local crashed = false
            while not crashed do
                local selected = channel.select({events:case_receive(), deadline:case_receive()})
                if not selected.ok or selected.channel == deadline then error("faulted carrier did not stop") end
                local event = selected.value
                if event.kind == process.event.EXIT and tostring(event.from) == tostring(crashed_pid) then
                    crashed = true
                    if not tostring(event.result and event.result.error):find("crash after placement_intent", 1, true) then error("unexpected end: " .. tostring(event.result and event.result.error)) end
                end
            end
            local before = kinds("thread:" .. request_id)
            test.eq(count(before, "action.admitted"), 1)
            test.eq(count(before, "attempt.prepared"), 1)
            test.eq(count(before, "turn.request"), 0)
            local retried = value(call("bee.tests.harness.launch:start", {request_id = request_id, definition_ref = DEFINITION, workspace_id = workspace, brief = "ping"}))
            test.eq(retried.mode, "open")
            test.eq(await_settled("thread:" .. request_id, tostring(retried.attempt_id)).answer, "pong")
            local after = kinds("thread:" .. request_id)
            test.eq(count(after, "action.admitted"), 1)
            test.eq(count(after, "attempt.prepared"), 1)
            test.eq(count(after, "attempt.started"), 1)
            test.eq(count(after, "turn.request"), 1)
            test.eq(count(after, "receipt"), 1)
        end)
        test.it("starts the carrier to settlement and a retried start recovers the same attempt", function()
            local request_id = fresh("request")
            local started = value(call("bee.tests.harness.launch:start", {request_id = request_id, definition_ref = DEFINITION, workspace_id = workspace, brief = "ping"}))
            test.eq(started.mode, "open")
            local thread_id = tostring(started.thread_id)
            test.eq(await_settled(thread_id, tostring(started.attempt_id)).answer, "pong")
            local list = kinds(thread_id)
            test.eq(count(list, "action.admitted"), 1)
            test.eq(count(list, "attempt.prepared"), 1)
            test.eq(count(list, "receipt"), 1)
            local settled_replay = value(call("bee.tests.harness.launch:start", {request_id = request_id,
                definition_ref = DEFINITION, workspace_id = workspace, brief = "ping"}))
            test.eq(settled_replay.mode, "settled")
            test.eq(settled_replay.thread_id, started.thread_id)
            test.eq(settled_replay.action_id, started.action_id)
            test.eq(settled_replay.attempt_id, started.attempt_id)
            test.eq(count(kinds(thread_id), "receipt"), 1)
            local retried_id = fresh("request")
            local first = value(call("bee.tests.harness.launch:start", {request_id = retried_id, definition_ref = DEFINITION, workspace_id = workspace, brief = "ping"}))
            test.eq(await_settled(tostring(first.thread_id), tostring(first.attempt_id)).answer, "pong")
            local retried_list = kinds(tostring(first.thread_id))
            test.eq(count(retried_list, "attempt.started"), 1)
            test.eq(count(retried_list, "turn.request"), 1)
        end)
        fixture.restore_host()
    end)
end
return test.run_cases(define_tests)
