-- MIT. UI keys never substitute for native workspace/application identities.
local test = require("test")
local inbox = require("inbox")
local workspace = "0123456789abcdef0123456789abcdef"
local function define_tests()
    test.describe("Client question projection", function()
        test.it("translates local tabs while preserving answer identity and correlation", function()
            local state = inbox.new(workspace, "connection")
            local targets = {{tab_id = "local-tab", workspace_id = workspace, view_id = "native-view", instance_id = "instance"}}
            test.is_true(inbox.select(state, targets))
            test.is_false(inbox.select(state, targets))
            local selection = inbox.selection(state)
            test.eq(selection.targets[1].id, "native-view")
            local snapshot = {version = 1, workspace_id = workspace, connection_id = "connection",
                selection_revision = selection.revision, revision = 4, items = {{version = 1, request_id = "question",
                    id = "native-view", instance_id = "instance", kind = "text", title = "Name", message = "", accept = "Save", initial = ""}}}
            test.is_true(inbox.observe(state, snapshot))
            test.eq(state.items[1].id, "local-tab")
            test.eq(snapshot.items[1].id, "native-view")
            local response = inbox.answer(state, {version = 1, request_id = "question", id = "local-tab",
                instance_id = "instance", action = "accept", value = "hello"})
            if not response then error("Expected selected answer") end
            test.eq(response.id, "native-view")
            test.eq(response.selection_revision, selection.revision)
            test.eq(response.workspace_id, workspace)
            local receipt = {version = 1, workspace_id = workspace, connection_id = "connection", request_id = "question",
                id = "wrong-view", instance_id = "instance", error_code = "delivery_failed", error = "retry"}
            test.is_nil(inbox.result(state, receipt))
            receipt.id = "native-view"
            local result = inbox.result(state, receipt)
            if not result then error("Expected correlated receipt") end
            test.eq(result.id, "local-tab")
            test.eq(result.error_code, "delivery_failed")
            test.not_nil(inbox.answer(state, {version = 1, request_id = "question", id = "local-tab",
                instance_id = "instance", action = "cancel", value = ""}))
        end)
        test.it("rejects stale streams and clears delivery on selection changes", function()
            local state = inbox.new(workspace, "connection")
            assert(inbox.select(state, {{tab_id = "tab", workspace_id = workspace, view_id = "view", instance_id = "instance"}}))
            local snapshot = {version = 1, workspace_id = workspace, connection_id = "connection",
                selection_revision = 1, revision = 2, items = {{version = 1, request_id = "question", id = "view",
                    instance_id = "instance", kind = "confirm", title = "Close", message = "", accept = "Close", initial = ""}}}
            test.is_true(inbox.observe(state, snapshot))
            snapshot.revision = 1
            test.is_false(inbox.observe(state, snapshot))
            snapshot.revision = 3; snapshot.connection_id = "other"
            test.is_false(inbox.observe(state, snapshot))
            snapshot.connection_id = "connection"
            test.is_true(inbox.select(state, {}))
            test.eq(#state.items, 0)
            test.is_false(inbox.observe(state, snapshot))
            test.is_nil(inbox.answer(state, {version = 1, request_id = "question", id = "tab",
                instance_id = "instance", action = "accept", value = ""}))
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
