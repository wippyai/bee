-- MIT. The timeline frame: the thread picker, or one thread's records in
-- owner order with the recap as stored, the session state, a detail pane
-- for the selected record, explicit actions and the status line. Every
-- text comes through the model's bounding; the view interprets nothing.
local tty = require("tty")
local appearance = require("appearance")
local model = require("model")
type Hit = {kind: string, index: integer, key: string, x: integer, y: integer, width: integer, height: integer}
type Frame = {rows: {string}, hits: {Hit}, capacity: integer, offset: integer}
local M = {}
local RESET = "\27[0m"
local function maximum(a: integer, b: integer): integer if a > b then return a end; return b end
function M.hit(hits: {Hit}, x: integer, y: integer): Hit?
    for _, hit in ipairs(hits) do
        if x >= hit.x and x < hit.x + hit.width and y >= hit.y and y < hit.y + hit.height then return hit end
    end
    return nil
end
local function session_line(state: model.State): string
    if state.phase == "attaching" then return "Attaching to the thread owner…" end
    if state.phase == "unavailable" then return "Owner unavailable: " .. state.unavailable end
    if state.phase == "resume_required" then return "Resume required: " .. state.notice end
    if state.phase == "reset_required" then return "The subscription closed at the owner; reopen the thread" end
    local current = state.session
    if not current then return "" end
    local line = "Cursor " .. tostring(current.after_sequence) .. " of " .. tostring(state.head_sequence) .. "  lease " .. tostring(current.lease_generation) .. "  owner incarnation " .. tostring(current.owner_incarnation)
    if current.state == "detached" then line = line .. "  detached: " .. state.unavailable end
    if state.dropped_through > 0 then line = line .. "  earlier records through " .. tostring(state.dropped_through) .. " not shown" end
    return line
