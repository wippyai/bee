-- Appearance cards and their hit rectangles. No processes or workspace authority.
local tty = require("tty")
local appearance = require("appearance")
type Pane = "theme" | "background" | "taskbar"
type Hit = {kind: string, index: integer, x: integer, y: integer, width: integer, height: integer}
type Grid = {columns: integer, rows: integer, capacity: integer, card_width: integer}
type Frame = {rows: {string}, hits: {Hit}}
local M = {}
local RESET = "\27[0m"
local function maximum(a: integer, b: integer): integer if a > b then return a end; return b end
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
local function put(canvas: tty.Canvas, x: integer, y: integer, text: string, width: integer, fg: string, bg: string)
    if width <= 0 then return end
    canvas:put(x, y, appearance.style(fg, bg) .. text .. RESET, width)
end
function M.draw(width: integer, height: integer, preferences: appearance.Preferences, pane: Pane, offset: integer, message: string?): Frame
    local theme = appearance.theme(preferences.theme)
    local grid = M.grid(width, height)
    local themes, backgrounds = appearance.themes(), appearance.backgrounds()
    local count = pane == "taskbar" and 2 or (pane == "theme" and #themes or #backgrounds)
    local canvas = tty.canvas(width, height)
    local hits: {Hit} = {}
    canvas:clear(appearance.style(theme.text, theme.surface) .. " " .. RESET)
    put(canvas, 2, 1, "BEE SETTINGS", width - 2, theme.text, theme.surface)
    local tab_x = 2
    for _, kind in ipairs({"theme", "background", "taskbar"}) do
        local text = kind == "theme" and " Themes " or (kind == "background" and " Backgrounds " or " Tabs ")
        if width < 26 then text = kind == "theme" and " Theme " or (kind == "background" and " BG " or " Tabs ") end
        local size = math.floor(math.max(0, math.min(tty.text.width(text), width - tab_x)))
        local selected = pane == kind
        put(canvas, tab_x, 2, text, size, selected and appearance.selection_text(theme) or theme.muted, selected and theme.accent or theme.surface)
        if size >= 3 and height >= 2 then hits[#hits + 1] = {kind = kind, index = 0, x = tab_x, y = 2, width = size, height = 1} end
        tab_x = tab_x + size + 1
    end
    if grid.capacity == 0 or width < 12 then
        local label = pane == "taskbar" and (preferences.taskbar == "icons" and "Icons" or "Labels") or (pane == "theme" and theme.title or preferences.background)
        put(canvas, 2, 4, tty.text.truncate(label, maximum(0, width - 2), "…"), width - 2, theme.text, theme.surface)
        if height >= 5 and width >= 16 then
            put(canvas, 2, 4, string.rep(" ", width - 2), width - 2, theme.text, theme.surface)
            put(canvas, 2, 4, " ‹ ", 3, theme.accent, theme.surface)
            put(canvas, 6, 4, tty.text.truncate(label, width - 11, "…"), width - 11, theme.text, theme.surface)
            put(canvas, width - 4, 4, " › ", 3, theme.accent, theme.surface)
            hits[#hits + 1] = {kind = "step", index = -1, x = 2, y = 4, width = 3, height = 1}
            hits[#hits + 1] = {kind = "step", index = 1, x = width - 4, y = 4, width = 3, height = 1}
        end
        if message and message ~= "" and height >= 3 then
            local row = height >= 5 and height or 3
            put(canvas, 2, row, tty.text.truncate(message:gsub("%c", " "), maximum(0, width - 2), "…"), width - 2, theme.text, theme.surface)
        end
        return {rows = canvas:rows(), hits = hits}
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
        put(canvas, x, y, "╭" .. string.rep("─", inside) .. "╮", grid.card_width, edge, theme.surface)
        for row = 1, 3 do
            put(canvas, x, y + row, "│" .. string.rep(" ", inside) .. "│", grid.card_width, edge, theme.surface)
        end
        put(canvas, x, y + 4, "╰" .. string.rep("─", inside) .. "╯", grid.card_width, edge, theme.surface)
        local label = " " .. (selected and "✓ " or "") .. title .. " "
        put(canvas, x + 1, y, tty.text.truncate(label, inside, "…"), inside, selected and theme.accent or theme.text, theme.surface)
        if pane == "taskbar" then
            local sample = index == 1 and " Terminal  Settings " or " >_  S  P "
            put(canvas, x + 1, y + 2, tty.text.truncate(sample, inside, "…"), inside, theme.text, theme.surface)
        elseif pane == "background" then
            for row = 1, 3 do
                put(canvas, x + 1, y + row, appearance.background_row(id, inside, row, 3), inside, theme.pattern, theme.ground)
            end
        else
            local candidate = themes[index]
            put(canvas, x + 1, y + 1, string.rep(" ", inside), inside, candidate.text, candidate.ground)
            put(canvas, x + 1, y + 2, "  Aa   Bee" .. string.rep(" ", inside), inside, candidate.text, candidate.surface)
            local band = maximum(1, inside // 3)
            put(canvas, x + 1, y + 3, string.rep(" ", inside), inside, candidate.text, candidate.accent)
            put(canvas, x + 1 + band, y + 3, string.rep(" ", band), band, candidate.text, candidate.border)
            put(canvas, x + 1 + band * 2, y + 3, string.rep(" ", inside - band * 2), inside - band * 2, candidate.text, candidate.muted)
        end
        hits[#hits + 1] = {kind = "select", index = index, x = x, y = y, width = grid.card_width, height = 5}
    end
    local last = math.floor(math.min(count, offset + grid.capacity))
    local range = tostring(offset + 1) .. "–" .. tostring(last) .. "/" .. tostring(count)
    local status = "Theme: " .. theme.title .. "  Background: " .. preferences.background
    if width < 48 then status = pane == "theme" and ("Theme: " .. theme.title) or ("Background: " .. preferences.background) end
    if pane == "taskbar" then status = "Tabs: " .. (preferences.taskbar == "icons" and "Icons" or "Labels") end
    if message and message ~= "" then status = message:gsub("%c", " ") end
    put(canvas, 2, height - 2, status, width - 2, theme.text, theme.surface)
    local pager = " ‹ " .. range .. " › "
    if tty.text.width(pager) > width - 2 then pager = " ‹  › " end
    local pager_width = tty.text.width(pager)
    local pager_x = width - pager_width
    local hints = width >= 60 and "Arrows Choose  Tab Switch  Wheel Browse" or "Tab Switch"
    put(canvas, 2, height - 1, hints, maximum(0, pager_x - 3), theme.muted, theme.surface)
    put(canvas, pager_x, height - 1, pager, pager_width, theme.muted, theme.surface)
    if offset > 0 then
        put(canvas, pager_x, height - 1, " ‹ ", 3, theme.accent, theme.surface)
        hits[#hits + 1] = {kind = "page", index = -1, x = pager_x, y = height - 1, width = 3, height = 1}
    end
    if last < count then
        put(canvas, width - 3, height - 1, " › ", 3, theme.accent, theme.surface)
        hits[#hits + 1] = {kind = "page", index = 1, x = width - 3, y = height - 1, width = 3, height = 1}
    end
    return {rows = canvas:rows(), hits = hits}
end
function M.hit(hits: {Hit}, x: integer, y: integer): Hit?
    for _, hit in ipairs(hits) do
        if x >= hit.x and x < hit.x + hit.width and y >= hit.y and y < hit.y + hit.height then return hit end
    end
    return nil
end
return M
