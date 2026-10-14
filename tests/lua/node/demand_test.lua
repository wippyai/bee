-- SPDX-License-Identifier: MIT
local test = require("test")
local owner_observer = require("owner_observer")
local process = require("process")
local events = require("events")
local channel = require("channel")
local committed = require("committed")
local system = require("system")
local uuid = require("uuid")
local sql = require("sql")
local runs = require("runs")
local demand = require("demand")
local owners = require("owners")
local routing = require("routing")
local bounds = require("bounds")
local SERVICE = "bee.node.service:tests_service"

local ACTIVATION = "bee.gov.service:activation_service"
type Supervised = {status: string, desired: string, started_at: number}
local function dormant(updates: events.Subscription): Supervised
    while true do
        local state = assert(system.supervisor.state(ACTIVATION))
        if state.status == "stopped" or state.status == "exited" or state.status == "unknown" then return state end
        local selected = channel.select({updates:channel():case_receive()})
        assert(selected.ok, "activation owner does not drain: " .. tostring(state.status) .. "/" .. tostring(state.desired))
    end
end
local function create(): string
    local id = assert(uuid.v7())
    assert(runs.create({run_id = id, workspace_id = string.rep("c",32), actor_id = "demand-test",
        overlay = "", application = "bee.tests.node.hub_tests_fixture:application", plan = {}, state = "pending", result = nil}))
    return id
end
local function wake()
    local accepted = assert(process.listen(demand.ACCEPTED, {message = true}))
    local request_id = assert(uuid.v7())
    local supervisor = tostring(assert(process.registry.lookup(demand.SUPERVISOR, process.registry.LOCAL)))
    local ok, problem = pcall(function()
        assert(demand.dispatch("bee.node.tests", {request_id = request_id}))
        while true do
            local message = assert((accepted:receive()))
            local value = assert(bounds.object(message:payload():data()))
            if value.request_id == request_id then
                test.eq(value.name, "bee.node.tests")
                test.eq(tostring(message:from()), supervisor)
                break
            end
        end
    end)
    process.unlisten(accepted)
    assert(ok, problem)
end
local function complete(id: string)
    committed.await({"bee_node_test_runs"}, function(): {[string]: unknown}
        return {state = assert(runs.get(id)).state}
    end, function(value: {[string]: unknown}): boolean return value.state == "complete" end, nil, "pending run")
end

