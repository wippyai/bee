-- MIT. The input/forms kit on the frame: text, number, multi-line and
-- choice widgets, and a form container that owns focus order, validation,
-- dirty tracking and a disabled state. Pure: every function reads and
-- writes only the typed state the caller passes in; it performs no calls,
-- opens no store, and grants nothing. The caller owns every record, routes
-- key and mouse events to it explicitly, and redraws after any change.
local tty = require("tty")
local frame = require("frame")
local appearance = require("appearance")
local M = {}

M.TEXT_MAX_LENGTH = 4096
M.AREA_MAX_LENGTH = 16384
M.NUMBER_MAX_LENGTH = 32
M.SELECT_MAX_VISIBLE = 6
M.AREA_PAGE = 8

local function maximum(a: integer, b: integer): integer if a > b then return a end; return b end
local function minimum(a: integer, b: integer): integer if a < b then return a end; return b end

type Option = {label: string, value: string}
type TextField = {value: string, cursor: integer, selected: boolean, placeholder: string, max_length: integer, masked: boolean}
type NumberField = {value: string, cursor: integer, selected: boolean, min: number?, max: number?, step: number}
type TextArea = {value: string, cursor: integer, selected: boolean, max_length: integer, scroll: integer}
type Select = {options: {Option}, selected: integer, open: boolean, highlighted: integer, scroll: integer}
type Checkbox = {checked: boolean}
type Radio = {options: {Option}, selected: integer}
type Toggle = {on: boolean}
type FieldKind = "text" | "number" | "textarea" | "select" | "checkbox" | "radio" | "toggle"
-- One form field: exactly one of the typed widgets below is set, matching
-- kind. error is the message from the last validate; baseline is the value
-- string at construction or the last reset, compared by dirty.
type Field = {key: string, label: string, kind: FieldKind, required: boolean, disabled: boolean, hint: string,
    text: TextField?, number: NumberField?, area: TextArea?, select: Select?, checkbox: Checkbox?, radio: Radio?, toggle: Toggle?,
    error: string?, baseline: string, rows: integer, validate: ((Field) -> string?)?}
-- focus is the one-based index of the focused field in fields, or 0 when
-- every field is disabled. disabled locks the whole form (for example while
-- a submit is in flight): key and click then do nothing.
type Form = {fields: {Field}, focus: integer, disabled: boolean}
type FieldOptions = {required: boolean?, disabled: boolean?, hint: string?, validate: ((Field) -> string?)?,
    placeholder: string?, max_length: integer?, masked: boolean?,
    min: number?, max: number?, step: number?, rows: integer?}

-- Truncates text to a display width with no ellipsis, on a grapheme boundary.
local function pop(text: string): string
    return tty.text.truncate(text, maximum(0, tty.text.width(text) - 1), "")
