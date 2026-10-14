local test = require("test")
local owner = require("owner")
local process = require("process")
local channel = require("channel")
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
    end)
end
return {run = test.run_cases(define_tests), requester = requester, responder = responder}
