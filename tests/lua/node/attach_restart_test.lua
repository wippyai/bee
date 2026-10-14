-- SPDX-License-Identifier: MIT
local test = require("test")
local process = require("process")
local channel = require("channel")
local system = require("system")
local tty = require("tty")
local time = require("time")
local client = require("client")
local sql = require("sql")

local function run(options: unknown)
    return test.run_cases(function()
        test.describe("Display attachment after a state-writing boot", function()
            test.it("follows an owner replaced before its first watch reply", function()
                local db = assert(sql.get("bee:db"))
                local writer = assert(db:query("SELECT id FROM _migrations WHERE id = 'bee.persist:state_writer'"))
                db:release()
                test.eq(#writer, 1)
                local held = assert(process.listen("bee.test.display.snapshot", {message = true}))
                local ready = assert(process.listen("bee.test.node.ready", {message = true}))
                local lifecycle = assert(process.events())
                assert(process.registry.register("bee.test.display.snapshot"))
                assert(process.registry.register("bee.test.node.ready"))
                local view = assert(tty.viewport({width = 100, height = 30}))
                local display = tostring(assert(process.with_options({terminal = assert(view:grant())})
                    :spawn_monitored("bee.shell:client", "bee:workers", assert(system.node.id()))))
                local ok, problem = pcall(function()
                    local old = tostring(assert((held:receive())):from())
                    assert(process.monitor(old))
                    assert(process.terminate(old))
                    while true do
                        local event = assert((lifecycle:receive()))
                        if event.kind == process.event.EXIT and tostring(event.from) == old then break end
                    end
                    assert(process.registry.unregister("bee.test.display.snapshot"))
                    local replacement = tostring(assert((ready:receive())):from())
                    test.neq(replacement, old)
                    local updates = assert(view:updates())
                    local deadline = time.after("10s")
                    while true do
                        local snapshot = view:snapshot()
                        local screen = snapshot and table.concat(snapshot.rows, "\n") or ""
                        if screen:find("Desktop 1", 1, true) then break end
                        local selected = channel.select({updates:case_receive(), lifecycle:case_receive(), deadline:case_receive()})
                        assert(selected.channel ~= deadline, "replacement owner is ready but display stays at\n" .. screen)
                        if selected.channel == lifecycle then
                            assert(selected.value.kind ~= process.event.EXIT or tostring(selected.value.from) ~= display,
                                "display exits during attachment")
                        end
                    end
                end)
                process.registry.unregister("bee.test.display.snapshot")
                assert(process.registry.unregister("bee.test.node.ready"))
                assert(process.cancel(display))
                while true do
                    local event = assert((lifecycle:receive()))
                    if event.kind == process.event.EXIT and tostring(event.from) == display then break end
                end
                view:close()
                process.unlisten(held)
                process.unlisten(ready)
                assert(client.call(assert(system.node.id()), "leave", {}))
                assert(ok, tostring(problem))
            end)
        end)
    end)(options)
end

return {run = run}
