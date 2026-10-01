-- MIT. Window plans cannot acquire a headless carrier or its durable effects.
local test = require("test")
local machine = require("machine")
local driver_types = require("driver_types")
local policy = require("policy")
local placement_types = require("placement_types")
local classify = require("classify")
local checkpoint = require("checkpoint")
local stream_json = require("stream_json")
local bounds = require("bounds")
local placement_decode = require("placement_decode")
local function claim_reply(epoch: integer): {[string]: unknown}
    return {ok = true, value = {attempt_id = "attempt", action_id = "action", carrier_epoch = epoch,
        checkpoint_revision = 0, attempt_state = "prepared"}}
end
local function commit_reply(request_value: unknown, revision: integer): {[string]: unknown}
    local request = request_value :: {[string]: unknown}
    return {ok = true, value = {attempt_id = request.attempt_id, carrier_epoch = request.carrier_epoch,
        checkpoint_revision = revision, records = {}}}
end
local function placement_attempt(notice: unknown?): {[string]: unknown}
    return {attempt_id = "attempt", action_id = "action", owner_id = "actor", owner_incarnation = 1, request_digest = string.rep("a", 64),
        execution_state = "intended", cleanup_state = "pending", capability = "direct_process", required_cleanup = "direct_process",
        exit_observation = "eof_gated", attachment_generation = 0, evidence_count = 0,
        created_at = "2025-01-01T00:00:00.000Z", updated_at = "2025-01-01T00:00:00.000Z", notice = notice}
end
local function prepare_reply(notice: unknown?): {[string]: unknown}
    return {ok = true, value = placement_attempt(notice)}
end
local function thread_record(kind: string, sequence: integer, record_id: string, action_id: string,
    body: {[string]: unknown}, attempt_id: string?): {[string]: unknown}
    local record: {[string]: unknown} = {schema_revision = "bee.thread-record@1", record_id = record_id, thread_id = "thread",
        sequence = sequence, recorded_at = "2025-01-01T00:00:00.000Z", producer_id = "test", source = "bee",
        action_id = action_id, kind = kind, body = body}
    if attempt_id then record.attempt_id = attempt_id end
    return record
end
local function plan(mode: string, protocol: string): machine.Plan
    local launch: driver_types.Launch = {executable = "codex", argv = {}, environment = {}, readiness = "terminal:attached"}
    local policy_value: policy.Policy = {ref = "policy", digest = "policy-digest", permission_answers = "provider", prepare_options = {}, required_cleanup = "direct_process", required_exit_observation = "eof_gated",
            start_ms = 1000, stop_grace_ms = 100, drain_ms = 100, runner_drain_ms = 100, retain_ms = 100,
            executables = {}, environment = {}, host_environment = {}, allow_host_home = false, gateway_tools = {}, agent_model_map = {}, agent_delegates = {}, gateway_ttl_ms = 1000, gateway_hooks = {}, fixture = true, allowed_overrides = {}}
    local placement_request_value: placement_types.LaunchRequest = {idempotency_key = "key", owner_id = "actor", owner_incarnation = 1, action_id = "action", attempt_id = "attempt",
            binding_ref = "binding", policy_ref = "policy", profile_id = "window", binding_digest = "binding-digest", profile_digest = "profile-digest",
            placement_binding_ref = "bee.placement.native.binding:binding", placement_binding_digest = string.rep("a", 64),
            launch = launch, resources = {}, environment = {}, environment_refs = {}, projections = {}, required_cleanup = "direct_process",
            required_exit_observation = "eof_gated", timeouts = {start_ms = 1000, stop_grace_ms = 100, drain_ms = 100, retain_ms = 100}}
    local profile_value: classify.Profile = {id = "window", mode = mode, protocol = protocol, protocol_revision = "1", supported = true, private_home = true,
            permission = {mode = "none", eligible = false}}
    local request_value: machine.Request = {thread_id = "thread", action_id = "action", attempt_id = "attempt", owner_id = "actor", owner_incarnation = 1,
            binding_ref = "binding", profile_id = "window", brief = "", policy_ref = "policy", resources = {}, environment = {}}
    return {
        request = request_value,
        binding = {binding_id = "binding", driver_id = "codex", title = "Codex", implementation_version = "1", profiles_ref = "profiles",
            binding_digest = {entry = "binding-digest", scope = "entry"}, profile_digest = {entry = "profile-digest", scope = "entry"},
            default_profile = "window", profiles = {}, methods = {}, state = "compatible", activated = true, diagnostics = {}},
        profile = profile_value,
        launch = launch,
        policy = policy_value,
        placement_binding = {binding_id = "bee.placement.native.binding:binding", binding_digest = string.rep("a", 64), placement_kind = "native", methods = {
            prepare = "bee.placement.native.binding:prepare", start = "bee.placement.native.binding:start", status = "bee.placement.native.binding:status",
            stop = "bee.placement.native.binding:stop", reconcile = "bee.placement.native.binding:reconcile", cleanup = "bee.placement.native.binding:cleanup",
            evidence = "bee.placement.native.binding:evidence", attach = "bee.placement.native.binding:attach",
            capabilities = "bee.placement.native.binding:capabilities", measure_executable = "bee.placement.native.binding:measure_executable",
            close_stdin = "bee.placement.native.binding:close_stdin"}},
        plan_digest = "plan-digest",
        placement_request = placement_request_value,
        exit_codes_trustworthy = false, prepare_target = "prepare", normalize_target = "normalize",
    }
