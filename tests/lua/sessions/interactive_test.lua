-- MIT. Interactive delivery enters through the authenticated Session boundary.
local test = require("test")
local harness = require("harness")
local funcs = require("funcs")
local security = require("security")
local bounds = require("bounds")
local admission = require("admission")
local registry = require("registry")
local process = require("process")
local channel = require("channel")
local time = require("time")
local json = require("json")
local WORKSPACE = string.rep("a", 32)
-- owner_text is the text Sessions types into the agent for a queued message.
local function owner_text(input: string, sender: string): string
    return "[Bee message from " .. sender .. "]\n" .. input
end

-- with_window_probes runs body with the window resume and type facades
-- replaced by probes that report to this test, then restores them.
local function with_window_probes(body: (resumed: process.Listener, typed: process.Listener, activity: process.Listener) -> ())
    local originals = {assert(registry.get("bee.harness.binding:present_restore")), assert(registry.get("bee.harness.binding:present_type")),
        assert(registry.get("bee.harness.binding:present_activity"))}
    local swap = assert(registry.snapshot()):changes()
    for probe, facade in pairs({resume_probe = "present_restore", type_probe = "present_type", activity_probe = "present_activity"}) do
        local entry = assert(registry.get("bee.tests.sessions:" .. probe))
        entry.id = "bee.harness.binding:" .. facade
        swap:update(entry)
    end
    assert(swap:apply())
    local resumed = assert(process.listen("bee.test.resumed", {message = true}))
    local typed = assert(process.listen("bee.test.typed", {message = true}))
    local activity = assert(process.listen("bee.test.activity", {message = true}))
    assert(process.registry.register("bee.test.resume_probe"))
    local ok, failure = pcall(body, resumed, typed, activity)
    process.registry.unregister("bee.test.resume_probe", process.registry.LOCAL)
    process.unlisten(resumed)
    process.unlisten(typed)
    process.unlisten(activity)
    local restore = assert(registry.snapshot()):changes()
    for _, original in ipairs(originals) do restore:update(original) end
    assert(restore:apply())
    if not ok then error(tostring(failure)) end
end
-- received waits for one probe report.
local function received(listener: process.Listener): {[string]: unknown}?
    local event = channel.select({listener:case_receive(), time.after("5s"):case_receive()})
    if not (event.ok and event.channel == listener) then return nil end
    return assert(bounds.object(event.value:payload():data()))
end
local function owner_caller(): funcs.Executor
    local actor = assert(security.new_actor("sessions-owner", {workspace_id = WORKSPACE}))
    return funcs.new():with_actor(actor):with_scope(security.new_scope({assert(security.policy("bee.threads.security:sessions_owner")),
        assert(security.policy("bee.tests.sessions:interactive_lifecycle_policy"))}))
end
local function owner_call(method: string, input: {[string]: unknown}): {[string]: unknown}
    local raw, err = owner_caller():call("bee.threads.sessions.binding:" .. method, input)
    if err then error(tostring(err)) end
    local reply = assert(bounds.object(raw))
    if reply.ok ~= true then error(method .. ": " .. tostring((assert(bounds.object(reply.error))).message)) end
    return assert(bounds.object(reply.value))
