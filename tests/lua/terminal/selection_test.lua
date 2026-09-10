-- MIT
local test = require("test")
local selection = require("selection")

local function binding(view_id: string?, attachment: string?, generation: integer?, width: integer?, height: integer?): selection.Binding
    return {
        view_id = view_id or "view-one",
        attachment = attachment or "attachment-one",
        mount_generation = generation or 7,
        width = width or 7,
        height = height or 3,
    }
end

local function captured(rows: {string}, value: selection.Binding?): selection.State
    local state, err = selection.capture(value or binding(), rows)
    test.is_nil(err)
    test.not_nil(state)
    if not state then error("selection capture failed") end
    return state
end

local function define_tests()
    test.describe("Terminal text selection model", function()
        test.it("captures frozen rows without selecting until the first press", function()
            local rows = {"alpha", "bravo", "charlie"}
            local state = captured(rows)
            rows[1] = "later"

            test.is_true(selection.active(state))
            test.is_nil(selection.range(state))
            test.is_nil(selection.text(state))
            local snapshot = selection.snapshot(state)
            snapshot.rows[2] = "changed outside"
            test.eq(selection.snapshot(state).rows[1], "alpha")
            test.eq(selection.snapshot(state).rows[2], "bravo")
            local identity = selection.binding(state)
            identity.attachment = "changed outside"
            test.eq(selection.binding(state).attachment, "attachment-one")

            local started = selection.press(state, 2, 1)
            test.is_nil(selection.range(state))
            local span = selection.range(started)
            test.not_nil(span)
            if span then
                test.eq(span.start.x, 2); test.eq(span.start.y, 1)
                test.eq(span.finish.x, 2); test.eq(span.finish.y, 1)
            end
            test.eq(selection.text(started), "l")
            local restarted = selection.press(started, 5, 2)
            test.eq(selection.text(restarted), "o")
        end)

        test.it("clamps body-relative drags and extracts reverse multiline spans", function()
            local state = captured({"alpha", "bravo", "charlie"})
            state = selection.press(state, 5, 3)
            state = selection.drag(state, -20, -30)
            test.eq(selection.text(state), "alpha\nbravo\ncharl")

            local clamped = selection.press(captured({"alpha", "bravo", "charlie"}), -20, -20)
            clamped = selection.drag(clamped, 99, 99)
            local span = selection.range(clamped)
            test.not_nil(span)
            if span then
                test.eq(span.start.x, 1); test.eq(span.start.y, 1)
                test.eq(span.finish.x, 7); test.eq(span.finish.y, 3)
            end
            test.eq(selection.text(clamped), "alpha\nbravo\ncharlie")
        end)

        test.it("moves only while the left press remains active", function()
            local state = selection.press(captured({"alpha", "bravo", "charlie"}), 2, 1)
            state = selection.motion(state, 4, 2)
            test.eq(selection.text(state), "lpha\nbrav")
            state = selection.release(state, 5, 2)
            test.eq(selection.text(state), "lpha\nbravo")
            -- A later hover must leave the completed range unchanged.
            state = selection.motion(state, 1, 3)
            test.eq(selection.text(state), "lpha\nbravo")
        end)

        test.it("uses native cell slicing and plain text conversion", function()
            local rows = {"A界éB", "\27[31mred\27[0m\tok\7", "tail"}
            local state = selection.press(captured(rows), 2, 1)
            state = selection.drag(state, 4, 1)
            test.eq(selection.text(state), "界é")

            state = selection.press(captured(rows), 1, 2)
            state = selection.drag(state, 6, 2)
            test.eq(selection.text(state), "red\tok")

            -- `tty.text.cut` treats a cell interval as a grapheme-safe range:
            -- its leading half of a wide glyph is empty, while its trailing
            -- half expands to the full glyph. The model keeps that native
            -- behavior rather than splitting UTF-8 or inventing padding.
            local wide = captured({"A界B"}, binding("view-wide", "attachment-wide", 1, 4, 1))
            test.eq(selection.text(selection.press(wide, 2, 1)), "")
            test.eq(selection.text(selection.press(wide, 3, 1)), "界")
        end)

        test.it("invalidates a captured range for a different view, mount, or geometry", function()
            local original = binding()
            local state = selection.drag(selection.press(captured({"alpha", "bravo", "charlie"}, original), 1, 1), 5, 3)
            test.is_true(selection.valid(state, original))
            test.is_false(selection.valid(state, binding("view-two")))
            test.is_false(selection.valid(state, binding("view-one", "attachment-two")))
            test.is_false(selection.valid(state, binding("view-one", "attachment-one", 8)))
            test.is_false(selection.valid(state, binding("view-one", "attachment-one", 7, 4, 3)))
            test.is_nil(selection.cancel(state))
            test.is_false(selection.active(selection.cancel(state)))
        end)

        test.it("rejects geometry, cell, row, and raw byte captures beyond its bounds", function()
            local state, err = selection.capture(binding("view", "mount", 1, 0, 1), {""})
            test.is_nil(state); test.not_nil(err)
            state, err = selection.capture(binding("view", "mount", 1, 65536, 1), {})
            test.is_nil(state); test.not_nil(err)
            state, err = selection.capture(binding("view", "mount", 1, 513, 512), {})
            test.is_nil(state); test.not_nil(err)
            state, err = selection.capture(binding("view", "mount", 1, 3, 1), {"wide"})
            test.is_nil(state); test.not_nil(err)
            state, err = selection.capture(binding("view", "mount", 1, 1, 1), {string.rep("\27[31m", 420000)})
            test.is_nil(state); test.not_nil(err)

            local rows: {string} = {}
            for _ = 1, 512 do rows[#rows + 1] = string.rep("x", 512) end
            state, err = selection.capture(binding("view", "mount", 1, 512, 512), rows)
            test.not_nil(state); test.is_nil(err)
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
