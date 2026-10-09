-- SPDX-License-Identifier: MIT
local test = require("test")
local registry = require("registry")
local protocol = require("protocol")
local system = require("system")
local events = require("events")
local channel = require("channel")
local time = require("time")
local function define_tests()
    test.describe("Gateway demand", function()
        test.it("starts the routed owner while absent and stops after the call drains", function()
            local found = false
            for _, entry in ipairs(registry.find({["meta.type"] = "bee.process.demand"}) or {}) do
                if entry.meta.demand.name == "bee.gateway.external" then found = true end
            end
            test.eq(found, true)
            local updates = assert(events.subscribe("supervisor", "service.update"))
            local reply, problem = protocol.call(assert(system.node.id()), "mcp.connect", {name = "invalid", workspace_id = "absent"}, "5s")
            test.eq(problem, nil)
            test.is_true(reply ~= nil and reply.ok)
            local deadline = time.after("5s")
            while true do
                local owner = assert(system.supervisor.state("bee.gateway.service:external_service"))
                if owner.desired == "stopped" and (owner.status == "stopped" or owner.status == "exited") then break end
                local selected = channel.select({updates:channel():case_receive(), deadline:case_receive()})
                if selected.channel == deadline then error("gateway does not stop: " .. tostring(owner.status) .. "/" .. tostring(owner.desired)) end
            end
            updates:close()
        end)
        test.it("keeps installation and publication scopes separate", function()
            local count = 0
            for _, entry in ipairs(registry.find({["meta.type"] = "bee.gateway.effect_scope"}) or {}) do
                local data = entry.data
                test.is_true(data.kind == "installation" or data.kind == "publication")
                for _, id in ipairs(data.policies) do
                    if data.kind == "installation" then test.neq(id, "bee.gateway.security:publication_queue_policy")
                    else test.neq(id, "bee.gateway.security:installation_apply_policy") end
                end
                count = count + 1
            end
            test.eq(count, 2)
        end)
    end)
end
return test.run_cases(define_tests)
