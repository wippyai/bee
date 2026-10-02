-- MIT. Executor turn tests assert admission, placement, gateway and recovery
-- ordering without starting a provider CLI or depending on credentials.
local test = require("test")
local turn = require("turn")
local stream = require("stream")
local bounds = require("bounds")

local function base_request(): {[string]: unknown}
    return {
        attempt_id = "attempt-current", claim = "claim-current", observation_target = "bee.threads.binding:turn_observation",
        generation = 2, prompt = "continue the task",
        sender = {kind = "principal", id = "owner"}, driver_binding_ref = "bee.driver.fixture.binding:binding", profile_id = "session",
        driver_methods = {prepare = "bee.driver.fixture.binding:prepare", dispatch = "bee.driver.fixture.binding:dispatch", normalize = "bee.driver.fixture.binding:normalize"},
        placement_methods = {prepare = "bee.placement.native.binding:prepare", attach = "bee.placement.native.binding:attach",
            start = "bee.placement.native.binding:start", stop = "bee.placement.native.binding:stop",
            reconcile = "bee.placement.native.binding:reconcile", cleanup = "bee.placement.native.binding:cleanup"},
        admission = {attempt_id = "attempt-current", definition_ref = "host:definition", workspace_id = "workspace", owner_id = "owner",
            thread_id = "thread-current", session_ref = "bs:node:workspace:session", action_id = "bs:node:workspace:session",
            brief = "continue the task", expected_plan_digest = string.rep("a", 64), profile_id = "session"},
    }
end

local function plan_for(request: unknown, with_gateway: boolean?): {[string]: unknown}
    local value = assert(bounds.object(request))
    local admission = assert(bounds.object(value.admission))
    test.eq(value.prompt, "[Bee sender principal owner]\ncontinue the task")
    test.eq(admission.brief, "continue the task")
    local methods = assert(bounds.object(value.placement_methods))
    if type(methods.prepare) ~= "string" then error("placement prepare method must be text") end
    local placement_request: {[string]: unknown} = {
        attempt_id = "attempt-current", binding_ref = "bee.driver.fixture.binding:binding", profile_id = "session",
        placement_binding_ref = methods.prepare:gsub("prepare$", "binding"),
        launch = {executable = "fixture-cli", argv = {"--prompt"}, environment = {}, readiness = "protocol:ready"},
    }
    if with_gateway then placement_request.gateway = {tools = {"session_send"}, hooks = {"SessionStart"}} end
    return {placement_request = placement_request, normalize_target = "bee.driver.fixture.binding:normalize"}
end

