local test = require("test")
local host = require("host")
local harness = require("harness")
local bounds = require("bounds")
local capabilities = require("capabilities")
local response = require("response")
local funcs = require("funcs")
local supervisor = require("supervisor")
local process = require("process")
local events = require("events")
local channel = require("channel")
local security = require("security")
local function dispatch(session: host.Session, point: string, input: unknown?, output: unknown?, occurrence: string?): {[string]: unknown}
    return host.call("bee.threads.hooks:dispatch", {session_ref = session.session, thread_id = session.thread,
        workspace_id = host.WORKSPACE, point = point, occurrence_id = occurrence or harness.key(), input = input, output = output})
end
local function define_tests(group: string, selected_driver: string?)
    test.describe("Session extension hooks", function()
        test.after_all(host.close_all)
        if group == "core" then
        test.it("chains changes in trait reference order at the production dispatcher", function()
            local session = host.open(nil, "bee.tests.memory:hooks_b")
            host.approve(session.binding, nil, "bee.tests.memory:hooks_a")
            local reply = dispatch(session, "tool.before", {text = "seed"})
            test.eq(assert(bounds.object(reply.input)).text, "seed:a:b")
        end)
        end
        if group == "core" then
        test.it("keeps managed trait consent on the session across work action bindings", function()
            local session, question = host.open(true, "bee.tests.memory:hooks_a", "claude", true)
            test.is_true(session.binding.action_id ~= session.session)
            local payload = assert(bounds.object(assert(bounds.object(question.proposal)).payload))
            test.eq(payload.session_ref, session.session)
            host.reattach(session)
            test.eq(assert(bounds.object(dispatch(session, "tool.before", {text = "seed"}).input)).text, "seed:a")
            host.revoke(session)
            test.eq(assert(bounds.object(dispatch(session, "tool.before", {text = "seed"}).input)).text, "seed")
        end)
        end
        if group == "core" then
        test.it("retains the storage disclosure when approval also includes a listening trait", function()
            local session = host.open(nil, "bee.tests.memory:hooks_a")
            local _, _, question = host.approve(session.binding, nil, "bee.tests.memory:hooks_a", host.TRAIT)
            test.is_true(assert(bounds.text(assert(bounds.object(question.prompt)).text)):find("originals are stored", 1, true) ~= nil)
        end)
        end
        if group == "core" then
        test.it("preserves the original across chained replacements and retrieves it under consent", function()
            local session, question = host.open(nil, "bee.tests.memory:hooks_a")
            test.is_true(assert(bounds.text(assert(bounds.object(question.prompt)).text)):find("originals are stored", 1, true) ~= nil)
            host.approve(session.binding, nil, "bee.tests.memory:hooks_b")
            local occurrence = harness.key()
            local reply = dispatch(session, "tool.after", {text = "seed"}, "original", occurrence)
            test.eq(reply.output, "original:a:b")
            local refs = assert(bounds.array(reply.original_refs, 16))
            test.eq(#refs, 2)
            test.eq(dispatch(session, "tool.after", {text = "seed"}, "original", occurrence).output, "original:a:b")
            local client = host.client("hook-reader-" .. harness.key())
            for _, ref in ipairs(refs) do
                local original_reply = harness.decode_reply(host.receive(client, "hook_original", {record_ref = ref}))
                test.is_false(original_reply.replayed)
                local original = harness.value(original_reply)
                test.eq(original.output, "original")
            end
            host.revoke(session)
            test.is_false(host.receive(client, "hook_original", {record_ref = refs[1]}).ok)
        end)
        end
        if group == "core" then
        test.it("records crash invalid oversized and budget failures as pass", function()
            local session = host.open(nil, "bee.tests.memory:hooks_a")
            for _, mode in ipairs({"crash", "invalid", "oversized", "budget"}) do
                local occurrence = harness.key()
                local reply = dispatch(session, "tool.before", {text = "seed", mode = mode}, nil, occurrence)
                test.eq(assert(bounds.object(reply.input)).text, "seed")
                test.eq(assert(bounds.object(dispatch(session, "tool.before", {text = "seed", mode = mode}, nil, occurrence).input)).text, "seed")
                test.is_false(reply.denied)
                local db = harness.open()
                local rows = harness.query(db, "SELECT state,diagnostic FROM bee_session_hook_invocations WHERE session_ref=? ORDER BY rowid DESC LIMIT 1", {session.session})
                db:release()
                test.eq(rows[1].state, "diagnostic")
                test.is_true(type(rows[1].diagnostic) == "string")
            end
            local original = string.rep("x", supervisor.MAX_TURN_BYTES + 1)
            local result = dispatch(session, "tool.after", {}, original)
            test.eq(result.output, original)
            test.is_false(result.changed)
            local db = harness.open()
            local row = harness.query(db, "SELECT diagnostic FROM bee_session_hook_invocations WHERE session_ref=? ORDER BY rowid DESC LIMIT 1", {session.session})[1]
            db:release()
            test.is_true(assert(bounds.text(row.diagnostic)):find("hook turn exceeds its bound", 1, true) ~= nil)
        end)
        end
        if group == "core" then
        test.it("fences a cancelled or mismatched late reply by invocation identity", function()
            local executor = host.client("future-" .. harness.key())
            local future = assert(executor:async("bee.tests.memory:run", {}))
            local pending: supervisor.Pending = {id = "current", future = future, started = supervisor.now(), limit_ms = 1000, active = true}
            test.is_false(supervisor.accept(pending, "earlier"))
            supervisor.cancel(pending)
            test.is_false(supervisor.accept(pending, "current"))
        end)
        end
        if group == "core" then
        test.it("revocation during invocation rejects the returned change", function()
            local session = host.open(nil, "bee.tests.memory:hooks_a")
            local result = dispatch(session, "tool.before", {text = "seed", mode = "revoke"})
            test.eq(assert(bounds.object(result.input)).text, "seed")
            test.is_false(result.changed)
            local db = harness.open()
            local rows = harness.query(db, "SELECT diagnostic FROM bee_session_hook_invocations WHERE session_ref=?", {session.session})
            db:release()
            test.eq(rows[1].diagnostic, "trait consent or activation changed during invocation")
        end)
        end
        if group == "core" then
        test.it("revocation mid session ends hook execution", function()
            local session = host.open(nil, "bee.tests.memory:hooks_a")
            test.eq(assert(bounds.object(dispatch(session, "tool.before", {text = "seed"}).input)).text, "seed:a")
            host.revoke(session)
            test.eq(assert(bounds.object(dispatch(session, "tool.before", {text = "seed"}).input)).text, "seed")
        end)
        end
        if group == "core" then
        test.it("isolates active hooks and retained originals by session workspace and app", function()
            local session = host.open(nil, "bee.tests.memory:hooks_a")
            local other = host.open()
            test.eq(assert(bounds.object(dispatch(other, "tool.before", {text = "seed"}).input)).text, "seed")
            local reply = dispatch(session, "tool.after", {}, "private")
            local ref = assert(bounds.array(reply.original_refs, 16))[1]
            local stranger = host.client("outside-hook", string.rep("f", 32))
            test.is_false(host.receive(stranger, "hook_original", {record_ref = ref}).ok)
            stranger = host.client("other-hook-app", nil, nil, "bee.tests.memory:other")
            test.is_false(host.receive(stranger, "hook_original", {record_ref = ref}).ok)
            local raw, err = stranger:call("bee.threads.hooks:dispatch", {session_ref = session.session, thread_id = session.thread,
                workspace_id = host.WORKSPACE, point = "tool.before", occurrence_id = harness.key(), input = {text = "seed"}})
            test.is_true(err ~= nil or (bounds.object(raw) and assert(bounds.object(raw)).ok == false))
            local peer = host.client("hook-peer", nil, nil, nil, true)
            test.is_false(host.receive(peer, "hook_original", {record_ref = ref}).ok)
            raw, err = host.client("hook-stranger", string.rep("f", 32)):call("bee.threads.hooks:dispatch", {session_ref = session.session,
                thread_id = session.thread, workspace_id = host.WORKSPACE, point = "tool.before", occurrence_id = harness.key(), input = {text = "seed"}})
            test.is_true(err ~= nil or (bounds.object(raw) and assert(bounds.object(raw)).ok == false))
            raw, err = funcs.new():call("bee.threads.hooks:dispatch", {session_ref = session.session, thread_id = other.thread,
                workspace_id = host.WORKSPACE, point = "tool.before", occurrence_id = harness.key(), input = {text = "seed"}})
            test.is_true(err ~= nil or (bounds.object(raw) and assert(bounds.object(raw)).ok == false))
        end)
        end
        if group == "native" then
        test.it("deny blocks native tool execution and delivers the reason to the model", function()
            local db = harness.open()
            local before = harness.query(db, "SELECT COUNT(*) AS total FROM bee_test_hook_calls")[1].total
            db:release()
            local session = host.open(nil, "bee.tests.memory:hooks_a")
            host.approve(session.binding, nil, "bee.tests.memory:hooks_b")
            local result = host.native(session, "native_deny")
            test.is_true(result.ok, tostring(assert(bounds.object(result.error or {})).message))
            local value = assert(bounds.object(result.value))
            test.is_true(assert(bounds.text(value.answer)):find("fixture refuses this operation", 1, true) ~= nil)
            db = harness.open()
            test.eq(harness.query(db, "SELECT COUNT(*) AS total FROM bee_test_hook_calls")[1].total, before)
            db:release()
        end)
        end
        if group == "native" then
        test.it("inserts chained input and output replacements into the native model request", function()
            local db = harness.open()
            db:release()
            local session = host.open(nil, "bee.tests.memory:hooks_a")
            host.approve(session.binding, nil, "bee.tests.memory:hooks_b")
            local result = host.native(session, "native_mutate")
            test.is_true(result.ok, tostring(assert(bounds.object(result.error or {})).message))
            local captured = assert(bounds.text(assert(bounds.object(result.value)).answer))
            test.is_true(captured:find("seed:a:b:a:b", 1, true) ~= nil, captured)
            db = harness.open()
            test.eq(harness.query(db, "SELECT text FROM bee_test_hook_calls ORDER BY id DESC LIMIT 1")[1].text, "seed:a:b")
            local originals = harness.query(db, "SELECT original_json FROM bee_session_hook_originals WHERE session_ref=?", {session.session})
            db:release()
            test.eq(#originals, 2)
            for _, original in ipairs(originals) do test.eq(original.original_json, '"seed:a:b"') end
        end)
        end
        if group == "native" then
        test.it("replaces oversized native output before insertion and retains the actual original", function()
            local session = host.open(nil, "bee.tests.memory:hooks_a")
            local result = host.native(session, "native_large_output")
            test.is_true(result.ok, tostring(assert(bounds.object(result.error or {})).message))
            local captured = assert(bounds.text(assert(bounds.object(result.value)).answer))
            test.is_true(captured:find("digest:a", 1, true) ~= nil, captured)
            test.is_true(captured:find(string.rep("original", 700), 1, true) == nil, captured)
            local db = harness.open()
            local originals = harness.query(db, "SELECT original_json FROM bee_session_hook_originals WHERE session_ref=?", {session.session})
            db:release()
            test.eq(#originals, 1)
            test.eq(originals[1].original_json, '"' .. string.rep("original", 700) .. '"')
        end)
        end
        if group == "native" then
        test.it("learned facts from session A reach session B's captured model request and stop after revocation", function()
            local first = host.open(nil, "bee.tests.memory:remember_hook")
            local fact = "orchid-" .. harness.key()
            host.turn(first, "\n\nfact: " .. fact .. "\n")
            local client = host.client("memory-index-" .. harness.key())
            local raw, err = client:call("bee.tests.memory:run", {session_ref = first.session, thread_id = first.thread, trait_id = "bee.tests.memory:remember_hook"})
            test.is_nil(err); test.eq(host.value(raw).indexed, 1, "listener stores session A's fact")
            local second = host.open(nil, "bee.tests.memory:remember_hook")
            local result = host.native(second, "memory_capture")
            test.is_true(result.ok, tostring(assert(bounds.object(result.error or {})).message))
            local captured = assert(bounds.text(assert(bounds.object(result.value)).answer))
            test.is_true(captured:find(fact, 1, true) ~= nil, "model request lacks stored fact: " .. captured)
            host.revoke(second)
            local next_attempt = "attempt-" .. harness.key()
            local carrier = harness.principal("sessions-owner", harness.ALL, host.WORKSPACE)
            harness.value(carrier:call("prepare_attempt", {thread_id = second.thread, action_id = second.session, attempt_id = next_attempt,
                prepared = harness.prepared(), idempotency_key = harness.key()}))
            second.binding.attempt_id = next_attempt
            result = host.native(second, "memory_capture")
            test.is_true(result.ok, "revoked native run failed: " .. tostring(assert(bounds.object(result.error or {})).message))
            captured = assert(bounds.text(assert(bounds.object(result.value)).answer))
            test.is_true(captured:find(fact, 1, true) == nil, "revoked model request contains stored fact: " .. captured)
        end)
        end
        if group == "driver" and (selected_driver == "claude" or selected_driver == "codex") then
        test.it("applies " .. tostring(selected_driver) .. " responses through authenticated HTTP and MCP transports", function()
            for _, driver in ipairs({assert(selected_driver)}) do
                local session = host.open(nil, "bee.tests.memory:hooks_a", driver)
                harness.value(session.owner:call("session_attach", {session = session.session, attempt_id = session.binding.attempt_id, operation_key = harness.key()}))
                local mcp = driver == "codex"
                local _, endpoint, raw_token = host.transport(session)
                local token = assert(raw_token)
                local prompt = host.cli_hook(session, "UserPromptSubmit", {prompt = "hello", turn_id = harness.key()}, token, endpoint, mcp)
                test.eq(assert(bounds.object(prompt.hookSpecificOutput)).additionalContext, "fixture context:a")
                local changed = host.cli_hook(session, "PreToolUse", {tool_name = "Bash", tool_use_id = harness.key(), tool_input = {command = "pwd"}}, token, endpoint, mcp)
                test.eq(assert(bounds.object(assert(bounds.object(changed.hookSpecificOutput)).updatedInput)).command, "pwd:a")
                local denied = host.cli_hook(session, "PreToolUse", {tool_name = "Bash", tool_use_id = harness.key(), tool_input = {mode = "deny"}}, token, endpoint, mcp)
                test.eq(assert(bounds.object(denied.hookSpecificOutput)).permissionDecision, "deny")
                local refused_prompt = host.cli_hook(session, "UserPromptSubmit", {prompt = "deny prompt", turn_id = harness.key()}, token, endpoint, mcp)
                test.eq(refused_prompt.decision, "block")
                test.eq(refused_prompt.reason, "fixture refuses this prompt")
                if driver == "claude" then
                    local after = host.cli_hook(session, "PostToolUse", {tool_name = "Bash", tool_use_id = harness.key(), tool_response = "original"}, token, endpoint)
                    test.eq(assert(bounds.object(after.hookSpecificOutput)).updatedToolOutput, "original:a")
                else
                    local after = host.cli_hook(session, "PostToolUse", {tool_name = "shell", tool_use_id = harness.key(), tool_response = "original"}, token, endpoint, true)
                    test.is_nil(after.hookSpecificOutput)
                end
            end
        end)
        end
        if group == "driver" and (selected_driver == "agy" or selected_driver == "muse" or selected_driver == "grok") then
        for _, driver in ipairs({assert(selected_driver)}) do
            test.it("captures " .. driver .. " tool rewrites and denials through its production hook boundary", function()
                local session = host.open(nil, "bee.tests.memory:tools_hook", driver)
                harness.value(session.owner:call("session_attach", {session = session.session, attempt_id = session.binding.attempt_id, operation_key = harness.key()}))
                local _, endpoint, token = host.transport(session)
                local rewritten = host.cli_hook(session, "PreToolUse", {tool_call_id = harness.key(), tool_name = "shell", tool_input = {command = "pwd"}}, assert(token), endpoint)
                if driver == "agy" then
                    test.eq(assert(bounds.object(rewritten.overwrite)).command, "pwd:b")
                else
                    local specific = assert(bounds.object(rewritten.hookSpecificOutput))
                    test.eq(assert(bounds.object(specific.updatedInput)).command, "pwd:b")
                    if driver == "muse" then test.eq(specific.permissionDecision, "allow") end
                end
                local denied = host.cli_hook(session, "PreToolUse", {tool_call_id = harness.key(), tool_name = "shell", tool_input = {mode = "deny"}}, assert(token), endpoint)
                if driver == "agy" then test.eq(denied.decision, "deny")
                else test.eq(assert(bounds.object(denied.hookSpecificOutput)).permissionDecision, "deny") end
            end)
        end
        end
        if group == "boundaries" then
        test.it("captures Agy injected steps and Grok output replacement with exact capability subsets", function()
            local session = host.open(nil, "bee.tests.memory:prompt_hook", "agy")
            harness.value(session.owner:call("session_attach", {session = session.session, attempt_id = session.binding.attempt_id, operation_key = harness.key()}))
            local _, endpoint, token = host.transport(session)
            local wire = host.cli_hook(session, "UserPromptSubmit", {prompt_id = harness.key(), prompt = "hello"}, assert(token), endpoint)
            test.is_true(type(wire.injectSteps) == "table")
            session = host.open(nil, "bee.tests.memory:after_hook", "grok")
            harness.value(session.owner:call("session_attach", {session = session.session, attempt_id = session.binding.attempt_id, operation_key = harness.key()}))
            _, endpoint, token = host.transport(session)
            wire = host.cli_hook(session, "PostToolUse", {tool_call_id = harness.key(), tool_name = "shell", tool_input = {}, tool_response = "original"}, assert(token), endpoint)
            test.eq(assert(bounds.object(wire.hookSpecificOutput)).updatedToolOutput, "original:b")
            test.is_false(assert(capabilities.at("agy", "session.start")).supported)
            test.eq(table.concat(assert(capabilities.at("agy", "tool.before")).allowed_results, ","), "pass,change,deny")
            test.eq(table.concat(assert(capabilities.at("muse", "tool.after")).allowed_results, ","), "pass,add_context")
            test.eq(table.concat(assert(capabilities.at("grok", "prompt.submit")).allowed_results, ","), "pass,deny")
        end)
        end
        if group == "boundaries" then
        test.it("captures Grok prompt denial and Muse post-tool context through their production boundaries", function()
            local session = host.open(nil, "bee.tests.memory:prompt_hook", "grok")
            harness.value(session.owner:call("session_attach", {session = session.session, attempt_id = session.binding.attempt_id, operation_key = harness.key()}))
            local _, endpoint, token = host.transport(session)
            local wire = host.cli_hook(session, "UserPromptSubmit", {prompt_id = harness.key(), prompt = "deny prompt"}, assert(token), endpoint)
            test.eq(wire.decision, "block")
            test.eq(wire.reason, "fixture refuses this prompt")
            wire = host.cli_hook(session, "UserPromptSubmit", {prompt_id = harness.key(), prompt = "hello"}, assert(token), endpoint)
            test.is_nil(wire.hookSpecificOutput)
            session = host.open(nil, "bee.tests.memory:after_hook", "muse")
            harness.value(session.owner:call("session_attach", {session = session.session, attempt_id = session.binding.attempt_id, operation_key = harness.key()}))
            _, endpoint, token = host.transport(session)
            wire = host.cli_hook(session, "PostToolUse", {tool_call_id = harness.key(), tool_name = "shell", tool_input = {mode = "context"}, tool_response = "original"}, assert(token), endpoint)
            local specific = assert(bounds.object(wire.hookSpecificOutput))
            test.eq(specific.additionalContext, "fixture explicit context")
            test.is_nil(specific.updatedToolOutput)
        end)
        end
        if group == "capabilities" then
        test.it("refuses activation when a capable CLI has no admitted hook transport", function()
            local ok, failure = pcall(host.open, nil, "bee.tests.memory:hooks_a", "claude", nil, true)
            test.is_false(ok)
            test.is_true(tostring(failure):find("UNSUPPORTED_CAPABILITY", 1, true) ~= nil)
            test.is_true(tostring(failure):find("transport is not admitted", 1, true) ~= nil)
            local session = host.open(nil, "bee.tests.memory:hooks_a", "claude")
            ok, failure = pcall(host.bind, session.owner, session.session, session.thread, "bee.tests.memory:hooks_a", nil, session.binding, nil, true)
            test.is_false(ok)
            test.is_true(tostring(failure):find("UNSUPPORTED_CAPABILITY", 1, true) ~= nil)
        end)
        end
        if group == "capabilities" then
        test.it("refuses activation on an observation only driver explicitly", function()
            local ok, failure = pcall(host.open, nil, "bee.tests.memory:hooks_a", "opencode")
            test.is_false(ok)
            test.is_true(tostring(failure):find("UNSUPPORTED_CAPABILITY", 1, true) ~= nil)
        end)
        end
        if group == "capabilities" then
        test.it("reports each driver's operations instead of treating observations as mutations", function()
            local native = capabilities.for_driver("wippy")
            test.eq(#native, 4)
            test.eq(native[4].allowed_results[3], "change")
            for _, point in ipairs(capabilities.for_driver("opencode")) do
                test.is_false(point.supported)
                test.is_true(#point.reason > 0)
            end
            test.eq(table.concat(capabilities.for_driver("codex")[4].allowed_results, ","), "pass,add_context")
            local changed = {changed = true, input = {command = "pwd"}, original_refs = {}, additional_context = "", denied = false}
            local wire = response.render("PreToolUse", changed, "codex")
            test.eq(assert(bounds.object(wire.hookSpecificOutput)).permissionDecision, "allow")
            local denied = response.render("UserPromptSubmit", {denied = true, reason = "no", additional_context = ""}, "claude")
            test.eq(denied.decision, "block")
        end)
        end
    end)
end
local methods = {}
for _, group in ipairs({"core", "native", "boundaries", "capabilities"}) do
    methods[group] = test.run_cases(function() define_tests(group) end)
end
for _, driver in ipairs({"claude", "codex", "agy", "muse", "grok"}) do
    methods[driver] = test.run_cases(function() define_tests("driver", driver) end)
end
return methods
