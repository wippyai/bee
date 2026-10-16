-- SPDX-License-Identifier: MIT
local test = require("test")
local harness = require("harness")
local bounds = require("bounds")
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local process = require("process")
local sql = require("sql")
local WORKSPACE = string.rep("e", 32)
type Sample = {session: string, future: funcs.Future, outbox: boolean}
local function define_tests()
    test.describe("Prompt hook latency", function()
        test.it("answers native and outbox prompts while the terminal owner cannot reply", function()
            local original = assert(registry.get("bee.harness.binding:present_type"))
            local probe = assert(registry.get("bee.tests.threads.sessions:type_probe"))
            probe.id = original.id
            local swap = assert(registry.snapshot()):changes()
            swap:update(probe)
            assert(swap:apply())
            local typed = assert(process.listen("bee.test.typed", {message = true}))
            local owner_requests = assert(process.listen("bee.session.window.request", {message = true}))
            assert(process.registry.register("bee.test.resume_probe"))
            local aliases: {string} = {}
            local samples: {Sample} = {}
            local ok, failure = pcall(function()
                local journal = harness.session_owner(WORKSPACE)
                local outbox = funcs.new():with_actor(assert(security.new_actor("bee.approvals.outbox", {workspace_id = WORKSPACE})))
                    :with_scope(security.new_scope({assert(security.policy("bee.threads.security:sessions_owner")),
                        assert(security.policy("bee.tests.threads.sessions:interactive_lifecycle_policy"))}))
                local gateway = funcs.new():with_scope(security.new_scope({})):with_actor(assert(security.new_actor("gateway")))
                for index = 1, 20 do
                    local opened = harness.value(journal:call("session_create", {operation_key = harness.key(), route = {delivery = "hook", provider = "claude"}}))
                    local session = assert(bounds.id(opened.session))
                    local attempt = "prompt-latency-" .. tostring(index)
                    harness.value(journal:call("session_attach", {session = session, attempt_id = attempt, operation_key = harness.key()}))
                    local text = "Prompt " .. tostring(index)
                    local from_outbox = index % 2 == 0
                    if from_outbox then
                        harness.value(journal:call("work_send", {session = session, input = "previous prompt", operation_key = harness.key()}))
                        local turn = harness.value(journal:call("turn_reserve", {session = session, operation_key = harness.key()}))
                        local input = harness.value(journal:call("turn_pull", {turn = turn.turn, claim = turn.claim}))
                        harness.value(journal:call("turn_accept", {turn = turn.turn, claim = turn.claim, input_digest = input.input_digest,
                            checkpoint = {attempt_id = attempt}, operation_key = harness.key()}))
                        harness.value(journal:call("work_settle", {turn = turn.turn, claim = turn.claim, operation_key = harness.key(),
                            result = {state = "succeeded", schema = "bee:Text@1", value = {text = "previous answer"}}}))
                        local raw, err = outbox:call("bee.threads.sessions.binding:send", {session = session, operation_key = harness.key(),
                            input = "Your request was approved: " .. text})
                        assert(not err, tostring(err))
                        assert(assert(bounds.object(raw)).ok == true)
                        local report = assert(bounds.object(assert((typed:receive())):payload():data()))
                        test.eq(report.session, session)
                        text = assert(bounds.text(report.text))
                        test.contains(text, "[Bee message from bee.approvals.outbox]")
                    end
                    local alias = "bee.session.window/" .. session
                    assert(process.registry.register(alias))
                    aliases[#aliases + 1] = alias
                    local stored = harness.value(journal:call("session_describe", {session = session}))
                    local future = assert(gateway:async("bee.tests.threads.sessions:hook_boundary_probe", {
                        binding = {binding_id = "latency-binding", subject = session, action_id = "action:" .. string.rep("e", 64),
                            attempt_id = attempt, thread_id = stored.thread_ref, workspace_id = WORKSPACE},
                        outcome = {event = "UserPromptSubmit", event_id = harness.key()}, payload = {prompt = text}}))
                    samples[#samples + 1] = {session = session, future = future, outbox = from_outbox}
                end
                local durations: {number} = {}
                local db = assert(sql.get("bee:db"))
                assert(db:execute("CREATE TABLE IF NOT EXISTS bee_test_hook_latency_samples (elapsed_ms REAL NOT NULL, outbox INTEGER NOT NULL)"))
                assert(db:execute("DELETE FROM bee_test_hook_latency_samples"))
                for _, sample in ipairs(samples) do
                    sample.future:response():receive()
                    local payload, err = sample.future:result()
                    assert(not err and payload, tostring(err))
                    local reply = assert(bounds.object(assert(payload):data()))
                    assert(reply.ok == true, tostring(reply.error))
                    local elapsed = reply.elapsed_ms
                    assert(type(elapsed) == "number")
                    durations[#durations + 1] = elapsed
                    assert(db:execute("INSERT INTO bee_test_hook_latency_samples VALUES (?, ?)", {elapsed, sample.outbox and 1 or 0}))
                    local current = harness.value(journal:call("session_describe", {session = sample.session}))
                    test.eq(assert(bounds.object(current.active_turn)).phase, "accepted")
                    test.is_nil(assert(bounds.object(reply.value)).hookSpecificOutput)
                end
                assert(db:release())
                table.sort(durations)
                test.is_true(durations[20] < 2000, "prompt hook waits for the busy terminal owner: " .. tostring(durations[20]) .. "ms")
            end)
            for _, alias in ipairs(aliases) do process.registry.unregister(alias, process.registry.LOCAL) end
            process.registry.unregister("bee.test.resume_probe", process.registry.LOCAL)
            process.unlisten(typed)
            process.unlisten(owner_requests)
            local restore = assert(registry.snapshot()):changes()
            restore:update(original)
            assert(restore:apply())
            if not ok then error(tostring(failure)) end
        end)
    end)
end
return test.run_cases(define_tests)
