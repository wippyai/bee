-- SPDX-License-Identifier: MIT
local test = require("test")
local sql = require("sql")
local process = require("process")
local events = require("events")
local channel = require("channel")
local time = require("time")
local system = require("system")
local bounds = require("bounds")
local dispatch = require("dispatch")
local demand = require("demand")
local resources = require("resources")
local function stopped(id: string, updates: events.Subscription)
    local deadline = time.after("10s")
    while true do
        local owner = assert(system.supervisor.state(id))
        if owner.desired == "stopped" and (owner.status == "stopped" or owner.status == "exited") then return end
        local selected = channel.select({updates:channel():case_receive(), deadline:case_receive()})
        assert(selected.channel ~= deadline, "consumer owner does not stop: " .. tostring(owner.status))
    end
end
local function define_tests()
    test.describe("Registered effect consumer demand", function()
        for _, target in ipairs({
            {destination = "gateway.installation", name = "bee.gateway.external", service = "bee.gateway.service:external_service"},
            {destination = "gateway.publication", name = "bee.gateway.external", service = "bee.gateway.service:external_service"},
            {destination = "gov.activation", name = "bee.gov.activation_worker", service = "bee.gov.service:activation_service"},
        }) do
            test.it("starts the absent owner for " .. target.destination .. " and drains it again", function()
                local updates = assert(events.subscribe("supervisor", "service.update"))
                local accepted = assert(process.listen(demand.ACCEPTED, {message = true}))
                local db = assert(sql.get("bee.approvals:effect_demand_db"))
                local ok, failure = pcall(function()
                    test.eq(process.registry.lookup(target.name, process.registry.LOCAL), nil)
                    test.eq(assert(resources.consumer(target.destination)).worker_name, target.name)
                    assert(db:execute("CREATE TABLE IF NOT EXISTS bee_approval_events (seq INTEGER PRIMARY KEY, event_id TEXT, approval_id TEXT, revision INTEGER, destination TEXT, acknowledged_at INTEGER)"))
                    assert(db:execute("DELETE FROM bee_approval_events"))
                    assert(db:execute("INSERT INTO bee_approval_events VALUES (1, 'demand-event', 'demand-approval', 2, ?, NULL)", {target.destination}))
                    test.eq(assert(dispatch.deliver(db, nil)), 1)
                    local selected = channel.select({accepted:case_receive(), time.after("10s"):case_receive()})
                    test.eq(selected.channel, accepted, "absent consumer wake is lost")
                    local supervisor = assert(process.registry.lookup(demand.SUPERVISOR, process.registry.LOCAL))
                    test.eq(tostring(selected.value:from()), tostring(supervisor))
                    local receipt = assert(bounds.object(selected.value:payload():data()))
                    test.eq(receipt.name, target.name)
                    test.eq(receipt.request_id, "demand-event")
                    test.is_true(type(receipt.pid) == "string")
                    stopped(target.service, updates)
                    test.eq(process.registry.lookup(target.name, process.registry.LOCAL), nil)
                end)
                db:release(); process.unlisten(accepted); updates:close()
                if not ok then error(tostring(failure)) end
            end)
        end
        test.it("retains completed boot gates across repeated demand for every owner", function()
            local updates = assert(events.subscribe("supervisor", "service.update"))
            local accepted = assert(process.listen(demand.ACCEPTED, {message = true}))
            local db = assert(sql.get("bee:db"))
            local function starts(): integer
                local rows = assert(db:query("SELECT COUNT(*) AS count FROM bee_test_recovery_starts"))
                return assert(bounds.integer(rows[1].count))
            end
            local before = starts()
            local boot = assert(system.supervisor.state("wippy.bootloader:bootloader.service")).started_at
            test.is_true(before > 0)
            local ok, failure = pcall(function()
                for _, target in ipairs({
                    {name = "bee.gov.activation_worker", service = "bee.gov.service:activation_service"},
                    {name = "bee.node.tests", service = "bee.node.service:tests_service"},
                    {name = "bee.gateway.external", service = "bee.gateway.service:external_service"},
                    {name = "bee.placement.docker/image", service = "bee.placement.docker.service:image_owner_service"},
                    {name = "bee.placement.sweeper", service = "bee.placement.native.service:sweeper_service"},
                }) do
                    for index = 1, 3 do
                        assert(demand.dispatch(target.name, {request_id = "boot-gate-" .. tostring(index)}))
                        local selected = channel.select({accepted:case_receive(), time.after("10s"):case_receive()})
                        test.eq(selected.channel, accepted, target.name)
                        stopped(target.service, updates)
                        test.eq(starts(), before, target.name .. " demand reruns boot restoration")
                        test.eq(assert(system.supervisor.state("wippy.bootloader:bootloader.service")).started_at, boot,
                            target.name .. " demand reruns the bootloader")
                        test.eq(assert(system.supervisor.state("bee:changes")).status, "running")
                    end
                end
            end)
            db:release(); process.unlisten(accepted); updates:close()
            if not ok then error(tostring(failure)) end
        end)
    end)
end
return test.run_cases(define_tests)
