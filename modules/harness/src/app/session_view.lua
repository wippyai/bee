-- MIT. One open Agent session: its activity, the work given to it and each
-- result, with a line to give it more work. Text is bounded to the display.
local tty = require("tty")
local appearance = require("appearance")
local frame = require("frame")
local text = require("text")
local agents = require("agents")
local protocol = require("protocol")
local M = {}
type Frame = {rows: {string}, hits: {frame.Hit}, controls: frame.Controls?}
local HINTS = frame.hints({{key = "Enter", verb = "send"}, {key = "Ctrl+K", verb = "stop work"},
    {key = "Ctrl+X", verb = "close session"}, {key = "Esc", verb = "sessions"}})
local ACTIVITY_ROLE = {idle = "muted", working = "accent", blocked = "warn", stalled = "warn"}
local STATE_ROLE = {queued = "muted", working = "muted", ready = "text", failed = "error", blocked = "warn", uncertain = "warn", budget_exceeded = "error"}
local STATE_LABEL = {queued = "queued", working = "working", ready = "", failed = "", blocked = "blocked", uncertain = "uncertain", budget_exceeded = "budget exceeded"}

local function wrap(value: string, room: integer): {string}
    local out: {string} = {}
    local width = math.floor(math.max(1, room))
    for line in (value .. "\n"):gmatch("(.-)\n") do
        local clean = line:gsub("%c", " ")
        local size = tty.text.width(clean)
        if size <= width then
            out[#out + 1] = clean
        else
            local remaining = clean
            while tty.text.width(remaining) > width do
                local piece = tty.text.cut(remaining, 0, width)
                local boundary = tonumber((piece:match("^.*()%s")))
                if remaining:sub(#piece + 1, #piece + 1):match("%s") then boundary = #piece + 1 end
                if boundary and boundary > 1 then
                    out[#out + 1] = piece:sub(1, boundary - 1)
                    remaining = remaining:sub(boundary + 1):gsub("^%s+", "")
                else
                    out[#out + 1] = piece
                    remaining = remaining:sub(#piece + 1)
                end
            end
            out[#out + 1] = remaining
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
        local tools = turn.tools or {}
        local keys: {string} = {}
        for key in pairs(tools) do keys[#keys + 1] = key end
        table.sort(keys)
        for _, key in ipairs(keys) do lines[#lines + 1] = {text = "  " .. text.bound(tools[key], room - 2), role = "muted"} end
        local role = STATE_ROLE[turn.state]
        local label = STATE_LABEL[turn.state]
        if turn.text == "" then
            lines[#lines + 1] = {text = "  " .. (label ~= "" and label or turn.state), role = role}
        else
            for index, row in ipairs(wrap(turn.text, room - 2 - (label ~= "" and #label + 2 or 0))) do
                local prefix = index == 1 and label ~= "" and (label .. ": ") or ""
                lines[#lines + 1] = {text = "  " .. prefix .. row, role = role}
            end
        end
        local reply = turn.text:lower()
        if reply:find("workspace is read-only", 1, true) or reply:find("permission denied", 1, true)
            or (reply:find("permission", 1, true) and reply:find("wasn't granted", 1, true)) then
            lines[#lines + 1] = {text = "  CLI refusals are not Bee approvals.", role = "warn"}
            lines[#lines + 1] = {text = "  Choose a writable profile or folder, then start a new session.", role = "warn"}
        end
    end
    return lines
end

function M.draw(width: integer, height: integer, preferences: appearance.Preferences, conv: agents.Conversation,
    draft: string, status: string, sidebar: {protocol.SessionSnapshot}?): Frame
    if sidebar and #sidebar > 0 and width >= 120 then
        local rail_width = 26
        local rail = frame.new(rail_width, height, preferences)
        frame.header(rail, "SESSIONS")
        local selected = 0
        for index, item in ipairs(sidebar) do if item.session == conv.session:ref() then selected = index end end
        local window = frame.window(#sidebar, height - 4, selected, 0)
        for slot = 1, window.capacity do
            local index = window.offset + slot
            local item = sidebar[index]
            if item then frame.row(rail, slot + 2, (item.activity or "idle") .. " · " .. text.bound(item.title, 128), index == selected, "sidebar_session", index, "") end
        end
        frame.fill(rail, height)
        frame.put(rail, 2, height, "Esc sessions", rail_width - 2, rail.theme.muted)
        local body = M.draw(width - rail_width, height, preferences, conv, draft, status)
        local rail_rows = frame.rows(rail)
        local rows: {string} = {}
        local hits: {frame.Hit} = {}
        for index = 1, height do rows[index] = rail_rows[index] .. body.rows[index] end
        for _, hit in ipairs(rail.hits) do hits[#hits + 1] = hit end
        for _, hit in ipairs(body.hits) do
            hits[#hits + 1] = {kind = hit.kind, index = hit.index, key = hit.key, x = hit.x + rail_width, y = hit.y, width = hit.width, height = hit.height}
        end
        return {rows = rows, hits = hits, controls = body.controls}
    end
    local painter = frame.new(width, height, preferences)
    local theme = painter.theme
    frame.header(painter, "SESSION", text.bound(conv.title, 128))
    local badge = conv.activity .. (conv.queued > 0 and (" · " .. tostring(conv.queued) .. " queued") or "")
    if height >= 3 then
        frame.badge(painter, 2, 2, badge, ACTIVITY_ROLE[conv.activity])
        if conv.lifecycle ~= "active" then frame.put(painter, #badge + 5, 2, conv.lifecycle, width - #badge - 6, theme.muted) end
    end
    local input_row = height - 3
    local last = input_row - 1
    local lines = M.lines(conv, math.floor(math.max(1, width - 2)))
    if height >= 7 then frame.line(painter, 3, "Conversation · " .. (conv.session.snapshot.provider or "Agent"), theme.muted) end
    if conv.details then
        lines = {{text = "Session: " .. conv.session:ref()}, {text = "Definition: " .. (conv.session.snapshot.definition or "Unavailable")},
            {text = "Workspace: " .. (conv.session.snapshot.workspace or "Unavailable")}}
        for _, turn in ipairs(conv.turns) do
            lines[#lines + 1] = {text = "Work: " .. turn.work:ref()}
            for _, row in ipairs(wrap(turn.diagnostics or "", width - 4)) do
                if row ~= "" then lines[#lines + 1] = {text = row, role = "muted"} end
            end
        end
    end
    if #lines == 0 and height >= 9 then
        frame.empty(painter, 4, "Ready for work", "Type below, then Enter sends work to this session")
    end
    if last >= 3 then
        frame.log(painter, 4, last - 1, {lines = lines, selected = 0, offset = math.floor(math.max(0, #lines - (last - 4))), focused = false})
    end
    if height >= 5 then
        frame.line(painter, input_row, conv.lifecycle == "closed" and "Closed · history remains available" or "> " .. text.bound(draft, 512) .. "▏", theme.text)
        frame.actions(painter, height - 1, {
            {kind = conv.lifecycle == "closed" and "new_from_session" or "send", key = "Enter", label = conv.lifecycle == "closed" and "Start new session from this" or "Send", enabled = conv.lifecycle == "closed" or draft ~= "" and conv.lifecycle == "active", primary = true},
            {kind = "back", key = "Esc", label = "Sessions", enabled = true},
            {kind = "details", key = "Ctrl+D", label = conv.details and "Hide details" or "Details", enabled = true, more = true},
            {kind = "stop_work", key = "Ctrl+K", label = "Stop current work", enabled = agents.pending(conv)},
            {kind = "close_session", key = "Ctrl+X", label = "Close session", enabled = conv.lifecycle == "active"},
        })
    end
    local message = status ~= "" and status or conv.notice
    if message == "" and conv.activity == "stalled" and conv.activity_evidence then
        message = "No progress for " .. tostring(conv.activity_evidence.quiet_for_ms) .. " ms · " .. conv.activity_evidence.turn
    end
    if height >= 6 then frame.line(painter, height - 2, text.bound(message, 512), theme.text) end
    if height >= 2 then frame.footer(painter, "", conv.lifecycle == "closed" and frame.hints({{key = "Enter", verb = "start new"}, {key = "Esc", verb = "sessions"}}) or HINTS) end
    return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter)}
end
return M
