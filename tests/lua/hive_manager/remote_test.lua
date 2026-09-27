-- MIT. The Hive Manager's remote view: the view process's state and frames are
-- decoded strictly, Alt+Q leaves, only a controlling view forwards input and
-- a mouse row moves below the title row.
local test = require("test")
local remote = require("remote")
local appearance = require("appearance")
type Object = {[string]: unknown}
local WORKSPACE = string.rep("b", 32)
local DISPLAY = string.rep("c", 32)
local function view(mode: "control" | "observe"): remote.View
    return {pid = "{local@bee.hive.desktop:display_host|7}", node_id = "forge", node_label = "Forge", workspace_id = WORKSPACE,
        desktop_id = DISPLAY, mode = mode, session_id = "session-1", rows = {}, cursor = nil, leaving = false}
end
local function define_tests()
    test.describe("Hive Manager remote view", function()
        test.it("decodes the view's attached or failed state and nothing else", function()
            local attached = remote.state({version = 1, state = "attached", session_id = "session-1", mode = "control",
                workspace_id = WORKSPACE, desktop_id = DISPLAY, owner_execution = string.rep("e", 32)})
            test.eq(attached.kind, "attached")
            if attached.kind == "attached" then
                test.eq(attached.attached.session_id, "session-1")
                test.eq(attached.attached.mode, "control")
            end
            local failed = remote.state({version = 1, state = "failed", code = "DENIED", message = "not admitted"})
            test.eq(failed.kind, "failed")
            if failed.kind == "failed" then
                test.eq(failed.failure.code, "DENIED")
                test.eq(failed.failure.message, "not admitted")
            end
            local malformed = remote.state({version = 1, state = "attached", session_id = "session-1", mode = "mirror",
                workspace_id = WORKSPACE, desktop_id = DISPLAY, owner_execution = string.rep("e", 32)})
            test.eq(malformed.kind, "failed")
            if malformed.kind == "failed" then test.eq(malformed.failure.code, "INVALID_STATE") end
            local unversioned = remote.state({state = "attached"})
            test.eq(unversioned.kind, "failed")
            if unversioned.kind == "failed" then test.eq(unversioned.failure.code, "INVALID_STATE") end
        end)
        test.it("accepts bounded frames only", function()
            local frame = remote.frame({version = 1, rows = {"one", "two"}, cursor = {x = 3, y = 1, visible = true}}, 8, 4)
            test.eq(frame.kind, "valid")
            if frame.kind == "valid" then
                test.eq(#frame.frame.rows, 2)
                test.eq(frame.frame.cursor.x, 3)
            end
            test.eq(remote.frame({version = 1, rows = {"one", 2}}, 8, 4).kind, "invalid")
            local many: {string} = {}
            for index = 1, remote.MAX_ROWS + 1 do many[index] = tostring(index) end
            test.eq(remote.frame({version = 1, rows = many}, 8, 4).kind, "invalid")
            test.eq(remote.frame({version = 1, rows = {[1] = "one", [3] = "three"}}, 8, 4).kind, "invalid")
            test.eq(remote.frame({version = 1, rows = {"one\27[2J"}}, 8, 4).kind, "invalid")
            test.eq(remote.frame({version = 1, rows = {"one"}, cursor = {x = 8, y = 0, visible = true}}, 8, 4).kind, "invalid")
            test.eq(remote.frame({version = 1, rows = {"one"}, cursor = {x = 0, y = 4, visible = true}}, 8, 4).kind, "invalid")
            local large = string.rep("x", remote.MAX_ROW_BYTES)
            local oversized = {large, large, large, large, large, large, large, large, large, large, large, large,
                large, large, large, large, large, large, large, large, large, large, large, large, large, large,
                large, large, large, large, large, large, large, large}
            test.eq(remote.frame({version = 1, rows = oversized}, 8, 4).kind, "invalid")
            test.eq(remote.frame({version = 2, rows = {}}, 8, 4).kind, "invalid")
        end)
        test.it("leaves on Alt+Q and forwards input only while controlling", function()
            local control = view("control")
            test.eq((remote.forward(control, {type = "key", key = "q", alt = true, action = "press"})), "leave")
            local decision, forwarded = remote.forward(control, {type = "key", key = "a", action = "press"})
            test.eq(decision, "forward")
            test.eq(forwarded and forwarded.key, "a")
            local clicked, moved = remote.forward(control, {type = "mouse", x = 4, y = 5, button = "left", action = "press"})
            test.eq(clicked, "forward")
            test.eq(moved and moved.y, 4)
            test.eq((remote.forward(control, {type = "mouse", x = 4, y = 1, button = "left", action = "press"})), "drop")
            test.eq((remote.forward(control, {type = "resize", width = 10, height = 10})), "drop")
            local observe = view("observe")
            test.eq((remote.forward(observe, {type = "key", key = "a", action = "press"})), "drop")
            test.eq((remote.forward(observe, {type = "key", key = "q", alt = true, action = "press"})), "leave")
            control.leaving = true
            test.eq((remote.forward(control, {type = "key", key = "a", action = "press"})), "drop")
        end)
        test.it("draws a title row above the remote rows", function()
            local shown: remote.View = {pid = "{local@bee.hive.desktop:display_host|7}", node_id = "forge", node_label = "Forge",
                workspace_id = WORKSPACE, desktop_id = DISPLAY, mode = "control", session_id = "session-1",
                rows = {"row one", "row two"}, cursor = {x = 2, y = 1, visible = true}, leaving = false}
            local drawn = remote.draw(60, 4, appearance.defaults(), shown)
            test.eq(#drawn.rows, 4)
            test.is_true(drawn.rows[1]:find("REMOTE", 1, true) ~= nil)
            test.is_true(drawn.rows[1]:find("Alt+Q leave", 1, true) ~= nil)
            test.eq(drawn.rows[2], "row one")
            test.eq(drawn.rows[4], "")
            test.eq(drawn.cursor.y, 2)
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