local function define_tests()
    test.describe("Test runner demand", function()
        test.it("preserves demand state when registry discovery fails", function()
            local previous = assert(owners.discover(nil))
            local owner = assert(previous["bee.node.tests"])
            owner.queue[1] = {caller = "retained-caller",data = {request_id = "retained-request"}}
            local function unavailable(): (nil,string) return nil,"registry unavailable" end
            local current, err = owners.discover(previous,unavailable)
            test.is_nil(current)
            test.contains(tostring(err),"registry unavailable")
            test.eq(#owner.queue,1)
            test.eq(previous["bee.node.tests"],owner)
            local routes, route_error = routing.routes(unavailable)
            test.is_nil(routes)
            test.contains(tostring(route_error),"registry unavailable")
        end)
        test.it("wakes a dormant activation owner on its declared Sync feed", function()
            local updates = assert(events.subscribe("supervisor","service.update"))
            local service = ACTIVATION
            local before = dormant(updates)
            assert(events.send("bee.sync","feed.changed","governance.application_versions",{source_owner = "peer",version_key = "version"}))
            while true do
                local current = assert(system.supervisor.state(service))
                if current.started_at ~= before.started_at then break end
                local selected = channel.select({updates:channel():case_receive()})
                assert(selected.ok,"Sync did not wake the dormant activation owner")
            end
            updates:close()
        end)
        test.it("dispatches to an absent runner and stops only after durable completion", function()
            local updates = assert(events.subscribe("supervisor", "service.update"))
            test.eq(process.registry.lookup("bee.node.tests", process.registry.LOCAL), nil)
            local id = create()
            wake()
            complete(id)
            owner_observer.stopped(SERVICE, "bee.node.tests", updates)
            updates:close()
        end)
        test.it("recovers pending rows through the boot backlog path", function()
            local updates = assert(events.subscribe("supervisor", "service.update"))
            local recovery = assert(process.listen("bee.test.boot_backlog.recovered", {message = true}))
            assert(process.registry.register("bee.test.effect_delivery"))
            local ok, problem = pcall(function()
                owner_observer.stopped(SERVICE, "bee.node.tests", updates)
                local id = create()
                local supervisor = tostring(assert(process.registry.lookup(demand.SUPERVISOR, process.registry.LOCAL)))
                assert(process.send(supervisor, demand.TOPIC, {action = "bee.test.boot_backlog"}))
                local message = assert((recovery:receive()))
                test.eq(tostring(message:from()), supervisor)
                complete(id)
                owner_observer.stopped(SERVICE, "bee.node.tests", updates)
            end)
            process.registry.unregister("bee.test.effect_delivery")
            process.unlisten(recovery)
            updates:close()
            assert(ok, problem)
        end)
        test.it("interrupts the previous running row once and resumes pending work on restart", function()
            local updates = assert(events.subscribe("supervisor", "service.update"))
            owner_observer.stopped(SERVICE, "bee.node.tests", updates)
            local running, pending = assert(uuid.v7()), assert(uuid.v7())
            local db = assert(sql.get("bee:db"))
            local tx = assert(db:begin())
            for _, row in ipairs({{id = running, state = "running"}, {id = pending, state = "pending"}}) do
                assert(tx:execute("INSERT INTO bee_node_test_runs (run_id, workspace_id, actor_id, overlay, application, plan_json, state, created_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                    {row.id, string.rep("c",32), "demand-test", "", "bee.tests.node.hub_tests_fixture:application", "[]", row.state, 0}))
            end
            assert(tx:commit())
            db:release()
            wake()
            complete(pending)
            owner_observer.stopped(SERVICE, "bee.node.tests", updates)
            test.eq(assert(runs.get(running)).state, "interrupted")
            test.eq(assert(runs.get(pending)).state, "complete")
            updates:close()
        end)
        test.it("retains an enqueue when a drained runner is stopping", function()
            local updates = assert(events.subscribe("supervisor", "service.update"))
            owner_observer.stopped(SERVICE, "bee.node.tests", updates)
            local quiet = assert(process.listen("bee.test.node.quiet", {message = true}))
            local accepted = assert(process.listen(demand.ACCEPTED, {message = true}))
            assert(process.registry.register("bee.test.node.quiet"))
            local supervisor = tostring(assert(process.registry.lookup(demand.SUPERVISOR, process.registry.LOCAL)))
            local first_request, second_request = assert(uuid.v7()), assert(uuid.v7())
            local first = create()
            assert(demand.dispatch("bee.node.tests", {request_id = first_request}))
            complete(first)
            local selected = channel.select({quiet:case_receive()})
            test.eq(selected.channel, quiet)
            local owner = tostring(selected.value:from())
            local second = create()
            assert(demand.dispatch("bee.node.tests", {request_id = second_request}))
            process.registry.unregister("bee.test.node.quiet")
            assert(process.send(owner, "bee.test.node.quiet.release", {}))
            local first_accepted, second_accepted = false, false
            while not (first_accepted and second_accepted) do
                local message = assert((accepted:receive()))
                local value = assert(bounds.object(message:payload():data()))
                test.eq(tostring(message:from()), supervisor)
                if value.request_id == first_request then first_accepted = true end
                if value.request_id == second_request then second_accepted = true end
            end
            complete(second)
            owner_observer.stopped(SERVICE, "bee.node.tests", updates)
            process.unlisten(accepted)
            process.unlisten(quiet)
            updates:close()
        end)
        test.it("cancels a runner held at the quiet barrier without a release", function()
            local updates = assert(events.subscribe("supervisor", "service.update"))
            owner_observer.stopped(SERVICE, "bee.node.tests", updates)
            local quiet = assert(process.listen("bee.test.node.quiet", {message = true}))
            local lifecycle = assert(process.events())
            assert(process.registry.register("bee.test.node.quiet"))
            local owner: string? = nil
            local ok, problem = pcall(function()
                local id = create()
                assert(demand.wake("bee.node.tests"))
                complete(id)
                local message = assert((quiet:receive()))
                local pid = tostring(message:from())
                owner = pid
                assert(process.monitor(pid))
                assert(events.send("supervisor", "service.stop", SERVICE))
                while true do
                    local event = assert((lifecycle:receive()))
                    if tostring(event.from) == pid and (event.kind == process.event.EXIT or event.kind == process.event.MONITOR_DOWN) then break end
                    test.neq(event.kind, process.event.CANCEL)
                end
                process.registry.unregister("bee.test.node.quiet")
                owner_observer.stopped(SERVICE, "bee.node.tests", updates)
            end)
            process.registry.unregister("bee.test.node.quiet")
            if owner then
                process.send(owner, "bee.test.node.quiet.release", {})
                process.unmonitor(owner)
            end
            process.unlisten(quiet)
            updates:close()
            assert(ok, problem)
        end)
    end)
end
return test.run_cases(define_tests)
