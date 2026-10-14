-- SPDX-License-Identifier: MIT
local test = require("test")
local process = require("process")
local events = require("events")
local system = require("system")
local channel = require("channel")
local time = require("time")
local protocol = require("protocol")
local uuid = require("uuid")
local SERVICE = "bee.tests.process:transaction_service"
local function define_tests()
    test.describe("Demand during a runtime registry transaction", function()
        test.it("serves dormant owner demand after the registry transaction closes", function()
            local updates = assert(events.subscribe("supervisor", "service.update"))
            local deadline = time.after("5s")
            while true do
                local current = assert(system.supervisor.state(SERVICE))
                if current.status == "stopped" or current.status == "exited" or current.status == "unknown" then break end
                local selected = channel.select({updates:channel():case_receive(), deadline:case_receive()})
                assert(selected.channel ~= deadline, "Transaction owner is not dormant")
            end
            test.is_nil((process.registry.lookup("bee.test.transaction.owner", process.registry.LOCAL)))
            local commands = assert(process.listen("bee.test.transaction.command", {message = true}))
            local running = assert(process.listen("bee.test.transaction.running", {message = true}))
            assert(process.registry.register("bee.test.transaction.demand"))
            local running_updates = assert(events.subscribe("supervisor", "service.update"))
            local open = false
            local ok, problem = pcall(function()
                -- Drive the real registry transaction lifecycle protocol. Both
                -- registry events and the owner's start go through ONE FIFO
                -- runtime subscriber and action queue, so scheduling cannot
                -- move the start outside begin/commit. No runtime is patched.
                assert(events.send("registry", "registry.begin", "bee.test.transaction"))
                open = true
                local completed = channel.new(1)
                local request_id = assert(uuid.v7())
                coroutine.spawn(function()
                    -- This production primitive subscribes before sending and
                    -- waits for the served reply, with an event-driven deadline.
                    local reply, fault = protocol.call(assert(system.node.id()), "transaction.serve",
                        {request_id = request_id}, "3s")
                    completed:send({reply = reply, fault = fault})
                end)
                local selected = channel.select({commands:case_receive(), deadline:case_receive()})
                assert(selected.channel == commands, "dormant owner did not submit its start")
                local command = selected.value:payload():data()
                test.eq(command.action, "start")
                test.eq(command.phase, "starting")
                -- Routed Hive calls stay in Hive's parked queue until ready.
                test.eq(command.queued, 0)
                local supervisor = tostring(assert(process.registry.lookup(protocol.SUPERVISOR, process.registry.LOCAL)))
                test.eq(tostring(selected.value:from()), supervisor)
                assert(events.send("registry", "registry.commit", "bee.test.transaction"))
                open = false
                local result = assert((completed:receive()))
                selected = channel.select({running:case_receive(), deadline:case_receive()})
                assert(selected.channel == running, "owner never reached running before demand delivery")
                local owner = selected.value:payload():data()
                local current = assert(system.supervisor.state(SERVICE))
                assert(result.fault == nil, "demand unserved after transaction: owner=" .. owner.phase
                    .. ", queued=" .. tostring(owner.queued) .. ", parked=" .. tostring(owner.parked) .. ", runtime=" .. current.status
                    .. "/" .. current.desired .. ", call=" .. tostring(result.fault))
                test.is_true(result.reply ~= nil and result.reply.ok)
                test.eq(assert(assert(result.reply).value).request_id, request_id)
                test.eq(owner.queued, 0)
                test.eq(owner.parked, 0)
                test.eq(owner.phase, "ready")
                -- Readiness and a served reply can precede publication of the
                -- runtime's running state. Observe that real transition even
                -- when the quiet worker has already stopped by the next read.
                while true do
                    selected = channel.select({running_updates:channel():case_receive(), deadline:case_receive()})
                    assert(selected.channel ~= deadline, "runtime never published running for the demanded service")
                    local event = selected.value
                    if event.path == SERVICE and type(event.data) == "table" and event.data.status == "running" then
                        test.eq(event.data.desired, "running")
                        break
                    end
                end
                while true do
                    local current = assert(system.supervisor.state(SERVICE))
                    if current.desired == "stopped" and (current.status == "stopped" or current.status == "exited")
                        and not process.registry.lookup("bee.test.transaction.owner", process.registry.LOCAL) then break end
                    local selected = channel.select({running_updates:channel():case_receive(), deadline:case_receive()})
                    assert(selected.channel ~= deadline, "transaction owner did not stop after serving demand")
                end
            end)
            if open then assert(events.send("registry", "registry.discard", "bee.test.transaction")) end
            process.registry.unregister("bee.test.transaction.demand")
            process.unlisten(commands)
            process.unlisten(running)
            updates:close()
            running_updates:close()
            assert(ok, problem)
        end)
    end)
end
return test.run_cases(define_tests)
