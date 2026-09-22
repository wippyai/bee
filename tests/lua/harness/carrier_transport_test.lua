-- MIT. Window plans cannot acquire a headless carrier or its durable effects.
local test = require("test")
local machine = require("machine")
local driver_types = require("driver_types")
local policy = require("policy")
local placement_types = require("placement_types")
local classify = require("classify")
local function plan(mode: string, protocol: string): machine.Plan
    local launch: driver_types.Launch = {executable = "codex", argv = {}, environment = {}, readiness = "terminal:attached"}
    local policy_value: policy.Policy = {ref = "policy", digest = "policy-digest", prepare_options = {}, required_cleanup = "direct_process", required_exit_observation = "eof_gated",
            start_ms = 1000, stop_grace_ms = 100, drain_ms = 100, runner_drain_ms = 100, retain_ms = 100,
            executables = {}, environment = {}, host_environment = {}, allow_host_home = false, gateway_tools = {}, agent_launch = {}, gateway_ttl_ms = 1000, gateway_hooks = {}, fixture = true}
    local placement_request_value: placement_types.LaunchRequest = {idempotency_key = "key", owner_id = "actor", owner_incarnation = 1, action_id = "action", attempt_id = "attempt",
            binding_ref = "binding", policy_ref = "policy", profile_id = "window", binding_digest = "binding-digest", profile_digest = "profile-digest",
            placement_binding_ref = "bee.placement.native:binding", placement_binding_digest = string.rep("a", 64),
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
        placement_binding = {binding_id = "bee.placement.native:binding", binding_digest = string.rep("a", 64), placement_kind = "native", methods = {
            prepare = "bee.placement.native:prepare", start = "bee.placement.native:start", status = "bee.placement.native:status",
            stop = "bee.placement.native:stop", reconcile = "bee.placement.native:reconcile", cleanup = "bee.placement.native:cleanup",
            evidence = "bee.placement.native:evidence", attach = "bee.placement.native:attach",
            capabilities = "bee.placement.native:capabilities", measure_executable = "bee.placement.native:measure_executable",
            close_stdin = "bee.placement.native:close_stdin"}},
        plan_digest = "plan-digest",
        placement_request = placement_request_value,
        exit_codes_trustworthy = false, prepare_target = "prepare", normalize_target = "normalize",
    }
end
local function define_tests()
    test.describe("Carrier transport ownership", function()
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
                        test.eq(target, "bee.driver.claude:prepare")
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
                    if target == "bee.threads.carrier:claim" then return {ok = true, value = {carrier_epoch = 7}}, nil end
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
            test.eq(table.concat(calls, ","), "bee.threads.service:admit_action,bee.threads.service:prepare_attempt,bee.threads.carrier:claim,bee.placement.native:prepare")
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
                    if target == "bee.threads.carrier:claim" then return {ok = true, value = {carrier_epoch = 7}}, nil end
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
            test.is_nil(table.concat(calls, ","):find("bee.placement.native:prepare", 1, true))
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