end
local function define_tests()
    test.describe("Carrier transport ownership", function()
        test.it("validates stdin closure against the selected attempt and explicit refusal", function()
            local value, err = placement_decode.stdin_closure({attempt = placement_attempt(nil), closed = true}, "attempt")
            test.is_nil(err)
            test.is_true(value and value.closed == true)
            local wrong, wrong_error = placement_decode.stdin_closure({attempt = placement_attempt(nil), closed = true}, "other")
            test.is_nil(wrong)
            test.eq(wrong_error, "close_stdin returned another attempt")
            local invalid = placement_decode.stdin_closure({attempt = placement_attempt(nil), closed = false}, "attempt")
            test.is_nil(invalid)
            local refused = placement_decode.stdin_closure({attempt = placement_attempt(nil), closed = false, reason = "runner unavailable"}, "attempt")
            test.eq(refused and refused.reason, "runner unavailable")
        end)
        test.it("refuses an unserializable normalizer state before commit or output acknowledgment", function()
            local selected = plan("session", "stream-json")
            local point = checkpoint.new({binding_ref = "binding", binding_digest = "binding-digest", profile_id = "window", profile_digest = "profile-digest"}, 1)
            local session: machine.Session = {plan = selected, turn_id = "turn:attempt:1", turn_open = true, epoch = 1, revision = 0,
                checkpoint = point, decoder = stream_json.new(machine.MAX_FRAME_BYTES), normalizer = nil, terminal = nil,
                stream_ended = false, exit = nil, eof = {stdout = false, stderr = false}, runner = "runner", settled = nil, recovered = false,
                output = "open", pending_hint = nil, placement_evidence = 0, stderr_sequence = 0, last_sequence = {stdout = 0, stderr = 0},
                held_from = nil, dropping_stdout = false}
            local calls: {string} = {}
            local topics: {string} = {}
            local io: machine.IO = {call = function(target: string, _: unknown): (unknown, string?)
                    calls[#calls + 1] = target
                    if target == "normalize" then
                        return {ok = true, state = {invalid = function() end}, observations = {}}, nil
                    end
                    return nil, "unexpected call " .. target
                end,
                send = function(_: string, topic: string, _: unknown) topics[#topics + 1] = topic end,
                self_pid = function(): string return "carrier" end,
                now_ms = function(): integer return 1 end,
                key = function(): string return "key" end}
            local accepted, refusal = machine.on_output(io, session, "runner", {attempt_id = "attempt", generation = 1, stream = "stdout",
                sequence = 1, data = "{}\n", eof = false})
            test.is_false(accepted)
            test.is_true(tostring(refusal):find("normalizer state", 1, true) ~= nil)
            test.eq(#calls, 1)
            test.eq(calls[1], "normalize")
            test.eq(#topics, 0)
            test.eq(session.revision, 0)
            test.eq(session.checkpoint.consumed.stdout, 0)
            test.eq(session.last_sequence.stdout, 0)
        end)
        test.it("refuses a required host file in a private home but allows it in the inherited home", function()
            local launch: driver_types.Launch = {executable = "codex", argv = {}, environment = {}, readiness = "terminal:attached",
                required_files = {{variable = "CODEX_HOME", path = "ds-flash.config.toml", default_directory = ".codex"}}}
            local refusal = machine.required_file_refusal(launch, true)
            test.not_nil(refusal)
            test.is_true(refusal:find("ds-flash", 1, true) ~= nil)
            test.is_true(refusal:find("only available where Bee inherits the user's home", 1, true) ~= nil)
            test.is_nil(machine.required_file_refusal(launch, false))
            local plain: driver_types.Launch = {executable = "codex", argv = {}, environment = {}, readiness = "terminal:attached"}
            test.is_nil(machine.required_file_refusal(plain, true))
        end)

        test.it("refuses malformed driver replies before executable measurement or admission", function()
            local request = plan("window", "pty").request
            request.binding_ref = "bee.driver.claude:binding"
            request.profile_id = "batch"
            request.policy_ref = "bee.harness.catalog:fixture_policy"
            request.brief = "test"
            local replies: {unknown} = {
                {ok = true, launch = {executable = 42, argv = {}, readiness = "ready"}},
                {ok = true, launch = {executable = "claude", argv = {false}, readiness = "ready"}},
                {ok = "yes", launch = {executable = "claude", argv = {}, readiness = "ready"}},
                {ok = true, launch = {executable = "claude", argv = {}, readiness = "ready"}, extra = true},
            }
            for _, response in ipairs(replies) do
                local calls = 0
                local io: machine.IO = {
                    call = function(target: string, value: unknown): (unknown, string?)
                        calls = calls + 1
                        test.eq(target, "bee.driver.claude.binding:prepare")
                        return response, nil
                    end,
                    send = function(target: string, topic: string, value: unknown) error("unexpected send") end,
                    self_pid = function(): string return "test" end,
                    now_ms = function(): integer return 0 end,
                    key = function(): string return "key" end,
                }
                local prepared, err = machine.plan(io, request)
                test.is_nil(prepared)
                test.eq(calls, 1)
                test.is_true(err ~= nil and err:find("driver prepare:", 1, true) ~= nil)
            end
        end)
        test.it("prepares a window attempt without requesting a turn or starting a transport", function()
            local calls: {string} = {}
            local io: machine.IO = {
                call = function(target: string, value: unknown): (unknown, string?)
                    calls[#calls + 1] = target
                    if target == "bee.threads.service:admit_action" then
                        if type(value) ~= "table" then error("missing action request") end
                        local admitted = value.admitted
                        if type(admitted) ~= "table" then error("missing admitted action") end
                        local input = admitted.input
                        if type(input) ~= "table" then error("missing action content") end
                        test.eq(input.text, "Open Codex window")
                    end
                    if target == "bee.threads.carrier:claim" then return claim_reply(7), nil end
                    if target == "bee.placement.native.binding:prepare" then
                        return prepare_reply({code = "LOGIN_REQUIRED", provider = "codex", command = "codex login"}), nil
                    end
                    return {ok = true, value = {}}, nil
                end,
                send = function(target: string, topic: string, value: unknown) error("unexpected transport send") end,
                self_pid = function(): string return "test" end,
                now_ms = function(): integer return 0 end,
                key = function(): string return "key" end,
            }
            local prepared, err = machine.prepare_attempt(io, plan("window", "pty"))
            if not prepared then error(tostring(err)) end
            test.eq(prepared.epoch, 7)
            test.is_nil(prepared.gateway_binding)
            test.eq(prepared.notice and prepared.notice.code, "LOGIN_REQUIRED")
            test.eq(prepared.notice and prepared.notice.command, "codex login")
            test.eq(table.concat(calls, ","), "bee.threads.service:admit_action,bee.threads.service:prepare_attempt,bee.threads.carrier:claim,bee.placement.native.binding:prepare")
        end)
        test.it("rejects a malformed placement login notice", function()
            local io: machine.IO = {
                call = function(target: string, value: unknown): (unknown, string?)
                    if target == "bee.threads.carrier:claim" then return claim_reply(7), nil end
                    if target == "bee.placement.native.binding:prepare" then
                        return prepare_reply({code = "LOGIN_REQUIRED", provider = "codex", command = "codex login\nextra"}), nil
                    end
                    return {ok = true, value = {}}, nil
                end,
                send = function(target: string, topic: string, value: unknown) error("unexpected transport send") end,
                self_pid = function(): string return "test" end,
                now_ms = function(): integer return 0 end,
                key = function(): string return "key" end,
            }
            local prepared, err = machine.prepare_attempt(io, plan("window", "pty"))
            test.is_nil(prepared)
            test.eq(err, "placement prepare returned an invalid attempt: attempt notice is malformed")
        end)
        test.it("dispatches preparation through the selected placement binding", function()
            local selected: machine.Plan = plan("window", "pty")
            selected.placement_binding = {binding_id = "example.placement:binding", binding_digest = string.rep("b", 64), placement_kind = "native", methods = {
                prepare = "example.placement:prepare", start = "example.placement:start", status = "example.placement:status",
                stop = "example.placement:stop", reconcile = "example.placement:reconcile", cleanup = "example.placement:cleanup",
                evidence = "example.placement:evidence", attach = "example.placement:attach",
                capabilities = "example.placement:capabilities", measure_executable = "example.placement:measure_executable",
                close_stdin = "example.placement:close_stdin"}}
            selected.placement_request.placement_binding_ref = "example.placement:binding"
            selected.placement_request.placement_binding_digest = string.rep("b", 64)
            local calls: {string} = {}
            local io: machine.IO = {
                call = function(target: string, value: unknown): (unknown, string?)
                    calls[#calls + 1] = target
                    if target == "example.placement:prepare" then test.eq(value, selected.placement_request) end
                    if target == "bee.threads.carrier:claim" then return claim_reply(7), nil end
                    if target == "example.placement:prepare" then return prepare_reply(nil), nil end
                    return {ok = true, value = {}}, nil
                end,
                send = function(target: string, topic: string, value: unknown) error("unexpected send") end,
                self_pid = function(): string return "test" end,
                now_ms = function(): integer return 0 end,
                key = function(): string return "key" end,
            }
            local prepared, err = machine.prepare_attempt(io, selected)
            if not prepared then error(tostring(err)) end
            test.eq(calls[#calls], "example.placement:prepare")
            test.is_nil(table.concat(calls, ","):find("bee.placement.native.binding:prepare", 1, true))
        end)
        test.it("attaches a fresh sequential attempt to its own admitted action and chains the settled attempt", function()
            local selected = plan("session", "stream-json")
            selected.binding.driver_id = "codex"
            local prepared_body: {[string]: unknown}? = nil
            local io: machine.IO = {
                call = function(target: string, value: unknown): (unknown, string?)
                    if target == "bee.threads.service:admit_action" then return {ok = false, error = {code = "CONFLICT", message = "action already exists"}}, nil end
                    if target == "bee.threads.service:read_after" then
                        return {ok = true, value = {records = {
                            thread_record("action.admitted", 2, "admitted-record", "action", {request_id = "request", principal_id = "actor",
                                binding_ref = "binding", binding_digest = string.rep("a", 64), grant_refs = {}, budget_ref = "budget", input = {text = "request"}}),
                            thread_record("receipt", 9, "receipt-record", "action", {scope = "attempt", outcome = "succeeded", evidence_refs = {}}, "attempt-1"),
                        }, has_more = false, scanned_through = 9}}, nil
                    end
                    if target == "bee.threads.service:prepare_attempt" then
                        prepared_body = value :: {[string]: unknown}
                        return {ok = true, value = {}}, nil
                    end
                    if target == "bee.threads.carrier:claim" then return claim_reply(2), nil end
                    if target == "bee.placement.native.binding:prepare" then return prepare_reply(nil), nil end
                    return {ok = true, value = {}}, nil
                end,
                send = function(target: string, topic: string, value: unknown) error("unexpected send") end,
                self_pid = function(): string return "test" end,
                now_ms = function(): integer return 0 end,
                key = function(): string return "key" end,
            }
            local prepared, err = machine.prepare_attempt(io, selected)
            if not prepared then error(tostring(err)) end
            test.eq(prepared_body and prepared_body.expected_previous_attempt_id, "attempt-1")
            local foreign: machine.IO = {
                call = function(target: string, value: unknown): (unknown, string?)
                    if target == "bee.threads.service:admit_action" then return {ok = false, error = {code = "CONFLICT", message = "action already exists"}}, nil end
                    if target == "bee.threads.service:read_after" then
                        return {ok = true, value = {records = {
                            thread_record("action.admitted", 2, "foreign-admitted-record", "action", {request_id = "request", principal_id = "someone-else",
                                binding_ref = "binding", binding_digest = string.rep("a", 64), grant_refs = {}, budget_ref = "budget", input = {text = "request"}}),
                        }, has_more = false, scanned_through = 2}}, nil
                    end
                    return {ok = true, value = {}}, nil
                end,
                send = function(target: string, topic: string, value: unknown) error("unexpected send") end,
                self_pid = function(): string return "test" end,
                now_ms = function(): integer return 0 end,
                key = function(): string return "key" end,
            }
            local refused, refuse_error = machine.prepare_attempt(foreign, selected)
            test.is_nil(refused)
            test.eq(refuse_error, "bee.threads.service:admit_action: CONFLICT: action already exists")
        end)
        test.it("refuses window and nonstructured profiles before opening or claiming an attempt", function()
            local calls = 0
            local io: machine.IO = {
                call = function(target: string, value: unknown): (unknown, string?) calls = calls + 1; return nil, "unexpected call" end,
                send = function(target: string, topic: string, value: unknown) calls = calls + 1 end,
                self_pid = function(): string return "test" end,
                now_ms = function(): integer return 0 end,
                key = function(): string return "key" end,
            }
            for _, candidate in ipairs({plan("window", "pty"), plan("window", "stream-json"), plan("session", "pty")}) do
                local opened, open_error = machine.open(io, candidate)
                test.is_nil(opened)
                test.eq(open_error, "structured carrier requires a stream-json session or batch profile")
                local resumed, resume_error = machine.resume(io, candidate)
                test.is_nil(resumed)
                test.eq(resume_error, open_error)
            end
            test.eq(calls, 0)
        end)
    end)
end
return test.run_cases(define_tests)
