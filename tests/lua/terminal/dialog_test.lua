local test = require("test")
local dialog = require("dialog")
local tty = require("tty")
local appearance = require("appearance")

local function confirm_spec(): dialog.Spec
    return {request_id = "request", id = "view", instance_id = "instance", kind = "confirm",
        title = "Close terminal?", message = "Running commands will stop.", accept = "Close", initial = ""}
end

local function text_spec(initial: string): dialog.Spec
    return {request_id = "request", id = "view", instance_id = "instance", kind = "text",
        title = "Find text", message = "Enter a search value.", accept = "Find", initial = initial}
end

local function result_text(state: dialog.State): string
    return state.left .. state.right
end

local function define_tests()
    test.describe("Terminal interaction dialog", function()
        test.it("starts confirmations on Cancel and requires explicit acceptance", function()
            local state = dialog.open(confirm_spec())
            test.eq(state.focus, "cancel")
            local enter = dialog.respond(state, {type = "key", key_type = "enter"}, 80, 24)
            test.eq(enter.action, "cancel")
            test.eq(enter.value, "")

            state = dialog.respond(state, {type = "key", key_type = "tab"}, 80, 24).state
            test.eq(state.focus, "accept")
            local space = dialog.respond(state, {type = "key", key_type = "space"}, 80, 24)
            test.eq(space.action, "accept")
            test.eq(space.value, "")
            test.eq(dialog.respond(state, {type = "key", key_type = "escape"}, 80, 24).action, "cancel")
        end)

        test.it("edits text by grapheme, captures paste and never accepts controls", function()
            local state = dialog.open(text_spec("A界é"))
            test.eq(result_text(state), "A界é")
            state = dialog.respond(state, {type = "key", key_type = "home"}, 80, 24).state
            state = dialog.respond(state, {type = "key", key_type = "runes", key = "x"}, 80, 24).state
            test.eq(result_text(state), "xA界é")
            state = dialog.respond(state, {type = "key", key_type = "right"}, 80, 24).state
            state = dialog.respond(state, {type = "key", key_type = "backspace"}, 80, 24).state
            test.eq(result_text(state), "x界é")
            state = dialog.respond(state, {type = "paste", text = "界"}, 80, 24).state
            test.eq(result_text(state), "x界界é")
            local before = result_text(state)
            state = dialog.respond(state, {type = "paste", text = "\27[31m"}, 80, 24).state
            test.eq(result_text(state), before)
            state = dialog.respond(state, {type = "key", key_type = "f1", key = "f1"}, 80, 24).state
            test.eq(result_text(state), before)
        end)

        test.it("bounds text to 256 bytes and returns it only on accept", function()
            local state = dialog.open(text_spec(""))
            state = dialog.respond(state, {type = "paste", text = string.rep("x", 256)}, 80, 24).state
            test.eq(#result_text(state), 256)
            state = dialog.respond(state, {type = "paste", text = "y"}, 80, 24).state
            test.eq(#result_text(state), 256)
            state = dialog.respond(state, {type = "key", key_type = "tab"}, 80, 24).state
            local accepted = dialog.respond(state, {type = "key", key_type = "enter"}, 80, 24)
            test.eq(accepted.action, "accept")
            test.eq(accepted.value, string.rep("x", 256))
            test.eq(dialog.respond(accepted.state, {type = "key", key_type = "escape"}, 80, 24).value, "")
        end)

        test.it("keeps the Cancel hit available and clips every supported size", function()
            local state = dialog.open(text_spec("界界"))
            local preferences = appearance.defaults()
            for _, width in ipairs({1, 2, 3, 8, 24, 80}) do
                for _, height in ipairs({1, 2, 3, 5, 12, 24}) do
                    local canvas = tty.canvas(width, height)
                    canvas:clear(appearance.style("#ffffff", "#000000") .. " \27[0m")
                    local cursor = dialog.draw(canvas, state, width, height, preferences)
                    for _, row in ipairs(canvas:rows()) do test.eq(tty.text.width(row), width) end
                    if cursor.visible then
                        test.is_true(cursor.x >= 1 and cursor.x <= width)
                        test.is_true(cursor.y >= 1 and cursor.y <= height)
                    end
                end
            end
            local panel_canvas = tty.canvas(60, 12)
            panel_canvas:clear(appearance.style("#ffffff", "#000000") .. " \27[0m")
            local rows = dialog.draw(panel_canvas, state, 60, 12, preferences)
            test.is_true(rows.visible)
            local joined = table.concat(panel_canvas:rows())
            test.is_true(joined:find("Cancel", 1, true) ~= nil)

            local cancel = dialog.respond(state, {type = "mouse", action = "press", button = "left", x = 40, y = 8}, 60, 12)
            test.eq(cancel.action, "cancel")
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
