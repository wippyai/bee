-- MIT. Focused tests for the Bee Antigravity CLI (agy) harness child component.
local test = require("test")
local json = require("json")
local hash = require("hash")
local registry = require("registry")
local funcs = require("funcs")
local profile = require("profile")
local launch = require("launch")
local protocol = require("protocol")
local configuration = require("configuration")
local configure_protocol = require("configure_protocol")
local observation = require("observation")
local stream_json = require("stream_json")
local quote = require("quote")
local bounds = require("bounds")

local function has(list: {string}, item: string): boolean
    for _, candidate in ipairs(list) do
        if candidate == item then return true end
    end
    return false
end

local function quoted_arguments(value: unknown): string?
    if type(value) ~= "table" then return nil end
    local raw = value :: {unknown}
    local arguments: {string} = {}
    for index, argument in ipairs(raw) do
        if type(argument) ~= "string" then return nil end
        arguments[index] = argument
    end
    return quote.line(arguments)
end

local function define_tests()
    test.describe("Antigravity CLI binding and profile declarations", function()
        test.it("validates the agy binding and profiles against the driver profile decoder", function()
            local entry, err = registry.get("bee.driver.agy:binding")
            if not entry then error("bee.driver.agy:binding: " .. tostring(err)) end
            test.eq(entry.meta.type, "harness.driver")
            test.eq(entry.meta.driver_id, "agy")

            local declaration, decl_err = registry.get(tostring(entry.meta.profiles_ref))
            if not declaration then error("profiles: " .. tostring(decl_err)) end
            test.eq(declaration.meta.driver_ref, "bee.driver.agy:binding")

            local binding, decode_error = profile.decode(declaration.data.driver)
            if not binding then error("profile decode: " .. tostring(decode_error)) end
            test.eq(binding.schema_revision, "bee.driver@1")
            test.eq(binding.kind, "harness")
            test.eq(binding.default_profile, "session")

            -- session profile: stream-json with per-process resume
            local session_p = profile.find(binding, "session")
            if not session_p then error("session profile missing") end
            test.eq(session_p.mode, "session")
            test.eq(session_p.protocol, "stream-json")
            test.eq(session_p.protocol_revision, "agy-stream-json-1")
            test.eq(session_p.answer_path.strategy, "terminal_field")
            test.eq(session_p.answer_path.adapter_ref, "bee.driver.agy:protocol")
            test.eq(session_p.resume.strategy, "per-process")
            test.eq(session_p.input_ready.strategy, "protocol")
            test.eq(session_p.permission_exchange.mode, "none")

            -- unsupported capability claims removed: no hooks declared in profile
            test.eq(#session_p.hooks.transports, 0)
            test.eq(#session_p.hooks.events, 0)

            -- MCP client transports verified: stdio and streamable_http, no speculative sse/ws
            test.is_true(has(session_p.mcp.client_transports, "stdio"))
            test.is_true(has(session_p.mcp.client_transports, "streamable_http"))
            test.is_false(has(session_p.mcp.client_transports, "sse"))
            test.is_false(has(session_p.mcp.client_transports, "ws"))

            -- batch and window profiles
            local batch_p = profile.find(binding, "batch")
            if not batch_p then error("batch profile missing") end
            test.eq(batch_p.mode, "batch")
            test.is_true(batch_p.isolation_env.private_home)
            test.is_true(has(batch_p.mcp.client_transports, "streamable_http"))
            test.is_false(has(batch_p.mcp.client_transports, "stdio"))

            local window_p = profile.find(binding, "window")
            if not window_p then error("window profile missing") end
            test.eq(window_p.mode, "window")
            test.eq(window_p.protocol, "pty")
        end)
    end)

    test.describe("Antigravity CLI launch specifications and host-policy options", function()
        test.it("produces structured stream-json print launches with expressible host-policy options", function()
            local request, err = launch.decode({
                profile_id = "session",
                brief = "list workspace files",
                mode = "accept-edits",
                model = "gemini-3.8-flash-high",
                effort = "high",
                sandbox = true,
                dangerously_skip_permissions = true,
                agent = "default",
                print_timeout = "10m",
            })
            if not request then error(tostring(err)) end

            local spec = launch.specification(request)
            test.eq(spec.executable, "agy")
            test.eq(spec.readiness, "protocol:init")
            test.is_true(spec.stdin_eof)
            test.eq(spec.stdin, '{"event":"user","message":{"content":"list workspace files","role":"user"}}\n')

            local line = quote.line(spec.argv)
            test.is_true(line:find("^%-%-print= %-%-input%-format stream%-json %-%-output%-format stream%-json %-%-disable%-slash%-commands") ~= nil)
            test.is_true(line:find("%-%-mode accept%-edits") ~= nil)
            test.is_true(line:find("%-%-dangerously%-skip%-permissions") ~= nil)
            test.is_true(line:find("%-%-sandbox") ~= nil)
            test.is_true(line:find("%-%-model gemini%-3%.8%-flash%-high") ~= nil)
            test.is_true(line:find("%-%-effort high") ~= nil)
            test.is_true(line:find("%-%-agent default") ~= nil)
            test.is_true(line:find("%-%-print%-timeout 10m") ~= nil)
        end)

        test.it("prepares the hidden Gemini batch profile and delivers its admitted HTTP MCP configuration", function()
            local prepared, prepare_error = funcs.call("bee.driver.agy.binding:prepare", {
                profile_id = "batch",
                brief = "Use the admitted Bee overlay tool once.",
                model = "gemini-3.8-flash",
                effort = "high",
                print_timeout = "5m",
                gateway_tools = {"thread_read", "overlay"},
            })
            if prepare_error then error(tostring(prepare_error)) end
            test.is_true(prepared.ok)
            test.eq(prepared.launch.executable, "agy")
            test.eq(prepared.launch.readiness, "protocol:init")
            test.is_true(prepared.launch.stdin_eof)
            local arguments = quoted_arguments(prepared.launch.argv)
            if not arguments then error("prepared launch argv must be a string list") end
            test.is_true(arguments:find("^%-%-print= %-%-input%-format stream%-json") ~= nil)
            test.is_true(arguments:find("%-%-model gemini%-3%.8%-flash") ~= nil)
            test.is_true(arguments:find("%-%-effort high") ~= nil)
            test.is_true(arguments:find("%-%-print%-timeout 5m") ~= nil)

            local gateway = {
                endpoint = "127.0.0.1:18790",
                action_id = "agy-batch-proof",
                tools = {"thread_read", "overlay"},
                hooks = {},
                token_environment = "BEE_GATEWAY_TOKEN",
            }
            local configured, configure_error = funcs.call("bee.driver.agy.binding:configure", {
                gateway = gateway,
                home_directory = "/private/agy-batch-session",
                fixture = false,
            })
            if configure_error then error(tostring(configure_error)) end
            test.is_true(configured.ok)
            test.eq(configured.delivery.arguments[1], "--add-dir")
            test.eq(configured.delivery.arguments[2], "/private/agy-batch-session")
            test.eq(#configured.delivery.files, 1)
            local mcp_file = configured.delivery.files[1]
            test.eq(mcp_file.path, ".agents/mcp_config.json")
            test.eq(mcp_file.provider_ref, "bee:gateway_endpoint")
            test.is_true(mcp_file.content:find("/mcp/agy%-batch%-proof") ~= nil)
            test.eq(mcp_file.secret_fields[1].environment, "BEE_GATEWAY_TOKEN")
        end)

        test.it("selects the native sandbox for the shipped batch worker without skipping permissions", function()
            local request, err = launch.decode({
                profile_id = "batch",
                brief = "read traits",
                model = "gemini-3.8-flash",
                effort = "high",
                sandbox = true,
                print_timeout = "5m",
            })
            if not request then error(tostring(err)) end
            local line = quote.line(launch.specification(request).argv)
            test.is_true(line:find("%-%-sandbox") ~= nil)
            test.is_true(line:find("dangerously%-skip%-permissions") == nil)
            test.is_true(line:find("%-%-print%-timeout 5m") ~= nil)
        end)

        test.it("does not hardcode a model when omitted in production", function()
            local request, err = launch.decode({
                profile_id = "session",
                brief = "no model specified",
            })
            if not request then error(tostring(err)) end
            test.is_nil(request.model)

            local spec = launch.specification(request)
            local line = quote.line(spec.argv)
            test.is_nil(line:find("%-%-model"))
        end)

        test.it("refuses foreign permission modes and unsupported turn limits", function()
            local refused, err = launch.decode({profile_id = "session", brief = "x", permission_mode = "dontAsk"})
            test.is_nil(refused)
            test.eq(err, "unknown field permission_mode")
            local limited, limit_error = launch.decode({profile_id = "session", brief = "x", max_turns = 1})
            test.is_nil(limited)
            test.eq(limit_error, "unknown field max_turns")
            local request, request_error = launch.decode({profile_id = "session", brief = "x", mode = "plan"})
            if not request then error(tostring(request_error)) end
            local command = quote.line(launch.specification(request).argv)
            test.is_true(command:find("--mode plan", 1, true) ~= nil)
            test.is_nil(command:find("--dangerously-skip-permissions", 1, true))
        end)

        test.it("handles continuation turns with conversation resume reference", function()
            local request, err = launch.decode({
                profile_id = "session",
                brief = "continue turn",
                resume_ref = "f30fe2e7-e321-4839-8e4c-bbda9d2f9c4b",
            })
            if not request then error(tostring(err)) end

            local spec = launch.specification(request)
            local line = quote.line(spec.argv)
            test.is_true(line:find("%-%-conversation f30fe2e7%-e321%-4839%-8e4c%-bbda9d2f9c4b") ~= nil)
            test.is_true(spec.stdin:find("continue turn") ~= nil)

            -- Dispatch method requires resume_ref
            local fail_reply, call_err = funcs.call("bee.driver.agy.binding:dispatch", {
                profile_id = "session",
                brief = "missing resume",
            })
            if call_err then error(tostring(call_err)) end
            test.is_false(fail_reply.ok)
            test.eq(fail_reply.error, "a dispatched turn needs resume_ref")

            local ok_reply, ok_err = funcs.call("bee.driver.agy.binding:dispatch", {
                profile_id = "session",
                brief = "has resume",
                resume_ref = "f30fe2e7-e321-4839-8e4c-bbda9d2f9c4b",
            })
            if ok_err then error(tostring(ok_err)) end
            test.is_true(ok_reply.ok)
            test.not_nil(ok_reply.launch)
        end)

        test.it("produces native terminal interactive window specifications", function()
            local empty_req, empty_err = launch.decode({
                profile_id = "window",
                brief = "",
            })
            if not empty_req then error(tostring(empty_err)) end

            local empty_spec = launch.specification(empty_req)
            test.eq(empty_spec.executable, "agy")
            test.eq(empty_spec.readiness, "terminal:attached")
            test.is_nil(empty_spec.stdin)
            test.eq(quote.line(empty_spec.argv), "")

            local prompt_req, prompt_err = launch.decode({
                profile_id = "window",
                brief = "interactive review",
                resume_ref = "session-conv-1",
            })
            if not prompt_req then error(tostring(prompt_err)) end

            local prompt_spec = launch.specification(prompt_req)
            test.eq(quote.line(prompt_spec.argv), "--conversation session-conv-1 --prompt-interactive 'interactive review'")
        end)

        test.it("strictly rejects malformed options and invalid shapes", function()
            local empty_session = launch.decode({profile_id = "session", brief = ""})
            test.is_nil(empty_session)

            local _, timeout_err = launch.decode({profile_id = "window", brief = "", print_timeout = "5m"})
            test.eq(timeout_err, "print_timeout is only supported for structured print turns")

            local _, model_err = launch.decode({profile_id = "session", brief = "x", model = "invalid space"})
            test.eq(model_err, "model is not one bounded model identifier")

            local _, effort_err = launch.decode({profile_id = "session", brief = "x", effort = "maximum"})
            test.eq(effort_err, "effort is not one Bee admits")

            local _, mode_err = launch.decode({profile_id = "session", brief = "x", mode = "turbo"})
            test.eq(mode_err, "mode is not one Bee admits")

            local _, perm_err = launch.decode({profile_id = "session", brief = "x", permission_mode = "invalid"})
            test.eq(perm_err, "unknown field permission_mode")

            local _, turns_err = launch.decode({profile_id = "session", brief = "x", max_turns = 0})
            test.eq(turns_err, "unknown field max_turns")

            local _, resume_err = launch.decode({profile_id = "session", brief = "x", resume_ref = "-invalid"})
            test.eq(resume_err, "resume_ref must not be a command-line option")

            local _, agent_err = launch.decode({profile_id = "session", brief = "x", agent = "--flag"})
            test.eq(agent_err, "agent must not be a command-line option")

            local _, bad_bool = launch.decode({profile_id = "session", brief = "x", sandbox = "true"})
            test.eq(bad_bool, "sandbox must be a boolean")
        end)
    end)

    test.describe("normalize_method structural validation of state and booleans", function()
        test.it("validates eof and resumed boolean flags", function()
            local bad_eof, err1 = funcs.call("bee.driver.agy.binding:normalize", {
                index = 1,
                eof = "true",
            })
            if err1 then error(tostring(err1)) end
            test.is_false(bad_eof.ok)
            test.eq(bad_eof.error, "eof must be a boolean")

            local bad_resumed, err2 = funcs.call("bee.driver.agy.binding:normalize", {
                index = 1,
                resumed = 1,
                envelope = {event = "init", conversation_id = "c1"},
            })
            if err2 then error(tostring(err2)) end
            test.is_false(bad_resumed.ok)
            test.eq(bad_resumed.error, "resumed must be a boolean")
        end)

        test.it("structurally validates incoming state against malformed shapes and bounds", function()
            -- Non-object state
            local not_obj, err1 = funcs.call("bee.driver.agy.binding:normalize", {
                index = 1,
                state = "invalid",
                envelope = {event = "init", conversation_id = "c1"},
            })
            if err1 then error(tostring(err1)) end
            test.is_false(not_obj.ok)
            test.eq(not_obj.error, "state must be an object")

            -- Unknown fields in state
            local unknown_state, err2 = funcs.call("bee.driver.agy.binding:normalize", {
                index = 1,
                state = {started = true, resumed = false, foreign_key = "leak"},
                envelope = {event = "init", conversation_id = "c1"},
            })
            if err2 then error(tostring(err2)) end
            test.is_false(unknown_state.ok)
            test.eq(unknown_state.error, "state: unknown field foreign_key")

            -- Non-boolean started / resumed in state
            local bad_started, err3 = funcs.call("bee.driver.agy.binding:normalize", {
                index = 1,
                state = {started = "yes", resumed = false},
                envelope = {event = "init", conversation_id = "c1"},
            })
            if err3 then error(tostring(err3)) end
            test.is_false(bad_started.ok)
            test.eq(bad_started.error, "state.started must be a boolean")

            -- Invalid session_id in state
            local bad_session, err4 = funcs.call("bee.driver.agy.binding:normalize", {
                index = 1,
                state = {started = true, resumed = false, session_id = ""},
                envelope = {event = "step_update", step_update = {}},
            })
            if err4 then error(tostring(err4)) end
            test.is_false(bad_session.ok)
            test.eq(bad_session.error, "state.session_id is not an identifier")

            -- Oversized answer in state
            local bad_answer, err5 = funcs.call("bee.driver.agy.binding:normalize", {
                index = 1,
                state = {started = true, resumed = false, answer_truncated = false, answer = string.rep("x", bounds.MAX_RECORD_BYTES + 1)},
                envelope = {event = "step_update", step_update = {}},
            })
            if err5 then error(tostring(err5)) end
            test.is_false(bad_answer.ok)
            test.eq(bad_answer.error, "state.answer exceeds maximum record bytes")

            -- Valid bounded state succeeds
            local valid_reply, err6 = funcs.call("bee.driver.agy.binding:normalize", {
                index = 1,
                state = {started = true, resumed = false, answer_truncated = false, session_id = "conv-valid", answer = "prior"},
                envelope = {
                    event = "step_update",
                    step_update = {
                        conversation_id = "conv-valid",
                        step_index = 1,
                        state = "ACTIVE",
                        step_type = "agent_response",
                        text_delta = " delta",
                    },
                },
            })
            if err6 then error(tostring(err6)) end
            test.is_true(valid_reply.ok)
            test.eq(valid_reply.state.answer, "prior delta")

            -- Terminal checkpoints are decoded field by field, including
            -- nested usage and fault values.
            local terminal_reply, terminal_err = funcs.call("bee.driver.agy.binding:normalize", {
                index = 1,
                state = {
                    started = true,
                    resumed = false,
                    answer_truncated = false,
                    session_id = "conv-valid",
                    terminal = {
                        outcome = "failed",
                        answer = "bounded answer",
                        resume_ref = "conv-valid",
                        usage = {
                            input_tokens = 4,
                            output_tokens = 5,
                            cached_tokens = 6,
                            cost_decimal = "1.25",
                            currency = "USD",
                        },
                        error = {code = "failed", message = "bounded fault", retryable = false},
                    },
                },
                envelope = {event = "step_update", step_update = {}},
            })
            if terminal_err then error(tostring(terminal_err)) end
            test.is_true(terminal_reply.ok)
            test.eq(terminal_reply.state.terminal.usage.cost_decimal, "1.25")
            test.eq(terminal_reply.state.terminal.error.message, "bounded fault")

            local bad_terminal_answer, bad_terminal_answer_call_error = funcs.call("bee.driver.agy.binding:normalize", {
                index = 1,
                state = {started = true, resumed = false, answer_truncated = false, terminal = {outcome = "succeeded", answer = string.rep("x", bounds.MAX_RECORD_BYTES + 1)}},
                envelope = {event = "step_update", step_update = {}},
            })
            if bad_terminal_answer_call_error then error(tostring(bad_terminal_answer_call_error)) end
            test.eq(bad_terminal_answer.error, "state.terminal.answer exceeds maximum record bytes")

            local bad_terminal_usage, bad_terminal_usage_call_error = funcs.call("bee.driver.agy.binding:normalize", {
                index = 1,
                state = {started = true, resumed = false, answer_truncated = false, terminal = {outcome = "succeeded", usage = {input_tokens = -1}}},
                envelope = {event = "step_update", step_update = {}},
            })
            if bad_terminal_usage_call_error then error(tostring(bad_terminal_usage_call_error)) end
            test.eq(bad_terminal_usage.error, "state.terminal.usage.input_tokens must be a nonnegative integer")

            local bad_terminal_error, bad_terminal_error_call_error = funcs.call("bee.driver.agy.binding:normalize", {
                index = 1,
                state = {started = true, resumed = false, answer_truncated = false, terminal = {outcome = "failed", error = {code = "failed", message = "x", retryable = "no"}}},
                envelope = {event = "step_update", step_update = {}},
            })
            if bad_terminal_error_call_error then error(tostring(bad_terminal_error_call_error)) end
            test.eq(bad_terminal_error.error, "state.terminal.error.retryable must be a boolean")
        end)
    end)

    test.describe("Antigravity CLI protocol normalization, answer bounds, and identity pinning", function()
        test.it("pins conversation identity on init and claims readiness", function()
            local state = protocol.new(false)
            local step = protocol.normalize(state, 1, {
                event = "init",
                conversation_id = "f30fe2e7-e321-4839-8e4c-bbda9d2f9c4b",
                init = {cwd = "/workspace"},
            })

            test.is_true(state.started)
            test.eq(state.session_id, "f30fe2e7-e321-4839-8e4c-bbda9d2f9c4b")
            test.is_nil(step.terminal)
            test.eq(#step.observations, 2)
            test.eq(step.observations[1].type, "session.state")
            test.eq(step.observations[2].type, "turn.signal")

            for _, obs in ipairs(step.observations) do
                local decoded, dec_err = observation.decode(obs)
                if not decoded then error("obs decode: " .. tostring(dec_err)) end
            end
        end)

        test.it("refuses malformed init and does not claim readiness", function()
            -- Missing conversation_id in init
            local state1 = protocol.new(false)
            local step1 = protocol.normalize(state1, 1, {
                event = "init",
                init = {cwd = "/workspace"},
            })
            test.is_false(state1.started)
            test.is_nil(state1.session_id)
            test.eq(#step1.observations, 1)
            test.eq(step1.observations[1].type, "notice")
            test.eq(step1.observations[1].data.code, "malformed_init")

            -- Empty conversation_id in init
            local state2 = protocol.new(false)
            local step2 = protocol.normalize(state2, 1, {
                event = "init",
                conversation_id = "",
                init = {},
            })
            test.is_false(state2.started)
            test.eq(#step2.observations, 1)
            test.eq(step2.observations[1].data.code, "malformed_init")
        end)

        test.it("refuses conflicting later conversation IDs and fails conflicting result", function()
            local state = protocol.new(false)
            protocol.normalize(state, 1, {
                event = "init",
                conversation_id = "pinned-conv-1",
                init = {},
            })
            test.eq(state.session_id, "pinned-conv-1")

            -- step_update with foreign conversation ID is refused and emits warning notice
            local step2 = protocol.normalize(state, 2, {
                event = "step_update",
                step_update = {
                    conversation_id = "foreign-conv-99",
                    step_index = 1,
                    state = "ACTIVE",
                    step_type = "agent_response",
                    text_delta = "hijacked",
                },
            })
            test.eq(#step2.observations, 1)
            test.eq(step2.observations[1].type, "notice")
            test.eq(step2.observations[1].data.code, "conflicting_conversation_id")
            test.is_nil(state.answer) -- delta was not applied

            -- result with foreign conversation ID fails and must not succeed
            local step3 = protocol.normalize(state, 3, {
                event = "result",
                result = {
                    conversation_id = "foreign-conv-99",
                    status = "SUCCESS",
                    response = "stolen success",
                },
            })
            test.not_nil(step3.terminal)
            test.eq(step3.terminal.outcome, "failed")
            test.eq(step3.terminal.error.code, "conflicting_conversation_id")

            -- The actual wire can carry an envelope identity and a nested
            -- result identity; they must agree before either is trusted.
            local state2 = protocol.new(false)
            protocol.normalize(state2, 1, {event = "init", conversation_id = "nested-conflict", init = {}})
            local nested_conflict = protocol.normalize(state2, 2, {
                event = "result",
                conversation_id = "outer-conv",
                result = {conversation_id = "inner-conv", status = "SUCCESS", response = "no"},
            })
            test.not_nil(nested_conflict.terminal)
            test.eq(nested_conflict.terminal.outcome, "failed")
            test.eq(nested_conflict.terminal.error.code, "conflicting_conversation_id")
        end)

        test.it("enforces that malformed results must not succeed", function()
            -- Result received on unstarted session fails
            local unstarted = protocol.new(false)
            local unstarted_step = protocol.normalize(unstarted, 1, {
                event = "result",
                result = {
                    conversation_id = "c1",
                    status = "SUCCESS",
                    response = "premature result",
                },
            })
            test.not_nil(unstarted_step.terminal)
            test.eq(unstarted_step.terminal.outcome, "failed")
            test.eq(unstarted_step.terminal.error.code, "unstarted_session")

            -- Result with status SUCCESS but error object present fails
            local state = protocol.new(false)
            protocol.normalize(state, 1, {event = "init", conversation_id = "c1", init = {}})
            local corrupt_step = protocol.normalize(state, 2, {
                event = "result",
                result = {
                    conversation_id = "c1",
                    status = "SUCCESS",
                    error = "hidden failure",
                },
            })
            test.not_nil(corrupt_step.terminal)
            test.eq(corrupt_step.terminal.outcome, "failed")
            test.eq(corrupt_step.terminal.error.code, "status_error_mismatch")
        end)

        test.it("bounds retained answer using thread observation limits and removes unused tools map", function()
            local state = protocol.new(false)
            protocol.normalize(state, 1, {event = "init", conversation_id = "c1", init = {}})

            -- verify tools map is nil / not accumulating
            test.is_nil((state :: {[string]: unknown}).tools)

            -- Stream delta chunks totaling > the retained answer bound. Every
            -- bounded frame must remain present in observations even though
            -- the checkpointed summary is omitted after overflow.
            local chunk = string.rep("A", 5000)
            local observed = {}
            for i = 1, 5 do
                local step = protocol.normalize(state, i + 1, {
                    event = "step_update",
                    step_update = {
                        conversation_id = "c1",
                        step_index = i,
                        state = "ACTIVE",
                        step_type = "agent_response",
                        text_delta = chunk,
                    },
                })
                for _, obs in ipairs(step.observations) do
                    if obs.type == "text" then
                        observed[#observed + 1] = obs.data.text
                    end
                end
            end

            test.eq(table.concat(observed), string.rep("A", 25000))
            test.is_nil(state.answer)
            test.is_true(state.answer_truncated)

            -- An oversized terminal response is omitted rather than silently
            -- sliced; the bound is signaled as an observation.
            local notices = 0
            local result_step = protocol.normalize(state, 10, {
                event = "result",
                result = {
                    conversation_id = "c1",
                    status = "SUCCESS",
                    response = string.rep("B", bounds.MAX_RECORD_BYTES + 500),
                },
            })
            test.not_nil(result_step.terminal)
            test.eq(result_step.terminal.outcome, "succeeded")
            test.is_nil(result_step.terminal.answer)
            for _, obs in ipairs(result_step.observations) do
                if obs.type == "notice" and obs.data.code == "answer_truncated" then notices = notices + 1 end
            end
            test.is_true(notices >= 1)

            -- A provider output field does not imply a completed tool call
            -- while the step remains active.
            local live_state = protocol.new(false)
            protocol.normalize(live_state, 1, {event = "init", conversation_id = "tool-state", init = {}})
            local live_step = protocol.normalize(live_state, 2, {
                event = "step_update",
                step_update = {conversation_id = "tool-state", state = "ACTIVE", step_type = "tool_call", tool_name = "run_command", output = "still running"},
            })
            test.eq(#live_step.observations, 1)
            test.eq(live_step.observations[1].type, "tool.call")
        end)

        test.it("normalizes actual observed wire schema without speculative aliases", function()
            local state = protocol.new(false)
            protocol.normalize(state, 1, {event = "init", conversation_id = "conv-wire", init = {}})

            -- agent response with thinking
            local step2 = protocol.normalize(state, 2, {
                event = "step_update",
                step_update = {
                    conversation_id = "conv-wire",
                    step_index = 1,
                    state = "ACTIVE",
                    step_type = "agent_response",
                    text_delta = "Hello\n",
                    thinking = "Plan the response",
                },
            })
            test.eq(#step2.observations, 2)
            test.eq(step2.observations[1].type, "text")
            test.eq(step2.observations[2].type, "text")

            -- tool call and tool result using wire schema fields
            local step3 = protocol.normalize(state, 3, {
                event = "step_update",
                step_update = {
                    conversation_id = "conv-wire",
                    step_index = 2,
                    state = "ACTIVE",
                    step_type = "tool_call",
                    tool_name = "run_command",
                    call_id = "call-1",
                    parameters = {CommandLine = "ls"},
                },
            })
            test.eq(#step3.observations, 1)
            test.eq(step3.observations[1].type, "tool.call")
            test.eq(step3.observations[1].data.tool_name, "run_command")

            local step4 = protocol.normalize(state, 4, {
                event = "step_update",
                step_update = {
                    conversation_id = "conv-wire",
                    step_index = 2,
                    state = "DONE",
                    step_type = "tool_call",
                    tool_name = "run_command",
                    call_id = "call-1",
                    output = "file.txt\n",
                },
            })
            test.eq(#step4.observations, 1)
            test.eq(step4.observations[1].type, "tool.result")
            test.eq(step4.observations[1].data.outcome, "succeeded")

            -- permission denials
            local step5 = protocol.normalize(state, 5, {
                event = "step_update",
                step_update = {
                    conversation_id = "conv-wire",
                    step_index = 3,
                    state = "DONE",
                    permission_denials = "denied by policy",
                },
            })
            test.eq(#step5.observations, 1)
            test.eq(step5.observations[1].type, "notice")
            test.eq(step5.observations[1].data.code, "permission_denied")

            -- result with usage
            local step6 = protocol.normalize(state, 6, {
                event = "result",
                result = {
                    conversation_id = "conv-wire",
                    status = "SUCCESS",
                    response = "Done!\n",
                    usage = {
                        input_tokens = 1000,
                        output_tokens = 50,
                        cache_read_tokens = 200,
                    },
                },
            })
            test.not_nil(step6.terminal)
            test.eq(step6.terminal.outcome, "succeeded")
            test.eq(step6.terminal.answer, "Done!\n")
            test.eq(step6.terminal.usage.input_tokens, 1000)
            test.eq(step6.terminal.usage.output_tokens, 50)
            test.eq(step6.terminal.usage.cached_tokens, 200)
        end)

        test.it("handles cancellation, terminal failure, and unexpected EOF", function()
            local fail_state = protocol.new(false)
            protocol.normalize(fail_state, 1, {event = "init", conversation_id = "c-fail", init = {}})
            local fail_step = protocol.normalize(fail_state, 2, {
                event = "result",
                result = {
                    conversation_id = "c-fail",
                    status = "ERROR",
                    error = "rate limit exceeded",
                },
            })
            test.not_nil(fail_step.terminal)
            test.eq(fail_step.terminal.outcome, "failed")
            test.eq(fail_step.terminal.error.code, "error")

            local cancel_state = protocol.new(false)
            protocol.normalize(cancel_state, 1, {event = "init", conversation_id = "c-cancel", init = {}})
            local cancel_step = protocol.normalize(cancel_state, 2, {
                event = "result",
                result = {
                    conversation_id = "c-cancel",
                    status = "CANCELLED",
                },
            })
            test.not_nil(cancel_step.terminal)
            test.eq(cancel_step.terminal.outcome, "cancelled")

            local trunc_state = protocol.new(false)
            protocol.normalize(trunc_state, 1, {event = "init", conversation_id = "c-trunc", init = {}})
            local trunc_step = protocol.finish(trunc_state, 2)
            test.not_nil(trunc_step.terminal)
            test.eq(trunc_step.terminal.outcome, "uncertain")
            test.eq(trunc_step.terminal.error.code, "stream_ended")
        end)

        test.it("feeds real captured live wire frames through stream_json transport and normalizer", function()
            local frames = {
                '{"event":"init","conversation_id":"f30fe2e7-e321-4839-8e4c-bbda9d2f9c4b","init":{"cwd":"/workspace","permission_mode":"always-proceed"}}\n',
                '{"event":"step_update","step_update":{"conversation_id":"f30fe2e7-e321-4839-8e4c-bbda9d2f9c4b","step_index":0,"state":"DONE","step_type":"user_input"}}\n',
                '{"event":"step_update","step_update":{"conversation_id":"f30fe2e7-e321-4839-8e4c-bbda9d2f9c4b","step_index":1,"state":"DONE","step_type":"agent_response","text_delta":"Hi! How can I help you today?\\n","duration_seconds":0.017,"usage":{"input_tokens":14290,"output_tokens":26,"thinking_tokens":17,"cache_read_tokens":0,"total_tokens":14316}}}\n',
                '{"event":"result","result":{"conversation_id":"f30fe2e7-e321-4839-8e4c-bbda9d2f9c4b","status":"SUCCESS","response":"Hi! How can I help you today?\\n","duration_seconds":1.08,"num_turns":1,"usage":{"input_tokens":14290,"output_tokens":26,"thinking_tokens":17,"cache_read_tokens":0,"total_tokens":14316}}}\n',
            }

            local decoder = stream_json.new()
            local state = protocol.new(false)
            local observations_count = 0

            for _, frame in ipairs(frames) do
                local envelopes, problems = stream_json.feed(decoder, frame)
                test.eq(#problems, 0)
                for _, env in ipairs(envelopes) do
                    local step = protocol.normalize(state, env.index, env.value)
                    for _, obs in ipairs(step.observations) do
                        local decoded, dec_err = observation.decode(obs)
                        if not decoded then error("live observation decode failed: " .. tostring(dec_err)) end
                        observations_count = observations_count + 1
                    end
                end
            end

            test.is_true(observations_count >= 3)
            test.not_nil(state.terminal)
            test.eq(state.terminal.outcome, "succeeded")
            test.eq(state.terminal.answer, "Hi! How can I help you today?\n")
            test.eq(state.terminal.usage.input_tokens, 14290)
            test.eq(state.terminal.usage.output_tokens, 26)
        end)
    end)

    test.describe("Antigravity CLI configuration and verified MCP delivery", function()
        test.it("refuses provider configurations and hooks without a host command", function()
            local reply1, err1 = funcs.call("bee.driver.agy.binding:configure", {
                provider_ref = "bee:provider_custom",
                provider = {model = "custom"},
                fixture = false,
            })
            if err1 then error(tostring(err1)) end
            test.is_false(reply1.ok)
            test.eq(reply1.error, "agy accepts no provider configuration")

            local reply2, err2 = funcs.call("bee.driver.agy.binding:configure", {
                gateway = {
                    endpoint = "127.0.0.1:18790",
                    action_id = "act-1",
                    tools = {"run_command"},
                    hooks = {"PreToolUse"},
                    token_environment = "GATEWAY_TOKEN",
                    hook_token_environment = "HOOK_TOKEN",
                },
                fixture = false,
            })
            if err2 then error(tostring(err2)) end
            test.is_false(reply2.ok)
            test.eq(reply2.error, "agy hooks require the host-selected hook command")
        end)

        test.it("renders gateway MCP with an admitted private credential field", function()
            test.eq(configuration.AGY_AUTHENTICATION, "unproven")
            test.eq(configuration.AGY_HOOKS, "unproven")
            test.eq(configuration.AGY_MCP, "unproven")

            local reply_mcp, err_mcp = funcs.call("bee.driver.agy.binding:configure", {
                gateway = {
                    endpoint = "127.0.0.1:18790",
                    action_id = "act-test",
                    tools = {"tool_a", "tool_b"},
                    hooks = {},
                    token_environment = "GATEWAY_TOKEN",
                },
                home_directory = "/private/agy-session",
                fixture = false,
            })
            if err_mcp then error(tostring(err_mcp)) end
            test.is_true(reply_mcp.ok)
            test.eq(#reply_mcp.delivery.files, 1)

            local file = reply_mcp.delivery.files[1]
            -- verified declared MCP file path
            test.eq(file.path, ".agents/mcp_config.json")
            test.eq(file.revision, "bee.agy-mcp@2")
            test.eq(file.provider_ref, "bee:gateway_endpoint")
            test.eq(reply_mcp.delivery.arguments[1], "--add-dir")
            test.eq(reply_mcp.delivery.arguments[2], "/private/agy-session")

            local content = tostring(file.content)
            local expected_hash, hash_err = hash.sha256(content)
            if hash_err then error(tostring(hash_err)) end
            test.eq(file.digest, expected_hash)
            test.is_true(content:find("http://127.0.0.1:18790/mcp/act-test", 1, true) ~= nil)
            -- Agy sends literal headers. Placement fills the empty template
            -- field from the admitted gateway credential immediately before exec.
            test.is_nil(content:find("${GATEWAY_TOKEN}", 1, true))
            test.eq(file.secret_fields[1].environment, "GATEWAY_TOKEN")
            test.eq(file.secret_fields[1].prefix, "Bearer ")

            local validated, val_err = configure_protocol.decode_reply(reply_mcp, nil, {
                endpoint = "127.0.0.1:18790",
                action_id = "act-test",
                tools = {"tool_a", "tool_b"},
                hooks = {},
                token_environment = "GATEWAY_TOKEN",
            })
            if val_err then error("decode_reply failed: " .. tostring(val_err)) end
            test.not_nil(validated)
            test.eq(#validated.files, 1)
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
