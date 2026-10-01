-- MIT. A wake is only a hint: durable journal scans recover reserved work
-- after the scheduler process or its wake message is lost.
local test = require("test")
local scheduler = require("scheduler")
local threads = require("threads")
local fake_executor = require("executor")
local bounds = require("bounds")

local function request(key: string): {[string]: unknown}
    return {session = "bs:node:workspace:s1", operation_key = key,
        input = "Review the current patch", output_schema = "bee:Text@1"}
end

local function define_tests()
    test.describe("Session scheduler", function()
        test.it("persists an executor failure as uncertainty without repeating the invocation", function()
            local owner = threads.new()
            local calls = 0
            local registry: scheduler.Registry = {get = function(_: string): (scheduler.Executor?, string?)
                return {run_turn = function(_: {[string]: unknown}): (scheduler.Execution?, string?)
                    calls = calls + 1
                    return nil, "executor ended without an outcome"
                end}, nil
            end}
            local service = assert(scheduler.create(owner.journal, registry, nil, "failed-worker"))
            local work = assert(service.send(request("failed-executor")))
            test.eq(assert(service.run_pass()).uncertain, 1)
            test.not_nil(assert(owner.work_state(work.work)).uncertainty)
            service.run_pass()
            test.eq(calls, 1)
        end)
        test.it("runs only the Work selected by an independent session worker", function()
            local owner = threads.new()
            local executor = fake_executor.new({})
            local service = assert(scheduler.create(owner.journal, fake_executor.registry("external", executor), nil, "selected-worker"))
            local first = assert(service.send(request("first-session")))
            local second_request = request("second-session")
            second_request.session = "bs:node:workspace:s2"
            local second = assert(service.send(second_request))
            local report = assert(service.run_pass(second.work))
            test.eq(report.activated, 1)
            test.eq(executor.launches, 1)
            test.eq(assert(owner.work_state(first.work)).phase, "queued")
            test.eq(assert(owner.work_state(second.work)).phase, "settled")
        end)
        test.it("wakes queued work, keeps owner-set sender identity and settles the turn", function()
            local owner = threads.new()
            local executor = fake_executor.new({})
            local registry = fake_executor.registry("external", executor)
            local wakes = 0
            local service = assert(scheduler.create(owner.journal, registry, function(): (boolean, string?)
                wakes = wakes + 1
                return true, nil
            end, "scheduler-1"))
            local receipt = assert(service.send(request("send-1")))
            test.eq(receipt.state, "queued")
            test.eq(receipt.sender.kind, "session")
            test.eq(receipt.sender.id, receipt.session)
            test.eq(wakes, 1)
            local pass = assert(service.run_pass())
            test.eq(pass.activated, 1)
            test.eq(executor.launches, 1)
            local state = assert(owner.work_state(receipt.work))
            test.eq(state.phase, "settled")
            test.eq((state.sender :: {[string]: unknown}).kind, receipt.sender.kind)
            test.eq((state.sender :: {[string]: unknown}).id, receipt.sender.id)
            local turn = assert(executor.last_turn)
            test.eq((turn.sender :: {[string]: unknown}).kind, receipt.sender.kind)
            test.eq((turn.sender :: {[string]: unknown}).id, receipt.sender.id)
            local admission = turn.admission :: {[string]: unknown}
            test.eq(admission.session_ref, receipt.session)
            test.eq(admission.action_id, receipt.session)
            local result = state.result
            test.eq(type(result), "table")
            test.eq((result :: {[string]: unknown}).value and ((result :: {[string]: unknown}).value :: {[string]: unknown}).text,
                "done: Review the current patch")
        end)
        test.it("passes a Work budget to the executor and persists its evidenced outcome", function()
            local owner = threads.new()
            local registry: scheduler.Registry = {get = function(_: string): (scheduler.Executor?, string?)
                return {run_turn = function(turn: {[string]: unknown}): (scheduler.Execution?, string?)
                    local selected = bounds.object(turn.budget)
                    test.eq(selected and selected.max_tokens, 24)
                    local execution: scheduler.Execution = {state = "settled", outcome = "budget_exceeded",
                        error = {code = "BUDGET_EXCEEDED", message = "max_tokens exceeded"},
                        evidence = {summary = "placement proved the process stopped after max_tokens", artifacts = {"attempt exited"}}}
                    return execution, nil
                end}, nil
            end}
            local service = assert(scheduler.create(owner.journal, registry, nil, "budget-worker"))
            local selected = request("budgeted-work")
            selected.budget = {max_tokens = 24}
            local receipt = assert(service.send(selected))
            local pass = assert(service.run_pass())
            test.eq(pass.activated, 1)
            local state = assert(owner.work_state(receipt.work))
            local result = bounds.object(state.result)
            local fault = result and bounds.object(result.error)
            local evidence = result and bounds.object(result.evidence)
            test.eq(result and result.state, "budget_exceeded")
            test.eq(fault and fault.code, "BUDGET_EXCEEDED")
            test.eq(evidence and evidence.summary, "placement proved the process stopped after max_tokens")
        end)

        test.it("recovers queued work on a fresh scheduler after its wake hint is lost", function()
            local owner = threads.new()
            local executor = fake_executor.new({})
            local registry = fake_executor.registry("external", executor)
            local first = assert(scheduler.create(owner.journal, registry, function(): (boolean, string?)
                return false, "worker is restarting"
            end, "scheduler-first"))
            local receipt, hint_error = first.send(request("send-lost-hint"))
            test.not_nil(receipt)
            test.eq(hint_error, "worker is restarting")
            local restarted = assert(scheduler.create(owner.journal, registry, nil, "scheduler-restarted"))
            local pass = assert(restarted.run_pass())
            test.eq(pass.activated, 1)
            test.eq(assert(owner.work_state(assert(receipt).work)).phase, "settled")
        end)

        test.it("recovers an accepted turn with the same attempt identity", function()
            local owner = threads.new()
            local executor = fake_executor.new({stop_after_first = true})
            local registry = fake_executor.registry("external", executor)
            local first = assert(scheduler.create(owner.journal, registry, nil, "scheduler-first"))
            local receipt = assert(first.send(request("send-accepted")))
            local first_pass = assert(first.run_pass())
            test.eq(first_pass.running, 1)
            test.eq(assert(owner.work_state(receipt.work)).phase, "accepted")
            local restarted = assert(scheduler.create(owner.journal, registry, nil, "scheduler-restarted"))
            local recovery_pass = assert(restarted.run_pass())
            test.eq(recovery_pass.recovered, 1)
            test.eq(recovery_pass.activated, 1)
            test.eq(executor.launches, 1)
            test.eq(executor.resumes, 1)
            test.eq(assert(owner.work_state(receipt.work)).phase, "settled")
        end)

        test.it("marks an unprovable recovered turn uncertain without a duplicate invocation", function()
            local owner = threads.new()
            local executor = fake_executor.new({stop_after_first = true})
            local registry = fake_executor.registry("external", executor)
            local first = assert(scheduler.create(owner.journal, registry, nil, "scheduler-first"))
            local receipt = assert(first.send(request("send-unknown")))
            assert(first.run_pass())
            local attempt = assert(owner.turn_for_work(receipt.work))
            test.is_true(executor.set_state(attempt, "unknown"))
            local restarted = assert(scheduler.create(owner.journal, registry, nil, "scheduler-restarted"))
            local pass = assert(restarted.run_pass())
            test.eq(pass.uncertain, 1)
            test.eq(executor.launches, 1)
            local state = assert(owner.work_state(receipt.work))
            test.eq(state.phase, "accepted")
            test.not_nil(state.uncertainty)
        end)
    end)
end

return test.run_cases(define_tests)
