-- MIT. A registry definition change upgrades a live desktop session in place.
local test = require("test")
local process = require("process")
local channel = require("channel")
local registry = require("registry")
local time = require("time")
type Channel = channel.Channel

local workspace = "0123456789abcdef0123456789abcdef"
local function wait_for(ch: Channel<process.Message>, sender: string, topic: string): {[string]: unknown}
    local timeout = assert(time.after("8s"))
    while true do
        local selected = channel.select({ch:case_receive(), timeout:case_receive()})
        if selected.channel == timeout or not selected.ok then error("Timed out waiting for " .. topic) end
        if tostring(selected.value:from()) == sender then return selected.value:payload():data() end
    end
end
local function define_tests()
    test.describe("live session code handoff", function()
        test.it("keeps its PID, scene and queued command when its definition changes", function()
            local self = tostring(process.pid())
            local scenes = assert(process.listen("bee.desktop.scene", {message = true}))
            local acks = assert(process.listen("bee.desktop.ack", {message = true}))
            local upgraded = assert(process.listen("bee.desktop.upgraded", {message = true}))
            local events = assert(process.events())
            local child = tostring(assert(process.with_context({["bee.workspace_owner"] = self,
                ["bee.workspace_id"] = workspace}):spawn_monitored("bee.session:main", "bee:workers",
                self, 80, 24, nil, nil)))
            wait_for(scenes, child, "initial scene")
            assert(process.send(child, "bee.desktop.command", {version = 1, op = "add", id = "view",
                instance_id = "instance", workspace_id = workspace, title = "Terminal", request_id = "add"}))
            local added = wait_for(acks, child, "add acknowledgement")
            test.eq(added.request_id, "add")
            local entry = assert(registry.get("bee.session:main"))
            entry.meta.handoff_probe = "definition-changed"
            local changes = assert(registry.snapshot()):changes()
            changes:update(entry)
            local applied, apply_error = changes:apply()
            if not applied then error("Apply session definition change: " .. tostring(apply_error)) end
            local sent, send_error = process.send(child, "bee.desktop.command", {version = 1, op = "snapshot", request_id = "queued"})
            if not sent then
                local event = events:receive()
                error("Queue command during handoff: " .. tostring(send_error) .. ": "
                    .. tostring(event and event.result and event.result.error))
            end
            local ready = wait_for(upgraded, child, "upgrade readiness")
            test.eq(ready.pid, child)
            test.eq(ready.schema, 1)
            local drained = wait_for(acks, child, "queued acknowledgement")
            test.eq(drained.request_id, "queued")
            test.eq(drained.scene.windows[1].id, "view")
            process.cancel(child, "session handoff test complete")
            process.unlisten(scenes); process.unlisten(acks); process.unlisten(upgraded)
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
