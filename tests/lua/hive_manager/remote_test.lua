-- MIT. The Hive Manager's remote view: the view process's state and frames are
-- decoded strictly, Alt+Q leaves, only a controlling view forwards input and
-- a mouse row moves below the title row.
local test = require("test")
local remote = require("remote")
local model = require("model")
local directory = require("directory")
local types = require("types")
local desktop_remote = require("desktop_remote")
local display = require("display")
local appearance = require("appearance")
type Object = {[string]: unknown}
local WORKSPACE = string.rep("b", 32)
local DISPLAY = string.rep("c", 32)
local OWNER = string.rep("a", 32)
type Receipt = {signature: string, handle: display.Handle}
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
        test.it("passes the confirmed manager key to one remote desktop attach across an uncertain reply", function()
            local state = model.new({})
            local member: directory.Member = {node_id = "forge", is_local = false, addr = "10.0.0.2:7946", client_only = false}
            model.apply_members(state, {member}, nil, 0)
            model.apply_presence(state, "forge", types.reply_ok("presence", {protocol_revision = types.REVISION,
                node_id = "forge", role = "member", cluster_size = 1, sampled_at = "2026-01-02T03:04:05.006Z"}))
            local catalog: directory.Catalog = {available = true, reason = "", workspaces = {{workspace_id = WORKSPACE, label = "Main", served = true}}, next_after = nil}
            model.apply_catalog(state, "forge", catalog)
            model.select_node(state, "forge")
            model.select_workspace(state, WORKSPACE)
            local intent = model.attach_intent(state, "control", "confirmed-manager-key")
            if not intent then error("confirmed manager attach is missing") end

            local receipts: {[string]: Receipt} = {}
            local owner_operations = 0
            local opened: {{key: string, desktop_id: string}} = {}
            local uncertain = true
            local operations: desktop_remote.Operations = {
                list = function(): types.Reply
                    return types.reply_ok("list", {owner_execution = OWNER, desktops = {{desktop_id = DISPLAY, is_default = true}}})
                end,
                create = function(_execution: string, _id: string): types.Reply
                    error("a listed display should be reused")
                end,
                open = function(target: display.Target, key: string): (display.Handle?, display.Fault?)
                    opened[#opened + 1] = {key = key, desktop_id = target.desktop_id}
                    local signature = target.owner_execution .. target.workspace_id .. target.desktop_id .. target.mode
                    local receipt = receipts[key]
                    if receipt then
                        if receipt.signature ~= signature then return nil, {code = "CONFLICT", message = "key changed attach"} end
                        return receipt.handle, nil
                    end
                    owner_operations = owner_operations + 1
                    local handle: display.Handle = {id = "session-1"}
                    receipts[key] = {signature = signature, handle = handle}
                    if uncertain then
                        uncertain = false
                        return nil, {code = "UNCERTAIN", message = "attach completed but reply was lost"}
                    end
                    return handle, nil
                end,
                new_id = function(): string return string.rep("d", 32) end,
            }
            local selected, failure, target = desktop_remote.choose(operations, intent.node_id, intent.workspace_id,
                intent.mode, intent.idempotency_key)
            test.is_nil(selected)
            test.eq(failure and failure.code, "UNCERTAIN")
            test.not_nil(target)
            model.apply_outcome(state, intent, {ok = false, code = "UNCERTAIN", message = "attach result is unknown"})
            local pending = model.pending_intent(state)
            test.not_nil(pending)
            if not target then error("uncertain operation lost its target") end
            local handle, replay_error = operations.open(target, pending and pending.idempotency_key or "")
            test.is_nil(replay_error)
            test.not_nil(handle)
            test.eq(owner_operations, 1)
            test.eq(#opened, 2)
            test.eq(opened[1].key, intent.idempotency_key)
            test.eq(opened[2].key, intent.idempotency_key)
            test.eq(opened[1].desktop_id, DISPLAY)
            test.eq(opened[2].desktop_id, DISPLAY)
            if not handle or not target then error("remote attach replay did not produce a session") end
            model.apply_outcome(state, intent, {ok = true, code = "", message = "", session_id = handle.id,
                mode = intent.mode, viewer = "{local@bee.hive.desktop:display_host|9}", owner_execution = target.owner_execution})
            test.is_nil(model.pending_intent(state))
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
