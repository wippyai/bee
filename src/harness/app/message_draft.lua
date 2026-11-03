-- MIT. The message being written to an agent session: typed characters and
-- pasted text, edited at a cursor. A paste of more than CHIP_LINES lines or
-- CHIP_BYTES bytes stands in the draft as one chip that shows only its label,
-- edits as one unit and sends its full text in place. An opened chip shows
-- its text read-only until it is closed.
local tty = require("tty")
local M = {}
M.CHIP_LINES = 3
M.CHIP_BYTES = 800
type Paste = {number: integer, text: string, lines: integer}
-- A part is a run of typed or small pasted text, or one chip.
type Part = {text: string, paste: Paste?}
-- before and after are the parts on each side of the cursor; limit is the
-- most bytes the whole message holds; chips is whether a large paste becomes
-- a chip; shown is the chip whose text is open, scrolled to offset lines.
type Draft = {before: {Part}, after: {Part}, bytes: integer, limit: integer, chips: boolean, pastes: integer, shown: Paste?, offset: integer}

local LAST = "[^\128-\191][\128-\191]*$"
local FIRST = "^[^\128-\191][\128-\191]*"

local function line_count(value: string): integer
    local _, breaks = value:gsub("\n", "")
    if value:sub(-1) ~= "\n" then breaks = breaks + 1 end
    return math.floor(breaks)
end

local function size(bytes: integer): string
    if bytes < 1024 then return tostring(bytes) .. " B" end
    return string.format("%.1f KB", bytes / 1024)
end

