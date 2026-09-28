-- MIT. The forms kit's widget state transitions, focus traversal, validation
-- and a small fixture form's fill/validate/submit flow.
local test = require("test")
local tty = require("tty")
local frame = require("frame")
local forms = require("forms")
local appearance = require("appearance")

local function plain(row: string): string
    local value = row:gsub("\27%[[0-9;]*m", "")
    return value
end
local function text(painter: frame.Painter): {string}
    local rows: {string} = {}
    for index, row in ipairs(frame.rows(painter)) do rows[index] = plain(row) end
    return rows
end
local function sized(painter: frame.Painter)
    test.eq(#frame.rows(painter), painter.height)
    for _, row in ipairs(frame.rows(painter)) do test.eq(tty.text.width(plain(row)), painter.width) end
    for _, hit in ipairs(painter.hits) do
        test.is_true(hit.x >= 1 and hit.y >= 1)
        test.is_true(hit.x + hit.width - 1 <= painter.width)
        test.is_true(hit.y + hit.height - 1 <= painter.height)
    end
end
local function key(key_type: string, letter: string?, ctrl: boolean?, shift: boolean?): unknown
    return {type = "key", key_type = key_type, key = letter or "", action = "press", ctrl = ctrl == true, shift = shift == true, alt = false}
end
local function rune(letter: string): unknown
    return {type = "key", key_type = "runes", key = letter, action = "press", ctrl = false, shift = false, alt = false}
end
local function paste(value: string): unknown
    return {type = "paste", text = value}
end
local function text_of(field: forms.Field): forms.TextField
    local value = field.text
    if not value then error("field has no text widget") end
    return value
end
local function number_of(field: forms.Field): forms.NumberField
    local value = field.number
    if not value then error("field has no number widget") end
    return value
end
local function checkbox_of(field: forms.Field): forms.Checkbox
    local value = field.checkbox
    if not value then error("field has no checkbox widget") end
    return value
end
local function radio_of(field: forms.Field): forms.Radio
    local value = field.radio
    if not value then error("field has no radio widget") end
    return value
end

local function define_tests()
    test.describe("Forms text field", function()
        test.it("inserts, moves and deletes on grapheme boundaries", function()
            local field = forms.text_new("", "Name", 40, false)
            for _, ch in ipairs({"h", "i"}) do test.is_true(forms.text_key(field, rune(ch))) end
            test.eq(field.value, "hi")
            test.eq(field.cursor, 2)
            test.is_true(forms.text_key(field, key("left")))
            test.eq(field.cursor, 1)
            test.is_true(forms.text_key(field, rune("a")))
            test.eq(field.value, "hai")
            test.eq(field.cursor, 2)
            test.is_true(forms.text_key(field, key("backspace")))
            test.eq(field.value, "hi")
            test.is_true(forms.text_key(field, key("end")))
            test.eq(field.cursor, 2)
            test.is_true(forms.text_key(field, key("delete")))
            test.eq(field.value, "hi")
        end)
        test.it("selects all, replaces on insert and clears on backspace", function()
            local field = forms.text_new("hello", "", 40, false)
            test.is_true(forms.text_key(field, key("runes", "a", true)))
            test.is_true(field.selected)
            test.is_true(forms.text_key(field, rune("x")))
            test.eq(field.value, "x")
            test.is_false(field.selected)
            field.selected = true
            test.is_true(forms.text_key(field, key("backspace")))
            test.eq(field.value, "")
        end)
        test.it("moves and deletes by word with Ctrl", function()
            local field = forms.text_new("one two three", "", 40, false)
            field.cursor = #field.value
            test.is_true(forms.text_key(field, key("left", nil, true)))
            test.eq(field.value:sub(field.cursor + 1), "three")
            test.is_true(forms.text_key(field, key("backspace", nil, true)))
            test.eq(field.value, "one three")
            field.cursor = 0
            test.is_true(forms.text_key(field, key("right", nil, true)))
            test.eq(field.cursor, 3)
            test.is_true(forms.text_key(field, key("delete", nil, true)))
            test.eq(field.value, "one")
        end)
        test.it("accepts a paste and stops at max_length", function()
            local field = forms.text_new("", "", 5, false)
            test.is_true(forms.text_key(field, paste("hello world")))
            test.eq(field.value, "hello")
            test.is_false(forms.text_key(field, rune("x")))
        end)
        test.it("draws the placeholder when empty and unfocused, and a caret when focused", function()
            local field = forms.text_new("", "Search", 40, false)
            local painter = frame.new(20, 1, appearance.defaults())
            forms.text_draw(painter, 2, 1, 18, field, false, 1)
            test.eq(text(painter)[1]:sub(2, 7), "Search")
            local focused_painter = frame.new(20, 1, appearance.defaults())
            forms.text_draw(focused_painter, 2, 1, 18, field, true, 1)
            test.eq(text(focused_painter)[1]:sub(2, 4), "▏")
            sized(painter)
            sized(focused_painter)
        end)
        test.it("masks the drawn value but keeps the underlying text", function()
            local field = forms.text_new("secret", "", 40, true)
            local painter = frame.new(20, 1, appearance.defaults())
            forms.text_draw(painter, 2, 1, 18, field, false, 1)
            test.eq(field.value, "secret")
            test.is_nil(text(painter)[1]:find("secret", 1, true))
            test.eq(text(painter)[1]:sub(2, 19), string.rep("•", 6))
        end)
    end)

    test.describe("Forms number field", function()
        test.it("steps within bounds and rejects non-digits", function()
            local field = forms.number_new(5, 0, 10, 2)
            test.is_true(forms.number_key(field, key("up")))
            test.eq(forms.number_value(field), 7)
            test.is_true(forms.number_key(field, key("up")))
            test.eq(forms.number_value(field), 9)
            test.is_true(forms.number_key(field, key("up")))
            test.eq(forms.number_value(field), 10)
            field.cursor = 0
            test.is_false(forms.number_key(field, rune("a")))
            test.eq(field.value, "10")
        end)
        test.it("only allows one leading minus and one decimal point", function()
            local field = forms.number_new(nil, nil, nil, 1)
            test.is_true(forms.number_key(field, rune("-")))
            test.is_false(forms.number_key(field, rune("-")))
            test.is_true(forms.number_key(field, rune("3")))
            test.is_true(forms.number_key(field, rune(".")))
            test.is_false(forms.number_key(field, rune(".")))
            test.is_true(forms.number_key(field, rune("5")))
            test.eq(field.value, "-3.5")
            test.eq(forms.number_value(field), -3.5)
        end)
    end)

    test.describe("Forms text area", function()
        test.it("inserts a newline on Enter and moves the cursor by line", function()
            local field = forms.area_new("", 200)
            for _, ch in ipairs({"a", "b"}) do test.is_true(forms.area_key(field, rune(ch))) end
            test.is_true(forms.area_key(field, key("enter")))
            for _, ch in ipairs({"c", "d"}) do test.is_true(forms.area_key(field, rune(ch))) end
            test.eq(field.value, "ab\ncd")
            test.is_true(forms.area_key(field, key("up")))
            test.eq(field.cursor, 2)
            test.is_true(forms.area_key(field, key("end")))
            test.eq(field.cursor, 2)
            test.is_true(forms.area_key(field, key("down")))
            test.eq(field.cursor, 5)
        end)
        test.it("scrolls a long value to keep the cursor's line visible", function()
            local lines: {string} = {}
            for i = 1, 20 do lines[i] = "line " .. tostring(i) end
            local field = forms.area_new(table.concat(lines, "\n"), 2000)
            field.cursor = #field.value
            local painter = frame.new(30, 6, appearance.defaults())
            local window = forms.area_draw(painter, {x = 2, y = 1, width = 28, height = 5}, field, true, 1)
            test.eq(window.capacity, 5)
            test.is_true(window.offset > 0)
            test.eq(text(painter)[5]:sub(2, 8), "line 20")
            sized(painter)
        end)
    end)

    test.describe("Forms select, checkbox, radio and toggle", function()
        test.it("opens, moves the highlight and picks an option", function()
            local options: {forms.Option} = {{label = "Small", value = "s"}, {label = "Medium", value = "m"}, {label = "Large", value = "l"}}
            local field = forms.select_new(options, "s")
            test.is_false(field.open)
            test.is_true(forms.select_key(field, key("enter")))
            test.is_true(field.open)
            test.eq(field.highlighted, 1)
            test.is_true(forms.select_key(field, key("down")))
            test.is_true(forms.select_key(field, key("down")))
            test.eq(field.highlighted, 3)
            test.is_true(forms.select_key(field, key("enter")))
            test.is_false(field.open)
            test.eq(forms.select_value(field), "l")
        end)
        test.it("closes on Esc without changing the selection", function()
            local options: {forms.Option} = {{label = "A", value = "a"}, {label = "B", value = "b"}}
            local field = forms.select_new(options, "a")
            forms.select_key(field, key("enter"))
            forms.select_key(field, key("down"))
            test.is_true(forms.select_key(field, key("esc")))
            test.eq(forms.select_value(field), "a")
        end)
        test.it("toggles a checkbox and a toggle on space or enter", function()
            local box = forms.checkbox_new(false)
            test.is_true(forms.checkbox_key(box, key("space")))
            test.is_true(box.checked)
            local switch = forms.toggle_new(false)
            test.is_true(forms.toggle_key(switch, key("right")))
            test.is_true(switch.on)
        end)
        test.it("moves a radio group's selection with arrow keys", function()
            local options: {forms.Option} = {{label = "A", value = "a"}, {label = "B", value = "b"}, {label = "C", value = "c"}}
            local field = forms.radio_new(options, "a")
            test.is_true(forms.radio_key(field, key("down")))
            test.eq(forms.radio_value(field), "b")
            test.is_true(forms.radio_key(field, key("down")))
            test.is_true(forms.radio_key(field, key("down")))
            test.eq(forms.radio_value(field), "c")
        end)
    end)

    test.describe("Forms field rendering at a couple of sizes", function()
        test.it("draws every field kind inside its rect without leaking escapes", function()
            for _, width in ipairs({30, 60}) do
                local painter = frame.new(width, 20, appearance.defaults())
                local list_field = forms.field_select("plan", "Plan",
                    {{label = "Free", value = "free"}, {label = "Pro", value = "pro"}}, "free")
                local form = forms.form_new({
                    forms.field_text("name", "Name", "", {required = true, max_length = 30}),
                    forms.field_number("age", "Age", 21, {min = 0, max = 130}),
                    forms.field_textarea("bio", "Bio", "hello\nworld", {rows = 4}),
                    list_field,
                    forms.field_checkbox("agree", "I agree", false, {required = true}),
                    forms.field_radio("tier", "Tier", {{label = "One", value = "1"}, {label = "Two", value = "2"}}, "1"),
                    forms.field_toggle("beta", "Beta features", false),
                })
                local y = 1
                for index = 1, #form.fields do
                    local height = forms.rows(form.fields[index])
                    forms.draw(painter, {x = 2, y = y, width = width - 2, height = height}, form, index)
                    y = y + height + 1
                end
                for _, row in ipairs(frame.rows(painter)) do
                    local rendered = plain(row)
                    test.is_nil(rendered:find("\27", 1, true))
                end
                sized(painter)
            end
        end)
    end)

    test.describe("Forms focus traversal and clicking", function()
        test.it("Tab and Shift+Tab cycle focus, skipping disabled fields", function()
            local form = forms.form_new({
                forms.field_text("a", "A", ""),
                forms.field_text("b", "B", "", {disabled = true}),
                forms.field_text("c", "C", ""),
            })
            test.eq(form.focus, 1)
            test.is_true(forms.key(form, key("tab")))
            test.eq(form.focus, 3)
            test.is_true(forms.key(form, key("tab")))
            test.eq(form.focus, 1)
            test.is_true(forms.key(form, key("tab", nil, false, true)))
            test.eq(form.focus, 3)
        end)
        test.it("routes a field hit to focus and a checkbox click to toggle", function()
            local form = forms.form_new({forms.field_text("a", "A", ""), forms.field_checkbox("b", "B", false)})
            test.is_true(forms.click(form, {kind = "field", index = 2, key = "", x = 1, y = 1, width = 1, height = 1}))
            test.eq(form.focus, 2)
            test.is_true(checkbox_of(form.fields[2]).checked)
        end)
        test.it("routes an option hit to pick a radio value", function()
            local field = forms.field_radio("tier", "Tier", {{label = "One", value = "1"}, {label = "Two", value = "2"}}, "1")
            local form = forms.form_new({field})
            test.is_true(forms.click(form, {kind = "option", index = 1, key = "2", x = 1, y = 1, width = 1, height = 1}))
            test.eq(forms.radio_value(radio_of(field)), "2")
        end)
    end)

    test.describe("Forms validation and dirty tracking", function()
        test.it("flags a required field empty and a number out of bounds", function()
            local form = forms.form_new({
                forms.field_text("name", "Name", "", {required = true}),
                forms.field_number("age", "Age", 200, {min = 0, max = 130}),
            })
            test.is_false(forms.validate(form))
            test.eq(form.fields[1].error, "Required")
            test.eq(form.fields[2].error, "At most 130")
            test.is_false(forms.can_submit(form))
        end)
        test.it("clears a field's error on the next edit", function()
            local field = forms.field_text("name", "Name", "", {required = true})
            local form = forms.form_new({field})
            forms.validate(form)
            test.not_nil(field.error)
            forms.key(form, rune("a"))
            test.is_nil(field.error)
        end)
        test.it("tracks dirty against the baseline and clears it on reset", function()
            local field = forms.field_text("name", "Name", "Ada")
            local form = forms.form_new({field})
            test.is_false(forms.dirty(field))
            forms.key(form, rune("!"))
            test.is_true(forms.dirty(field))
            forms.reset_field(field)
            test.is_false(forms.dirty(field))
            test.eq(forms.value(field), "Ada")
        end)
    end)

    test.describe("Forms fixture: fill, validate and submit", function()
        test.it("blocks submit until every required field is valid, then allows it", function()
            local form = forms.form_new({
                forms.field_text("name", "Name", "", {required = true, max_length = 40}),
                forms.field_number("age", "Age", nil, {required = true, min = 0, max = 130}),
                forms.field_checkbox("agree", "I agree to the terms", false, {required = true}),
            })
            test.is_false(forms.can_submit(form))
            for _, ch in ipairs({"A", "d", "a"}) do forms.key(form, rune(ch)) end
            test.eq(text_of(form.fields[1]).value, "Ada")
            test.is_false(forms.can_submit(form))
            forms.focus_next(form)
            for _, ch in ipairs({"3", "0"}) do forms.key(form, rune(ch)) end
            test.eq(number_of(form.fields[2]).value, "30")
            test.is_false(forms.can_submit(form))
            forms.focus_next(form)
            forms.key(form, key("space"))
            test.is_true(checkbox_of(form.fields[3]).checked)
            test.is_true(forms.can_submit(form))
            test.is_true(forms.validate(form))
            test.is_true(forms.form_dirty(form))
            form.disabled = true
            test.is_false(forms.can_submit(form))
            test.is_false(forms.key(form, rune("x")))
            form.disabled = false
            forms.reset(form)
            test.is_false(forms.form_dirty(form))
            test.eq(text_of(form.fields[1]).value, "")
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
