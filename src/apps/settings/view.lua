-- Appearance cards and their hit rectangles. No processes or workspace authority.
local tty = require("tty")
local appearance = require("appearance")
local frame = require("frame")
local build_info = require("build_info")
type Pane = "theme" | "background" | "taskbar" | "about"
type Grid = {columns: integer, rows: integer, capacity: integer, card_width: integer}
type Frame = {rows: {string}, hits: {frame.Hit}}
local M = {}
local function maximum(a: integer, b: integer): integer if a > b then return a end; return b end
local function about_details(info: build_info.Info, width: integer): {string}
    local details: {string} = {}
    local function field(label: string, value: string)
        local clean = value:gsub("%c", " ")
        local room = maximum(1, width - 4)
        if tty.text.width(label .. "  " .. clean) <= maximum(0, width - 2) then
            details[#details + 1] = label .. "  " .. clean
            return
        end
        details[#details + 1] = label
        for first = 1, #clean, room do details[#details + 1] = "  " .. clean:sub(first, first + room - 1) end
    end
    field("Version", info.version)
    field("Build", info.build)
    field("Source revision", info.source_revision)
    field("Source URL", info.source)
    field("Runtime commit", info.runtime_commit)
    field("Runtime URL", info.runtime)
    field("Native version", info.native_version)
    field("Native module", info.native)
    field("Website", info.website)
    return details
end
function M.about_count(width: integer): integer return #about_details(build_info.info(), width) end
function M.grid(width: integer, height: integer): Grid
    local columns = maximum(1, math.floor(math.min(3, (width - 2) // 24)))
    local rows = maximum(0, (height - 6) // 6)
    return {columns = columns, rows = rows, capacity = columns * rows,
        card_width = maximum(1, (width - 2 - (columns - 1) * 2) // columns)}
end
function M.offset(index: integer, offset: integer, grid: Grid, count: integer, reveal: boolean): integer
    if grid.capacity == 0 then return 0 end
    local last = maximum(0, ((count + grid.columns - 1) // grid.columns - grid.rows) * grid.columns)
    local value = math.floor(math.max(0, math.min(last, offset // grid.columns * grid.columns)))
    if reveal then
        if index <= value then value = (index - 1) // grid.columns * grid.columns end
        if index > value + grid.capacity then value = ((index - 1) // grid.columns - grid.rows + 1) * grid.columns end
    end
    return math.floor(math.max(0, math.min(last, value)))
end
local HINTS = frame.hints({{key = "←→↑↓", verb = "choose"}, {key = "Tab", verb = "switch"}, {key = "D", verb = "default"}})
local ABOUT_HINTS = frame.hints({{key = "Tab", verb = "switch"}, {key = "PgUp/PgDn", verb = "scroll"}})
local TABS: {frame.Tab} = {{kind = "theme", label = "Themes", short = "Theme"}, {kind = "background", label = "Backgrounds", short = "BG"},
    {kind = "taskbar", label = "Tabs", short = "Tabs"}, {kind = "about", label = "About", short = "About"}}
function M.draw(width: integer, height: integer, preferences: appearance.Preferences, pane: Pane, offset: integer, message: string?): Frame
    local painter = frame.new(width, height, preferences)
    local theme = painter.theme
    local grid = M.grid(width, height)
    local themes, backgrounds = appearance.themes(), appearance.backgrounds()
    local count = pane == "taskbar" and 2 or (pane == "theme" and #themes or (pane == "background" and #backgrounds or 0))
    local notice = message or ""
    frame.header(painter, pane == "about" and "BEE SETTINGS · ABOUT" or "BEE SETTINGS · DISPLAY")
    if pane ~= "about" and width >= 18 and height >= 3 then
        local wide = width >= 48
        local label = wide and "Use node default (D)" or "Default (D)"
        local size = tty.text.width(" " .. label .. " ")
        frame.button(painter, wide and width - size or 2, wide and 1 or 3, {kind = "inherit", label = label, enabled = true})
    end
    if height >= 2 then frame.tabs(painter, 2, TABS, pane) end
    if pane == "about" then
        local details = about_details(build_info.info(), width)
        local capacity = math.floor(math.max(0, height - 5))
        local first = math.floor(math.max(0, math.min(math.max(0, #details - capacity), offset)))
        for index = 1, math.floor(math.min(capacity, #details - first)) do
            frame.line(painter, 4 + index - 1, details[first + index], theme.text)
        end
        local page = "Build details are from the loaded Bee bundle"
        if capacity == 0 then page = "Resize to read build details"
        elseif #details > capacity then
            page = "Details " .. tostring(first + 1) .. "–" .. tostring(math.min(#details, first + capacity)) .. "/" .. tostring(#details)
        end
        if height >= 3 then frame.footer(painter, notice ~= "" and notice or page, ABOUT_HINTS) end
        return {rows = frame.rows(painter), hits = painter.hits}
    end
    if grid.capacity == 0 or width < 12 then
        local label = pane == "taskbar" and (preferences.taskbar == "icons" and "Icons" or "Labels") or (pane == "theme" and theme.title or preferences.background)
        if height >= 5 and width >= 16 then
            frame.put(painter, 2, 4, " ‹ ", 3, theme.accent)
            frame.put(painter, 6, 4, label, width - 11, theme.text)
            frame.put(painter, width - 4, 4, " › ", 3, theme.accent)
            frame.add_hit(painter, "step", -1, "", 2, 4, 3, 1)
            frame.add_hit(painter, "step", 1, "", width - 4, 4, 3, 1)
        else
            frame.line(painter, 4, label, theme.text)
        end
        if notice ~= "" and height >= 3 then frame.line(painter, height >= 5 and height or 3, notice, theme.text) end
        return {rows = frame.rows(painter), hits = painter.hits}
    end
    for slot = 1, grid.capacity do
        local index = offset + slot
        if index > count then break end
        local x = 2 + ((slot - 1) % grid.columns) * (grid.card_width + 2)
        local y = 4 + ((slot - 1) // grid.columns) * 6
        local id = pane == "taskbar" and (index == 1 and "labels" or "icons") or (pane == "theme" and themes[index].id or backgrounds[index])
        local title = pane == "theme" and themes[index].title or (id:sub(1, 1):upper() .. id:sub(2))
        local selected = id == (pane == "taskbar" and (preferences.taskbar or "labels") or (pane == "theme" and preferences.theme or preferences.background))
        local edge = selected and theme.accent or theme.border
        local inside = grid.card_width - 2
        frame.put(painter, x, y, "╭" .. string.rep("─", inside) .. "╮", grid.card_width, edge)
        for row = 1, 3 do
            frame.put(painter, x, y + row, "│" .. string.rep(" ", inside) .. "│", grid.card_width, edge)
        end
        frame.put(painter, x, y + 4, "╰" .. string.rep("─", inside) .. "╯", grid.card_width, edge)
        frame.put(painter, x + 1, y, " " .. (selected and "✓ " or "") .. title .. " ", inside, selected and theme.accent or theme.text)
        if pane == "taskbar" then
            frame.put(painter, x + 1, y + 2, index == 1 and " Terminal  Settings " or " >_  S  P ", inside, theme.text)
        elseif pane == "background" then
            for row = 1, 3 do
                frame.put(painter, x + 1, y + row, appearance.background_row(id, inside, row, 3), inside, theme.pattern, theme.ground)
            end
        else
            local candidate = themes[index]
            frame.put(painter, x + 1, y + 1, string.rep(" ", inside), inside, candidate.text, candidate.ground)
            frame.put(painter, x + 1, y + 2, "  Aa   Bee" .. string.rep(" ", inside), inside, candidate.text, candidate.surface)
            local band = maximum(1, inside // 3)
            frame.put(painter, x + 1, y + 3, string.rep(" ", inside), inside, candidate.text, candidate.accent)
            frame.put(painter, x + 1 + band, y + 3, string.rep(" ", band), band, candidate.text, candidate.border)
            frame.put(painter, x + 1 + band * 2, y + 3, string.rep(" ", inside - band * 2), inside - band * 2, candidate.text, candidate.muted)
        end
        frame.add_hit(painter, "select", index, id, x, y, grid.card_width, 5)
    end
    local last = math.floor(math.min(count, offset + grid.capacity))
    local range = tostring(offset + 1) .. "–" .. tostring(last) .. "/" .. tostring(count)
    local status = "Theme: " .. theme.title .. "  Background: " .. preferences.background
    if width < 48 then status = pane == "theme" and ("Theme: " .. theme.title) or ("Background: " .. preferences.background) end
    if pane == "taskbar" then status = "Tabs: " .. (preferences.taskbar == "icons" and "Icons" or "Labels") end
    if notice ~= "" then status = notice end
    local pager = " ‹ " .. range .. " › "
    if tty.text.width(pager) > width - 2 then pager = " ‹  › " end
    local pager_width = tty.text.width(pager)
    local pager_x = width - pager_width
    frame.put(painter, pager_x, height - 1, pager, pager_width, theme.muted)
    if offset > 0 then
        frame.put(painter, pager_x, height - 1, " ‹ ", 3, theme.accent)
        frame.add_hit(painter, "page", -1, "", pager_x, height - 1, 3, 1)
    end
    if last < count then
        frame.put(painter, width - 3, height - 1, " › ", 3, theme.accent)
        frame.add_hit(painter, "page", 1, "", width - 3, height - 1, 3, 1)
    end
    frame.footer(painter, status, HINTS)
    return {rows = frame.rows(painter), hits = painter.hits}
end
return M
