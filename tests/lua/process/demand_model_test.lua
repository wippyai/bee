-- SPDX-License-Identifier: MIT
local test = require("test")
local owner = require("owner")
local runtime = require("runtime")
local state = require("state")
local demand = require("demand")

type Trace = {string}
local NAME = "fixture.owner"
local function run(trace: Trace, initially_running: boolean, deferred: boolean?)
    runtime.reset()
    runtime.model, runtime.deferred = true, deferred == true
    local lifecycle = state.new()
    if initially_running then
        state.wake(lifecycle)
        state.ready(lifecycle, "old")
    else
        runtime.live, runtime.status, runtime.desired = "", "stopped", "stopped"
    end
    local owners: owner.Owners = {}
    owners[NAME] = {id = "fixture:service", name = NAME, state = lifecycle,
        queue = {}, tables = {}, actor = "fixture", policies = {}, retry_ms = 1}
    local observed_revision = runtime.revision
    local ready_pids: {[string]: boolean} = {}
    if initially_running then ready_pids["old"] = true end
    local old_exited = false
    local function update()
        observed_revision = runtime.revision
        owner.update(owners)
    end
    local requests = 0
    local wake_generation = 0
    local delivered: {[string]: boolean} = {}
    local accepted: {[string]: boolean} = {}
    local delivered_count, observed_messages = 0, 0
    local function request()
        requests = requests + 1
        owner.wake(owners, NAME, {caller = "caller", data = {request_id = tostring(requests)}})
    end
    local function check()
        for index = observed_messages + 1, #runtime.messages do
            local message = runtime.messages[index]
            if message.topic == demand.ACCEPTED then
                local receipt = message.data
                assert(type(receipt) == "table" and type(receipt.request_id) == "string")
                assert(not accepted[receipt.request_id], "duplicate acceptance")
                accepted[receipt.request_id] = true
            elseif message.topic == demand.WAKE then
                local payload = message.data
                assert(type(payload) == "table" and type(payload.requests) == "table")
                for _, entry in ipairs(payload.requests) do
                    local id = entry.data.request_id
                    assert(type(id) == "string" and not delivered[id], "duplicate delivery")
                    delivered[id], delivered_count = true, delivered_count + 1
                end
            end
        end
        observed_messages = #runtime.messages
        for id in pairs(delivered) do assert(accepted[id], "delivery not acknowledged") end
        for id in pairs(accepted) do assert(delivered[id], "acknowledged without delivery") end
        assert(delivered_count + #owners[NAME].queue == requests, "request disappeared")
        assert(runtime.outstanding <= 1, "multiple starts outstanding")
    end
    for _, event in ipairs(trace) do
        if event == "request" then request()
        elseif event == "wake" then
            owner.wake(owners, NAME, nil)
            wake_generation = lifecycle.generation
        elseif event == "ready" then
            if runtime.live ~= "" then
                runtime.outstanding = 0
                ready_pids[runtime.live] = true
                owner.ready(owners, NAME, runtime.live)
                if lifecycle.phase == "ready" then assert(#owners[NAME].queue == 0, "readiness did not flush") end
            end
        elseif event == "send-failure" then
            if runtime.live ~= "" then runtime.outstanding = 0 end
            runtime.live = ""
            request()
        elseif event == "EXIT" then
            if runtime.live == "old" then runtime.live = "" end
            old_exited = true
            owner.exit(owners, "old")
        elseif event == "quiet-stop" then
            owner.receive(owners, "old", {name = NAME, action = "quiet", value = lifecycle.generation})
        elseif event == "running" then update()
        elseif event == "terminal-update" then
            runtime.revision = runtime.revision + 1
            update()
        elseif event == "batch-failure" then runtime.fail_at = runtime.wakes + 2
        elseif event == "unstarted" then runtime.status, runtime.desired = "unknown", "unknown"
        else
            if runtime.live == "old" then runtime.live = "" end
            if runtime.live == "" then
                if runtime.status ~= event then runtime.revision = runtime.revision + 1 end
                runtime.status = event
                if event == "stopped" then runtime.desired = "stopped" end
            end
            update()
        end
        check()
    end
    -- Finish only actual pending commands and notifications, without inventing
    -- another ready message or supervisor update for an already completed stop.
    for _ = 1, 4 do
        runtime.pump()
        if runtime.live == "" and runtime.status ~= "stopped" and runtime.status ~= "exited" then
            runtime.revision = runtime.revision + 1
            runtime.status = "exited"
        end
        if observed_revision ~= runtime.revision then update() end
        if initially_running and not old_exited and runtime.live ~= "old" then
            old_exited = true
            owner.exit(owners, "old")
        end
        if runtime.live ~= "" and not ready_pids[runtime.live] then
            runtime.outstanding = 0
            ready_pids[runtime.live] = true
            owner.ready(owners, NAME, runtime.live)
        end
        check()
    end
    assert(#owners[NAME].queue == 0, "queued request stranded in " .. lifecycle.phase)
    local delivered_generation = 0
    for _, message in ipairs(runtime.messages) do
        local payload = message.data
        if message.topic == demand.WAKE and type(payload) == "table" and type(payload.generation) == "number" then
            delivered_generation = math.max(delivered_generation, payload.generation)
        end
    end
    assert(wake_generation <= delivered_generation or wake_generation <= lifecycle.drained,
        "wake stranded in " .. lifecycle.phase)
    runtime.model = false
end
local function define_tests()
    test.describe("Demand owner event model", function()
        test.it("does not lose demand between process exit and supervisor completion", function()
            run({"EXIT", "request", "exited"}, true)
        end)
        test.it("reconciles a completed stop before a delayed quiet message", function()
            run({"stopped", "quiet-stop", "request"}, true)
        end)
        test.it("starts a never-started supervisor entry", function()
            run({"unstarted", "request"}, false)
        end)
        test.it("retains only the unsent tail when a later batch loses its process", function()
            local trace: Trace = {}
            for _ = 1, 130 do trace[#trace + 1] = "request" end
            trace[#trace + 1] = "batch-failure"
            run(trace, false, true)
        end)
        test.it("retains repeated demand and ignores repeated old readiness and exit", function()
            run({"quiet-stop", "request", "request", "ready", "EXIT", "exited", "ready", "EXIT", "ready"}, true, true)
        end)
        test.it("does not mistake terminal detail updates for start acknowledgement", function()
            run({"send-failure", "exited", "terminal-update"}, true, true)
        end)
        test.it("checks every permutation through six events from absent and ready", function()
            local alphabet = {"request", "wake", "ready", "send-failure", "EXIT", "stopped", "exited", "running", "quiet-stop"}
            local trace: Trace = {}
            local used: {[string]: boolean} = {}
            local results = {checked = 0, failed = 0, first = ""}
            local function visit(depth: integer)
                for _, deferred in ipairs({false, true}) do
                    for _, running in ipairs({false, true}) do
                        local ok, problem = pcall(run, trace, running, deferred)
                        results.checked = results.checked + 1
                        if not ok then
                            results.failed = results.failed + 1
                            if results.first == "" then results.first = (running and "ready: " or "absent: ") .. table.concat(trace, ", ") .. ": " .. tostring(problem) end
                        end
                    end
                end
                if depth == 6 then return end
                for _, event in ipairs(alphabet) do
                    if not used[event] then
                        used[event] = true
                        trace[#trace + 1] = event
                        visit(depth + 1)
                        table.remove(trace)
                        used[event] = nil
                    end
                end
            end
            visit(0)
            test.eq(results.checked, 316840, "enumerated prefixes")
            test.eq(results.failed, 0, tostring(results.failed) .. "/" .. tostring(results.checked) .. " failing sequences; first " .. results.first)
        end)
    end)
end
return test.run_cases(define_tests)