-- describe names a chip: its number, lines and size.
function M.describe(paste: Paste): string
    return "Pasted text #" .. tostring(paste.number) .. " · " .. tostring(paste.lines) .. (paste.lines == 1 and " line" or " lines")
        .. " · " .. size(#paste.text)
end

-- label is what a chip shows in place of its text.
function M.label(paste: Paste): string
    return "[" .. M.describe(paste) .. "]"
end

local function shown(parts: {Part}): string
    local out: {string} = {}
    for index, part in ipairs(parts) do
        local paste = part.paste
        out[index] = paste and M.label(paste) or (part.text:gsub("\n", "↵"):gsub("%c", " "))
    end
    return table.concat(out)
end

-- new is a draft of at most limit bytes holding value as typed text.
function M.new(limit: integer, chips: boolean, value: string?): Draft
    local before: {Part} = {}
    if value and value ~= "" then before[1] = {text = value} end
    return {before = before, after = {}, bytes = #(value or ""), limit = limit, chips = chips, pastes = 0, offset = 0}
end

-- text is the message the draft sends: each chip's full text in its place.
function M.text(draft: Draft): string
    local out: {string} = {}
    for _, part in ipairs(draft.before) do out[#out + 1] = part.text end
    for _, part in ipairs(draft.after) do out[#out + 1] = part.text end
    return table.concat(out)
end

function M.empty(draft: Draft): boolean
    return #draft.before == 0 and #draft.after == 0
end

-- clear empties the draft and numbers its next chip from one.
function M.clear(draft: Draft)
    draft.before, draft.after, draft.bytes, draft.pastes, draft.shown, draft.offset = {}, {}, 0, 0, nil, 0
end

-- selected is the chip right after the cursor.
function M.selected(draft: Draft): Paste?
    local part = draft.after[1]
    return part and part.paste
end

local function refuse(draft: Draft, bytes: integer, verb: string): string
    return verb .. " of " .. tostring(bytes) .. " bytes refused: the draft holds " .. tostring(draft.bytes)
        .. " of at most " .. tostring(draft.limit) .. " bytes"
end

-- push_back adds a part before the cursor, joining text to the text there.
local function push_back(parts: {Part}, part: Part)
    local last = parts[#parts]
    if not part.paste and last and not last.paste then last.text = last.text .. part.text
    else parts[#parts + 1] = part end
end

-- push_front adds a part after the cursor, joining text to the text there.
local function push_front(parts: {Part}, part: Part)
    local first = parts[1]
    if not part.paste and first and not first.paste then first.text = part.text .. first.text
    else table.insert(parts, 1, part) end
end

-- take_back removes the chip or last character before the cursor.
local function take_back(parts: {Part}): Part?
    local last = parts[#parts]
    if not last then return nil end
    if last.paste then return table.remove(parts) end
    local character = last.text:match(LAST) or last.text
    last.text = last.text:sub(1, #last.text - #character)
    if last.text == "" then table.remove(parts) end
    return {text = character}
end

-- take_front removes the chip or first character after the cursor.
local function take_front(parts: {Part}): Part?
    local first = parts[1]
    if not first then return nil end
    if first.paste then return table.remove(parts, 1) end
    local character = first.text:match(FIRST) or first.text
    first.text = first.text:sub(#character + 1)
    if first.text == "" then table.remove(parts, 1) end
    return {text = character}
end

local function insert(draft: Draft, part: Part, verb: string): (boolean, string?)
    if draft.bytes + #part.text > draft.limit then return false, refuse(draft, #part.text, verb) end
    push_back(draft.before, part)
    draft.bytes = draft.bytes + #part.text
    return true, nil
end

local function paste(draft: Draft, raw: string): (boolean, string?)
    local value = raw:gsub("\r\n?", "\n")
    if value == "" then return false, nil end
    local lines = line_count(value)
    if not draft.chips or (lines <= M.CHIP_LINES and #value <= M.CHIP_BYTES) then return insert(draft, {text = value}, "Paste") end
    local chip: Paste = {number = draft.pastes + 1, text = value, lines = lines}
    local inserted, refused = insert(draft, {text = value, paste = chip}, "Paste")
    if inserted then draft.pastes = chip.number end
    return inserted, refused
end

-- edit applies one input event: printable keys and pastes insert at the
-- cursor, Backspace and Delete remove the character or whole chip before or
-- after it, Left, Right, Home and End move it, and Ctrl+U clears the draft.
-- It returns whether the draft changed and, for an insertion past the limit,
-- which leaves the draft as it was, why it was refused.
function M.edit(draft: Draft, event: {[string]: unknown}): (boolean, string?)
    if event.type == "paste" then return paste(draft, tostring(event.text)) end
    if event.type ~= "key" or event.action ~= "press" then return false, nil end
    local name, key = tostring(event.key_type), tostring(event.key)
    if event.ctrl == true then
        if key ~= "u" or M.empty(draft) then return false, nil end
        M.clear(draft)
        return true, nil
    end
    if name == "backspace" or name == "backspace2" or name == "delete" then
        local removed = name == "delete" and take_front(draft.after) or name ~= "delete" and take_back(draft.before) or nil
        if not removed then return false, nil end
        draft.bytes = draft.bytes - #removed.text
        return true, nil
    end
    if name == "left" or name == "right" then
        local moved = name == "left" and take_back(draft.before) or name == "right" and take_front(draft.after) or nil
        if not moved then return false, nil end
        if name == "left" then push_front(draft.after, moved) else push_back(draft.before, moved) end
        return true, nil
    end
    if name == "home" or name == "end" then
        local from, to = name == "home" and draft.before or draft.after, name == "home" and draft.after or draft.before
        if #from == 0 then return false, nil end
        if name == "home" then for index = #from, 1, -1 do push_front(to, from[index]) end
        else for _, part in ipairs(from) do push_back(to, part) end end
        if name == "home" then draft.before = {} else draft.after = {} end
        return true, nil
    end
    if event.alt == true then return false, nil end
    if name == "space" then return insert(draft, {text = " "}, "Typing") end
    if key ~= "" and not key:find("%c") then return insert(draft, {text = key}, "Typing") end
    return false, nil
end

-- line is the draft as one row of at most room cells: chips by their labels
-- and the cursor as a bar, scrolled to keep the cursor in view.
function M.line(draft: Draft, room: integer): string
    local before, after = shown(draft.before), shown(draft.after)
    local space = math.floor(math.max(1, room - 1))
    local before_width, after_width = tty.text.width(before), tty.text.width(after)
    if before_width + after_width > space then
        local after_kept = math.floor(math.min(after_width, math.max(space - before_width, space // 3)))
        local before_kept = math.floor(math.min(before_width, space - after_kept))
        before = tty.text.cut(before, before_width - before_kept, before_width)
        after = tty.text.cut(after, 0, after_kept)
    end
    return before .. "▏" .. after
end

-- open shows the selected chip's text; it is false when no chip is selected.
function M.open(draft: Draft): boolean
    local selected = M.selected(draft)
    if not selected then return false end
    draft.shown, draft.offset = selected, 0
    return true
end

-- preview_input applies one event while a chip's text is shown: Up, Down and
-- the page keys scroll it, Esc or Enter closes it, and no key or paste edits
-- the draft. It returns false for any other event and when no chip's text is
-- shown.
function M.preview_input(draft: Draft, event: {[string]: unknown}): boolean
    local open = draft.shown
    if not open then return false end
    if event.type ~= "key" and event.type ~= "paste" then return false end
    if event.type == "paste" or event.action ~= "press" then return true end
    local name = tostring(event.key_type)
    local step = name == "up" and -1 or name == "down" and 1 or name == "pgup" and -10 or name == "pgdown" and 10 or 0
    if name == "esc" or name == "escape" or name == "enter" then draft.shown, draft.offset = nil, 0
    elseif step ~= 0 then draft.offset = math.floor(math.max(0, math.min(open.lines - 1, draft.offset + step))) end
    return true
end
return M
