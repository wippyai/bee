-- MIT. Executor turn tests use ports to assert durable call ordering without
-- starting a provider CLI or depending on credentials.
local test = require("test")
local turn = require("turn")
local stream = require("stream")

local function base_request(): {[string]: unknown}
    return {
        attempt_id = "attempt-current", generation = 2, prompt = "continue the task",
        sender = {kind = "principal", id = "owner"}, driver_binding_ref = "bee.driver.fixture:binding", profile_id = "session",
        driver_methods = {prepare = "bee.driver.fixture.binding:prepare", dispatch = "bee.driver.fixture.binding:dispatch", normalize = "bee.driver.fixture.binding:normalize"},
        driver_options = {},
        placement_methods = {prepare = "bee.placement.native.binding:prepare", attach = "bee.placement.native.binding:attach",
            start = "bee.placement.native.binding:start", reconcile = "bee.placement.native.binding:reconcile", cleanup = "bee.placement.native.binding:cleanup"},
        placement_request = {attempt_id = "attempt-current", idempotency_key = "turn-current", owner_id = "owner", owner_incarnation = 1,
            action_id = "action", binding_ref = "bee.driver.fixture:binding", profile_id = "session", policy_ref = "host:policy"},
    }
end

local function success_io(calls: {string}?, expect_resume: boolean?, resume_identity: string?): turn.IO
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
        driver = function(method: string, target: string, arguments: unknown)
            seen[#seen + 1] = "driver:" .. method
            test.eq(target, "bee.driver.fixture.binding:" .. method)
            local args = arguments :: {[string]: unknown}
            test.eq(args.brief, "[Bee sender principal owner]\ncontinue the task")
            test.eq(args.resume_ref, expect_resume and selected_resume_ref or nil)
            return {ok = true, launch = {executable = "fixture-cli", argv = {"--prompt"}, environment = {}, readiness = "protocol:ready"}}, nil
        end,
        prepare = function(request: unknown)
            seen[#seen + 1] = "prepare"
            local args = request :: {[string]: unknown}
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
        start = function(id: string)
            seen[#seen + 1] = "start"
            test.eq(id, "attempt-current")
            return {attempt_id = id, execution_state = "running", cleanup_state = "pending"}, nil
        end,
        observe = function(_listener: unknown, _attempt: unknown, _normalizer: string, resumed: boolean, _checkpoint: unknown)
            seen[#seen + 1] = "observe"
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
        test.it("persists placement intent before one driver invocation and retains resume identity and usage", function()
            local calls: {string} = {}
            local result, err = turn.execute(success_io(calls), base_request())
            if not result then error(tostring(err)) end
            test.eq(result.state, "settled")
            test.eq(result.outcome, "succeeded")
            test.eq(result.answer, "done")
            test.eq((result.checkpoint :: {[string]: unknown}).resume_ref, "conversation-1")
            test.eq((result.usage :: {[string]: unknown}).input_tokens, 5)
            test.eq(table.concat(calls, ","), "driver:prepare,prepare,listen,attach,start,observe,close,reconcile:attempt-current")
        end)

        test.it("reconciles and cleans the previous placement before dispatching a resumed turn", function()
            local request = base_request()
            request.previous_attempt_id = "attempt-previous"
            request.checkpoint = {resume_ref = "conversation-1"}
            local calls: {string} = {}
            local io = success_io(calls, true)
            local original_driver = io.driver
            io.driver = function(method: string, target: string, arguments: unknown)
                local args = arguments :: {[string]: unknown}
                test.eq(args.resume_ref, "conversation-1")
                original_driver(method, target, arguments)
                return {ok = true, launch = {executable = "fixture-cli", argv = {"--resume", "conversation-1"}, environment = {}, readiness = "protocol:ready"}}, nil
            end
            local result, err = turn.execute(io, request)
            if not result then error(tostring(err)) end
            test.eq(result.state, "settled")
            test.eq(calls[1], "reconcile:attempt-previous")
            test.eq(calls[2], "cleanup:attempt-previous")
            test.eq(calls[3], "driver:dispatch")
        end)

        test.it("does not invoke a driver when the previous placement exit is uncertain", function()
            local io = success_io()
            io.reconcile = function(id: string)
                return {attempt = {attempt_id = id, execution_state = "uncertain", cleanup_state = "uncertain"}}, nil
            end
            local request = base_request()
            request.previous_attempt_id = "attempt-previous"
            local result, err = turn.execute(io, request)
            if not result then error(tostring(err)) end
            test.eq(result.state, "uncertain")
        end)

        test.it("keeps a known-live previous attempt pending without invoking a driver", function()
            local calls: {string} = {}
            local io = success_io(calls)
            io.reconcile = function(id: string)
                calls[#calls + 1] = "reconcile:" .. id
                return {attempt = {attempt_id = id, execution_state = "running", cleanup_state = "pending"}}, nil
            end
            local original = io.driver
            io.driver = function(method: string, target: string, arguments: unknown)
                calls[#calls + 1] = "unexpected-driver:" .. method
                return original(method, target, arguments)
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
            test.eq(table.concat(calls, ","), "driver:prepare,prepare,reconcile:attempt-current")
        end)

        test.it("keeps a proven live attempt pending when start loses its acknowledgement", function()
            local calls: {string} = {}
            local io = success_io(calls)
            io.start = function(id: string)
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
            test.eq(table.concat(calls, ","), "driver:prepare,prepare,listen,attach,start:attempt-current,close,reconcile:attempt-current")
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
            io.observe = function(_listener: unknown, _attempt: unknown, _normalizer: string, _resumed: boolean, _checkpoint: unknown)
                return nil, "stream ended without a result"
            end
            local result, err = turn.execute(io, base_request())
            if not result then error(tostring(err)) end
            test.eq(result.state, "uncertain")
            test.eq(result.outcome, "uncertain")
        end)

        test.it("keeps a successful turn uncertain when the driver supplied no resume identity", function()
            local io = success_io()
            io.observe = function(_listener: unknown, _attempt: unknown, _normalizer: string, _resumed: boolean, _checkpoint: unknown)
                return {terminal = {outcome = "succeeded", answer = "done"}}, nil
            end
            local result, err = turn.execute(io, base_request())
            if not result then error(tostring(err)) end
            test.eq(result.state, "uncertain")
            test.eq(result.outcome, "uncertain")
        end)

        test.it("passes an opaque resume identity through the selected driver", function()
            local request = base_request()
            request.checkpoint = {resume_ref = "conversation-1"}
            local calls: {string} = {}
            local result, err = turn.execute(success_io(calls, true), request)
            if not result then error(tostring(err)) end
            test.eq(result.outcome, "succeeded")
            test.eq((result.checkpoint :: {[string]: unknown}).resume_ref, "conversation-1")
            test.eq((result.usage :: {[string]: unknown}).output_tokens, 7)
            test.eq(calls[1], "driver:dispatch")
        end)

        test.it("rejects injected execution controls while treating resume identity as opaque", function()
            local injected = base_request()
            injected.driver_options = {control_enabled = true}
            local refused, injection_error = turn.execute(success_io(), injected)
            test.is_nil(refused)
            test.eq(injection_error, "turn execution does not accept injected controls or driver frames")

            local changed = base_request()
            changed.checkpoint = {resume_ref = "opaque-driver-owned-identity"}
            local resumed, continuity_error = turn.execute(success_io(nil, true, "opaque-driver-owned-identity"), changed)
            if not resumed then error(tostring(continuity_error)) end
            test.eq((resumed.checkpoint :: {[string]: unknown}).resume_ref, "opaque-driver-owned-identity")
        end)

        test.it("requires the placement request to use the selected driver binding and profile", function()
            local wrong_binding = base_request()
            local wrong_binding_placement = wrong_binding.placement_request :: {[string]: unknown}
            wrong_binding_placement.binding_ref = "bee.driver.other:binding"
            local binding_result, binding_error = turn.execute(success_io(), wrong_binding)
            test.is_nil(binding_result)
            test.eq(binding_error, "placement request binding_ref differs from the selected driver")

            local wrong_profile = base_request()
            local wrong_profile_placement = wrong_profile.placement_request :: {[string]: unknown}
            wrong_profile_placement.profile_id = "batch"
            local profile_result, profile_error = turn.execute(success_io(), wrong_profile)
            test.is_nil(profile_result)
            test.eq(profile_error, "placement request profile_id differs from the selected profile")
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
