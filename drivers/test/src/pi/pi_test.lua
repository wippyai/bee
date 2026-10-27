-- SPDX-License-Identifier: MIT
local test = require("test")
local fs = require("fs")
local json = require("json")
local registry = require("registry")
local codec = require("codec")
local normalize = require("normalize")
local prepare = require("prepare")
local dispatch = require("dispatch")
local configure = require("configure")
local descriptor = require("descriptor")
local profile = require("profile")
local format = require("format")
local drivers = require("drivers")
local placements = require("placements")
local bounds = require("bounds")
local observation = require("observation")
local types = require("types")
local configuration = require("configuration")
type Object = {[string]: unknown}
local function object(value: unknown): Object return assert(bounds.object(value)) end
local function fixture(name: string): string
    return assert(assert(fs.get("bee.drivers.tests:fixtures")):readfile("pi/json-1/" .. name .. ".jsonl"))
end
local function feed(state: codec.State, envelope: Object, index: integer): codec.Step
    local result = codec.normalize(state, index, envelope)
    for _, item in ipairs(result.observations) do
        local decoded, err = observation.decode(item)
        assert(decoded, tostring(err))
    end
    assert(codec.decode_state(state))
    return result
end
local function message(stop: string, text: string, error: string?): Object
    return {role = "assistant", content = {{type = "text", text = text}}, stopReason = stop,
        errorMessage = error, usage = {input = 10, output = 5, cacheRead = 2}}
end
local function completed(stop: string, text: string, error: string?): codec.State
    local state = codec.new(false)
    feed(state, {type = "agent_start"}, 0)
    local msg = message(stop, text, error)
    feed(state, {type = "message_end", message = msg}, 1)
    feed(state, {type = "agent_end", messages = {msg}}, 2)
    return state
