-- MIT. Recovery launch behaviour.
local test = require("test")
local principals = require("principals")
local process = require("process")
local channel = require("channel")
local registry = require("registry")
local time = require("time")
local bounds = require("bounds")
local fixture = require("fixture")
local REQUESTER = fixture.REQUESTER
local DEFINITION = fixture.DEFINITION
local RETAINED_DEFINITION = fixture.RETAINED_DEFINITION
local fresh = fixture.fresh
local workspace_id = fixture.workspace_id
local scope = fixture.scope
local call = fixture.call
local value = fixture.value
local code = fixture.code
local apply = fixture.apply
local await_settled = fixture.await_settled
local kinds = fixture.kinds
local count = fixture.count
local function define_tests()
    test.describe("Launch recovery", function()
        local workspace = fixture.prepare()
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