local function success_io(calls: {string}?, expect_resume: boolean?, resume_identity: string?, with_gateway: boolean?): turn.IO
    local seen = calls or {}
    local selected_resume_ref = resume_identity or "conversation-1"
    return {
        reconcile = function(id: string)
            seen[#seen + 1] = "reconcile:" .. id
            return {attempt = {attempt_id = id, execution_state = "exited", exit_source = "runner", cleanup_state = "pending"}}, nil
        end,
        cleanup = function(id: string)
            seen[#seen + 1] = "cleanup:" .. id
            return {attempt_id = id, execution_state = "exited", exit_source = "runner", cleanup_state = "complete"}, nil
        end,
        plan = function(request: unknown)
            seen[#seen + 1] = "plan"
            local value = assert(bounds.object(request))
            local checkpoint = value.checkpoint and assert(bounds.object(value.checkpoint)) or nil
            test.eq(checkpoint and checkpoint.resume_ref, expect_resume and selected_resume_ref or nil)
            return plan_for(request, with_gateway), nil
        end,
        prepare = function(request: unknown)
            seen[#seen + 1] = "prepare"
            local args = assert(bounds.object(request))
            test.not_nil(args.launch)
            return {attempt_id = "attempt-current", execution_state = "intended", cleanup_state = "pending"}, nil
        end,
        listen = function()
            seen[#seen + 1] = "listen"
            return {listener = true}, nil
        end,
        attach = function(id: string, generation: integer)
            seen[#seen + 1] = "attach"
            test.eq(id, "attempt-current")
            test.eq(generation, 2)
            return {attempt_id = id, execution_state = "intended", cleanup_state = "pending"}, nil
        end,
        admit_gateway = function(generation: integer): (string?, string?)
            seen[#seen + 1] = "admit_gateway"
            test.eq(generation, 2)
            return with_gateway and "gateway-binding-1" or nil, nil
        end,
        gateway_ready = function(binding_id: string): string?
            seen[#seen + 1] = "gateway_ready"
            test.eq(binding_id, "gateway-binding-1")
            return nil
        end,
        revoke_gateway = function(binding_id: string)
            seen[#seen + 1] = "revoke_gateway"
            test.eq(binding_id, "gateway-binding-1")
        end,
        start = function(id: string, gateway_binding: string?)
            seen[#seen + 1] = "start"
            test.eq(id, "attempt-current")
            test.eq(gateway_binding, with_gateway and "gateway-binding-1" or nil)
            return {attempt_id = id, execution_state = "running", cleanup_state = "pending"}, nil
        end,
        observe = function(_listener: unknown, _attempt: unknown, normalizer: string, resumed: boolean, _checkpoint: unknown, _request: turn.Request)
            seen[#seen + 1] = "observe"
            test.eq(normalizer, "bee.driver.fixture.binding:normalize")
            test.eq(resumed, expect_resume == true)
            return {terminal = {outcome = "succeeded", answer = "done", resume_ref = selected_resume_ref, usage = {input_tokens = 5, output_tokens = 7}}}, nil
        end,
        close = function(_listener: unknown)
            seen[#seen + 1] = "close"
        end,
    }
end

local function define_tests()
    test.describe("External executor turn", function()
        test.it("refuses methods belonging to another driver binding before invoking the host", function()
            local request = base_request()
            local methods = assert(bounds.object(request.driver_methods))
            methods.prepare = "bee.driver.other.binding:prepare"
            local calls: {string} = {}
            local result, reason = turn.execute(success_io(calls), request)
            test.is_nil(result)
            test.eq(reason, "driver_methods.prepare is not an operation of the selected bee.driver binding")
            test.eq(#calls, 0)
        end)
        test.it("executes the admitted Docker placement through the shared turn lifecycle", function()
            local request = base_request()
            local methods = assert(bounds.object(request.placement_methods))
            for name in pairs(methods) do methods[name] = "bee.placement.docker.binding:" .. name end
            local calls: {string} = {}
            local result, reason = turn.execute(success_io(calls), request)
            test.is_nil(reason); test.eq(result and result.outcome, "succeeded")
            test.eq(table.concat(calls, ","), "plan,prepare,listen,attach,start,observe,close,reconcile:attempt-current")
        end)
        test.it("refuses mixed placement operations before invoking the host", function()
            local request = base_request()
            local methods = assert(bounds.object(request.placement_methods))
            methods.prepare = "bee.placement.docker.binding:prepare"
            local calls: {string} = {}
            local result, reason = turn.execute(success_io(calls), request)
            test.is_nil(result); test.not_nil(reason); test.eq(#calls, 0)
        end)
        test.it("settles an authenticated placement stop without requiring a provider terminal frame", function()
            local request = base_request()
            local io = success_io()
            io.observe = function(): (unknown, string) return {stopped = true, observations = {}}, "interrupted frame" end
            local result = assert(turn.execute(io, request))
            test.eq(result.state, "settled")
            test.eq(result.outcome, "cancelled")
            io.reconcile = function(): (unknown, nil) return {attempt_id = "attempt-current", execution_state = "running"}, nil end
            test.eq(assert(turn.execute(io, request)).state, "uncertain")
        end)
        test.it("returns budget_exceeded with typed placement exit evidence for each budget kind", function()
            for _, kind in ipairs({"provider_steps", "tokens", "wall_time_ms"}) do
                local request = base_request()
                request.budget = kind == "provider_steps" and {provider_steps = 1}
                    or kind == "tokens" and {tokens = 1} or {wall_time_ms = 1}
                local io = success_io()
                io.observe = function(): (unknown, nil)
                    return {stopped = true, budget_exceeded = kind,
                        evidence = {summary = "placement proved the CLI exited after the budget", artifacts = {"placement attempt attempt-current", "exit observed by runner"}}}, nil
                end
                local result = assert(turn.execute(io, request))
                test.eq(result.state, "settled")
                test.eq(result.outcome, "budget_exceeded")
                local evidence = bounds.object(result.evidence)
                test.eq(evidence and evidence.summary, "placement proved the CLI exited after the " .. kind .. " budget")
            end
        end)
        test.it("settles an exceeded budget when placement proves the process exited naturally", function()
            local request = base_request()
            request.budget = {tokens = 1}
            local io = success_io()
            io.observe = function(): (unknown, nil)
                return {stopped = false, budget_exceeded = "tokens",
                    evidence = {summary = "placement proved the CLI exited after tokens", artifacts = {"placement attempt attempt-current", "exit observed by runner"}}}, nil
            end
            local result = assert(turn.execute(io, request))
            test.eq(result.state, "settled")
            test.eq(result.outcome, "budget_exceeded")
            local evidence = bounds.object(result.evidence)
            test.eq(evidence and evidence.summary, "placement proved the CLI exited after the tokens budget")
        end)
        test.it("leaves a long fake turn unbounded by default", function()
            local request = base_request()
            local io = success_io()
            local normalized_turns = 0
            io.observe = function(_: unknown, _: unknown, _: string, _: boolean, _: unknown, observed_request: turn.Request): (unknown, nil)
                test.is_nil(observed_request.budget)
                for _ = 1, 300 do normalized_turns = normalized_turns + 1 end
                return {terminal = {outcome = "succeeded", resume_ref = "provider-session"},
                    observations = {}, stopped = false}, nil
            end
            local result = assert(turn.execute(io, request))
            test.eq(result.state, "settled")
            test.eq(result.outcome, "succeeded")
            test.eq(normalized_turns, 300)
        end)
        test.it("does not settle a budget outcome without placement exit evidence", function()
            local request = base_request()
            request.budget = {provider_steps = 1}
            local io = success_io()
            io.reconcile = function(id: string)
                return {attempt = {attempt_id = id, execution_state = "running", cleanup_state = "pending"}}, nil
            end
            io.observe = function(): (unknown, nil)
                return {stopped = false, budget_exceeded = "provider_steps",
                    evidence = {summary = "stop was not proven", artifacts = {}}}, nil
            end
            local result = assert(turn.execute(io, request))
            test.eq(result.state, "uncertain")
            test.eq(result.outcome, "uncertain")
        end)
        test.it("reconciles a recovered current attempt before any plan or invocation", function()
            local calls: {string} = {}
            local io = success_io(calls)
            local request = base_request()
            request.recovery = true
            local result = assert(turn.execute(io, request))
            test.eq(result.state, "uncertain")
            test.eq(#calls, 1)
            test.eq(calls[1], "reconcile:" .. request.attempt_id)
        end)
        test.it("persists a host planned placement intent and retains resume identity and usage", function()
            local calls: {string} = {}
            local result, err = turn.execute(success_io(calls), base_request())
            if not result then error(tostring(err)) end
            test.eq(result.state, "settled")
            test.eq(result.outcome, "succeeded")
            test.eq(result.answer, "done")
            test.eq((assert(bounds.object(result.checkpoint))).resume_ref, "conversation-1")
            test.eq((assert(bounds.object(result.usage))).input_tokens, 5)
            test.eq(table.concat(calls, ","), "plan,prepare,listen,attach,start,observe,close,reconcile:attempt-current")
        end)

        test.it("admits and checks the gateway after attaching before native start", function()
            local calls: {string} = {}
            local result, err = turn.execute(success_io(calls, nil, nil, true), base_request())
            if not result then error(tostring(err)) end
            test.eq(result.state, "settled")
            test.eq(table.concat(calls, ","), "plan,prepare,listen,attach,admit_gateway,gateway_ready,start,observe,close,reconcile:attempt-current")
        end)

        test.it("reconciles and cleans the previous placement before planning a resumed turn", function()
            local request = base_request()
            request.previous_attempt_id = "attempt-previous"
            request.checkpoint = {resume_ref = "conversation-1"}
            local calls: {string} = {}
            local result, err = turn.execute(success_io(calls, true), request)
            if not result then error(tostring(err)) end
            test.eq(result.state, "settled")
            test.eq(calls[1], "reconcile:attempt-previous")
            test.eq(calls[2], "cleanup:attempt-previous")
            test.eq(calls[3], "plan")
        end)

        test.it("does not plan a new invocation when the previous placement exit is uncertain", function()
            local calls: {string} = {}
            local io = success_io(calls)
            io.reconcile = function(id: string)
                return {attempt = {attempt_id = id, execution_state = "uncertain", cleanup_state = "uncertain"}}, nil
            end
            local request = base_request()
            request.previous_attempt_id = "attempt-previous"
            local result, err = turn.execute(io, request)
            if not result then error(tostring(err)) end
            test.eq(result.state, "uncertain")
            test.eq(#calls, 0)
        end)

        test.it("keeps a known-live previous attempt pending without planning a new turn", function()
            local calls: {string} = {}
            local io = success_io(calls)
            io.reconcile = function(id: string)
                calls[#calls + 1] = "reconcile:" .. id
                return {attempt = {attempt_id = id, execution_state = "running", cleanup_state = "pending"}}, nil
            end
            local request = base_request()
            request.previous_attempt_id = "attempt-previous"
            local result, err = turn.execute(io, request)
            if not result then error(tostring(err)) end
            test.eq(result.state, "pending")
            test.eq(result.outcome, "pending")
            test.eq(table.concat(calls, ","), "reconcile:attempt-previous")
        end)

        test.it("reconciles an existing live current attempt before it can be started again", function()
            local calls: {string} = {}
            local io = success_io(calls)
            io.prepare = function(_request: unknown)
                calls[#calls + 1] = "prepare"
                return {attempt_id = "attempt-current", execution_state = "running", cleanup_state = "pending"}, nil
            end
            io.reconcile = function(id: string)
                calls[#calls + 1] = "reconcile:" .. id
                return {attempt = {attempt_id = id, execution_state = "running", cleanup_state = "pending"}}, nil
            end
            local result, err = turn.execute(io, base_request())
            if not result then error(tostring(err)) end
            test.eq(result.state, "pending")
            test.eq(table.concat(calls, ","), "plan,prepare,reconcile:attempt-current")
        end)

        test.it("keeps a proven live attempt pending when start loses its acknowledgement", function()
            local calls: {string} = {}
            local io = success_io(calls)
            io.start = function(id: string, _gateway_binding: string?)
                calls[#calls + 1] = "start:" .. id
                return nil, "runner startup acknowledgment lost"
            end
            io.reconcile = function(id: string)
                calls[#calls + 1] = "reconcile:" .. id
                return {attempt = {attempt_id = id, execution_state = "running", cleanup_state = "pending"}}, nil
            end
            local result, err = turn.execute(io, base_request())
            if not result then error(tostring(err)) end
            test.eq(result.state, "pending")
            test.eq(table.concat(calls, ","), "plan,prepare,listen,attach,start:attempt-current,close,reconcile:attempt-current")
        end)

        test.it("decodes declared JSON-lines frames and rejects malformed output", function()
            local input = stream.new()
            local frames, feed_error = stream.feed(input, "{\"event\":\"ready\"}\n{\"event\":\"done\"}\n")
            test.is_nil(feed_error)
            test.eq(#frames, 2)
            test.eq(frames[1].index, 1)
            test.eq(frames[2].index, 2)
            local _, malformed_error = stream.feed(input, "unexpected output\n")
            test.not_nil(malformed_error)
        end)

        test.it("keeps an interrupted driver stream uncertain even after placement proves exit", function()
            local io = success_io()
            io.observe = function(_listener: unknown, _attempt: unknown, _normalizer: string, _resumed: boolean, _checkpoint: unknown, _request: turn.Request)
                return nil, "stream ended without a result"
            end
            local result, err = turn.execute(io, base_request())
            if not result then error(tostring(err)) end
            test.eq(result.state, "uncertain")
            test.eq(result.outcome, "uncertain")
        end)

        test.it("keeps a successful turn uncertain when the driver supplied no resume identity", function()
            local io = success_io()
            io.observe = function(_listener: unknown, _attempt: unknown, _normalizer: string, _resumed: boolean, _checkpoint: unknown, _request: turn.Request)
                return {terminal = {outcome = "succeeded", answer = "done"}}, nil
            end
            local result, err = turn.execute(io, base_request())
            if not result then error(tostring(err)) end
            test.eq(result.state, "uncertain")
            test.eq(result.outcome, "uncertain")
        end)

        test.it("passes an opaque resume identity through host planning", function()
            local request = base_request()
            request.checkpoint = {resume_ref = "opaque-driver-owned-identity"}
            local calls: {string} = {}
            local result, err = turn.execute(success_io(calls, true, "opaque-driver-owned-identity"), request)
            if not result then error(tostring(err)) end
            test.eq(result.outcome, "succeeded")
            test.eq((assert(bounds.object(result.checkpoint))).resume_ref, "opaque-driver-owned-identity")
            test.eq((assert(bounds.object(result.usage))).output_tokens, 7)
            test.eq(calls[1], "plan")
        end)

        test.it("rejects injected controls and a placement plan for another route", function()
            local injected = base_request()
            injected.driver_options = {control_enabled = true}
            local refused, injection_error = turn.execute(success_io(), injected)
            test.is_nil(refused)
            test.eq(injection_error, "turn request has unknown field driver_options")

            local io = success_io()
            io.plan = function(_request: unknown)
                return {placement_request = {attempt_id = "attempt-current", binding_ref = "bee.driver.other.binding:binding", profile_id = "session"},
                    normalize_target = "bee.driver.other.binding:normalize"}, nil
            end
            local changed = turn.execute(io, base_request())
            test.is_nil(changed)
        end)

        test.it("rejects admission for a different profile", function()
            local request = base_request()
            local admission = assert(bounds.object(request.admission))
            admission.profile_id = "batch"
            local result, err = turn.execute(success_io(), request)
            test.is_nil(result)
            test.eq(err, "session admission profile differs from the selected profile")
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
