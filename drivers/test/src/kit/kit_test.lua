local test = require("test")
local fs = require("fs")
local kit = require("kit")
local isolations = require("isolations")

local function recording(path: string): string
    local volume = assert(fs.get("bee.drivers.tests:fixtures"))
    return assert(volume:readfile(path))
end

local function define_tests()
    test.describe("Driver kit", function()
        test.it("lists the activated drivers with their profiles and declared options", function()
            local drivers = assert(kit.catalog())
            local ids: {string} = {}
            for _, driver in ipairs(drivers) do ids[#ids + 1] = driver.driver_id end
            test.eq(table.concat(ids, ","), "agy,claude,codex,grok,muse,opencode")
            local claude = drivers[2]
            test.eq(claude.binding_ref, "bee.drivers.claude.binding:binding")
            test.eq(claude.title, "Claude Code")
            test.eq(claude.descriptor_ref, "bee.drivers.claude.descriptor:cli")
            test.not_nil(claude.options.model)
            local modes: {[string]: boolean} = {}
            for _, profile in ipairs(claude.profiles) do modes[profile.mode] = true end
            test.is_true(modes.batch == true)
        end)
        test.it("prepares a declarative launch through the binding for a placement isolation", function()
            local launch = assert(kit.prepare("bee.drivers.claude.binding:binding",
                {profile_id = "batch", brief = "say pong", model = "sonnet", isolation = isolations.DOCKER}))
            test.eq(launch.executable, "claude")
            local argv = table.concat(launch.argv :: {string}, " ")
            test.is_true(argv:find("--model sonnet", 1, true) ~= nil, argv)
            test.is_true(argv:find("stream-json", 1, true) ~= nil, argv)
        end)
        test.it("refuses a binding the host did not activate", function()
            local launch, err = kit.prepare("bee.drivers.tests:not_a_binding", {profile_id = "batch", brief = "x"})
            test.is_nil(launch)
            test.is_true(tostring(err):find("is not activated", 1, true) ~= nil, tostring(err))
        end)
        test.it("folds a recorded output stream fed in chunks into records and one terminal report", function()
            local stream = kit.stream("bee.drivers.claude.binding:binding", false)
            local content = recording("/claude/stream-json-2/plain.jsonl")
            local observations = 0
            local terminal = nil
            for offset = 1, #content, 37 do
                local step = assert(stream:feed(content:sub(offset, offset + 36)))
                observations = observations + #step.observations
                terminal = step.terminal or terminal
            end
            local last = assert(stream:finish())
            terminal = terminal or last.terminal
            test.is_true(observations > 0)
            test.eq(assert(terminal).outcome, "succeeded")
            test.eq(assert(terminal).answer, "pong")
        end)
    end)
end

return test.run_cases(define_tests)
