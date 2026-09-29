-- MIT. One open Agent session: its activity, the work given to it and each
-- result, with a line to give it more work. Text is bounded to the display.
local tty = require("tty")
local appearance = require("appearance")
local frame = require("frame")
local text = require("text")
local agents = require("agents")
local M = {}
type Frame = {rows: {string}, hits: {frame.Hit}}
local HINTS = frame.hints({{key = "Enter", verb = "send"}, {key = "Ctrl+X", verb = "close session"}, {key = "Esc", verb = "back"}})
local ACTIVITY_ROLE = {idle = "muted", working = "accent", blocked = "warn", stalled = "error"}
local STATE_ROLE = {queued = "muted", working = "muted", ready = "text", failed = "error", blocked = "warn", uncertain = "warn"}
local STATE_LABEL = {queued = "queued", working = "working", ready = "", failed = "", blocked = "blocked", uncertain = "uncertain"}

local function wrap(value: string, room: integer): {string}
    local out: {string} = {}
    local width = math.floor(math.max(1, room))
    for line in (value .. "\n"):gmatch("(.-)\n") do
        local clean = line:gsub("%c", " ")
        local size = tty.text.width(clean)
        if size <= width then
            out[#out + 1] = clean
        else
            local offset = 0
            while offset < size do
                out[#out + 1] = tty.text.cut(clean, offset, offset + width)
                offset = offset + width
            end
        end
    end
    return out
end

-- The draft after one input event: printable text and paste append, Backspace
-- removes one character, Ctrl+U clears. Anything else leaves it unchanged.
function M.edit(draft: string, event: {[string]: unknown}): string
    local limit = 4096
    local value = draft
    if event.type == "paste" then
        value = draft .. tostring(event.text)
    elseif event.type == "key" and event.action == "press" then
        local name, key = tostring(event.key_type), tostring(event.key)
        if event.ctrl == true then
            if key == "u" then value = "" end
        elseif name == "backspace" or name == "backspace2" then
            value = draft:gsub("[^\128-\191][\128-\191]*$", "")
        elseif name == "space" and event.alt ~= true then
            value = draft .. " "
        elseif event.alt ~= true and key ~= "" and not key:find("%c") then
            value = draft .. key
        end
    end
    if #value > limit then return draft end
    return value
end

-- Transcript rows: each input, then its state or result.
function M.lines(conv: agents.Conversation, room: integer): {frame.LogLine}
    local lines: {frame.LogLine} = {}
    for _, turn in ipairs(conv.turns) do
        for index, row in ipairs(wrap(turn.input, room - 2)) do
            lines[#lines + 1] = {text = (index == 1 and "> " or "  ") .. row, role = "accent"}
        end
        local role = STATE_ROLE[turn.state]
        local label = STATE_LABEL[turn.state]
        if turn.text == "" then
            lines[#lines + 1] = {text = "  " .. (label ~= "" and label or turn.state), role = role}
        else
            for index, row in ipairs(wrap(turn.text, room - 2)) do
                local prefix = index == 1 and label ~= "" and (label .. ": ") or ""
                lines[#lines + 1] = {text = "  " .. prefix .. row, role = role}
            end
        end
    end
    return lines
end

function M.draw(width: integer, height: integer, preferences: appearance.Preferences, conv: agents.Conversation,
    draft: string, status: string): Frame
    local painter = frame.new(width, height, preferences)
    local theme = painter.theme
    frame.header(painter, "AGENT", text.bound(conv.title, 128))
    local badge = conv.activity .. (conv.queued > 0 and (" · " .. tostring(conv.queued) .. " queued") or "")
    if height >= 3 then
        frame.badge(painter, 2, 2, badge, ACTIVITY_ROLE[conv.activity])
        if conv.lifecycle ~= "active" then frame.put(painter, #badge + 5, 2, conv.lifecycle, width - #badge - 6, theme.muted) end
    end
    local input_row = height - 2
    local last = input_row - 1
    local lines = M.lines(conv, math.floor(math.max(1, width - 2)))
    if last >= 3 then
        frame.log(painter, 3, last, {lines = lines, selected = #lines, offset = 0, focused = false})
    end
    if height >= 5 then
        frame.line(painter, input_row, "> " .. text.bound(draft, 512) .. "▏", theme.text)
        frame.actions(painter, height - 1, {
            {kind = "send", label = "Send", enabled = draft ~= "", primary = true},
            {kind = "close_session", label = "Close session", enabled = true},
            {kind = "back", label = "Back", enabled = true},
        })
    end
    local message = status ~= "" and status or conv.notice
    if height >= 2 then frame.footer(painter, text.bound(message, 512), HINTS) end
    return {rows = frame.rows(painter), hits = painter.hits}
end
return M
