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
            executables = {}, environment = {}, gateway_tools = {}, gateway_ttl_ms = 1000, gateway_hooks = {}, fixture = true}
    local placement_request_value: placement_types.LaunchRequest = {idempotency_key = "key", owner_id = "actor", owner_incarnation = 1, action_id = "action", attempt_id = "attempt",
            binding_ref = "binding", policy_ref = "policy", profile_id = "window", binding_digest = "binding-digest", profile_digest = "profile-digest",
            launch = launch, resources = {}, environment = {}, environment_refs = {}, projections = {}, required_cleanup = "direct_process",
            required_exit_observation = "eof_gated", timeouts = {start_ms = 1000, stop_grace_ms = 100, drain_ms = 100, retain_ms = 100}}
    local profile_value: classify.Profile = {id = "window", mode = mode, protocol = protocol, protocol_revision = "1", supported = true,
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
        plan_digest = "plan-digest",
        placement_request = placement_request_value,
        exit_codes_trustworthy = false, prepare_target = "prepare", normalize_target = "normalize",
    }
end
local function define_tests()
    test.describe("Carrier transport ownership", function()
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
