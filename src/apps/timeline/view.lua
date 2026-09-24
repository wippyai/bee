-- MIT. The timeline frame: the thread picker, or one thread's records in
-- owner order with the recap as stored, the session state, a detail pane
-- for the selected record, explicit actions and the status line. Every
-- text comes through the model's bounding; the view interprets nothing.
local appearance = require("appearance")
local frame = require("frame")
local model = require("model")
type Frame = {rows: {string}, hits: {frame.Hit}, capacity: integer, offset: integer}
local M = {}
local function session_line(state: model.State): string
    if state.phase == "attaching" then return "Attaching to the thread owner…" end
    if state.phase == "unavailable" then return "Owner unavailable: " .. state.unavailable end
    if state.phase == "resume_required" then return "Resume required: " .. state.notice end
    if state.phase == "reset_required" then return "The subscription closed at the owner; reopen the thread" end
    local current = state.session
    if not current then return "" end
    local line = "Live · " .. tostring(state.head_sequence) .. " records"
    if current.state == "detached" then line = line .. "  detached: " .. state.unavailable end
    if state.dropped_through > 0 then line = line .. "  earlier records through " .. tostring(state.dropped_through) .. " not shown" end
    return line
end
local function technical_session_line(state: model.State): string
    local current = state.session
    if not current then return "" end
    return "Cursor " .. tostring(current.after_sequence) .. " of " .. tostring(state.head_sequence) .. "  lease " .. tostring(current.lease_generation) ..
        "  owner incarnation " .. tostring(current.owner_incarnation)
end
local function row_label(row: model.Row, technical: boolean): string
    if technical then
        return string.format("%6d %s %-18s %-10s %s", row.sequence, row.glyph, row.kind, row.source, row.summary)
    end
    return row.glyph .. " " .. row.state_label .. " · " .. row.activity
end
local PICKER_HINTS = frame.hints({{key = "↑↓", verb = "select"}, {key = "Enter", verb = "open"}, {key = "M", verb = "more"},
    {key = "R", verb = "refresh"}, {key = "T", verb = "details"}})
local THREAD_HINTS = frame.hints({{key = "↑↓", verb = "select"}, {key = "F", verb = "follow"}, {key = "B", verb = "threads"},
    {key = "R", verb = "refresh"}, {key = "T", verb = "details"}})