end
function M.draw(width: integer, height: integer, preferences: appearance.Preferences, state: model.State, offset: integer, status: string): Frame
    local theme = appearance.theme(preferences.theme)
    local canvas = tty.canvas(width, height)
    local hits: {Hit} = {}
    local function put(x: integer, y: integer, value: string, size: integer, fg: string?, bg: string?)
        if y >= 1 and y <= height and x >= 1 and size > 0 then
            canvas:put(x, y, appearance.style(fg or theme.text, bg or theme.surface) .. value .. RESET, size)
        end
    end
    local function line(y: integer, value: string, fg: string?, bg: string?)
        put(1, y, string.rep(" ", width), width, fg, bg)
        put(2, y, tty.text.truncate(value, maximum(0, width - 2), "…"), maximum(0, width - 2), fg, bg)
    end
    canvas:clear(appearance.style(theme.text, theme.surface) .. " " .. RESET)
    local actions_y = height - 1
    local x = 2
    local function button(kind: string, label: string, enabled: boolean)
        local size = tty.text.width(label)
        if x + size > width then return end
        put(x, actions_y, label, size, enabled and appearance.selection_text(theme) or theme.muted, enabled and theme.accent or theme.surface)
        if enabled then hits[#hits + 1] = {kind = kind, index = 0, key = "", x = x, y = actions_y, width = size, height = 1} end
        x = x + size + 1
    end
    if state.phase == "picking" then
        line(1, "TIMELINE  choose a thread", theme.text)
        local picker = state.picker
        if picker.unavailable then line(2, "Threads unavailable: " .. picker.unavailable, theme.muted)
        else line(2, string.format("%-40s %-10s %6s  %s", "THREAD", "STATE", "HEAD", "OWNER"), theme.muted) end
        local first, last = 3, height - 2
        local capacity = maximum(0, last - first + 1)
        local next_offset = math.floor(math.max(0, math.min(maximum(0, #picker.threads - capacity), offset)))
        for index, summary in ipairs(picker.threads) do
            if summary.thread_id == picker.selected then
                if index <= next_offset then next_offset = index - 1 end
                if index > next_offset + capacity then next_offset = index - capacity end
            end
        end
        if #picker.threads == 0 and not picker.unavailable then line(first, "No threads to read", theme.muted) end
        for slot = 1, capacity do
            local summary = picker.threads[next_offset + slot]
            if not summary then break end
            local y = first + slot - 1
            local active = summary.thread_id == picker.selected
            local label = string.format("%-40s %-10s %6d  %s", tty.text.truncate(summary.title ~= "" and summary.title or summary.thread_id, 40, "…"), summary.state, summary.head_sequence, summary.owner_id)
            if state.technical then label = label .. "  " .. summary.thread_id end
            line(y, label, active and appearance.selection_text(theme) or theme.text, active and theme.accent or theme.surface)
            hits[#hits + 1] = {kind = "thread", index = next_offset + slot, key = summary.thread_id, x = 1, y = y, width = width, height = 1}
        end
        if height >= 4 then
            local available = picker.unavailable == nil
            button("open", " Open ", available and picker.selected ~= nil)
            button("more", " More ", available and picker.next_after ~= nil)
            button("refresh", " Refresh ", true)
            button("technical", state.technical and " Less " or " Details ", true)
        end
        local message = status
        if message == "" then message = state.notice end
        if message == "" then message = "↑↓ select · Enter open · M more · R refresh" end
        line(height, message, theme.muted)
        return {rows = canvas:rows(), hits = hits, capacity = capacity, offset = next_offset}
    end
    local title = "TIMELINE  " .. (state.title ~= "" and state.title or tostring(state.thread_id))
    if state.thread_state ~= "" then title = title .. "  " .. state.thread_state end
    if state.technical then title = title .. "  " .. tostring(state.thread_id) end
    line(1, title, theme.text)
    local recap = state.recap
    if recap then
        local head = "Recap through " .. tostring(recap.through_sequence) .. (recap.last_turn ~= "" and ("  last turn " .. recap.last_turn) or "")
        if recap.lines[1] then head = head .. ": " .. recap.lines[1] end
        line(2, head, theme.muted)
    else line(2, "No recap stored", theme.muted) end
    line(3, session_line(state), theme.muted)
    local selected = model.selected_row(state)
    local detail_rows = 0
    if selected and state.technical and height >= 12 then detail_rows = 4 end
    local list_first = 4
    local list_last = height - 2 - detail_rows
    local capacity = maximum(0, list_last - list_first + 1)
    local rows = state.rows
    local last = maximum(0, #rows - capacity)
    local next_offset = math.floor(math.max(0, math.min(last, offset)))
    if state.follow then next_offset = last end
    if selected then
        for index, row in ipairs(rows) do
            if row.sequence == selected.sequence then
                if index <= next_offset then next_offset = index - 1 end
                if index > next_offset + capacity then next_offset = index - capacity end
            end
        end
    end
    if #rows == 0 then line(list_first, state.phase == "attached" and "No records yet" or "", theme.muted) end
    for slot = 1, capacity do
        local row = rows[next_offset + slot]
        if not row then break end
        local y = list_first + slot - 1
        local active = selected ~= nil and row.sequence == selected.sequence
        local label = string.format("%6d %s %-18s %-10s %s", row.sequence, row.glyph, row.kind, row.source, row.summary)
        if state.gap_after ~= nil and next_offset + slot > 1 and rows[next_offset + slot - 1].sequence == state.gap_after then
            label = "(records between " .. tostring(state.gap_after) .. " and " .. tostring(row.sequence) .. " not shown) " .. label
        end
        line(y, label, active and appearance.selection_text(theme) or theme.text, active and theme.accent or theme.surface)
        hits[#hits + 1] = {kind = "row", index = next_offset + slot, key = tostring(row.sequence), x = 1, y = y, width = width, height = 1}
    end
    if selected and detail_rows > 0 then
        local y = list_last + 1
        put(1, y, string.rep("─", width), width, theme.border)
        line(y + 1, selected.details[1], theme.text)
        line(y + 2, selected.details[2], theme.text)
        line(y + 3, "producer " .. selected.producer_id .. (selected.approval_id and ("  approval " .. selected.approval_id .. " is decided in Approvals") or ""), theme.text)
    end
    if height >= 4 then
        button("follow", state.follow and " Following " or " Follow ", true)
        button("threads", " Threads ", true)
        button("refresh", " Refresh ", true)
        button("technical", state.technical and " Less " or " Details ", true)
    end
    local message = status
    if message == "" then message = state.notice end
    if message == "" and state.unavailable ~= "" and state.phase == "attached" then message = "Owner unavailable: " .. state.unavailable end
    if message == "" then message = "↑↓ select · F follow · B threads · R refresh · T details" end
    line(height, message, theme.muted)
    return {rows = canvas:rows(), hits = hits, capacity = capacity, offset = next_offset}
end
return M
