local test = require("test")
local channel = require("channel")
local time = require("time")
local directory = require("directory")
return test.run_cases(function()
    test.describe("Agent directory reads", function()
        test.it("starts independent reads before any of them completes", function()
            local started = channel.new(3)
            local release = channel.new(3)
            local finished = channel.new(1)
            local function begin(name: string)
                started:send(name)
                release:receive()
            end
            coroutine.spawn(function()
                local rows, names, err = directory.load({
                    directory = function() begin("sessions"); return {}, nil end,
                    peers = function() begin("peers"); return {ok = true, value = {items = {}}}, nil end,
                    workspace = function() begin("workspace"); return {label = "Home", folder = "/"} end,
                }, "home", nil, false)
                finished:send({count = #rows, label = names.home.label, error = err})
            end)
            local seen = {}
            local deadline = time.after("1s")
            for _ = 1, 3 do
                local event = channel.select({started:case_receive(), deadline:case_receive()})
                test.is_true(event.channel == started, "directory serialized independent reads")
                seen[event.value] = true
            end
            test.is_true(seen.sessions and seen.peers and seen.workspace)
            for _ = 1, 3 do release:send(true) end
            local result = finished:receive()
            test.eq(result.count, 0)
            test.eq(result.label, "Home")
            test.is_true(result.error == nil)
        end)
    end)
end)
