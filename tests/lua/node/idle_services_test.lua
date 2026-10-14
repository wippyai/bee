-- SPDX-License-Identifier: MIT
local test = require("test")
local process = require("process")
local system = require("system")
local bounds = require("bounds")
local RESIDENT = {
    ["bee.hive.service:supervisor"] = "bee.hive.supervisor",
    ["bee.node.service:owner"] = "bee.node",
    ["bee.threads.service:threads"] = "bee.threads",
    ["bee.sync.service:sync"] = "bee.sync",
}
local DEMAND = {
    ["bee.credentials.service:worker"] = true,
    ["bee.gateway.service:external"] = true,
    ["bee.gov.service:activation_worker"] = true,
    ["bee.node.service:tests"] = true,
    ["bee.placement.docker.service:image_owner"] = true,
    ["bee.placement.native.service:sweeper"] = true,
    ["bee.placement.docker.service:sweeper"] = true,
    ["bee.gateway.service:worker"] = true,
    ["bee.gateway.service:publication_worker"] = true,
    ["bee.threads.service:pump_worker"] = true,
}
local function define_tests()
    test.describe("Idle node service residency", function()
        test.it("runs exactly Hive, Node, Threads and Sync within the audited set", function()
            local counts: {[string]: integer} = {}
            for _, raw in ipairs(assert(system.hosts.list())) do
                local host = assert(bounds.object(raw))
                local id = assert(bounds.id(host.id))
                for _, record in ipairs(assert(system.hosts.processes(id))) do
                    local item = assert(bounds.object(record))
                    local source = bounds.id(item.source) or ""
                    test.eq(DEMAND[source], nil, "idle owner: " .. source)
                    if RESIDENT[source] then counts[source] = (counts[source] or 0) + 1 end
                end
            end
            for source, name in pairs(RESIDENT) do
                test.eq(counts[source], 1, source)
                test.is_true(process.registry.lookup(name, process.registry.LOCAL) ~= nil, name)
            end
        end)
    end)
end
return test.run_cases(define_tests)
