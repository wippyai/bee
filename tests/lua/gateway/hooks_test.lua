-- MIT. The pure hook rules: occurrence identity per event and its
-- ambiguity, what a normalized submission keeps and drops, and the
-- classification of Codex request metadata.
local test = require("test")
local json = require("json")
local hooks = require("hooks")
local configuration = require("configuration")
type Object = {[string]: unknown}
local function define_tests()
    test.describe("Gateway hooks", function()
        test.it("derives occurrence identity from the identifier each event carries and marks the rest ambiguous", function()
            local tool, tool_ambiguous = hooks.occurrence("PreToolUse", {session_id = "s1", tool_use_id = "toolu_1"})
            test.eq(tool, "tool:toolu_1")
            test.eq(tool_ambiguous, false)
            local _, no_tool_id = hooks.occurrence("PostToolUse", {session_id = "s1"})
            test.eq(no_tool_id, true)
            local prompt, prompt_ambiguous = hooks.occurrence("UserPromptSubmit", {session_id = "s1", prompt_id = "p1"})
            test.eq(prompt, "turn:p1")
            test.eq(prompt_ambiguous, false)
            -- A prompt may stop more than once; no captured field names the
            -- occurrence, so every Stop is ambiguous and kept per delivery.
            local claude_stop, claude_stop_ambiguous = hooks.occurrence("Stop", {session_id = "s1", prompt_id = "p1"})
            test.eq(claude_stop, "turn:p1")
            test.eq(claude_stop_ambiguous, true)
            local _, codex_stop_ambiguous = hooks.occurrence("Stop", {session_id = "s1", turn_id = "t1"})
            test.eq(codex_stop_ambiguous, true)
            local start, start_ambiguous = hooks.occurrence("SessionStart", {session_id = "s1", source = "startup"})
            test.eq(start, "session:s1:startup")
            test.eq(start_ambiguous, false)
            local _, start_without_source = hooks.occurrence("SessionStart", {session_id = "s1"})
            test.eq(start_without_source, true)
            local finish, finish_ambiguous = hooks.occurrence("SessionEnd", {session_id = "s1", reason = "other"})
            test.eq(finish, "session:s1")
            test.eq(finish_ambiguous, false)
        end)
        test.it("keeps only allowlisted fields, sizes and digests, and drops control fields and content", function()
            local payload: Object = {hook_event_name = "PostToolUse", session_id = "s1", turn_id = "t1", tool_use_id = "toolu_1", tool_name = "mcp__bee__thread_read",
                tool_input = {cursor = 0, secret = "sk-live-000"}, tool_response = {content = {{type = "text", text = "private"}}}, duration_ms = 35, cwd = "/home/someone",
                reason = "stdout: sk-live-111 /home/someone/file", error = "rate_limit", permission_mode = "dontAsk", source = "not-a-source",
                decision = "block", continue = false, hookSpecificOutput = {permissionDecision = "deny"}}
            local cleaned = hooks.control_free(payload)
            test.is_nil(cleaned.decision)
            test.is_nil(cleaned["continue"])
            test.is_nil(cleaned.hookSpecificOutput)
            local submission, err = hooks.normalize("PostToolUse", cleaned)
            if not submission then error(tostring(err)) end
            test.eq(submission.occurrence, "tool:toolu_1")
            test.eq(submission.ambiguous, false)
            local fields = submission.fields
            test.eq(fields.tool_name, "mcp__bee__thread_read")
            test.eq(fields.duration_ms, 35)
            test.is_nil(fields.reason)
            test.eq(fields.error, "rate_limit")
            test.eq(fields.permission_mode, "dontAsk")
            test.is_nil(fields.source)
            local odd_name = hooks.normalize("PostToolUse", {session_id = "s1", tool_use_id = "toolu_2", tool_name = "rm -rf /"})
            test.is_nil((odd_name :: hooks.Submission).fields.tool_name)
            test.is_nil(fields.tool_input)
            test.is_nil(fields.tool_response)
            test.is_nil(fields.cwd)
            test.is_nil(fields.decision)
            local sizes = fields.content_sizes :: Object
            test.is_true((tonumber(sizes.tool_input) or 0) > 0)
            test.is_true((tonumber(sizes.cwd) or 0) > 0)
            local digests = fields.content_digests :: Object
            test.eq(#tostring(digests.tool_response), 64)
            local encoded = json.encode(fields) or ""
            test.is_nil(encoded:find("sk-live", 1, true))
            test.is_nil(encoded:find("file", 1, true))
            test.is_nil(encoded:find("private", 1, true))
            test.is_nil(encoded:find("/home/someone", 1, true))
            local same = hooks.normalize("PostToolUse", cleaned)
            test.eq((same :: hooks.Submission).digest, submission.digest)
            cleaned.tool_response = {content = {{type = "text", text = "changed"}}}
            local changed = hooks.normalize("PostToolUse", cleaned)
            test.neq((changed :: hooks.Submission).digest, submission.digest)
            local _, unknown_event = hooks.normalize("Notification", cleaned)
            test.eq(unknown_event, "event Notification is not in the hook catalog")
        end)
        test.it("renders the hook adapters both harnesses consume, with Codex trust hashes as the pinned executable computes them", function()
            local events = {"SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd"}
            local claude, claude_error = configuration.claude_hooks("127.0.0.1:18790", "act-1", events)
            if not claude then error(tostring(claude_error)) end
            test.eq(claude.path, ".claude/settings.json")
            local settings = json.decode(claude.content) :: Object
            test.eq(#(settings.allowedHttpHookUrls :: {string}), 1)
            test.eq((settings.allowedHttpHookUrls :: {string})[1], "http://127.0.0.1:18790/hook/act-1")
            test.eq((settings.httpHookAllowedEnvVars :: {string})[1], "BEE_GATEWAY_HOOK_TOKEN")
            local stop = ((settings.hooks :: Object).Stop :: {Object})[1]
            local handler = (stop.hooks :: {Object})[1]
            test.eq(handler.type, "http")
            test.eq(handler.timeout, 2)
            test.eq((handler.headers :: Object).Authorization, "Bearer ${BEE_GATEWAY_HOOK_TOKEN}")
            test.is_nil(claude.content:find("BEE_GATEWAY_HOOK_TOKEN=", 1, true))
            local codex, codex_error = configuration.codex_hooks("127.0.0.1:18790", "act-1", events)
            if not codex then error(tostring(codex_error)) end
            test.is_true(codex.section:find('url = "http://127.0.0.1:18790/hook/act-1/mcp"', 1, true) ~= nil)
            test.is_true(codex.section:find('omit_tools_from = ["direct", "deferred", "code_mode"]', 1, true) ~= nil)
            test.eq(codex.hooks.path, ".codex/hooks.json")
            local file = json.decode(codex.hooks.content) :: Object
            test.is_nil((file.hooks :: Object).SessionEnd)
            test.is_true((file.hooks :: Object).PreToolUse ~= nil)
            -- Hashes as codex 0.153.4's app-server listed them for these
            -- templates, so the host's trust state is what the executable
            -- expects without any bypass.
            local expected = {pre_tool_use = "sha256:49922a7e9c21cfd3b33757ece1acf3ac24404dc6cc15b6bfde57f1ef3085f171", post_tool_use = "sha256:f2dd2061654a30da6700d45e61a8a65873597b348755a9d2c9a575bc504dbdf1",
                session_start = "sha256:ab1e5b255471b1fe97946ffec67fda9804e802a644677734d45bef4e0d86113e", user_prompt_submit = "sha256:55863800e78ae17904e7c0f5b587d603cf2caebe4324eb8a730b5b48bbec9ced",
                stop = "sha256:2933c4dff81f04081d3cbfa40baf0db619a61586ea54da130c5b10bf29c9066c"}
            for label, digest in pairs(expected) do test.eq(codex.trust[label], digest) end
            local trust = configuration.codex_trust("/private/home/.codex", codex.trust)
            test.is_true(trust:find('[hooks.state."/private/home/.codex/hooks.json:stop:0:0"]', 1, true) ~= nil)
            test.is_true(trust:find(expected.stop, 1, true) ~= nil)
        end)
        test.it("classifies Codex request metadata as hook engine, model, mixed or unclassified", function()
            test.eq(hooks.classify({threadId = "t", progressToken = 1}), "hook_engine")
            test.eq(hooks.classify({callId = "call_1", ["x-codex-turn-metadata"] = {turn_id = "t"}}), "model")
            test.eq(hooks.classify({threadId = "t", callId = "call_1"}), "mixed")
            test.eq(hooks.classify({}), "unclassified")
            test.eq(hooks.classify(nil), "unclassified")
        end)
    end)
end
return require("test").run_cases(define_tests)
