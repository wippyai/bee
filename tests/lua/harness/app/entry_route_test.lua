local test = require("test")
local registry = require("registry")
local process = require("process")
local tty = require("tty")
local function replace(entry)
    local changes = assert(registry.snapshot()):changes()
    changes:update(entry)
    assert(changes:apply())
end
return test.run_cases(function()
    test.describe("Agents native execution handoff", function()
        test.it("keeps the broker PID and terminal for selection, direct and restored launches", function()
            local selection = assert(registry.get("bee.harness.app:selection"))
            local execution = assert(registry.get("bee.harness.app:execution"))
            local selection_probe = assert(registry.get("bee.tests.harness.app:selection_probe"))
            local execution_probe = assert(registry.get("bee.tests.harness.app:execution_probe"))
            selection_probe.id, execution_probe.id = selection.id, execution.id
            replace(selection_probe)
            replace(execution_probe)
            local ready = assert(process.listen("bee.test.route.ready", {message = true}))
            local events = assert(process.events())
            local owned: string? = nil
            local view: tty.Viewport? = nil
            local ok, failure = pcall(function()
                for _, case in ipairs({
                    {arguments = {}, resume_state = "", route = "selection"},
                    {arguments = {"--session", "session"}, resume_state = "", route = "selection"},
                    {arguments = {"driver:definition"}, resume_state = "", route = "execution"},
                    {arguments = {}, resume_state = "{}", route = "execution"},
                }) do
                    local terminal = assert(tty.viewport({width = 80, height = 12}))
                    view = terminal
                    local self = tostring(process.pid())
                    local pid = assert(process.with_options({terminal = assert(terminal:grant())}):spawn_monitored(
                        "bee.harness.app:app", "bee:workers", {version = 1,
                            broker_pid = self, workspace_pid = self, workspace_id = string.rep("a", 32),
                            instance_id = "route", view_id = "route", definition_id = "bee.harness.app:app",
                            execution_generation = 1, definition_revision = "1", registry_revision = "1",
                            launch_token = "route", resume_schema = "bee.agent.window@1",
                            resume_state = case.resume_state, arguments = case.arguments}))
                    owned = tostring(pid)
                    local message = assert((ready:receive()))
                    local result = message:payload():data()
                    test.eq(result.pid, tostring(pid))
                    test.eq(result.route, case.route)
                    local frame = assert(terminal:snapshot())
                    test.is_true(table.concat(frame.rows, "\n"):find("routed " .. case.route, 1, true) ~= nil)
                    assert(process.send(pid, "bee.test.route.release", {}))
                    local event = assert((events:receive()))
                    test.eq(event.kind, process.event.EXIT)
                    test.eq(tostring(event.from), tostring(pid))
                    owned = nil
                    terminal:close()
                    view = nil
                end
            end)
            if owned then process.terminate(owned) end
            if view then view:close() end
            process.unlisten(ready)
            replace(selection)
            replace(execution)
            if not ok then error(failure) end
        end)
    end)
end)
