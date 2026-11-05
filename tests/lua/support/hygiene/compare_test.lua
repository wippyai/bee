local test = require("test")
local owner = require("owner")
local process = require("process")
local channel = require("channel")
local events = require("events")
local system = require("system")
local demand = require("demand")
local owner_observer = require("owner_observer")
local ACCESS_SERVICE = "bee.gateway.service:access_service"
local ACCESS = "bee.gateway.access"
local function requester()
    local events = assert(process.events())
    assert(assert(events:receive()).kind == process.event.CANCEL)
end
local function responder(expired: string, live: string)
    owner.reply(expired, {})
    owner.reply(live, {})
end
local function define_tests()
    test.describe("Suite hygiene", function()
        test.it("keeps the inspector alive when a cancelled requester cannot receive its reply", function()
            local events = assert(process.events())
            local expired = tostring(assert(process.spawn_monitored("bee.tests.support.hygiene:requester", "bee:workers")))
            assert(process.cancel(expired, "suite cancelled"))
            while true do
                local event = assert((events:receive()))
                if event.kind == process.event.EXIT and tostring(event.from) == expired then break end
            end
            local replies = assert(process.listen("bee.test.hygiene.reply", {message = true}))
            local inspector = tostring(assert(process.spawn_monitored("bee.tests.support.hygiene:responder", "bee:workers", expired, tostring(process.pid()))))
            local answered, exited = false, false
            while not answered or not exited do
                local selected = channel.select({replies:case_receive(), events:case_receive()})
                assert(selected.ok)
                if selected.channel == replies then
                    test.eq(tostring(selected.value:from()), inspector)
                    answered = true
                elseif selected.value.kind == process.event.EXIT and tostring(selected.value.from) == inspector then
                    test.is_nil(selected.value.result and selected.value.result.error)
                    exited = true
                end
            end
            process.unlisten(replies)
        end)
        test.it("reports every resource class that exceeds the shard baseline", function()
            local before: owner.Snapshot = {processes = {resident = {source = "resident"}},
                names = {}, entries = {}, pending = {}, owners = {}}
            local after: owner.Snapshot = {processes = {resident = {source = "resident"},
                    child = {source = "fixture.child"}}, names = {fixture = "child"}, entries = {fixture = true},
                pending = {fixture = true}, owners = {fixture = true}}
            local leaks = owner.compare(before, after)
            test.eq(#leaks, 5)
            test.eq(table.concat(leaks, "\n"), "demand owner fixture\nname fixture\npending fixture\nprocess fixture.child child\nregistry fixture")
            test.eq(#owner.compare(before, before), 0)
            test.eq(#owner.compare(after, before), 0)
        end)
        test.it("accepts a replaced baseline service and rejects a second instance", function()
            local before: owner.Snapshot = {processes = {old = {source = "service", parent = "supervisor"}}, names = {}, entries = {}, pending = {}, owners = {}}
            local after: owner.Snapshot = {processes = {replacement = {source = "service", parent = "supervisor"}}, names = {}, entries = {}, pending = {}, owners = {}}
            test.eq(#owner.compare(before, after), 0)
            after.processes.extra = {source = "service", parent = "supervisor"}
            test.eq(#owner.compare(before, after), 1)
            after.processes = {replacement = {source = "service", parent = "foreign"}}
            test.eq(#owner.compare(before, after), 1)
            before.services = {service = true}
            test.eq(#owner.compare(before, after), 0)
            after.processes.extra = {source = "service", parent = "foreign"}
            test.eq(#owner.compare(before, after), 1)
        end)
        test.it("charges a retained leak once, but detects new and returning resources", function()
            local baseline: owner.Snapshot = {processes = {}, names = {}, entries = {}, pending = {}, owners = {}}
            local leaked: owner.Snapshot = {processes = {child = {source = "fixture.child"}},
                names = {fixture = "child"}, entries = {fixture = true}, pending = {fixture = true}, owners = {fixture = true}}
            local reported: {[string]: boolean} = {}
            test.eq(#owner.compare(baseline, leaked, reported), 5)
            test.eq(#owner.compare(baseline, leaked, reported), 0)
            leaked.processes.other = {source = "fixture.other"}
            test.eq(table.concat(owner.compare(baseline, leaked, reported)), "process fixture.other other")
            test.eq(#owner.compare(baseline, baseline, reported), 0)
            test.eq(#owner.compare(baseline, leaked, reported), 6)
        end)
        test.it("retires a demand owner only once the Hive supervisor acknowledges it absent, not while a start it commanded is in flight", function()
            local updates = assert(events.subscribe("supervisor", "service.update"))
            owner_observer.stopped(ACCESS_SERVICE, ACCESS, updates)
            local baseline = owner.snapshot()
            local commanding = assert(process.listen("bee.test.hive.commanding", {message = true}))
            assert(process.registry.register("bee.test.hive.commanding"))
            local ok, problem = pcall(function()
                assert(demand.wake(ACCESS))
                local held = assert((commanding:receive()))
                process.registry.unregister("bee.test.hive.commanding")
                local asking = channel.new(1)
                local settled = channel.new(1)
                local started = assert(system.supervisor.state(ACCESS_SERVICE)).started_at
                coroutine.spawn(function()
                    local asked = false
                    owner.retire(baseline, {}, updates, function()
                        if not asked then asked = true; asking:send(true) end
                    end)
                    settled:send(true)
                end)
                local first = channel.select({asking:case_receive(), settled:case_receive()})
                test.eq(first.channel, asking, "hygiene retired the owner while the Hive supervisor's start was in flight")
                assert(process.send(tostring(held:from()), "bee.test.hive.command", {}))
                assert((settled:receive()))
                test.is_nil((process.registry.lookup(ACCESS, process.registry.LOCAL)))
                local state = assert(system.supervisor.state(ACCESS_SERVICE))
                test.is_true(state.started_at ~= started, "the commanded start ran before hygiene settled")
                test.eq(state.desired, "stopped")
            end)
            process.registry.unregister("bee.test.hive.commanding")
            process.unlisten(commanding)
            updates:close()
            assert(ok, tostring(problem))
        end)
    end)
end
return {run = test.run_cases(define_tests), requester = requester, responder = responder}
