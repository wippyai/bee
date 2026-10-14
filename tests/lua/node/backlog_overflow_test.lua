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
local sql = require("sql")
local json = require("json")
local runs = require("runs")
local demand = require("demand")
local bounds = require("bounds")
local SERVICE = "bee.node.service:tests_service"

local function create(): string
    local id = assert(uuid.v7())
    assert(runs.create({run_id = id, workspace_id = string.rep("c",32), actor_id = "demand-test",
        overlay = "", application = "bee.tests.node.hub_tests_fixture:application", plan = {}, state = "pending", result = nil}))
    return id
end
local function define_tests()
    test.describe("Hive backlog observation", function()
        for _, registry_replacement in ipairs({false, true}) do
            local name = registry_replacement
                and "rescans disconnected writes when a registry commit replaces the overflowed stream"
                or "retains Hive and rescans disconnected writes after CDC backlog overflow without a wake"
            test.it(name, function()
                local updates = assert(events.subscribe("supervisor", "service.update"))
                local hive = assert(process.registry.lookup(demand.SUPERVISOR, process.registry.LOCAL))
                local cleanup: {() -> ()} = {}
                local ok, problem = pcall(function()
                    owner_observer.stopped(SERVICE, "bee.node.tests", updates)
                    local terminal = assert(process.listen("bee.test.hive.backlog_terminal", {message = true}))
                    cleanup[#cleanup + 1] = function() process.unlisten(terminal) end
                    assert(process.registry.register("bee.test.hive.backlog_terminal"))
                    local held = assert(process.listen("bee.test.hive.backlog_hold", {message = true}))
                    cleanup[#cleanup + 1] = function() process.unlisten(held) end
                    assert(process.registry.register("bee.test.hive.backlog_hold"))
                    local before = assert(system.supervisor.state("bee.hive.service:supervisor_service"))
                    local id = create()
                    assert((held:receive()))
                    local changes = assert(cdc.stream("bee:changes", {tables = {"bee_node_test_runs"}, ops = {"update"}, buffer = 1}))
                    cleanup[#cleanup + 1] = function() changes:close() end
                    local delivered = assert(cdc.stream("bee:changes", {tables = {"bee_node_test_runs"}, ops = {"update"}, buffer = 256}))
                    cleanup[#cleanup + 1] = function() delivered:close() end
                    local committed = changes:channel()
                    local published = delivered:channel()
                    local db = assert(sql.get("bee:db"))
                    for index = 1, 192 do
                        assert(db:execute("UPDATE bee_node_test_runs SET state = 'complete', result_json = ? WHERE run_id = ?",
                            {assert(json.encode({progress = {done = index, total = 192}})), id}))
                    end
                    db:release()
                    local overflow = time.after("5s")
                    local captured = 0
                    while captured < 192 do
                        local selected = channel.select({published:case_receive(), overflow:case_receive()})
                        assert(selected.channel ~= overflow and selected.ok, "CDC did not publish the overflow writes")
                        local change = assert(bounds.object(selected.value))
                        test.eq(change.table, "bee_node_test_runs")
                        test.eq(change.op, "update")
                        test.eq(assert(bounds.object(change.after)).run_id, id)
                        captured = captured + 1
                    end
                    delivered:close()
                    while true do
                        local selected = channel.select({committed:case_receive(), overflow:case_receive()})
                        assert(selected.channel ~= overflow, "CDC overflow did not terminate its stream")
                        if not selected.ok then break end
                    end
                    changes:close()
                    if registry_replacement then
                        assert(process.registry.register("bee.test.hive.backlog_registry"))
                        assert(events.send("registry", "registry.begin", "bee.test.hive.backlog"))
                        assert(events.send("registry", "registry.commit", "bee.test.hive.backlog"))
                    end
                    process.registry.unregister("bee.test.hive.backlog_hold")
                    assert(process.send(tostring(hive), "bee.test.hive.backlog_release", {}))
                    process.unlisten(held)
                    local ended = channel.select({terminal:case_receive(), time.after("5s"):case_receive()})
                    test.eq(ended.channel, terminal, "Hive backlog did not terminate after its overflow")
                    local dormant = assert(system.supervisor.state(SERVICE))
                    test.is_true(dormant.status == "stopped" or dormant.status == "exited" or dormant.status == "unknown", "runner already active: " .. dormant.status)
                    local recovered = create()
                    process.registry.unregister("bee.test.hive.backlog_terminal")
                    if registry_replacement then process.registry.unregister("bee.test.hive.backlog_registry") end
                    assert(process.send(tostring(hive), "bee.test.hive.backlog_resume", {}))
                    process.unlisten(terminal)
                    local observed = assert(cdc.stream("bee:changes", {tables = {"bee_node_test_runs"}, ops = {"update"}}))
                    cleanup[#cleanup + 1] = function() observed:close() end
                    local completion = time.after("5s")
                    while assert(runs.get(recovered)).state ~= "complete" do
                        local current = assert(system.supervisor.state("bee.hive.service:supervisor_service"))
                        test.eq(current.status, "running", "Hive must survive a terminated backlog stream")
                        test.eq(current.started_at, before.started_at, "Hive must retain its process")
                        local selected = channel.select({updates:channel():case_receive(), observed:channel():case_receive(), completion:case_receive()})
                        assert(selected.channel ~= completion, "Hive did not recover durable demand after overflow")
                        assert(selected.ok, "durable demand did not complete")
                    end
                    test.eq(assert(runs.get(id)).state, "complete")
                    observed:close()
                    owner_observer.stopped(SERVICE, "bee.node.tests", updates)
                    updates:close()
                    test.eq(tostring(assert(process.registry.lookup(demand.SUPERVISOR, process.registry.LOCAL))), tostring(hive))
                end)
                for _, name in ipairs({"bee.test.hive.backlog_hold", "bee.test.hive.backlog_terminal", "bee.test.hive.backlog_registry"}) do
                    process.registry.unregister(name)
                end
                if not ok then
                    process.send(tostring(hive), "bee.test.hive.backlog_release", {})
                    process.send(tostring(hive), "bee.test.hive.backlog_resume", {})
                end
                for _, close in ipairs(cleanup) do close() end
                updates:close()
                assert(ok, problem)
            end)
        end
    end)
end
return test.run_cases(define_tests)
