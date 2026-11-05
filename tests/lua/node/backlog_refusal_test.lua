-- SPDX-License-Identifier: MIT
local test = require("test")
local owner_observer = require("owner_observer")
local process = require("process")
local events = require("events")
local channel = require("channel")
local cdc = require("cdc")
local system = require("system")
local uuid = require("uuid")
local time = require("time")
local runs = require("runs")
local demand = require("demand")
local SERVICE = "bee.node.service:tests_service"
local HIVE = "bee.hive.service:supervisor_service"

local function create(): string
    local id = assert(uuid.v7())
    assert(runs.create({run_id = id, workspace_id = string.rep("c", 32), actor_id = "demand-test",
        overlay = "", application = "bee.tests.node.hub.fixture:application", plan = {}, state = "pending", result = nil}))
    return id
end

local function commit(path: string)
    assert(events.send("registry", "registry.begin", path))
    assert(events.send("registry", "registry.commit", path))
end

local function define_tests()
    test.describe("Hive backlog subscription", function()
        test.it("keeps the Hive supervisor and recovers durable demand when the change source refuses its backlog subscription", function()
            local updates = assert(events.subscribe("supervisor", "service.update"))
            local hive = tostring(assert(process.registry.lookup(demand.SUPERVISOR, process.registry.LOCAL)))
            local before = assert(system.supervisor.state(HIVE))
            local refused = assert(process.listen("bee.test.hive.backlog_refusal", {message = true}))
            local ok, problem = pcall(function()
                owner_observer.stopped(SERVICE, "bee.node.tests", updates)
                assert(process.registry.register("bee.test.hive.backlog_refusal"))
                commit("bee.test.hive.backlog_refusal")
                local notice = channel.select({refused:case_receive(), time.after("5s"):case_receive()})
                test.eq(notice.channel, refused, "the registry commit did not resubscribe the Hive backlog")
                process.registry.unregister("bee.test.hive.backlog_refusal")
                local id = create()
                commit("bee.test.hive.backlog_refusal")
                local observed = assert(cdc.stream("bee:changes", {tables = {"bee_node_test_runs"}, ops = {"update"}}))
                local completion = time.after("5s")
                while assert(runs.get(id)).state ~= "complete" do
                    local current = assert(system.supervisor.state(HIVE))
                    test.eq(current.status, "running", "Hive must survive a refused backlog subscription")
                    test.eq(current.started_at, before.started_at, "Hive must retain its process")
                    local selected = channel.select({updates:channel():case_receive(), observed:channel():case_receive(), completion:case_receive()})
                    assert(selected.channel ~= completion, "Hive did not recover durable demand after a refused backlog subscription")
                    assert(selected.ok, "durable demand did not complete")
                end
                observed:close()
                owner_observer.stopped(SERVICE, "bee.node.tests", updates)
                test.eq(tostring(assert(process.registry.lookup(demand.SUPERVISOR, process.registry.LOCAL))), hive)
            end)
            process.registry.unregister("bee.test.hive.backlog_refusal")
            process.unlisten(refused)
            updates:close()
            assert(ok, problem)
        end)
    end)
end
return test.run_cases(define_tests)