end
-- The first display character of text and the rest.
local function shift(text: string): (string, string)
    for width = 1, tty.text.width(text) do
        local first = tty.text.truncate(text, width, "")
        if first ~= "" then return first, text:sub(#first + 1) end
    end
    return text, ""
end
-- Trims a byte string to at most limit bytes without splitting a UTF-8
-- sequence, for bounding pasted or overflowing insert text.
local function safe_cut(text: string, limit: integer): string
    if limit <= 0 then return "" end
    if #text <= limit then return text end
    local cut = limit
    while cut > 0 and text:byte(cut + 1) and text:byte(cut + 1) >= 0x80 and text:byte(cut + 1) < 0xC0 do cut = cut - 1 end
    return text:sub(1, cut)
end
-- The number of UTF-8 characters (lead bytes) in value.
local function count(value: string): integer
    local n = 0
    for i = 1, #value do
        local b = value:byte(i)
        if b < 0x80 or b >= 0xC0 then n = n + 1 end
    end
    return n
end
local function mask(value: string): string return string.rep("•", count(value)) end
-- The byte cursor one word back from cursor in value, skipping trailing space.
local function word_back(value: string, cursor: integer): integer
    local left = value:sub(1, cursor)
    local trimmed = left:gsub("%s+$", "")
    local cut = trimmed:find("%s[^%s]*$")
    return cut or 0
end
-- The byte cursor one word forward from cursor in value, skipping leading space.
local function word_forward(value: string, cursor: integer): integer
    local right = value:sub(cursor + 1)
    local spaces = right:match("^%s*") or ""
    local word = right:sub(#spaces + 1):match("^%S*") or ""
    return cursor + #spaces + #word
end
local function strip_control(text: string): string
    return (text:gsub("[%z\1-\8\11\12\14-\31\127]", ""))
end

-- A single-line text field: value, empty, cursor at the end.
function M.text_new(value: string, placeholder: string, max_length: integer, masked: boolean): TextField
    local clean = strip_control((value or ""):gsub("\n", ""))
    local bound = safe_cut(clean, max_length)
    return {value = bound, cursor = #bound, selected = false, placeholder = placeholder or "", max_length = max_length, masked = masked}
end
-- Replaces the value programmatically (for example on reset); cursor moves to the end.
function M.text_set(field: TextField, value: string)
    local clean = safe_cut(strip_control((value or ""):gsub("\n", "")), field.max_length)
    field.value, field.cursor, field.selected = clean, #clean, false
end
local function text_insert(field: TextField, text: string): boolean
    local clean = strip_control(text):gsub("\n", "")
    if clean == "" then return false end
    local left = field.selected and "" or field.value:sub(1, field.cursor)
    local right = field.selected and "" or field.value:sub(field.cursor + 1)
    local room = field.max_length - #left - #right
    if room <= 0 then return false end
    clean = safe_cut(clean, room)
    field.value = left .. clean .. right
    field.cursor = #left + #clean
    field.selected = false
    return true
end
-- Applies one key or paste event: cursor and word motions, backspace/delete
-- (forward and by word), Home/End, Ctrl+A select-all, and insertion. Returns
-- true when the field changed.
function M.text_key(field: TextField, event: unknown): boolean
    if type(event) ~= "table" then return false end
    if event.type == "paste" then
        if type(event.text) ~= "string" then return false end
        return text_insert(field, event.text)
    end
    if event.type ~= "key" or event.action == "release" then return false end
    local key = event.key_type
    if event.ctrl == true and event.key == "a" then field.selected = true; return true end
    if key == "home" then field.cursor = 0; field.selected = false; return true end
    if key == "end" then field.cursor = #field.value; field.selected = false; return true end
    if key == "left" then
        if field.selected then field.cursor, field.selected = 0, false
        elseif event.ctrl == true then field.cursor = word_back(field.value, field.cursor)
        else field.cursor = #pop(field.value:sub(1, field.cursor)) end
        return true
    end
    if key == "right" then
        if field.selected then field.cursor, field.selected = #field.value, false
        elseif event.ctrl == true then field.cursor = word_forward(field.value, field.cursor)
        else local first = shift(field.value:sub(field.cursor + 1)); field.cursor = field.cursor + #first end
        return true
    end
    if key == "backspace" then
        if field.selected then field.value, field.cursor, field.selected = "", 0, false
        elseif event.ctrl == true then
            local target = word_back(field.value, field.cursor)
            field.value = field.value:sub(1, target) .. field.value:sub(field.cursor + 1)
            field.cursor = target
        else
            local prefix = pop(field.value:sub(1, field.cursor))
            field.value = prefix .. field.value:sub(field.cursor + 1)
            field.cursor = #prefix
        end
        return true
    end
    if key == "delete" then
        if field.selected then field.value, field.cursor, field.selected = "", 0, false
        elseif event.ctrl == true then
            local target = word_forward(field.value, field.cursor)
            field.value = field.value:sub(1, field.cursor) .. field.value:sub(target + 1)
        else
            local _, rest = shift(field.value:sub(field.cursor + 1))
            field.value = field.value:sub(1, field.cursor) .. rest
        end
        return true
    end
    if key == "space" and event.ctrl ~= true and event.alt ~= true then return text_insert(field, " ") end
    if key == "runes" and event.ctrl ~= true and event.alt ~= true and type(event.key) == "string" then
        return text_insert(field, event.key)
    end
    return false
end
-- Draws the value (or the placeholder, muted, when empty and unfocused)
-- scrolled to keep the cursor visible; masked shows one bullet per character.
-- The whole value is drawn in the selection colors when select-all is set.
function M.text_draw(painter: frame.Painter, x: integer, y: integer, width: integer, field: TextField, focused: boolean, hit_index: integer?)
    if hit_index then frame.add_hit(painter, "field", hit_index, "", x, y, width, 1) end
    local theme = painter.theme
    if field.value == "" and not focused then
        frame.put(painter, x, y, field.placeholder, width, theme.muted)
        return
    end
    local left = field.masked and mask(field.value:sub(1, field.cursor)) or field.value:sub(1, field.cursor)
    local right = field.masked and mask(field.value:sub(field.cursor + 1)) or field.value:sub(field.cursor + 1)
    local room = maximum(0, width - 1)
    local left_width = tty.text.width(left)
    local offset = maximum(0, left_width - room)
    local shown = tty.text.cut(left .. right, offset, offset + width)
    if field.selected and focused then
        frame.put(painter, x, y, shown, width, appearance.selection_text(theme), theme.accent)
        return
    end
    frame.put(painter, x, y, shown, width, theme.text)
    if focused then
        local caret_x = x + (left_width - offset)
        if caret_x >= x and caret_x < x + width then frame.put(painter, caret_x, y, "▏", 1, theme.accent) end
    end
end

-- A bounded numeric field, stored as its own digit buffer so an in-progress
-- "-" or "." is never coerced; min, max and step are optional bounds.
function M.number_new(value: number?, min: number?, max: number?, step: number?): NumberField
    local text = value and tostring(value) or ""
    return {value = text, cursor = #text, selected = false, min = min, max = max, step = step or 1}
end
function M.number_set(field: NumberField, value: number?)
    local text = value and tostring(value) or ""
    field.value, field.cursor, field.selected = text, #text, false
end
local function number_parse(value: string): number?
    local mantissa, exponent = value:match("^(.+)[eE]([+-]?%d+)$")
    if not mantissa or not exponent then return tonumber(value) end
    local base, power = tonumber(mantissa), tonumber(exponent)
    if base == nil or power == nil or math.abs(power) > 308 then return nil end
    local parsed = base * (10 ^ power)
    if parsed == math.huge or parsed == -math.huge then return nil end
    return parsed
end
-- The parsed number, or nil when the buffer is empty or not a number.
function M.number_value(field: NumberField): number?
    if field.value == "" then return nil end
    return number_parse(field.value)
end
-- True when buffer is a well-formed in-progress decimal or exponent number.
local function number_allowed(buffer: string): boolean
    local index = 1
    if buffer:sub(1, 1) == "-" then index = 2 end
    local digits, decimal = 0, false
    while index <= #buffer do
        local char = buffer:sub(index, index)
        if char == "e" or char == "E" then
            if digits == 0 then return false end
            index = index + 1
            local sign = buffer:sub(index, index)
            if sign == "+" or sign == "-" then index = index + 1 end
            while index <= #buffer do
                local exponent_digit = buffer:sub(index, index)
                if exponent_digit < "0" or exponent_digit > "9" then return false end
                index = index + 1
            end
            return true
        elseif char == "." then
            if decimal then return false end
            decimal = true
        elseif char >= "0" and char <= "9" then
            digits = digits + 1
        else
            return false
        end
        index = index + 1
    end
    return true
end
local function number_insert(field: NumberField, text: string): boolean
    local left = field.selected and "" or field.value:sub(1, field.cursor)
    local right = field.selected and "" or field.value:sub(field.cursor + 1)
    local inserted = ""
    for ch in text:gmatch(".") do
        if #left + #inserted + #right < M.NUMBER_MAX_LENGTH and number_allowed(left .. inserted .. ch .. right) then
            inserted = inserted .. ch
        end
    end
    if inserted == "" then return false end
    field.value = left .. inserted .. right
    field.cursor = #left + #inserted
    field.selected = false
    return true
end
local function number_format(value: number): string
    if value == math.floor(value) then return tostring(math.floor(value)) end
    return tostring(value)
end
local function number_step(field: NumberField, delta: number)
    local current = number_parse(field.value) or 0
    local next_value = current + delta
    if field.min and next_value < field.min then next_value = field.min end
    if field.max and next_value > field.max then next_value = field.max end
    field.value = number_format(next_value)
    field.cursor, field.selected = #field.value, false
end
-- Cursor, selection and digit-composing insertion, plus Up/Down to step by
-- the field's step, clamped to min/max.
function M.number_key(field: NumberField, event: unknown): boolean
    if type(event) ~= "table" then return false end
    if event.type == "paste" then
        if type(event.text) ~= "string" then return false end
        return number_insert(field, event.text)
    end
    if event.type ~= "key" or event.action == "release" then return false end
    local key = event.key_type
    if event.ctrl == true and event.key == "a" then field.selected = true; return true end
    if key == "home" then field.cursor = 0; field.selected = false; return true end
    if key == "end" then field.cursor = #field.value; field.selected = false; return true end
    if key == "left" then
        if field.selected then field.cursor, field.selected = 0, false
        else field.cursor = #pop(field.value:sub(1, field.cursor)) end
        return true
    end
    if key == "right" then
        if field.selected then field.cursor, field.selected = #field.value, false
        else local first = shift(field.value:sub(field.cursor + 1)); field.cursor = field.cursor + #first end
        return true
    end
    if key == "backspace" then
        if field.selected then field.value, field.cursor, field.selected = "", 0, false
        else
            local prefix = pop(field.value:sub(1, field.cursor))
            field.value = prefix .. field.value:sub(field.cursor + 1)
            field.cursor = #prefix
        end
        return true
    end
    if key == "delete" then
        if field.selected then field.value, field.cursor, field.selected = "", 0, false
        else
            local _, rest = shift(field.value:sub(field.cursor + 1))
            field.value = field.value:sub(1, field.cursor) .. rest
        end
        return true
    end
    if key == "up" then number_step(field, field.step); return true end
    if key == "down" then number_step(field, -field.step); return true end
    if key == "runes" and event.ctrl ~= true and event.alt ~= true and type(event.key) == "string" then
        return number_insert(field, event.key)
    end
    return false
end
-- Draws the digit buffer, scrolled to keep the cursor visible, in error role
-- when out of bounds.
function M.number_draw(painter: frame.Painter, x: integer, y: integer, width: integer, field: NumberField, focused: boolean, hit_index: integer?)
    if hit_index then frame.add_hit(painter, "field", hit_index, "", x, y, width, 1) end
    local theme = painter.theme
    local parsed = M.number_value(field)
    local out_of_bounds = parsed ~= nil and ((field.min and parsed < field.min) or (field.max and parsed > field.max))
    local color = out_of_bounds and theme.error or theme.text
    if field.value == "" and not focused then
        frame.put(painter, x, y, "0", width, theme.muted)
        return
    end
    local left, right = field.value:sub(1, field.cursor), field.value:sub(field.cursor + 1)
    local room = maximum(0, width - 1)
    local left_width = tty.text.width(left)
    local offset = maximum(0, left_width - room)
    local shown = tty.text.cut(left .. right, offset, offset + width)
    if field.selected and focused then
        frame.put(painter, x, y, shown, width, appearance.selection_text(theme), theme.accent)
        return
    end
    frame.put(painter, x, y, shown, width, color)
    if focused then
        local caret_x = x + (left_width - offset)
        if caret_x >= x and caret_x < x + width then frame.put(painter, caret_x, y, "▏", 1, theme.accent) end
    end
end

-- Every line of value and, for each, the one-based byte offset (in value)
-- of its first character.
local function area_scan(value: string): ({string}, {integer})
    local lines: {string} = {}
    local starts: {integer} = {}
    local start = 1
    while true do
        starts[#starts + 1] = start
        local stop = value:find("\n", start, true)
        if not stop then lines[#lines + 1] = value:sub(start); break end
        lines[#lines + 1] = value:sub(start, stop - 1)
        start = stop + 1
    end
    return lines, starts
end
-- The one-based line and the zero-based column of cursor within it.
local function area_position(value: string, cursor: integer): (integer, integer)
    local line, start = 1, 1
    for i = 1, cursor do
        if value:byte(i) == 10 then line = line + 1; start = i + 1 end
    end
    return line, cursor - start + 1
end
local function area_move_line(area: TextArea, delta: integer)
    local lines, starts = area_scan(area.value)
    local line, column = area_position(area.value, area.cursor)
    local target = maximum(1, minimum(#lines, line + delta))
    local wanted = tty.text.width((lines[line] or ""):sub(1, column))
    area.cursor = starts[target] - 1 + #tty.text.truncate(lines[target] or "", wanted, "")
    area.selected = false
end
-- The byte cursor one character before cursor: a newline is one character,
-- and any other character is found within its own line.
local function area_previous(value: string, cursor: integer): integer
    if cursor <= 0 then return 0 end
    if value:byte(cursor) == 10 then return cursor - 1 end
    local _, column = area_position(value, cursor)
    local start = cursor - column
    return start + #pop(value:sub(start + 1, cursor))
end
-- The byte cursor one character after cursor, treating a newline as one character.
local function area_next(value: string, cursor: integer): integer
    if cursor >= #value then return #value end
    if value:byte(cursor + 1) == 10 then return cursor + 1 end
    local stop = value:find("\n", cursor + 1, true) or (#value + 1)
    local first = shift(value:sub(cursor + 1, stop - 1))
    return cursor + #first
end
local function area_line_home(area: TextArea)
    local _, starts = area_scan(area.value)
    local line = area_position(area.value, area.cursor)
    area.cursor, area.selected = starts[line] - 1, false
end
local function area_line_end(area: TextArea)
    local lines, starts = area_scan(area.value)
    local line = area_position(area.value, area.cursor)
    area.cursor, area.selected = starts[line] - 1 + #(lines[line] or ""), false
end

-- A multi-line text area: value with embedded "\n", cursor at the end.
function M.area_new(value: string, max_length: integer): TextArea
    local clean = safe_cut(strip_control(value or ""), max_length)
    return {value = clean, cursor = #clean, selected = false, max_length = max_length, scroll = 0}
end
function M.area_set(field: TextArea, value: string)
    local clean = safe_cut(strip_control(value or ""), field.max_length)
    field.value, field.cursor, field.selected, field.scroll = clean, #clean, false, 0
end
local function area_insert(field: TextArea, text: string): boolean
    local clean = strip_control(text)
    if clean == "" then return false end
    local left = field.selected and "" or field.value:sub(1, field.cursor)
    local right = field.selected and "" or field.value:sub(field.cursor + 1)
    local room = field.max_length - #left - #right
    if room <= 0 then return false end
    clean = safe_cut(clean, room)
    field.value = left .. clean .. right
    field.cursor = #left + #clean
    field.selected = false
    return true
end
-- Cursor, word and line motions, backspace/delete, Enter for a newline,
-- Up/Down/PgUp/PgDown to move by line, Home/End for the line and
-- Ctrl+Home/Ctrl+End for the whole value.
function M.area_key(field: TextArea, event: unknown): boolean
    if type(event) ~= "table" then return false end
    if event.type == "paste" then
        if type(event.text) ~= "string" then return false end
        return area_insert(field, event.text)
    end
    if event.type ~= "key" or event.action == "release" then return false end
    local key = event.key_type
    if event.ctrl == true and event.key == "a" then field.selected = true; return true end
    if key == "up" then area_move_line(field, -1); return true end
    if key == "down" then area_move_line(field, 1); return true end
    if key == "pgup" then area_move_line(field, -M.AREA_PAGE); return true end
    if key == "pgdown" then area_move_line(field, M.AREA_PAGE); return true end
    if key == "home" then
        if event.ctrl == true then field.cursor, field.selected = 0, false else area_line_home(field) end
        return true
    end
    if key == "end" then
        if event.ctrl == true then field.cursor, field.selected = #field.value, false else area_line_end(field) end
        return true
    end
    if key == "left" then
        if field.selected then field.cursor, field.selected = 0, false
        elseif event.ctrl == true then field.cursor = word_back(field.value, field.cursor)
        else field.cursor = area_previous(field.value, field.cursor) end
        return true
    end
    if key == "right" then
        if field.selected then field.cursor, field.selected = #field.value, false
        elseif event.ctrl == true then field.cursor = word_forward(field.value, field.cursor)
        else field.cursor = area_next(field.value, field.cursor) end
        return true
    end
    if key == "backspace" then
        if field.selected then field.value, field.cursor, field.selected = "", 0, false
        elseif event.ctrl == true then
            local target = word_back(field.value, field.cursor)
            field.value = field.value:sub(1, target) .. field.value:sub(field.cursor + 1)
            field.cursor = target
        else
            local target = area_previous(field.value, field.cursor)
            field.value = field.value:sub(1, target) .. field.value:sub(field.cursor + 1)
            field.cursor = target
        end
        return true
    end
    if key == "delete" then
        if field.selected then field.value, field.cursor, field.selected = "", 0, false
        elseif event.ctrl == true then
            local target = word_forward(field.value, field.cursor)
            field.value = field.value:sub(1, field.cursor) .. field.value:sub(target + 1)
        else
            local target = area_next(field.value, field.cursor)
            field.value = field.value:sub(1, field.cursor) .. field.value:sub(target + 1)
        end
        return true
    end
    if key == "enter" or key == "return" then return area_insert(field, "\n") end
    if key == "space" and event.ctrl ~= true and event.alt ~= true then return area_insert(field, " ") end
    if key == "runes" and event.ctrl ~= true and event.alt ~= true and type(event.key) == "string" then
        return area_insert(field, event.key)
    end
    return false
end
-- Draws the lines visible in rect, scrolled with frame.window to keep the
-- cursor's line in view, with a caret on the focused cursor's line.
function M.area_draw(painter: frame.Painter, rect: frame.Rect, field: TextArea, focused: boolean, hit_index: integer?): frame.Window
    if hit_index then frame.add_hit(painter, "field", hit_index, "", rect.x, rect.y, rect.width, rect.height) end
    local theme = painter.theme
    local lines, _ = area_scan(field.value)
    local line, column = area_position(field.value, field.cursor)
    local window = frame.window(#lines, rect.height, line, field.scroll)
    field.scroll = window.offset
    for slot = 1, window.capacity do
        local index = window.offset + slot
        local content = lines[index]
        if not content then break end
        local y = rect.y + slot - 1
        frame.put(painter, rect.x, y, content, rect.width, theme.text)
        if focused and index == line then
            local left_width = tty.text.width(content:sub(1, column))
            if left_width < rect.width then frame.put(painter, rect.x + left_width, y, "▏", 1, theme.accent) end
        end
    end
    return window
end

-- A single-choice dropdown: one option is selected, closed by default;
-- open shows the option list, highlighted is the option Up/Down moves.
function M.select_new(options: {Option}, value: string): Select
    local selected = #options > 0 and 1 or 0
    for index, option in ipairs(options) do if option.value == value then selected = index end end
    return {options = options, selected = selected, open = false, highlighted = maximum(1, selected), scroll = 0}
end
-- The value of the selected option, or nil when none is selected.
function M.select_value(field: Select): string?
    local option = field.options[field.selected]
    return option and option.value or nil
end
function M.select_set(field: Select, value: string)
    for index, option in ipairs(field.options) do
        if option.value == value then field.selected, field.highlighted, field.open = index, index, false; return end
    end
end
-- Closed: Enter/Space/Down opens with the current option highlighted. Open:
-- Up/Down move the highlight, Enter selects it and closes, Esc closes
-- without changing the selection.
function M.select_key(field: Select, event: unknown): boolean
    if type(event) ~= "table" or event.type ~= "key" or event.action == "release" then return false end
    local key = event.key_type
    if not field.open then
        if key == "enter" or key == "space" or key == "down" then
            field.open, field.highlighted = true, maximum(1, field.selected)
            return true
        end
        return false
    end
    local count_options = #field.options
    if key == "up" then field.highlighted = maximum(1, field.highlighted - 1); return true end
    if key == "down" then field.highlighted = minimum(maximum(1, count_options), field.highlighted + 1); return true end
    if key == "enter" then
        if count_options > 0 then field.selected = field.highlighted end
        field.open = false
        return true
    end
    if key == "esc" or key == "escape" then field.open = false; return true end
    return false
end
-- The collapsed row (label's selected option, or a placeholder, with a
-- disclosure marker) and, when open, the scrolled option list below it.
-- Returns the number of rows drawn.
function M.select_draw(painter: frame.Painter, rect: frame.Rect, field: Select, focused: boolean, hit_index: integer?): integer
    local theme = painter.theme
    if rect.width <= 0 or rect.height <= 0 then return 0 end
    if hit_index then frame.add_hit(painter, "field", hit_index, "", rect.x, rect.y, rect.width, 1) end
    local option = field.options[field.selected]
    local shown_width = maximum(0, rect.width - 2)
    local text = frame.pad(option and option.label or "Select…", shown_width)
    if focused then frame.put(painter, rect.x, rect.y, text, shown_width, appearance.selection_text(theme), theme.accent)
    else frame.put(painter, rect.x, rect.y, text, shown_width, theme.text) end
    frame.put(painter, rect.x + shown_width, rect.y, field.open and "▲" or "▼", minimum(2, rect.width), theme.muted)
    if not field.open or rect.height <= 1 then return 1 end
    local body_height = rect.height - 1
    local window = frame.window(#field.options, minimum(M.SELECT_MAX_VISIBLE, body_height), field.highlighted, field.scroll)
    field.scroll = window.offset
    for slot = 1, window.capacity do
        local index = window.offset + slot
        local item = field.options[index]
        if not item then break end
        local y = rect.y + slot
        local active = index == field.highlighted
        local fg = active and appearance.selection_text(theme) or theme.text
        local bg = active and theme.accent or theme.surface
        frame.put(painter, rect.x, y, frame.pad(item.label, rect.width), rect.width, fg, bg)
        if hit_index then frame.add_hit(painter, "option", hit_index, item.value, rect.x, y, rect.width, 1) end
    end
    return 1 + window.capacity
end

function M.checkbox_new(checked: boolean): Checkbox return {checked = checked} end
-- Space or Enter toggles.
function M.checkbox_key(field: Checkbox, event: unknown): boolean
    if type(event) ~= "table" or event.type ~= "key" or event.action == "release" then return false end
    local key = event.key_type
    if key == "space" or key == "enter" then field.checked = not field.checked; return true end
    return false
end
function M.checkbox_draw(painter: frame.Painter, x: integer, y: integer, width: integer, label: string, field: Checkbox, focused: boolean, hit_index: integer?)
    local theme = painter.theme
    local text = (field.checked and "[x] " or "[ ] ") .. label
    local fg = focused and appearance.selection_text(theme) or theme.text
    local bg = focused and theme.accent or theme.surface
    frame.put(painter, x, y, text, width, fg, bg)
    if hit_index then frame.add_hit(painter, "field", hit_index, "", x, y, width, 1) end
end

-- A single-choice group of options rendered as one row each; selected holds
-- the chosen option's index (0 when options is empty).
function M.radio_new(options: {Option}, value: string): Radio
    local selected = #options > 0 and 1 or 0
    for index, option in ipairs(options) do if option.value == value then selected = index end end
    return {options = options, selected = selected}
end
function M.radio_value(field: Radio): string?
    local option = field.options[field.selected]
    return option and option.value or nil
end
function M.radio_set(field: Radio, value: string)
    for index, option in ipairs(field.options) do if option.value == value then field.selected = index; return end end
end
-- Up/Left moves the selection to the previous option, Down/Right to the next.
function M.radio_key(field: Radio, event: unknown): boolean
    if type(event) ~= "table" or event.type ~= "key" or event.action == "release" then return false end
    local key = event.key_type
    local total = #field.options
    if total == 0 then return false end
    if key == "up" or key == "left" then field.selected = maximum(1, field.selected - 1); return true end
    if key == "down" or key == "right" then field.selected = minimum(total, field.selected + 1); return true end
    return false
end
function M.radio_draw(painter: frame.Painter, rect: frame.Rect, field: Radio, focused: boolean, hit_index: integer?)
    local theme = painter.theme
    for index, option in ipairs(field.options) do
        local y = rect.y + index - 1
        if y > rect.y + rect.height - 1 then break end
        local active = index == field.selected
        local text = (active and "(•) " or "(  ) ") .. option.label
        local fg = (active and focused) and appearance.selection_text(theme) or theme.text
        local bg = (active and focused) and theme.accent or theme.surface
        frame.put(painter, rect.x, y, text, rect.width, fg, bg)
        if hit_index then frame.add_hit(painter, "option", hit_index, option.value, rect.x, y, rect.width, 1) end
    end
end

function M.toggle_new(on: boolean): Toggle return {on = on} end
-- Space, Enter, Left or Right flips the state.
function M.toggle_key(field: Toggle, event: unknown): boolean
    if type(event) ~= "table" or event.type ~= "key" or event.action == "release" then return false end
    local key = event.key_type
    if key == "space" or key == "enter" or key == "left" or key == "right" then field.on = not field.on; return true end
    return false
end
function M.toggle_draw(painter: frame.Painter, x: integer, y: integer, width: integer, label: string, field: Toggle, focused: boolean, hit_index: integer?)
    local theme = painter.theme
    local text = (field.on and "[ ON] " or "[OFF] ") .. label
    local fg = focused and appearance.selection_text(theme) or (field.on and theme.ok or theme.text)
    local bg = focused and theme.accent or theme.surface
    frame.put(painter, x, y, text, width, fg, bg)
    if hit_index then frame.add_hit(painter, "field", hit_index, "", x, y, width, 1) end
end

-- The current value of any field kind as one comparable string: the text,
-- number buffer or area value, the selected option's value, or "true"/"false".
function M.value(field: Field): string
    if field.kind == "text" and field.text then return field.text.value end
    if field.kind == "number" and field.number then return field.number.value end
    if field.kind == "textarea" and field.area then return field.area.value end
    if field.kind == "select" and field.select then return M.select_value(field.select) or "" end
    if field.kind == "checkbox" and field.checkbox then return tostring(field.checkbox.checked) end
    if field.kind == "radio" and field.radio then return M.radio_value(field.radio) or "" end
    if field.kind == "toggle" and field.toggle then return tostring(field.toggle.on) end
    return ""
end
-- True when the field's value has changed since construction or the last reset.
function M.dirty(field: Field): boolean return M.value(field) ~= field.baseline end
function M.form_dirty(form: Form): boolean
    for _, item in ipairs(form.fields) do if M.dirty(item) then return true end end
    return false
end
-- Restores one field to its baseline value and clears its error.
function M.reset_field(field: Field)
    local text, number, area = field.text, field.number, field.area
    local select, checkbox, radio, toggle = field.select, field.checkbox, field.radio, field.toggle
    if field.kind == "text" and text then M.text_set(text, field.baseline)
    elseif field.kind == "number" and number then M.number_set(number, tonumber(field.baseline))
    elseif field.kind == "textarea" and area then M.area_set(area, field.baseline)
    elseif field.kind == "select" and select then M.select_set(select, field.baseline)
    elseif field.kind == "checkbox" and checkbox then checkbox.checked = field.baseline == "true"
    elseif field.kind == "radio" and radio then M.radio_set(radio, field.baseline)
    elseif field.kind == "toggle" and toggle then toggle.on = field.baseline == "true" end
    field.error = nil
end
function M.reset(form: Form) for _, field in ipairs(form.fields) do M.reset_field(field) end end

-- The field with its baseline taken from the value its widget holds, so a
-- widget that normalizes its initial value starts clean.
local function baselined(field: Field): Field
    field.baseline = M.value(field)
    return field
end

local function field_text(key: string, label: string, value: string, settings: FieldOptions): Field
    return baselined({key = key, label = label, kind = "text", required = settings.required == true, disabled = settings.disabled == true,
        hint = settings.hint or "", error = nil, baseline = value, validate = settings.validate, rows = 1,
        text = M.text_new(value, settings.placeholder or "", settings.max_length or M.TEXT_MAX_LENGTH, settings.masked == true),
        number = nil, area = nil, select = nil, checkbox = nil, radio = nil, toggle = nil})
end
-- A single-line text field. opts: required, disabled, hint, validate,
-- placeholder, max_length, masked.
function M.field_text(key: string, label: string, value: string, opts: FieldOptions?): Field return field_text(key, label, value, opts or {}) end

local function field_number(key: string, label: string, value: number?, settings: FieldOptions): Field
    local baseline = value and tostring(value) or ""
    return baselined({key = key, label = label, kind = "number", required = settings.required == true, disabled = settings.disabled == true,
        hint = settings.hint or "", error = nil, baseline = baseline, validate = settings.validate, rows = 1,
        number = M.number_new(value, settings.min, settings.max, settings.step),
        text = nil, area = nil, select = nil, checkbox = nil, radio = nil, toggle = nil})
end
-- A bounded numeric field. opts: required, disabled, hint, validate, min, max, step.
function M.field_number(key: string, label: string, value: number?, opts: FieldOptions?): Field return field_number(key, label, value, opts or {}) end

local function field_textarea(key: string, label: string, value: string, settings: FieldOptions): Field
    return baselined({key = key, label = label, kind = "textarea", required = settings.required == true, disabled = settings.disabled == true,
        hint = settings.hint or "", error = nil, baseline = value, validate = settings.validate, rows = maximum(2, settings.rows or 5),
        area = M.area_new(value, settings.max_length or M.AREA_MAX_LENGTH),
        text = nil, number = nil, select = nil, checkbox = nil, radio = nil, toggle = nil})
end
-- A multi-line text area. rows is the field's total drawn height, label
-- included (default 5). opts: required, disabled, hint, validate, max_length, rows.
function M.field_textarea(key: string, label: string, value: string, opts: FieldOptions?): Field return field_textarea(key, label, value, opts or {}) end

local function field_select(key: string, label: string, options: {Option}, value: string, settings: FieldOptions): Field
    return baselined({key = key, label = label, kind = "select", required = settings.required == true, disabled = settings.disabled == true,
        hint = settings.hint or "", error = nil, baseline = value, validate = settings.validate, rows = 1,
        select = M.select_new(options, value),
        text = nil, number = nil, area = nil, checkbox = nil, radio = nil, toggle = nil})
end
-- A single-choice dropdown. opts: required, disabled, hint, validate.
function M.field_select(key: string, label: string, options: {Option}, value: string, opts: FieldOptions?): Field
    return field_select(key, label, options, value, opts or {})
end

local function field_checkbox(key: string, label: string, checked: boolean, settings: FieldOptions): Field
    return baselined({key = key, label = label, kind = "checkbox", required = settings.required == true, disabled = settings.disabled == true,
        hint = settings.hint or "", error = nil, baseline = tostring(checked), validate = settings.validate, rows = 1,
        checkbox = M.checkbox_new(checked),
        text = nil, number = nil, area = nil, select = nil, radio = nil, toggle = nil})
end
-- required on a checkbox means it must be checked to submit (for example
-- "I agree"). opts: required, disabled, hint, validate.
function M.field_checkbox(key: string, label: string, checked: boolean, opts: FieldOptions?): Field return field_checkbox(key, label, checked, opts or {}) end

local function field_radio(key: string, label: string, options: {Option}, value: string, settings: FieldOptions): Field
    return baselined({key = key, label = label, kind = "radio", required = settings.required == true, disabled = settings.disabled == true,
        hint = settings.hint or "", error = nil, baseline = value, validate = settings.validate, rows = 1,
        radio = M.radio_new(options, value),
        text = nil, number = nil, area = nil, select = nil, checkbox = nil, toggle = nil})
end
-- A single-choice group drawn as one row per option. opts: required, disabled, hint, validate.
function M.field_radio(key: string, label: string, options: {Option}, value: string, opts: FieldOptions?): Field
    return field_radio(key, label, options, value, opts or {})
end

local function field_toggle(key: string, label: string, on: boolean, settings: FieldOptions): Field
    return baselined({key = key, label = label, kind = "toggle", required = settings.required == true, disabled = settings.disabled == true,
        hint = settings.hint or "", error = nil, baseline = tostring(on), validate = settings.validate, rows = 1,
        toggle = M.toggle_new(on),
        text = nil, number = nil, area = nil, select = nil, checkbox = nil, radio = nil})
end
-- opts: required, disabled, hint, validate.
function M.field_toggle(key: string, label: string, on: boolean, opts: FieldOptions?): Field return field_toggle(key, label, on, opts or {}) end

-- A form over an ordered list of fields; focus starts at the first enabled
-- field, or 0 when every field is disabled.
function M.form_new(fields: {Field}): Form
    local form: Form = {fields = fields, focus = 0, disabled = false}
    for index, field in ipairs(fields) do
        if not field.disabled then form.focus = index; break end
    end
    return form
end

local function close_selects(form: Form)
    for _, field in ipairs(form.fields) do
        if field.kind == "select" and field.select then field.select.open = false end
    end
end
-- Moves focus to the next enabled field, wrapping; closes any open dropdown.
function M.focus_next(form: Form)
    close_selects(form)
    local total = #form.fields
    if total == 0 then return end
    local index = form.focus
    for _ = 1, total do
        index = index % total + 1
        if not form.fields[index].disabled then form.focus = index; return end
    end
end
-- Moves focus to the previous enabled field, wrapping; closes any open dropdown.
function M.focus_previous(form: Form)
    close_selects(form)
    local total = #form.fields
    if total == 0 then return end
    local index = form.focus
    for _ = 1, total do
        index = index - 1
        if index < 1 then index = total end
        if not form.fields[index].disabled then form.focus = index; return end
    end
end
-- Focuses the field at index directly (for a mouse click); false when it is
-- out of range or disabled.
function M.focus_at(form: Form, index: integer): boolean
    local field = form.fields[index]
    if not field or field.disabled then return false end
    close_selects(form)
    form.focus = index
    return true
end

-- Routes one key event: Tab/Shift+Tab move focus, everything else goes to
-- the focused field's own key handler. Clears that field's error on change.
-- Returns true when the event changed the form.
function M.key(form: Form, event: unknown): boolean
    if form.disabled or type(event) ~= "table" then return false end
    if event.type == "key" and event.action ~= "release" and event.key_type == "tab" then
        if event.shift == true then M.focus_previous(form) else M.focus_next(form) end
        return true
    end
    local field = form.fields[form.focus]
    if not field or field.disabled then return false end
    local changed = false
    if field.kind == "text" and field.text then changed = M.text_key(field.text, event)
    elseif field.kind == "number" and field.number then changed = M.number_key(field.number, event)
    elseif field.kind == "textarea" and field.area then changed = M.area_key(field.area, event)
    elseif field.kind == "select" and field.select then changed = M.select_key(field.select, event)
    elseif field.kind == "checkbox" and field.checkbox then changed = M.checkbox_key(field.checkbox, event)
    elseif field.kind == "radio" and field.radio then changed = M.radio_key(field.radio, event)
    elseif field.kind == "toggle" and field.toggle then changed = M.toggle_key(field.toggle, event) end
    if changed then field.error = nil end
    return changed
end
-- Routes one resolved frame.hit from frame.hit(hits, x, y): kind "field"
-- focuses (and toggles a checkbox, toggle or open dropdown); kind "option"
-- picks a select or radio option by its value. Returns true on a change.
function M.click(form: Form, hit: frame.Hit): boolean
    if form.disabled then return false end
    local index = hit.index
    local field = form.fields[index]
    if not field or field.disabled then return false end
    if hit.kind == "field" then
        local was_open = field.select ~= nil and field.select.open
        M.focus_at(form, index)
        if field.kind == "checkbox" and field.checkbox then field.checkbox.checked = not field.checkbox.checked; field.error = nil; return true end
        if field.kind == "toggle" and field.toggle then field.toggle.on = not field.toggle.on; field.error = nil; return true end
        if field.kind == "select" and field.select then
            field.select.open = not was_open
            field.select.highlighted = maximum(1, field.select.selected)
            return true
        end
        return true
    end
    if hit.kind == "option" then
        M.focus_at(form, index)
        if field.kind == "select" and field.select then
            for opt_index, option in ipairs(field.select.options) do
                if option.value == hit.key then field.select.selected, field.select.open, field.error = opt_index, false, nil; return true end
            end
        elseif field.kind == "radio" and field.radio then
            for opt_index, option in ipairs(field.radio.options) do
                if option.value == hit.key then field.radio.selected, field.error = opt_index, nil; return true end
            end
        end
    end
    return false
end
-- Routes a wheel step to the focused field: scrolls a text area, or moves
-- the highlight of an open dropdown. Returns true when it did something.
function M.scroll(form: Form, delta: integer): boolean
    if form.disabled then return false end
    local field = form.fields[form.focus]
    if not field or field.disabled then return false end
    if field.kind == "textarea" and field.area then area_move_line(field.area, delta); return true end
    if field.kind == "select" and field.select and field.select.open then
        local total = maximum(1, #field.select.options)
        field.select.highlighted = maximum(1, minimum(total, field.select.highlighted + delta))
        return true
    end
    return false
end

-- The built-in checks (required, and a number's bounds) plus the field's own
-- validate, or nil when the field passes. Disabled fields always pass.
function M.validate_field(field: Field): string?
    if field.disabled then return nil end
    if field.required then
        if field.kind == "checkbox" or field.kind == "toggle" then
            if M.value(field) ~= "true" then return "Required" end
        elseif M.value(field) == "" then
            return "Required"
        end
    end
    if field.kind == "number" and field.number then
        local parsed = M.number_value(field.number)
        if field.number.value ~= "" and not parsed then return "Enter a valid number" end
        if parsed then
            if field.number.min and parsed < field.number.min then return "At least " .. tostring(field.number.min) end
            if field.number.max and parsed > field.number.max then return "At most " .. tostring(field.number.max) end
        end
    end
    if field.validate then
        local message = field.validate(field)
        if message then return message end
    end
    return nil
end
local function store_error(field: Field, message: string?) field.error = message end
-- Validates every enabled field, storing each field's message on .error.
-- Returns true when every field passed.
function M.validate(form: Form): boolean
    local ok = true
    for _, field in ipairs(form.fields) do
        local message = M.validate_field(field)
        store_error(field, message)
        if message then ok = false end
    end
    return ok
end
-- True when the form is enabled and every field currently validates, without
-- storing errors; use to gate a submit button's enabled state.
function M.can_submit(form: Form): boolean
    if form.disabled then return false end
    for _, field in ipairs(form.fields) do
        if M.validate_field(field) then return false end
    end
    return true
end

local function base_rows(field: Field): integer
    if field.kind == "textarea" then return field.rows end
    if field.kind == "radio" and field.radio then return 1 + maximum(1, #field.radio.options) end
    if field.kind == "select" and field.select then
        if field.select.open then return 1 + minimum(M.SELECT_MAX_VISIBLE, maximum(1, #field.select.options)) end
        return 1
    end
    return 1
end
-- The rows a field needs at its current state (open dropdown, radio option
-- count, a shown error), for sizing a frame.stack of field rectangles.
function M.rows(field: Field): integer
    local extra = (field.error and field.error ~= "") and 1 or 0
    return base_rows(field) + extra
end
-- Draws one field of form at its position in form.fields, inside rect
-- (sized at least M.rows(field) tall). Single-row kinds draw the label and
-- the value on one row; textarea and radio draw an uppercase label row above
-- their body. A shown error goes on the row after the widget's own rows.
function M.draw(painter: frame.Painter, rect: frame.Rect, form: Form, index: integer)
    local field = form.fields[index]
    if not field or rect.width <= 0 or rect.height <= 0 then return end
    local theme = painter.theme
    local focused = index == form.focus and not field.disabled
    local hit = field.disabled and nil or index
    local total = minimum(rect.height, base_rows(field))
    local label_width = minimum(rect.width, minimum(16, maximum(4, rect.width // 3)))
    local body_x = rect.x + label_width + 1
    local body_width = maximum(0, rect.width - label_width - 1)
    if field.kind == "checkbox" and field.checkbox then
        M.checkbox_draw(painter, rect.x, rect.y, rect.width, field.label, field.checkbox, focused, hit)
    elseif field.kind == "toggle" and field.toggle then
        M.toggle_draw(painter, rect.x, rect.y, rect.width, field.label, field.toggle, focused, hit)
    elseif field.kind == "text" and field.text then
        frame.put(painter, rect.x, rect.y, frame.pad(field.label, label_width), label_width, theme.muted)
        if body_width > 0 then M.text_draw(painter, body_x, rect.y, body_width, field.text, focused, hit) end
    elseif field.kind == "number" and field.number then
        frame.put(painter, rect.x, rect.y, frame.pad(field.label, label_width), label_width, theme.muted)
        if body_width > 0 then M.number_draw(painter, body_x, rect.y, body_width, field.number, focused, hit) end
    elseif field.kind == "select" and field.select then
        frame.put(painter, rect.x, rect.y, frame.pad(field.label, label_width), label_width, theme.muted)
        M.select_draw(painter, {x = body_x, y = rect.y, width = body_width, height = total}, field.select, focused, hit)
    elseif field.kind == "textarea" and field.area then
        frame.put(painter, rect.x, rect.y, string.upper(field.label), rect.width, theme.muted)
        M.area_draw(painter, {x = rect.x, y = rect.y + 1, width = rect.width, height = maximum(0, total - 1)}, field.area, focused, hit)
    elseif field.kind == "radio" and field.radio then
        frame.put(painter, rect.x, rect.y, string.upper(field.label), rect.width, theme.muted)
        M.radio_draw(painter, {x = rect.x, y = rect.y + 1, width = rect.width, height = maximum(0, total - 1)}, field.radio, focused, hit)
    end
    if field.error and field.error ~= "" and rect.height > total then
        frame.put(painter, rect.x, rect.y + total, field.error, rect.width, theme.error)
    end
end

return M
