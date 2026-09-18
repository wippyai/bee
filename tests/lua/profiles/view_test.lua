-- MIT. Exercise form input, confirmation and bounded hit regions.
local test = require("test")
local view = require("view")
local editor = require("editor")
local appearance = require("appearance")
local function state(): view.State
    local draft, err = editor.new({title = "Agent", definition_ref = "host:agent", options = {},
        mcp_tools = {"thread_read"}, instructions = ""}, {options = {}, mcp_tools = {"thread_read"}, instructions = true})
    if not draft then error(tostring(err)) end
    return view.new({workspace_id = "workspace", profile_id = "profile", revision = 1, draft = draft, save_key = "save", remove_key = "remove"})
end
local function define_tests()
    test.describe("Agent profile form input", function()
        test.it("edits text, preserves UTF-8 on backspace and prepares a save without I/O", function()
            local s = state()
            local frame = view.draw(60, 16, appearance.defaults(), s)
            view.input(s, {type = "key", action = "press", key = "u", key_type = "rune", ctrl = true, alt = false, shift = false}, frame)
            view.input(s, {type = "paste", text = "Bee 🐝"}, frame)
            view.input(s, {type = "key", action = "press", key = "", key_type = "backspace", ctrl = false, alt = false, shift = false}, frame)
            test.eq(s.title, "Bee ")
            view.input(s, {type = "key", action = "press", key = "space", key_type = "space", ctrl = false, alt = false, shift = false}, frame)
            test.eq(s.title, "Bee  ")
            view.input(s, {type = "key", action = "press", key = "", key_type = "tab", ctrl = false, alt = false, shift = false}, frame)
            view.input(s, {type = "paste", text = "Use small changes.\nVerify them."}, frame)
            test.eq(view.action(s, "save"), "save")
            test.eq(s.form.draft.instructions, "Use small changes.\nVerify them.")
            test.is_nil(s.form.pending)
        end)
        test.it("requires confirmation for removal and keeps submitted values frozen", function()
            local s = state()
            test.is_nil(view.action(s, "remove"))
            test.is_nil(view.action(s, "save"))
            test.is_nil(view.action(s, "cancel"))
            test.is_false(s.confirming_remove)
            view.action(s, "remove")
            test.eq(view.action(s, "remove"), "remove")
            s.confirming_remove = false
            s.form.pending = "save"
            local frame = view.draw(60, 16, appearance.defaults(), s)
            view.input(s, {type = "paste", text = "Cannot append"}, frame)
            test.eq(s.title, "Agent")
            test.eq(view.action(s, "save"), "save")
        end)
        test.it("keeps rows and mouse targets within compact terminal sizes", function()
            for _, size in ipairs({{1, 1}, {12, 4}, {30, 8}, {60, 16}}) do
                local frame = view.draw(size[1], size[2], appearance.defaults(), state())
                test.eq(#frame.rows, size[2])
                for _, hit in ipairs(frame.hits) do
                    test.is_true(hit.x >= 1 and hit.y >= 1 and hit.y <= size[2])
                    test.is_true(hit.width >= 0 and hit.x + hit.width - 1 <= size[1])
                end
            end
        end)
        test.it("shows only actions that the current profile state accepts", function()
            local s = state()
            s.form.pending = "save"
            local pending = view.draw(60, 16, appearance.defaults(), s)
            local actions: {[string]: boolean} = {}
            for _, hit in ipairs(pending.hits) do actions[hit.action] = true end
            test.is_true(actions.save)
            test.is_nil(actions.remove)
            test.is_true(actions.cancel)
            s.form.pending = nil
            s.confirming_remove = true
            local confirming = view.draw(60, 16, appearance.defaults(), s)
            actions = {}
            for _, hit in ipairs(confirming.hits) do actions[hit.action] = true end
            test.is_nil(actions.save)
            test.is_true(actions.remove)
            test.is_true(actions.cancel)
            test.is_true(table.concat(confirming.rows, "\n"):find("Confirm", 1, true) ~= nil)
        end)
    end)
end
return test.run_cases(define_tests)
