-- MIT. A wake is only a hint: durable journal scans launch queued work after
-- the hint or the scheduler process is lost.
local test = require("test")
local scheduler = require("scheduler")
local threads = require("threads")
local fake_executor = require("executor")

local function request(key: string): scheduler.SendRequest
    return {session = "bs:node:workspace:s1", operation_key = key, executor_id = "external",
        input = "Review the current patch", input_digest = "sha256:input", output_schema = "bee:Text@1"}
end

local function journal(owner: threads.Owner): scheduler.Journal
    return {
        enqueue = function(value: scheduler.SendRequest): (scheduler.WorkReceipt?, string?)
            return owner.enqueue(value)
        end,
        scan_due = function(value: {limit: integer}): (scheduler.DuePage?, string?)
            local page, err = owner.scan_due(value)
            return page :: scheduler.DuePage?, err
        end,
        reserve_turn = function(value: {work: string, session: string}): (scheduler.Claim?, string?)
            return owner.reserve_turn(value)
        end,
        link_execution = function(claim: scheduler.Claim, intent: scheduler.ExecutionIntent): (boolean, string?)
            return owner.link_execution(claim, intent)
        end,
    }
end

local function define_tests()
    test.describe("Session scheduler", function()
        test.it("wakes an idle queued session and settles its pulled turn", function()
            local owner = threads.new()
            local executor = fake_executor.new(owner, {})
            local registry = fake_executor.registry("external", executor)
            local wakes = 0
            local service = assert(scheduler.create(journal(owner), registry, function(): (boolean, string?)
                wakes = wakes + 1
                return true, nil
            end))
            local receipt = assert(service.send(request("send-1")))
            test.eq(receipt.state, "queued")
            test.eq(wakes, 1)
            local pass = assert(service.run_pass())
            test.eq(pass.activated, 1)
            test.eq(executor.launches, 1)
            local result = assert(owner.work_state(receipt.work))
            test.eq(result.phase, "settled")
            test.eq((result.result :: threads.Result).value.text, "done: Review the current patch")
        end)

        test.it("recovers queued work on a fresh scheduler after its wake hint is lost", function()
            local owner = threads.new()
            local executor = fake_executor.new(owner, {})
            local registry = fake_executor.registry("external", executor)
            local first = assert(scheduler.create(journal(owner), registry, function(): (boolean, string?)
                return false, "worker is restarting"
            end))
            local receipt, hint_error = first.send(request("send-lost-hint"))
            test.not_nil(receipt)
            test.eq(hint_error, "worker is restarting")
            local restarted = assert(scheduler.create(journal(owner), registry, nil))
            local pass = assert(restarted.run_pass())
            test.eq(pass.activated, 1)
            test.eq(assert(owner.work_state(assert(receipt).work)).phase, "settled")
        end)

        test.it("reconciles accepted execution and resumes its exact worker after restart", function()
            local owner = threads.new()
            local executor = fake_executor.new(owner, {stop_after_accept = true})
            local registry = fake_executor.registry("external", executor)
            local first = assert(scheduler.create(journal(owner), registry, function(): (boolean, string?) return true, nil end))
            local receipt = assert(first.send(request("send-accepted")))
            local first_pass = assert(first.run_pass())
            test.eq(first_pass.activated, 1)
            test.eq(assert(owner.work_state(receipt.work)).phase, "accepted")
            local restarted = assert(scheduler.create(journal(owner), registry, nil))
            local recovery_pass = assert(restarted.run_pass())
            test.eq(recovery_pass.resumed, 1)
            test.eq(executor.launches, 1)
            test.eq(executor.resumes, 1)
            test.eq(assert(owner.work_state(receipt.work)).phase, "settled")
        end)

        test.it("does not start a replacement when execution reconciliation is unknown", function()
            local owner = threads.new()
            local executor = fake_executor.new(owner, {stop_after_accept = true})
            local registry = fake_executor.registry("external", executor)
            local first = assert(scheduler.create(journal(owner), registry, function(): (boolean, string?) return true, nil end))
            local receipt = assert(first.send(request("send-unknown")))
            assert(first.run_pass())
            test.is_true(executor.set_state(receipt.work, "unknown"))
            local restarted = assert(scheduler.create(journal(owner), registry, nil))
            local pass = assert(restarted.run_pass())
            test.eq(pass.uncertain, 1)
            test.eq(executor.launches, 1)
            test.eq(assert(owner.work_state(receipt.work)).phase, "accepted")
        end)
    end)
end

return test.run_cases(define_tests)
