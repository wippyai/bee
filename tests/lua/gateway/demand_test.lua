-- SPDX-License-Identifier: MIT
local test = require("test")
local process = require("process")
local registry = require("registry")
local protocol = require("protocol")
local system = require("system")
local events = require("events")
local channel = require("channel")
local time = require("time")
local effects = require("effects")
local funcs = require("funcs")
local security = require("security")
local uuid = require("uuid")
local demand = require("demand")
local owner_observer = require("owner_observer")
local bounds = require("bounds")
local gateway = require("gateway")
local NAME = "bee.gateway.external"
local SERVICE = "bee.gateway.service:external_service"
local function value(raw: unknown): {[string]: unknown}
    local reply = assert(bounds.object(raw))
    if reply.ok ~= true then error(tostring((bounds.object(reply.error) or {}).message)) end
    return assert(bounds.object(reply.value))
end
local function define_tests()
    test.describe("Gateway demand", function()
        test.it("probes both registered consumer queues under their separate execution scopes", function()
            test.eq(type(effects.pending()), "boolean")
        end)
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
        test.it("serves a parked call when demand readiness precedes Hive readiness", function()
            assert(process.registry.register("bee.test.hive.demand_ready"))
            local reply, problem = protocol.call(assert(system.node.id()), "mcp.connect", {name = "invalid", workspace_id = "absent"}, "5s")
            process.registry.unregister("bee.test.hive.demand_ready")
            test.eq(problem, nil)
            test.is_true(reply ~= nil and reply.ok)
        end)
        test.it("restarts a stopped owner when readiness delivery loses its process", function()
            local held = assert(process.listen("bee.test.hive.delivery_stop", {message = true}))
            local updates = assert(events.subscribe("supervisor", "service.update"))
            assert(process.registry.register("bee.test.hive.delivery_stop"))
            local completed = channel.new(1)
            coroutine.spawn(function()
                local reply, problem = protocol.call(assert(system.node.id()), "mcp.connect", {name = "invalid", workspace_id = "absent"}, "5s")
                completed:send({reply = reply, problem = problem})
            end)
            local deadline = time.after("5s")
            local selected = channel.select({held:case_receive(), deadline:case_receive()})
            test.eq(selected.channel, held, "readiness delivery does not reach its barrier")
            local supervisor = tostring(selected.value:from())
            test.eq(supervisor, tostring(assert(process.registry.lookup(protocol.SUPERVISOR, process.registry.LOCAL))))
            assert(events.send("supervisor", "service.stop", "bee.gateway.service:external_service"))
            while true do
                local owner = assert(system.supervisor.state("bee.gateway.service:external_service"))
                if owner.desired == "stopped" and (owner.status == "stopped" or owner.status == "exited") then break end
                selected = channel.select({updates:channel():case_receive(), deadline:case_receive()})
                test.neq(selected.channel, deadline, "owner does not complete its stop")
            end
            assert(process.send(supervisor, "bee.test.hive.delivery_release", {}))
            process.unlisten(held)
            updates:close()
            local result = assert((completed:receive()))
            process.registry.unregister("bee.test.hive.delivery_stop")
            test.eq(result.problem, nil)
            test.is_true(result.reply ~= nil and result.reply.ok)
        end)
        test.it("wakes from the approval owner's effect dispatch and declares no change tables", function()
            local declared: {[string]: unknown}? = nil
            for _, entry in ipairs(registry.find({["meta.type"] = "bee.process.demand"}) or {}) do
                if entry.meta.demand.name == NAME then declared = entry.meta.demand end
            end
            test.is_nil(assert(declared).tables, "the gateway owner watches change tables")
            owner_observer.stopped(SERVICE, NAME)
            local accepted = assert(process.listen(demand.ACCEPTED, {message = true}))
            local id = assert(uuid.v7())
            local sent, problem = demand.dispatch(NAME, {request_id = id, topic = "bee.approvals.wake", effect = {}})
            test.is_true(sent, tostring(problem))
            local selected = channel.select({accepted:case_receive(), time.after("5s"):case_receive()})
            process.unlisten(accepted)
            test.eq(selected.channel, accepted, "the absent owner does not take the approval owner's dispatch")
            test.eq(assert(bounds.object(selected.value:payload():data())).request_id, id)
            owner_observer.stopped(SERVICE, NAME)
        end)
        test.it("serves a pairing decided while its owner is absent", function()
            value(gateway.open({address = assert(gateway.endpoint())}))
            local node = assert(system.node.id())
            local workspaces = assert(protocol.await(node, "node.workspaces", {}))
            local workspace = assert(bounds.id(assert(bounds.object(workspaces.value)).home))
            local pairing = value(assert(protocol.await(node, "mcp.connect", {name = "Absent owner", workspace_id = workspace})).value)
            owner_observer.stopped(SERVICE, NAME)
            local approver = funcs.new():with_actor(security.new_actor("bee.application:" .. workspace .. ":mcp-approver",
                {workspace_id = workspace, definition_id = "bee.approvals.inbox.app:app"}))
            local approval = value(approver:call("bee.approvals.binding:read", {approval_id = pairing.approval_id}))
            value(approver:call("bee.approvals.binding:decide", {approval_id = pairing.approval_id, expected_revision = approval.revision,
                proposal_digest = approval.proposal_digest, reviewed_digest = approval.reviewed_digest, decision = "approved"}))
            local finished = assert(protocol.await(node, "mcp.wait", {client_id = pairing.client_id}))
            test.is_true(finished.ok == true)
            local connection = value(finished.value)
            test.eq(connection.status, "connected")
            test.is_true(type(connection.token) == "string")
            local manager = funcs.new():with_actor(security.new_actor("bee.application:" .. workspace .. ":mcp-manager",
                {workspace_id = workspace, definition_id = "bee.gateway.app:app"}))
            value(manager:call("bee.gateway.binding:external_call", {operation = "revoke", client_id = pairing.client_id}))
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