local function picker_columns(technical: boolean): {frame.Column}
    local columns: {frame.Column} = {{title = "Thread", width = 0}, {title = "State", width = 10}, {title = "Records", width = 7, align = "right"}}
    if technical then
        columns[#columns + 1] = {title = "Owner", width = 24}
        columns[#columns + 1] = {title = "Id", width = 36}
    end
    return columns
end
function M.draw(width: integer, height: integer, preferences: appearance.Preferences, state: model.State, offset: integer, status: string): Frame
    local painter = frame.new(width, height, preferences)
    local theme = painter.theme
    if state.phase == "picking" then
        local picker = state.picker
        frame.header(painter, "TIMELINE", "Choose a thread")
        local first, last = 3, height - 2
        local window: frame.Window = {offset = 0, capacity = 0}
        if picker.unavailable then
            frame.empty(painter, first, "Threads unavailable: " .. picker.unavailable, "R retries the thread owner")
        elseif #picker.threads == 0 then
            frame.empty(painter, first, "No threads to read", "Threads appear here once an agent or application starts one · R refresh")
        else
            local cells: {{string}} = {}
            local keys: {string} = {}
            local selected = 0
            for index, summary in ipairs(picker.threads) do
                local row = {summary.title ~= "" and summary.title or summary.thread_id, summary.state, tostring(summary.head_sequence)}
                if state.technical then
                    row[#row + 1] = summary.owner_id
                    row[#row + 1] = summary.thread_id
                end
                cells[index] = row
                keys[index] = summary.thread_id
                if summary.thread_id == picker.selected then selected = index end
            end
            window = frame.table(painter, first - 1, last, {columns = picker_columns(state.technical), cells = cells, keys = keys,
                kind = "thread", selected = selected, offset = offset})
        end
        if height >= 4 then
            local available = picker.unavailable == nil
            frame.actions(painter, height - 1, {
                {kind = "open", label = "Open", enabled = available and picker.selected ~= nil, primary = true},
                {kind = "more", label = "More", enabled = available and picker.next_after ~= nil},
                {kind = "refresh", label = "Refresh", enabled = true},
                {kind = "technical", label = state.technical and "Hide details" or "Details", enabled = true},
            })
        end
        local message = status
        if message == "" then message = state.notice end
        frame.footer(painter, message, PICKER_HINTS)
        return {rows = frame.rows(painter), hits = painter.hits, capacity = window.capacity, offset = window.offset}
    end
    local title = "TIMELINE  " .. (state.title ~= "" and state.title or tostring(state.thread_id))
    if state.thread_state ~= "" then title = title .. " · " .. state.thread_state end
    frame.header(painter, title, state.technical and tostring(state.thread_id) or nil)
    local recap = state.recap
    if recap then
        local head = "Recap"
        if recap.lines[1] then head = head .. ": " .. recap.lines[1] end
        if state.technical then head = head .. " · through " .. tostring(recap.through_sequence) .. (recap.last_turn ~= "" and (" · last turn " .. recap.last_turn) or "") end
        frame.line(painter, 2, head, theme.muted)
    else frame.line(painter, 2, "No recap stored", theme.muted) end
    frame.line(painter, 3, state.technical and technical_session_line(state) or session_line(state), theme.muted)
    local selected = model.selected_row(state)
    local detail_rows = 0
    if selected and state.technical and height >= 12 then detail_rows = 4 end
    local list_first = 4
    local list_last = height - 2 - detail_rows
    local rows = state.rows
    local selected_index = 0
    if selected then
        for index, row in ipairs(rows) do if row.sequence == selected.sequence then selected_index = index end end
    end
    local capacity = math.floor(math.max(0, list_last - list_first + 1))
    local start = offset
    if state.follow then start = #rows end
    local window = frame.window(#rows, capacity, selected_index, start)
    if #rows == 0 and state.phase == "attached" and capacity > 0 then
        frame.empty(painter, list_first, "No records yet", capacity > 1 and "Records appear here as the thread's owner commits them" or nil)
    end
    for slot = 1, window.capacity do
        local index = window.offset + slot
        local row = rows[index]
        if not row then break end
        local label = row_label(row, state.technical)
        if state.gap_after ~= nil and index > 1 and rows[index - 1].sequence == state.gap_after then
            label = "(records between " .. tostring(state.gap_after) .. " and " .. tostring(row.sequence) .. " not shown) " .. label
        end
        frame.row(painter, list_first + slot - 1, label, index == selected_index, "row", index, tostring(row.sequence))
    end
    if selected and detail_rows > 0 then
        local y = list_last + 1
        frame.rule(painter, y)
        frame.line(painter, y + 1, selected.details[1], theme.text)
        frame.line(painter, y + 2, selected.details[2], theme.text)
        local detail = selected.details[3]
        if selected.approval_id then detail = detail .. "  approval " .. selected.approval_id .. " is decided in Approvals" end
        frame.line(painter, y + 3, detail, theme.text)
    end
    if height >= 4 then
        frame.actions(painter, height - 1, {
            {kind = "follow", label = state.follow and "Following" or "Follow", enabled = true, active = state.follow},
            {kind = "threads", label = "Threads", enabled = true},
            {kind = "refresh", label = "Refresh", enabled = true},
            {kind = "technical", label = state.technical and "Hide details" or "Details", enabled = true},
        })
    end
    local message = status
    if message == "" then message = state.notice end
    if message == "" and state.unavailable ~= "" and state.phase == "attached" then message = "Owner unavailable: " .. state.unavailable end
    frame.footer(painter, message, THREAD_HINTS)
    return {rows = frame.rows(painter), hits = painter.hits, capacity = window.capacity, offset = window.offset}
end
return M
