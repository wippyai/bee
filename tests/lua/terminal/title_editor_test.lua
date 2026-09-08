-- MIT
local test = require("test")
local editor = require("editor")
local tty = require("tty")
local appearance = require("appearance")
local function define_tests()
    test.describe("Window title editor", function()
        test.it("edits graphemes and keeps control keys out of text", function()
            local panel = editor.panel(80, 24)
            local state = editor.open("one", "Old", "rose")
            state = editor.respond(state, {type = "paste", text = "A界é"}, panel).state
            state = editor.respond(state, {type = "key", key_type = "backspace"}, panel).state
            test.eq(state.left, "A界")
            state = editor.respond(state, {type = "key", key_type = "left"}, panel).state
            test.eq(state.left, "A"); test.eq(state.right, "界")
            state = editor.respond(state, {type = "key", key_type = "runes", key = "B"}, panel).state
            state = editor.respond(state, {type = "key", key_type = "delete"}, panel).state
            test.eq(state.left .. state.right, "AB")
            state = editor.respond(state, {type = "key", key_type = "space", key = " "}, panel).state
            test.eq(state.left, "AB ")
            state = editor.respond(state, {type = "key", key_type = "f1", key = "f1"}, panel).state
            test.eq(state.left, "AB ")
            test.eq(editor.respond(state, {type = "key", key_type = "enter"}, panel).action, "save")
            test.eq(editor.respond(state, {type = "key", key_type = "esc"}, panel).action, "cancel")
        end)
        test.it("rejects control paste and oversized labels before changing text", function()
            local original = editor.open("one", "Original", "")
            local panel = editor.panel(80, 24)
            local invalid = editor.respond(original, {type = "paste", text = "\27[31m"}, panel).state
            test.eq(invalid.left, "Original"); test.is_true(invalid.error ~= "")
            local large = editor.respond(original, {type = "paste", text = string.rep("x", 81)}, panel).state
            test.eq(large.left, "Original"); test.is_true(large.error ~= "")
            test.eq(original.error, "")
            local tabbed = editor.respond(original, {type = "key", key_type = "tab", shift = true}, panel).state
            test.eq(tabbed.focus, "cancel")
            test.eq(editor.respond(tabbed, {type = "key", key_type = "enter"}, panel).action, "cancel")
            tabbed = editor.respond(tabbed, {type = "key", key_type = "left"}, panel).state
            test.eq(editor.respond(tabbed, {type = "key", key_type = "enter"}, panel).action, "save")
        end)
        test.it("clips the modal and cursor at every supported terminal size", function()
            local state = editor.open("one", string.rep("界", 20), "")
            state.selected = false
            for _, width in ipairs({1, 4, 12, 24, 80}) do
                for _, height in ipairs({1, 4, 7, 24}) do
                    local canvas = tty.canvas(width, height)
                    canvas:clear(appearance.style("#ffffff", "#000000") .. " \27[0m")
                    local cursor = editor.draw(canvas, state, width, height, appearance.defaults())
                    for _, row in ipairs(canvas:rows()) do test.eq(tty.text.width(row), width) end
                    if cursor.visible then
                        test.is_true(cursor.x >= 1 and cursor.x <= width)
                        test.is_true(cursor.y >= 1 and cursor.y <= height)
                    end
                end
            end
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
