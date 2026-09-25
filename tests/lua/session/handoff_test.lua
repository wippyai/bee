-- MIT. State survives a same-PID session code handoff, including queued commands.
local test = require("test")
local handoff = require("handoff")
local state = require("state")

local workspace = "0123456789abcdef0123456789abcdef"
local function fixture()
    local desktop = state.new(100, 32, nil)
    desktop = state.reduce(desktop, {version = 1, op = "add", id = "view", instance_id = "instance",
        workspace_id = workspace, title = "Terminal"})
    local bindings = {version = 1, workspace_id = workspace, revision = 2,
        items = {{tab_id = "view", instance_id = "instance", thread_id = "thread"}}}
    local queued = {{kind = "command", payload = {version = 1, op = "focus", id = "view", request_id = "pending"}}}
    return state.envelope(desktop), bindings, queued
end
local function define_tests()
    test.describe("session process handoff", function()
        test.it("round trips a versioned desktop, bindings and pending command", function()
            local desktop, bindings, queued = fixture()
            local saved = handoff.pack(workspace, desktop, 3, bindings, queued)
            local restored = assert(handoff.decode(saved, workspace))
            test.eq(restored.desktop.scene.windows[1].id, "view")
            test.eq(restored.status_revision, 3)
            test.eq(restored.bindings.revision, 2)
            test.eq(restored.queued[1].payload.request_id, "pending")
            test.eq(restored.queued[1].kind, "command")
        end)
        test.it("rejects incompatible and foreign state before replay", function()
            local desktop, bindings, queued = fixture()
            local saved = handoff.pack(workspace, desktop, 3, bindings, queued)
            saved.version = 2
            test.is_nil(handoff.decode(saved, workspace))
            saved.version = 1
            test.is_nil(handoff.decode(saved, "ffffffffffffffffffffffffffffffff"))
            saved.workspace_id = workspace
            queued[1].payload = {version = 1, op = "delete_everything"}
            test.is_nil(handoff.decode(saved, workspace))
        end)
        test.it("refuses an unbounded pending queue", function()
            local desktop, bindings, queued = fixture()
            for index = 2, 129 do queued[index] = queued[1] end
            test.is_nil(handoff.decode(handoff.pack(workspace, desktop, 3, bindings, queued), workspace))
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
