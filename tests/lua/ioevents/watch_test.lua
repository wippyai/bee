-- MIT. A granted watch delivers native change notices through the scheduler.
local test = require("test")
local fs = require("fs")
local ioevents = require("ioevents")
local channel = require("channel")
local time = require("time")

local VOLUME = "bee.tests.ioevents:watched"

local function define_tests()
    test.describe("ioevents watch", function()
        test.it("reports a rescan, then the change to a file written in the watched folder", function()
            local volume = assert(fs.get(VOLUME))
            local name = "changed-" .. tostring(time.now():unix_nano()) .. ".txt"
            local opened, err = ioevents.watch(VOLUME, ".")
            test.is_nil(err)
            local watch = assert(opened)
            local events = watch:channel()
            local deadline = time.after("10s")
            local rescanned, changed, written = false, false, false
            while not changed do
                local selected = channel.select({events:case_receive(), deadline:case_receive()})
                test.is_true(selected.ok and selected.channel == events)
                local event = selected.value
                test.eq(event.resource, VOLUME)
                if event.kind == "rescan" then
                    rescanned = true
                    if not written then
                        assert(volume:writefile("/" .. name, "native change\n"))
                        written = true
                    end
                elseif event.kind == "change" and event.path == name then
                    changed = true
                end
            end
            test.is_true(rescanned)
            test.is_true(watch:close())
            test.is_true(watch:close())
            assert(volume:remove("/" .. name))
        end)
        test.it("refuses a path outside the volume", function()
            local watch, err = ioevents.watch(VOLUME, "../outside")
            test.is_nil(watch)
            test.not_nil(err)
        end)
    end)
end

return test.run_cases(define_tests)
