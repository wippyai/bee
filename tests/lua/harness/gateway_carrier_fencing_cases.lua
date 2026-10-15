-- MIT. Focused gateway carrier test cases.
local test = require("test")
local bounds = require("bounds")
local process = require("process")
local channel = require("channel")
local support = require("support")
local POLICY = support.POLICY
local fresh = support.fresh
local call = support.call
local install_policy = support.install_policy
local admit_root = support.admit_root
local open_gateway = support.open_gateway
local thread = support.thread
local request = support.request
local spawn_carrier = support.spawn_carrier
local exited = support.exited
local record_exit = support.record_exit
local await_exit = support.await_exit
local continue_carrier = support.continue_carrier
local await_paused = support.await_paused
local report = support.report
local evidence_kinds = support.evidence_kinds
local detail_with = support.detail_with
local await_evidence = support.await_evidence
local expect_evidence = support.expect_evidence
local expect_detail = support.expect_detail
local binding_of = support.binding_of
local await_presented = support.await_presented
local function define_fencing_tests()
    test.describe("Gateway attachment fencing", function()
        install_policy(POLICY)
        admit_root()
        open_gateway()
        test.it("starts the attachment fence only after supervised startup finishes", function()
            local attempt_id = fresh("startup-fence")
            local launch = request(thread(), attempt_id, {BEE_TEST_STARTUP_CONTROLLER = process.pid()})
            local runner_held = assert(process.listen("bee.test.runner.held", {message = true}))
            local held = assert(process.listen("bee.test.attach.held", {message = true}))
            local paused = assert(process.listen("bee.carrier.paused", {message = true}))
            local old = spawn_carrier(launch, "open", nil, "placement_started")
            await_paused(paused, old, "placement_started", false)
            local blocked = assert((runner_held:receive()))
            local runner = tostring(blocked:from())
            assert(process.terminate(old))
            await_exit(old, "old startup carrier")
            local replacement = spawn_carrier(launch, "resume", nil, "reattached", process.pid())
            local observation = assert((held:receive()))
            local phase = assert(bounds.object(observation:payload():data())).phase
            assert(process.send(runner, "bee.test.runner.release", {}))
            if phase ~= "startup" then
                assert(process.send(tostring(observation:from()), "bee.test.attach.timeout", {}))
                await_exit(replacement, "premature fence")
                error("fence timer armed before startup finished: " .. tostring(phase))
            end
            await_paused(paused, replacement, "reattached", false)
            continue_carrier(replacement)
            local outcome = await_exit(replacement, "startup attachment")
            assert(outcome.value, tostring(outcome.error))
            test.eq(assert(bounds.object(outcome.value.settlement)).outcome, "succeeded")
            local names, details = evidence_kinds(attempt_id)
            expect_evidence(names, details, "attach.unfenced", false)
            expect_detail(details, "runner installed generation 2", true)
            process.unlisten(runner_held)
            process.unlisten(held)
            process.unlisten(paused)
        end)
        for _, scenario in ipairs({{phase = "before", timeout = true}, {phase = "after", timeout = false}, {phase = "after", timeout = true}}) do
            test.it("commits the fence before acknowledgement: " .. scenario.phase .. (scenario.timeout and " deadline" or " reply"), function()
                local attempt_id = fresh("fence")
                local launch = request(thread(), attempt_id, {BEE_FIXTURE_GATEWAY_HOLD = "stop",
                    BEE_TEST_FENCE_CONTROLLER = process.pid(), BEE_TEST_FENCE_PHASE = scenario.phase})
                local paused = assert(process.listen("bee.carrier.paused", {message = true}))
                local held = assert(process.listen("bee.test.attach.held", {message = true}))
                local old = spawn_carrier(launch, "open", nil, "attempt_started")
                await_paused(paused, old, "attempt_started", false)
                await_presented(attempt_id, 1, 3)
                assert(process.terminate(old))
                await_exit(old, "old carrier")
                await_evidence(attempt_id, "carrier.lost")
                local live = binding_of(attempt_id, 1)
                call("bee.gateway.binding:revoke", {binding_id = live.binding_id})
                local replacement = spawn_carrier(launch, "resume", nil, "reattached", process.pid())
                local runner: string? = nil
                local service: string? = nil
                local events = assert(process.events())
                while not runner or not service do
                    local selected = channel.select({held:case_receive(), events:case_receive()})
                    assert(selected.ok, "attachment observation closed")
                    if selected.channel == events then
                        record_exit(selected.value)
                        assert(not exited[replacement], "replacement exited before barrier: " .. tostring(exited[replacement] and exited[replacement].error))
                    else
                        local message = selected.value
                        local data = assert(bounds.object(message:payload():data()))
                        if data.phase == "waiting" then service = tostring(message:from())
                        elseif data.phase == scenario.phase then runner = tostring(message:from()) end
                    end
                end
                local _, details = evidence_kinds(attempt_id)
                local installed = detail_with(details, "runner installed generation 2") ~= nil
                if scenario.timeout then
                    assert(process.send(service, "bee.test.attach.timeout", {}))
                else
                    assert(process.send(runner, "bee.test.attach.release", {}))
                end
                await_paused(paused, replacement, "reattached", true)
                local acknowledged = exited[replacement] == nil
                local failure = exited[replacement] and exited[replacement].error or nil
                if scenario.timeout then assert(process.send(runner, "bee.test.attach.release", {})) end
                if scenario.timeout then
                    if acknowledged then assert(process.terminate(replacement)) end
                    assert(process.monitor(runner))
                    assert(process.cancel(runner, "fence deadline fixture complete"))
                    await_exit(runner, "fence fixture runner")
                else
                    if acknowledged then continue_carrier(replacement) end
                    call("bee.placement.native.binding:reconcile", {attempt_id = attempt_id})
                end
                await_exit(replacement, "replacement carrier")
                process.unlisten(held)
                process.unlisten(paused)
                test.eq(installed, scenario.phase == "after", "fence evidence must be committed by the runner before either acknowledgement")
                test.eq(acknowledged, not scenario.timeout, "replacement attachment was acknowledged without a fence reply")
                if scenario.timeout then
                    assert(failure and failure:find("did not acknowledge", 1, true), tostring(failure))
                else
                    test.eq(report(assert(bounds.id(launch.thread_id))).after_hold, 401)
                end
            end)
        end
    end)
end
return {define = define_fencing_tests}
