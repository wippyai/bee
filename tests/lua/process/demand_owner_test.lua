-- SPDX-License-Identifier: MIT
local test = require("test")
local owner = require("owner")
local runtime = require("runtime")
local state = require("state")
local demand = require("demand")

local function running(): owner.Owners
    runtime.reset()
    local lifecycle = state.new()
    state.wake(lifecycle)
    state.ready(lifecycle, "old")
    local owners: owner.Owners = {}
    owners["fixture.owner"] = {id = "fixture:service", name = "fixture.owner", state = lifecycle,
        queue = {}, tables = {}, actor = "fixture", policies = {}, retry_ms = 1}
    return owners
end
local function dispatch(owners: owner.Owners)
    owner.receive(owners, "caller", {name = "fixture.owner", action = "dispatch", value = {request_id = "request"}})
end
local function delivered(owners: owner.Owners)
    test.eq(runtime.starts, 1)
    test.eq(#runtime.messages, 0)
    runtime.status, runtime.live = "running", "replacement"
    owner.ready(owners, "fixture.owner", "replacement")
    test.eq(#runtime.messages, 2)
    local wake = runtime.messages[1]
    test.eq(wake.pid, "replacement")
    test.eq(wake.topic, demand.WAKE)
    local batch = wake.data
    assert(type(batch) == "table" and type(batch.requests) == "table")
    test.eq(#batch.requests, 1)
    test.eq(batch.requests[1].caller, "caller")
    test.eq(batch.requests[1].data.request_id, "request")
    local accepted = runtime.messages[2]
    test.eq(accepted.pid, "caller")
    test.eq(accepted.topic, demand.ACCEPTED)
    local acknowledgement = accepted.data
    assert(type(acknowledgement) == "table")
    test.eq(acknowledgement.pid, "replacement")
    test.eq(acknowledgement.request_id, "request")
    test.eq(#owners["fixture.owner"].queue, 0)
end
local function define_tests()
    test.describe("Demand owner lifecycle", function()
        test.it("delivers after send fails following the exited notification", function()
            local owners = running()
            runtime.status, runtime.live = "exited", ""
            owner.update(owners)
            test.eq(runtime.starts, 0)
            dispatch(owners)
            delivered(owners)
        end)
        test.it("starts fresh demand after an idle owner exits", function()
            local owners = running()
            runtime.status, runtime.live = "exited", ""
            owner.update(owners)
            owner.exit(owners, "old")
            test.eq(runtime.starts, 0)
            dispatch(owners)
            delivered(owners)
        end)
        test.it("delivers after send fails before the exited notification", function()
            local owners = running()
            runtime.live = ""
            dispatch(owners)
            test.eq(runtime.starts, 0)
            test.eq(#runtime.messages, 0)
            owner.exit(owners, "old")
            runtime.status = "exited"
            owner.update(owners)
            delivered(owners)
        end)
        test.it("keeps a quiet owner stopping until lifecycle completion", function()
            local owners = running()
            local lifecycle = owners["fixture.owner"].state
            test.eq(state.quiet(lifecycle, "old", lifecycle.generation), true)
            dispatch(owners)
            owner.exit(owners, "old")
            test.eq(lifecycle.phase, "stopping")
            test.eq(runtime.starts, 0)
            test.eq(#owners["fixture.owner"].queue, 1)
            runtime.status, runtime.desired = "exited", "stopped"
            owner.update(owners)
            delivered(owners)
        end)
    end)
end
return test.run_cases(define_tests)