end
local function define_tests()
    test.describe("Sessions owner control boundary", function()
        test.it("restores the admitted placement owner only after journal cancellation authorization", function()
            local journal = harness.principal("bee.application:" .. WORKSPACE .. ":execution-owner", {"bee.threads.security:sessions_owner"}, WORKSPACE)
            local opened = harness.value(journal:call("session_create", {operation_key = harness.key(), route = {
                owner_id = "bee.application:" .. WORKSPACE .. ":execution-owner", workspace_id = WORKSPACE,
                placement_methods = {reconcile = "bee.tests.sessions:cancellation_owner_running", stop = "bee.tests.sessions:cancellation_owner_stop"}}}))
            local work = harness.value(journal:call("work_send", {session = opened.session, input = "running", operation_key = harness.key()}))
            local turn = harness.value(journal:call("turn_reserve", {session = opened.session, operation_key = harness.key()}))
            local pulled = harness.value(journal:call("turn_pull", {turn = turn.turn, claim = turn.claim}))
            harness.value(journal:call("turn_accept", {turn = turn.turn, claim = turn.claim, input_digest = pulled.input_digest,
                checkpoint = {attempt_id = "owner-fixture"}, operation_key = harness.key()}))
            local actor = assert(security.new_actor("person", {workspace_id = WORKSPACE}))
            local scope = security.new_scope({assert(security.policy("bee.threads.security:sessions_owner")),
                assert(security.policy("bee.tests.sessions:interactive_lifecycle_policy"))})
            local raw, err = funcs.new():with_actor(actor):with_scope(scope):call("bee.threads.sessions.binding:cancel", {work = work.work, operation_key = harness.key()})
            if err then error(tostring(err)) end
            test.is_true(assert(bounds.object(raw)).ok)
            local current = harness.value(journal:call("work_describe", {work = work.work}))
            test.is_nil(current.uncertainty)
            test.is_true(current.cancelling)
        end)
        test.it("accepts cancel, close and filtered list fields through the real owner", function()
            local journal = harness.session_owner(WORKSPACE)
            local opened = harness.value(journal:call("session_create", {operation_key = harness.key(), route = {}}))
            local work = harness.value(journal:call("work_send", {session = opened.session, input = "queued", operation_key = harness.key()}))
            local actor = assert(security.new_actor("sessions-owner", {workspace_id = WORKSPACE}))
            local scope = security.new_scope({assert(security.policy("bee.threads.security:sessions_owner")),
                assert(security.policy("bee.tests.sessions:interactive_lifecycle_policy"))})
            local function call(method: string, request: unknown): {[string]: unknown}
                local raw, err = funcs.new():with_actor(actor):with_scope(scope):call("bee.threads.sessions.binding:" .. method, request)
                if err then error(tostring(err)) end
                local reply = assert(bounds.object(raw))
                if not reply.ok then error(tostring(reply.error and reply.error.message)) end
                return assert(bounds.object(reply.value))
            end
            local cancelled = call("cancel", {work = work.work, reason = "regression", expected_incarnation = 1, operation_key = harness.key()})
            test.eq(cancelled.effect, "cancel")
            test.eq(harness.value(journal:call("work_describe", {work = work.work})).result.state, "cancelled")
            local page = call("list", {filter = {workspace = WORKSPACE, activity = "idle"}})
            local found = false
            for _, row in ipairs(page.items) do if row.session == opened.session then found = true end end
            test.is_true(found)
            local joined = call("join", {works = {work.work}, policy = "all_settled", operation_key = harness.key()})
            test.eq(joined.tag, "ready")
            test.eq(call("close", {session = opened.session, expected_incarnation = 1, operation_key = harness.key()}).effect, "close")
            test.eq(harness.value(journal:call("session_describe", {session = opened.session})).state, "closed")
        end)
    end)
    test.describe("Interactive Sessions", function()
        test.it("accepts a typed message through the gateway subject boundary and settles it with the agent's reply", function()
            local journal = harness.session_owner(WORKSPACE)
            local opened = harness.value(journal:call("session_create", {operation_key = harness.key(), route = {delivery = "hook"}}))
            local attempt = "attempt:" .. string.rep("a", 64)
            harness.value(journal:call("session_attach", {session = opened.session, attempt_id = attempt, operation_key = harness.key()}))
            local work = harness.value(journal:call("work_send", {session = opened.session, input = "peer boundary message", operation_key = harness.key()}))
            harness.value(journal:call("turn_reserve", {session = opened.session, operation_key = harness.key()}))
            local function hook(event: string, payload: {[string]: unknown}): {[string]: unknown}
                local raw, err = funcs.new():with_scope(security.new_scope({})):with_actor(assert(security.new_actor("gateway"))):call(
                    "bee.tests.sessions:hook_boundary_probe", {binding = {binding_id = "binding-1", subject = opened.session,
                        action_id = "action:" .. string.rep("a", 64), attempt_id = attempt, thread_id = "thread:" .. string.rep("a", 64),
                        workspace_id = WORKSPACE, origin_view = {view_id = string.rep("a", 64), instance_id = string.rep("a", 64)}},
                        outcome = {event = event, event_id = harness.key()}, payload = payload})
                if err then error(tostring(err)) end
                local reply = assert(bounds.object(raw))
                if not reply.ok then error(tostring(reply.error)) end
                return reply
            end
            local accepted = hook("UserPromptSubmit", {prompt = owner_text("peer boundary message", "sessions-owner")})
            test.is_nil((assert(bounds.object(accepted.value))).hookSpecificOutput)
            test.eq(harness.value(journal:call("work_describe", {work = work.work})).phase, "accepted")
            hook("Stop", {last_assistant_message = "The boundary reply."})
            local settled = harness.value(journal:call("work_describe", {work = work.work}))
            test.eq(settled.phase, "settled")
            test.eq((assert(bounds.object((assert(bounds.object(settled.result))).value))).text, "The boundary reply.")
        end)
        test.it("resumes the terminal of a session whose typed message waits after a restart", function()
            local journal = harness.session_owner(WORKSPACE)
            local opened = harness.value(journal:call("session_create", {operation_key = harness.key(), route = {delivery = "hook"}}))
            harness.value(journal:call("session_attach", {session = opened.session, attempt_id = "before-restart", operation_key = harness.key()}))
            harness.value(journal:call("work_send", {session = opened.session, input = "typed before the restart", operation_key = harness.key()}))
            harness.value(journal:call("turn_reserve", {session = opened.session, operation_key = harness.key()}))
            local original = assert(registry.get("bee.harness.binding:present_restore"))
            local probe = assert(registry.get("bee.tests.sessions:resume_probe"))
            probe.id = "bee.harness.binding:present_restore"
            local swap = assert(registry.snapshot()):changes()
            swap:update(probe)
            assert(swap:apply())
            local resumed = assert(process.listen("bee.test.resumed", {message = true}))
            assert(process.registry.register("bee.test.resume_probe"))
            local ok, failure = pcall(function()
                local actor = assert(security.new_actor("sessions-owner", {workspace_id = WORKSPACE}))
                local scope = security.new_scope({assert(security.policy("bee.threads.security:sessions_owner")),
                    assert(security.policy("bee.tests.sessions:interactive_lifecycle_policy"))})
                local raw, err = funcs.new():with_actor(actor):with_scope(scope):call("bee.threads.sessions.binding:send",
                    {session = opened.session, input = "sent after the restart", operation_key = harness.key()})
                if err then error(tostring(err)) end
                local reply = assert(bounds.object(raw))
                if reply.ok ~= true then error("send: " .. tostring((assert(bounds.object(reply.error))).message)) end
                local event = channel.select({resumed:case_receive(), time.after("5s"):case_receive()})
                if not (event.ok and event.channel == resumed) then error("no resume request reached the window facade") end
                test.eq((assert(bounds.object(event.value:payload():data()))).session, opened.session)
            end)
            process.registry.unregister("bee.test.resume_probe", process.registry.LOCAL)
            process.unlisten(resumed)
            local restore = assert(registry.snapshot()):changes()
            restore:update(original)
            assert(restore:apply())
            if not ok then error(tostring(failure)) end
        end)
        test.it("keeps a message that waits for a gone terminal when the resumed terminal attaches", function()
            local definition = "bee.driver.claude.profiles:default_window"
            local resolved = admission.resolve(definition, "window", WORKSPACE)
            local plan = assert(resolved)
            local thread = harness.thread(harness.principal("sessions-owner", harness.ALL, WORKSPACE), "resumed terminal")
            local actor = assert(security.new_actor("sessions-owner", {workspace_id = WORKSPACE}))
            local caller = funcs.new():with_actor(actor):with_scope(security.new_scope({assert(security.policy("bee.threads.security:sessions_owner")),
                assert(security.policy("bee.tests.sessions:interactive_lifecycle_policy"))}))
            local open_key = harness.key()
            local function attach(attempt: string): {[string]: unknown}
                local raw, err = caller:call("bee.threads.sessions.binding:attach", {definition = definition, thread_id = thread,
                    plan_digest = plan.plan_digest, attempt_id = attempt, origin_request_id = "origin-resumed", operation_key = open_key})
                if err then error(tostring(err)) end
                local reply = assert(bounds.object(raw))
                test.is_true(reply.ok == true, tostring(reply.error and assert(bounds.object(reply.error)).message))
                return assert(bounds.object(reply.value))
            end
            local session = attach("attempt:before-restart").session
            local journal = harness.session_owner(WORKSPACE)
            local work = harness.value(journal:call("work_send", {session = session, input = "typed before the restart", operation_key = harness.key()}))
            local reserved = harness.value(journal:call("turn_reserve", {session = session, operation_key = harness.key()}))
            attach("attempt:after-restart")
            local stored = harness.value(journal:call("session_describe", {session = session}))
            local active = assert(bounds.object(stored.active_turn))
            test.eq(active.turn, reserved.turn)
            test.eq(active.phase, "reserved")
            test.is_nil(harness.value(journal:call("work_describe", {work = work.work})).uncertainty)
        end)
        test.it("lists sessions in pages that fit one reply value, each session exactly once", function()
            local workspace = string.rep("c", 32)
            local journal = harness.session_owner(workspace)
            local created: {[string]: boolean} = {}
            local reply = string.rep("r", 4096)
            for _ = 1, 20 do
                local opened = harness.value(journal:call("session_create", {operation_key = harness.key(), route = {delivery = "hook"}}))
                local work = harness.value(journal:call("work_send", {session = opened.session, input = "a long answer", operation_key = harness.key()}))
                local turn = harness.value(journal:call("turn_reserve", {session = opened.session, operation_key = harness.key()}))
                local pulled = harness.value(journal:call("turn_pull", {turn = turn.turn, claim = turn.claim}))
                harness.value(journal:call("turn_accept", {turn = turn.turn, claim = turn.claim, input_digest = pulled.input_digest,
                    checkpoint = {attempt_id = "list-page"}, operation_key = harness.key()}))
                harness.value(journal:call("work_settle", {turn = turn.turn, claim = turn.claim, operation_key = harness.key(),
                    result = {state = "succeeded", schema = "bee:Text@1", value = {text = reply}}}))
                test.eq(harness.value(journal:call("work_describe", {work = work.work})).phase, "settled")
                created[tostring(opened.session)] = true
            end
            local actor = assert(security.new_actor("sessions-owner", {workspace_id = workspace}))
            local caller = funcs.new():with_actor(actor):with_scope(security.new_scope({assert(security.policy("bee.threads.security:sessions_owner"))}))
            local seen: {[string]: boolean} = {}
            local listed, pages = 0, 0
            local cursor: unknown = nil
            repeat
                local raw, err = caller:call("bee.threads.sessions.binding:list", {filter = {workspace = workspace}, cursor = cursor})
                if err then error(tostring(err)) end
                local reply_value = assert(bounds.object(raw))
                test.is_true(reply_value.ok == true, tostring(reply_value.error and assert(bounds.object(reply_value.error)).message))
                local page = assert(bounds.object(reply_value.value))
                test.is_true(#assert(json.encode(page)) <= 65536)
                for _, item in ipairs(assert(bounds.array(page.items))) do
                    local session = tostring(assert(bounds.object(item)).session)
                    test.is_nil(seen[session])
                    seen[session] = true
                    if created[session] then listed = listed + 1 end
                end
                pages = pages + 1
                cursor = page.next
            until cursor == nil
            test.eq(listed, 20)
            test.is_true(pages > 1)
        end)
        test.it("keeps a message for a terminal whose agent has finished no turn queued, and types it once that agent ends its first turn", function()
            local journal = harness.session_owner(WORKSPACE)
            local opened = harness.value(journal:call("session_create", {operation_key = harness.key(), route = {delivery = "hook"}}))
            harness.value(journal:call("session_attach", {session = opened.session, attempt_id = "starting-terminal", operation_key = harness.key()}))
            local session_ref = assert(bounds.id(opened.session))
            with_window_probes(function(resumed: process.Listener, typed: process.Listener, activity: process.Listener)
                local sent = owner_call("send", {session = opened.session, input = "wait for the agent", operation_key = harness.key()})
                test.eq(assert(received(resumed)).session, opened.session)
                test.eq(harness.value(journal:call("work_describe", {work = sent.work})).phase, "queued")
                local actor = assert(security.new_actor(session_ref, {workspace_id = WORKSPACE}))
                local boundary = funcs.new():with_actor(actor):with_scope(security.new_scope({assert(security.policy("bee.gateway.security:session_boundary_policy"))}))
                local function hook(event: string, input: string?, answer: string?)
                    local raw, err = boundary:call("bee.threads.sessions.binding:hook_boundary", {session = opened.session, event = event,
                        operation_key = harness.key(), attempt_id = "starting-terminal", input = input, answer = answer})
                    if err then error(tostring(err)) end
                    local reply = assert(bounds.object(raw))
                    if reply.ok ~= true then error(event .. ": " .. tostring((assert(bounds.object(reply.error))).message)) end
                end
                hook("UserPromptSubmit", "what the person typed first")
                hook("Stop", nil, "The first answer.")
                local delivered = assert(received(typed), "the queued message was not typed after the first turn")
                test.eq(delivered.text, owner_text("wait for the agent", "sessions-owner"))
                test.eq(harness.value(journal:call("work_describe", {work = sent.work})).phase, "reserved")
                hook("UserPromptSubmit", delivered.text)
                hook("Stop", nil, "The waited answer.")
                test.eq(harness.value(journal:call("work_describe", {work = sent.work})).phase, "settled")
                -- Every accepted turn reports the agent working, and only a
                -- turn that ends with nothing waiting reports it idle.
                local reports: {string} = {}
                for _ = 1, 4 do
                    local report = received(activity)
                    if not report then break end
                    test.eq(report.session, opened.session)
                    reports[#reports + 1] = tostring(report.state)
                end
                test.eq(table.concat(reports, ","), "working,working,idle")
            end)
        end)
        test.it("gives a starting terminal the message waiting for it as its prompt, the same message each time it asks", function()
            local journal = harness.session_owner(WORKSPACE)
            local opened = harness.value(journal:call("session_create", {operation_key = harness.key(), route = {delivery = "hook", definition = "interactive-fixture"}}))
            harness.value(journal:call("session_attach", {session = opened.session, attempt_id = "fresh-terminal", operation_key = harness.key()}))
            local actor = assert(security.new_actor("window", {workspace_id = WORKSPACE}))
            local window = funcs.new():with_actor(actor):with_scope(security.new_scope({assert(security.policy("bee.tests.sessions:interactive_lifecycle_policy"))}))
            local function launch_prompt(): {[string]: unknown}
                local raw, err = window:call("bee.threads.sessions.binding:launch_prompt", {session = opened.session})
                if err then error(tostring(err)) end
                local reply = assert(bounds.object(raw))
                if reply.ok ~= true then error("launch_prompt: " .. tostring((assert(bounds.object(reply.error))).message)) end
                return assert(bounds.object(reply.value))
            end
            test.is_nil(launch_prompt().prompt)
            local work = harness.value(journal:call("work_send", {session = opened.session, input = "start with this", operation_key = harness.key()}))
            local first = launch_prompt()
            test.eq(first.prompt, owner_text("start with this", "sessions-owner"))
            test.eq(harness.value(journal:call("work_describe", {work = work.work})).phase, "reserved")
            test.eq(launch_prompt().prompt, first.prompt)
        end)
        test.it("rejects an open key already used for another operation", function()
            local journal = harness.session_owner(WORKSPACE)
            local opened = harness.value(journal:call("session_create", {operation_key = harness.key(), route = {delivery = "hook"}}))
            local used = harness.key()
            harness.value(journal:call("work_send", {session = opened.session, input = "taken", operation_key = used}))
            local actor = assert(security.new_actor("sessions-owner", {workspace_id = WORKSPACE}))
            local scope = security.new_scope({assert(security.policy("bee.threads.security:sessions_owner")),
                assert(security.policy("bee.tests.sessions:interactive_lifecycle_policy"))})
            local raw, err = funcs.new():with_actor(actor):with_scope(scope):call("bee.threads.sessions.binding:open", {spec = {
                definition = "bee.driver.claude.profiles:default_window"}, operation_key = used})
            if err then error(tostring(err)) end
            local reply = assert(bounds.object(raw))
            test.is_false(reply.ok)
            test.eq(reply.error.code, "CONFLICT")
        end)
        test.it("refuses an open that names a presentation, budgets, supervision or placement before launch admission", function()
            for _, extra in ipairs({{presentation = "window"}, {budgets = {turn = {tokens = 10}}}, {supervision = {quiet_period_ms = 1000}},
                {placement = {kind = "native", home = "private"}}}) do
                local spec: {[string]: unknown} = {definition = "bee.driver.claude.profiles:default_window"}
                for name, value in pairs(extra) do spec[name] = value end
                local raw, err = funcs.call("bee.threads.sessions.binding:open", {spec = spec, operation_key = harness.key()})
                if err then error(tostring(err)) end
                local reply = assert(bounds.object(raw))
                test.is_false(reply.ok)
                test.eq(reply.error.code, "INVALID")
            end
        end)
        test.it("keeps idle window close pending until placement proves exit", function()
            local journal = harness.session_owner(WORKSPACE)
            local opened = harness.value(journal:call("session_create", {operation_key = harness.key(), route = {
                delivery = "hook", placement_methods = {reconcile = "bee.tests.sessions:interactive_running", stop = "bee.tests.sessions:interactive_running"}}}))
            harness.value(journal:call("session_attach", {session = opened.session, attempt_id = "idle-live", operation_key = harness.key()}))
            local actor = assert(security.new_actor("sessions-owner", {workspace_id = WORKSPACE}))
            local scope = security.new_scope({assert(security.policy("bee.threads.security:sessions_owner")), assert(security.policy("bee.tests.sessions:interactive_lifecycle_policy"))})
            local raw, err = funcs.new():with_actor(actor):with_scope(scope):call("bee.threads.sessions.binding:close", {session = opened.session, operation_key = harness.key()})
            if err then error(tostring(err)) end
            test.is_true(assert(bounds.object(raw)).ok)
            test.eq(harness.value(journal:call("session_describe", {session = opened.session})).state, "closing")
        end)
        test.it("closes an exited window with queued, reserved or accepted work without invoking an executor", function()
            for _, phase in ipairs({"queued", "reserved", "accepted"}) do
                local journal = harness.session_owner(WORKSPACE)
                local opened = harness.value(journal:call("session_create", {operation_key = harness.key(), route = {
                    delivery = "hook", placement_methods = {reconcile = "bee.tests.sessions:interactive_exited"}}}))
                harness.value(journal:call("session_attach", {session = opened.session, attempt_id = "interactive-lifecycle", operation_key = harness.key()}))
                local work = harness.value(journal:call("work_send", {session = opened.session, input = "queued", operation_key = harness.key()}))
                if phase ~= "queued" then
                    local turn = harness.value(journal:call("turn_reserve", {session = opened.session, operation_key = harness.key()}))
                    if phase == "accepted" then
                        local pulled = harness.value(journal:call("turn_pull", {turn = turn.turn, claim = turn.claim}))
                        harness.value(journal:call("turn_accept", {turn = turn.turn, claim = turn.claim, input_digest = pulled.input_digest,
                            checkpoint = {attempt_id = "interactive-lifecycle"}, operation_key = harness.key()}))
                    end
                end
                local actor = assert(security.new_actor("sessions-owner", {workspace_id = WORKSPACE}))
                local scope = security.new_scope({assert(security.policy("bee.threads.security:sessions_owner")), assert(security.policy("bee.tests.sessions:interactive_lifecycle_policy"))})
                local raw, err = funcs.new():with_actor(actor):with_scope(scope):call("bee.threads.sessions.binding:close", {session = opened.session, operation_key = harness.key()})
                if err then error(tostring(err)) end
                test.is_true(assert(bounds.object(raw)).ok)
                test.eq(harness.value(journal:call("session_describe", {session = opened.session})).state, "closed")
                test.eq(harness.value(journal:call("work_describe", {work = work.work})).result.state, "cancelled")
            end
        end)

        test.it("journals a native prompt as the current turn without repeating it as peer context", function()
            local journal = harness.session_owner(WORKSPACE)
            local opened = harness.value(journal:call("session_create", {operation_key = harness.key(), route = {delivery = "hook"}}))
            harness.value(journal:call("session_attach", {session = opened.session, attempt_id = "native-prompt", operation_key = harness.key()}))
            local session = assert(bounds.id(opened.session))
            local actor = assert(security.new_actor(session, {workspace_id = WORKSPACE}))
            local scope = security.new_scope({assert(security.policy("bee.gateway.security:session_boundary_policy"))})
            local operation = harness.key()
            local function submit(): {[string]: unknown}
                local raw, err = funcs.new():with_actor(actor):with_scope(scope):call("bee.threads.sessions.binding:hook_boundary",
                    {session = session, event = "UserPromptSubmit", operation_key = operation, attempt_id = "native-prompt", input = "Run a shell command"})
                if err then error(tostring(err)) end
                return assert(bounds.object(raw))
            end
            local reply = submit()
            test.eq(reply.ok, true)
            test.eq(assert(bounds.object(reply.value)).additional_context, nil)
            local stored = harness.value(journal:call("session_describe", {session = session}))
            local active = assert(bounds.object(stored.active_turn))
            local pulled = harness.value(journal:call("turn_pull", {turn = active.turn, claim = active.claim}))
            test.eq(pulled.input, "Run a shell command")
            test.eq(submit().ok, true)
            local repeated = harness.value(journal:call("session_describe", {session = session}))
            test.eq(assert(bounds.object(repeated.active_turn)).turn, active.turn)
        end)
        test.it("suspends only a proved exited attachment and preserves unfinished Work as uncertain", function()
            for _, state in ipairs({"running", "exited"}) do
                local journal = harness.session_owner(WORKSPACE)
                local opened = harness.value(journal:call("session_create", {operation_key = harness.key(), route = {delivery = "hook",
                    definition = "interactive-fixture", placement_methods = {reconcile = "bee.tests.sessions:interactive_" .. state}}}))
                harness.value(journal:call("session_attach", {session = opened.session, attempt_id = "interactive-lifecycle", operation_key = harness.key()}))
                local work = harness.value(journal:call("work_send", {session = opened.session, input = "unfinished", operation_key = harness.key()}))
                local turn = harness.value(journal:call("turn_reserve", {session = opened.session, operation_key = harness.key()}))
                local pulled = harness.value(journal:call("turn_pull", {turn = turn.turn, claim = turn.claim}))
                harness.value(journal:call("turn_accept", {turn = turn.turn, claim = turn.claim, input_digest = pulled.input_digest,
                    checkpoint = {attempt_id = "interactive-lifecycle"}, operation_key = harness.key()}))
                local actor = assert(security.new_actor("sessions-owner", {workspace_id = WORKSPACE}))
                local policies = {assert(security.policy("bee.threads.security:sessions_owner")), assert(security.policy("bee.tests.sessions:interactive_lifecycle_policy"))}
                local raw, err = funcs.new():with_actor(actor):with_scope(security.new_scope(policies)):call("bee.threads.sessions.binding:detach",
                    {session = opened.session, attempt_id = "interactive-lifecycle", operation_key = harness.key()})
                if err then error(tostring(err)) end
                local reply = assert(bounds.object(raw))
                test.eq(reply.ok, state == "exited")
                local current = harness.value(journal:call("session_describe", {session = opened.session}))
                test.eq(current.state, state == "exited" and "suspended" or "active")
                local pending = harness.value(journal:call("work_describe", {work = work.work}))
                if state == "exited" then test.not_nil(pending.uncertainty) else test.is_nil(pending.uncertainty) end
            end
        end)
        test.it("reports a suspended window's restore facts only to a host-granted caller", function()
            local journal = harness.session_owner(WORKSPACE)
            local opened = harness.value(journal:call("session_create", {operation_key = harness.key(), route = {delivery = "hook",
                definition = "interactive-fixture", plan_digest = "plan-1", origin_request_id = "origin-1", operation_key = "window-open-1",
                saved_profile_id = "profile-1", saved_profile_revision = 2,
                placement_methods = {reconcile = "bee.tests.sessions:interactive_exited"}}}))
            harness.value(journal:call("session_attach", {session = opened.session, attempt_id = "attempt:origin-1", operation_key = harness.key()}))
            local actor = assert(security.new_actor("window-viewer", {workspace_id = WORKSPACE}))
            local granted = funcs.new():with_actor(actor):with_scope(security.new_scope({assert(security.policy("bee.tests.sessions:interactive_lifecycle_policy"))}))
            local function restore(executor: funcs.Executor, session: unknown): {[string]: unknown}
                local raw, err = executor:call("bee.threads.sessions.binding:restore", {session = session})
                if err then error(tostring(err)) end
                return assert(bounds.object(raw))
            end
            local facts = restore(granted, opened.session)
            test.is_true(facts.ok == true, tostring(facts.error and assert(bounds.object(facts.error)).message))
            local value = assert(bounds.object(facts.value))
            local described = harness.value(journal:call("session_describe", {session = opened.session}))
            test.eq(value.session, opened.session)
            test.eq(value.definition_ref, "interactive-fixture")
            test.eq(value.plan_digest, "plan-1")
            test.eq(value.origin_request_id, "origin-1")
            test.eq(value.operation_key, "window-open-1")
            test.eq(value.previous_attempt_id, "attempt:origin-1")
            test.eq(value.thread_id, described.thread_ref)
            test.eq(value.saved_profile_id, "profile-1")
            test.eq(value.saved_profile_revision, 2)

            local denied = funcs.new():with_actor(actor):with_scope(security.new_scope({assert(security.policy("bee.tests.sessions:await_test_caller"))}))
            test.eq(assert(bounds.object(restore(denied, opened.session).error)).code, "DENIED")

            local headless = harness.value(journal:call("session_create", {operation_key = harness.key(), route = {definition = "interactive-fixture"}}))
            test.eq(assert(bounds.object(restore(granted, headless.session).error)).code, "INVALID")
            local unrecorded = harness.value(journal:call("session_create", {operation_key = harness.key(), route = {delivery = "hook",
                definition = "interactive-fixture", plan_digest = "plan-1"}}))
            harness.value(journal:call("session_attach", {session = unrecorded.session, attempt_id = "attempt:unrecorded", operation_key = harness.key()}))
            test.eq(assert(bounds.object(restore(granted, unrecorded.session).error)).code, "UNAVAILABLE")
        end)
        test.it("accepts only the message typed for the reserved turn, returns the agent's reply and settles a message no terminal can take", function()
            local journal = harness.session_owner(WORKSPACE)
            local opened = harness.value(journal:call("session_create", {operation_key = harness.key(), route = {delivery = "hook"}}))
            harness.value(journal:call("session_attach", {session = opened.session, attempt_id = "interactive-one", operation_key = harness.key()}))
            local session_ref = assert(bounds.id(opened.session))
            local peer = harness.principal("bs:node:" .. WORKSPACE .. ":peer", {"bee.threads.security:sessions_owner"}, WORKSPACE)
            local first = harness.value(peer:call("work_send", {session = opened.session, input = "reply to this peer", operation_key = harness.key()}))
            harness.value(journal:call("turn_reserve", {session = opened.session, operation_key = harness.key()}))
            local policies = {assert(security.policy("bee.gateway.security:session_boundary_policy"))}
            local function boundary(actor_id: string, event: string, operation_key: string, attempt: string?, input: string?, answer: string?): {[string]: unknown}
                local actor = assert(security.new_actor(actor_id, {workspace_id = WORKSPACE}))
                local raw, err = funcs.new():with_actor(actor):with_scope(security.new_scope(policies)):call("bee.threads.sessions.binding:hook_boundary",
                    {session = opened.session, event = event, operation_key = operation_key, attempt_id = attempt or "interactive-one", input = input, answer = answer})
                if err then error(tostring(err)) end
                return assert(bounds.object(raw))
            end
            local typed = owner_text("reply to this peer", peer.id)
            test.is_false(boundary("forged", "UserPromptSubmit", harness.key(), nil, typed).ok)
            test.is_false(boundary(session_ref, "UserPromptSubmit", harness.key(), "stale-window", typed).ok)
            test.is_false(boundary(session_ref, "UserPromptSubmit", harness.key(), nil, nil, "an answer belongs to Stop").ok)
            local ignored = boundary(session_ref, "UserPromptSubmit", harness.key(), nil, "something the person typed")
            if not ignored.ok then error("ignored prompt: " .. tostring(ignored.error and (assert(bounds.object(ignored.error))).message)) end
            test.eq(harness.value(journal:call("work_describe", {work = first.work})).phase, "reserved")
            local accepted = boundary(session_ref, "UserPromptSubmit", harness.key(), nil, typed)
            if not accepted.ok then error("typed prompt: " .. tostring(accepted.error and (assert(bounds.object(accepted.error))).message)) end
            test.is_nil((assert(bounds.object(accepted.value))).additional_context)
            test.eq(harness.value(journal:call("work_describe", {work = first.work})).phase, "accepted")
            local second = harness.value(peer:call("work_send", {session = opened.session, input = "next message", operation_key = harness.key()}))
            test.eq(harness.value(journal:call("work_describe", {work = second.work})).phase, "queued")
            local stopped = boundary(session_ref, "Stop", harness.key(), nil, nil, "Here is my reply to the peer.")
            if not stopped.ok then error("stop: " .. tostring(stopped.error and (assert(bounds.object(stopped.error))).message)) end
            local settled = harness.value(journal:call("work_describe", {work = first.work}))
            test.eq(settled.phase, "settled")
            local result = assert(bounds.object(settled.result))
            test.eq(result.state, "succeeded")
            test.eq((assert(bounds.object(result.value))).text, "Here is my reply to the peer.")
            local undelivered = harness.value(journal:call("work_describe", {work = second.work}))
            test.eq(undelivered.phase, "settled")
            local failure = assert(bounds.object((assert(bounds.object(undelivered.result))).error))
            test.eq(failure.code, "UNDELIVERED")
        end)
    end)
end
return test.run_cases(define_tests)