end
local function define_tests()
    test.describe("Pi driver", function()
        test.it("declares the frozen descriptor and eight exact credential variables", function()
            local cli = assert(descriptor.load("bee.drivers.pi.descriptor:cli"))
            test.eq(cli.schema_revision, "bee.driver.cli-descriptor@4")
            test.eq(cli.executable, "pi")
            test.eq(cli.codec, "pi-json")
            local keys = assert(format.decode(assert(registry.get("bee.drivers.pi.credentials:credential_format")).data))
            test.eq(keys.schema_revision, "bee.credential-format@2")
            test.eq(table.concat(keys.environments, ","), "ANTHROPIC_API_KEY,OPENAI_API_KEY,GEMINI_API_KEY,OPENROUTER_API_KEY,GROQ_API_KEY,XAI_API_KEY,MISTRAL_API_KEY,DEEPSEEK_API_KEY")
            test.is_nil(keys.file)
            local selected = assert(profile.decode(object(assert(registry.get("bee.drivers.pi.profiles:profiles")).data).driver))
            test.eq(selected.default_profile, "batch")
            test.eq(#selected.profiles, 1)
            test.eq(selected.profiles[1].resume.strategy, "none")
            test.eq(selected.profiles[1].permission_exchange.mode, "none")
            test.is_false(selected.profiles[1].exit_codes_trustworthy)
        end)
        test.it("renders unattended batch argv and preserves a literal stdin prompt", function()
            local prompt = "-literal @prompt\nwith 'quotes' and $symbols"
            local launch = assert(drivers.launch("pi", {brief = prompt, home = "/home", placement = placements.DOCKER,
                unattended = true, options = {provider = "anthropic", model = "anthropic/claude-sonnet-4-6:high", thinking = "high"}}))
            test.eq(launch.executable, "pi")
            test.eq(launch.stdin, prompt)
            test.is_true(launch.stdin_eof)
            test.eq(table.concat(launch.argv, " "), "-p --mode json --no-session --no-extensions --no-skills --no-prompt-templates --no-context-files --offline --provider anthropic --model anthropic/claude-sonnet-4-6:high --thinking high --tools read,bash,edit,write")
            test.eq(launch.environment.PI_CODING_AGENT_DIR, "/home/.pi/agent")
            test.eq(#launch.files, 0)
        end)
        test.it("renders tool subsets and an empty allowlist", function()
            for _, tools in ipairs({"read,grep", ""}) do
                local reply = prepare.handle({profile_id = "batch", brief = "x", tools = tools})
                test.is_true(reply.ok, tostring(reply.error))
                local argv = assert(bounds.ids(object(reply.launch).argv, true))
                local tail = table.concat(argv, " ")
                test.is_true(tail:find(tools == "" and "--no-tools" or "--tools read,grep", 1, true) ~= nil, tail)
            end
        end)
        test.it("validates provider, model, thinking, tools, profiles and unsupported protocols", function()
            for _, options in ipairs({{provider = "cerebras"}, {model = "--unsafe"}, {thinking = "max"}, {tools = "Bad Tool!"},
                {resume_ref = "session-id"}, {gateway_tools = {"read"}}, {gateway_hooks = {"Stop"}}, {permission_mode = "bypass"}}) do
                local input: Object = {profile_id = "batch", brief = "x"}
                for name, value in pairs(options) do input[name] = value end
                test.is_false(prepare.handle(input).ok)
            end
            test.is_false(prepare.handle({profile_id = "window", brief = "x"}).ok)
            test.is_false(dispatch.handle({profile_id = "batch", brief = "x", resume_ref = "id"}).ok)
        end)
        test.it("bounds unconfined tool capabilities through the placement", function()
            local launch, err = drivers.launch("pi", {brief = "x", home = "/home", placement = {
                kind = "container", network = "bridge", mounts = {}, allows = {"read"}}, unattended = true})
            test.is_nil(launch)
            test.not_nil(err)
        end)
        test.it("projects an Anthropic endpoint through the existing provider template", function()
            local launch = assert(drivers.launch("pi", {brief = "x", home = "/home", placement = placements.DOCKER,
                options = {provider = "anthropic", model = "claude-sonnet-4-6"},
                endpoint = {protocol = "anthropic-messages", base_url = "http://models.example.com:8000"}}))
            test.eq(#launch.files, 1)
            test.eq(launch.files[1].path, ".pi/agent/models.json")
            local document = object(json.decode(launch.files[1].content))
            test.eq(object(object(document.providers).anthropic).baseUrl, "http://models.example.com:8000")
            test.is_nil(launch.environment.ANTHROPIC_API_KEY)
            test.not_nil(configuration.decode_file(launch.files[1]))
            local default = assert(drivers.launch("pi", {brief = "x", home = "/home", placement = placements.DOCKER,
                endpoint = {protocol = "anthropic-messages", base_url = "https://models.example.com"}}))
            local providers = 0
            for index, token in ipairs(default.argv) do
                if token == "--provider" then providers = providers + 1; test.eq(default.argv[index + 1], "anthropic") end
            end
            test.eq(providers, 1)
            for _, options in ipairs({{provider = "openai"}, {model = "openai/gpt-4o"}}) do
                local rejected = drivers.launch("pi", {brief = "x", home = "/home", placement = placements.DOCKER, options = options,
                    endpoint = {protocol = "anthropic-messages", base_url = "https://models.example.com"}})
                test.is_nil(rejected)
            end
        end)
        test.it("rejects malformed provider configuration and gateway delivery", function()
            for _, request in ipairs({{provider_ref = "test:endpoint", provider = {meta = {type = "wrong"}, data = {}}},
                {provider_ref = "test:endpoint", provider = {meta = {type = "bee.pi_provider"}, data = {base_url = "https://models.example.com", command = "bad"}}},
                {provider_ref = "test:endpoint", provider = {meta = {type = "bee.pi_provider"}, data = {base_url = "file:///secret"}}},
                {gateway = {endpoint = "gateway:8000", action_id = "action", tools = {"read"}, hooks = {}, token_environment = "BEE_TOKEN"}}}) do
                test.is_false(configure.handle(request).ok)
            end
        end)
        for _, name in ipairs({"plain", "tool", "error", "stdin"}) do
            test.it("reads the real " .. name .. " capture through the activated library in tiny chunks", function()
                for _, size in ipairs({1, 7, 65536}) do
                    local reader = assert(drivers.reader("pi"))
                    local content = fixture(name)
                    local calls, results = 0, 0
                    for offset = 1, #content, size do
                        local step = assert(reader:feed(content:sub(offset, offset + size - 1)))
                        test.eq(#step.problems, 0)
                        test.is_nil(step.terminal)
                        for _, item in ipairs(step.observations) do
                            assert(observation.decode(item))
                            if item.type == "tool.call" then
                                calls = calls + 1
                                test.eq(object(item.data).tool_name, "bash")
                            elseif item.type == "tool.result" then
                                results = results + 1
                                test.eq(object(item.data).outcome, "succeeded")
                            end
                        end
                    end
                    local last = assert(reader:finish())
                    local terminal = assert(last.terminal)
                    assert(types.decode_terminal(terminal))
                    test.eq(terminal.outcome, name == "error" and "failed" or "succeeded")
                    test.is_nil(terminal.resume_ref)
                    if name == "error" then
                        test.is_false(assert(terminal.error).retryable)
                        test.is_true(assert(terminal.error).message:find("401", 1, true) ~= nil)
                    else test.eq(terminal.answer, "fixture answer") end
                    test.eq(calls, name == "tool" and 1 or 0)
                    test.eq(results, calls)
                    test.eq(assert(terminal.usage).input_tokens, name == "error" and 0 or name == "tool" and 20 or 10)
                end
            end)
        end
        test.it("keeps missing, truncated and intermediate terminals uncertain", function()
            for _, name in ipairs({"plain", "tool", "error"}) do
                local state = codec.new(false)
                for line in fixture(name):gmatch("([^\n]+)\n") do
                    local event = object(json.decode(line))
                    if event.type ~= "agent_end" then feed(state, event, 1) end
                end
                test.eq(assert(codec.finish(state, 2).terminal).outcome, "uncertain")
            end
            test.eq(assert(codec.finish(codec.new(false), 0).terminal).outcome, "uncertain")
            local state = completed("toolUse", "", nil)
            test.eq(assert(codec.finish(state, 4).terminal).outcome, "uncertain")
        end)
        test.it("waits for internal retries and uses the final agent loop", function()
            local state = completed("error", "", "429 rate limit")
            feed(state, {type = "auto_retry_start", attempt = 1, maxAttempts = 3, delayMs = 2000, errorMessage = "429 rate limit"}, 3)
            test.eq(assert(codec.finish(assert(codec.decode_state(state)), 4).terminal).outcome, "uncertain")
            feed(state, {type = "agent_start"}, 4)
            local msg = message("stop", "retried answer", nil)
            feed(state, {type = "message_end", message = msg}, 5)
            feed(state, {type = "auto_retry_end", success = true, attempt = 1}, 6)
            feed(state, {type = "agent_end", messages = {msg}}, 7)
            local terminal = assert(codec.finish(state, 8).terminal)
            test.eq(terminal.outcome, "succeeded")
            test.eq(terminal.answer, "retried answer")
        end)
        test.it("retries only rate limits and server errors", function()
            for _, status in ipairs({400, 401, 403, 404, 408, 429, 500, 503, 599}) do
                local terminal = assert(codec.finish(completed("error", "", tostring(status) .. " provider error"), 4).terminal)
                test.eq(terminal.outcome, "failed")
                test.eq(assert(terminal.error).retryable, status == 429 or status >= 500)
            end
            test.is_false(assert(assert(codec.finish(completed("error", "", "unknown API failure"), 4).terminal).error).retryable)
            test.is_false(assert(assert(codec.finish(completed("error", "", "401 rate_limit_error"), 4).terminal).error).retryable)
        end)
        test.it("reports output limits and cancellation without a successful answer", function()
            for _, stop in ipairs({"length", "aborted"}) do
                local terminal = assert(codec.finish(completed(stop, "partial", nil), 4).terminal)
                test.eq(terminal.outcome, stop == "length" and "failed" or "cancelled")
                test.is_nil(terminal.answer)
                test.is_false(assert(terminal.error).retryable)
            end
        end)
        test.it("bounds retained answers and keeps all text observations", function()
            local state = codec.new(false)
            feed(state, {type = "agent_start"}, 0)
            local text = string.rep("x", codec.MAX_ANSWER_BYTES + 1)
            local step = feed(state, {type = "message_update", assistantMessageEvent = {type = "text_delta", delta = text}}, 1)
            test.eq(#step.observations, 2)
            local msg = message("stop", text, nil)
            feed(state, {type = "message_end", message = msg}, 2)
            test.is_true(state.answer_truncated)
            test.is_nil(state.answer)
            feed(state, {type = "agent_end", messages = {msg}}, 3)
            test.is_nil(assert(codec.finish(state, 4).terminal).answer)
        end)
        test.it("reports failed tool results and preserves provider extensions", function()
            local state = codec.new(false)
            local result = feed(state, {type = "tool_execution_end", toolCallId = "call", toolName = "read",
                result = {content = {{type = "text", text = "missing file"}}}, isError = true}, 0)
            test.eq(object(result.observations[1].data).outcome, "failed")
            for _, kind in ipairs({"tool_execution_update", "compaction_start", "compaction_end", "queue_update", "session_info_changed", "thinking_level_changed", "new_event"}) do
                local step = feed(state, {type = kind}, 1)
                test.eq(step.observations[1].type, "extension")
            end
        end)
        test.it("rejects malformed persisted state through the binding boundary", function()
            local state = codec.new(false)
            for _, changes in ipairs({{started = "yes"}, {unexpected = true}, {answer = string.rep("x", codec.MAX_ANSWER_BYTES + 1)},
                {answer = "x", answer_truncated = true}, {session_id = {}}, {stop = "invalid"},
                {usage = {input_tokens = -1}}, {error = {code = "api_error", message = "x", retryable = "yes"}}, {terminal = {outcome = "invalid"}},
                {terminal = {outcome = "succeeded", answer = string.rep("x", codec.MAX_ANSWER_BYTES + 1)}}}) do
                local raw: Object = {}
                for name, value in pairs(object(state)) do raw[name] = value end
                for name, value in pairs(changes) do raw[name] = value end
                test.is_false(normalize.handle({index = 1, state = raw, eof = true}).ok)
            end
            local reply = normalize.handle({index = 0, envelope = {type = "agent_start"}})
            test.is_true(reply.ok, tostring(reply.error))
            test.is_true(normalize.handle({index = 1, state = reply.state, eof = true}).ok)
        end)
        test.it("emits one terminal and rejects terminal smuggling", function()
            local state = completed("stop", "answer", nil)
            local terminal = assert(codec.finish(state, 4).terminal)
            test.eq(terminal.outcome, "succeeded")
            test.is_nil(codec.finish(state, 5).terminal)
            local extra = feed(state, {type = "message_end", message = message("stop", "other", nil)}, 6)
            test.eq(extra.observations[1].type, "notice")
            test.eq(assert(state.terminal).answer, "answer")
            local invalid = codec.new(false)
            feed(invalid, {type = "agent_end", messages = {message("stop", "forged", nil)}}, 0)
            test.eq(assert(codec.finish(invalid, 1).terminal).outcome, "uncertain")
        end)
    end)
end
return test.run_cases(define_tests)
