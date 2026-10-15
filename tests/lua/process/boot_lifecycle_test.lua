-- SPDX-License-Identifier: MIT
local test = require("test")
local process = require("process")
local system = require("system")
local sql = require("sql")
local recovery = require("recovery")
local OWNERS = {
    ["bee.threads.service:service"] = "bee.threads.service:threads",
    ["bee.node.service:owner_service"] = "bee.node.service:owner",
    ["bee.hive.service:supervisor_service"] = "bee.hive.service:supervisor",
}
local M = {}

function M.observe(parent: string)
    for id in pairs(OWNERS) do
        local state = assert(system.supervisor.state(id))
        assert(state.status ~= "running" and state.status ~= "exited" and state.status ~= "failed", id)
    end
    for _, host in ipairs(assert(system.hosts.list())) do
        for _, child in ipairs(assert(system.hosts.processes(host.id))) do
            for _, source in pairs(OWNERS) do
                assert(child.source ~= source, "dependent started before recovery completed: " .. source)
            end
        end
    end
    assert(process.send(parent, "bee.test.lifecycle.release", true))
end

local function held()
    local released = assert(process.listen("bee.test.lifecycle.release", {message = true}))
    local observer = assert(process.spawn("bee.tests.process:lifecycle_observer", "bee:workers", tostring(process.pid())))
    local message = assert((released:receive()))
    assert(tostring(message:from()) == tostring(observer))
    process.unlisten(released)
end

function M.complete()
    held()
    recovery.main()
    local db = assert(sql.get("bee:db"))
    assert(db:execute("CREATE TABLE bee_test_lifecycle (completed INTEGER NOT NULL)"))
    assert(db:execute("INSERT INTO bee_test_lifecycle VALUES (1)"))
    db:release()
end

function M.failing_completion()
    held()
    error("injected boot completion failure")
end

M.run = test.run_cases(function()
    test.describe("Native boot completion lifecycle", function()
        test.it("starts dependents only after the held recovery gate completes", function()
            test.eq(assert(system.supervisor.state("bee.gov.service:recovery_service")).status, "exited")
            test.eq(assert(system.supervisor.state("wippy.bootloader:bootloader.service")).status, "exited")
            local db = assert(sql.get("bee:db"))
            test.eq(assert(db:query("SELECT completed FROM bee_test_lifecycle"))[1].completed, 1)
            db:release()
            for id in pairs(OWNERS) do
                test.eq(assert(system.supervisor.state(id)).status, "running", id)
            end
        end)
    end)
end)
return M
