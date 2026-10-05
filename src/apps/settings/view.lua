-- MIT. Appearance cards, the About details and their hit rectangles. No
-- processes or node authority.
local tty = require("tty")
local appearance = require("appearance")
local frame = require("frame")
local live_updates = require("live_updates")
type Pane = "theme" | "background" | "taskbar" | "edit_mode" | "about"
type Grid = {columns: integer, rows: integer, capacity: integer, card_width: integer}
type Frame = {rows: {string}, hits: {frame.Hit}, controls: frame.Controls?}
-- Build is what this binary and node are: the runtime build, the Lua
-- language version, the node's id and the folder its node runs in.
type Build = {runtime: string, lua: string, node: string, folder: string}
local M = {}
local function maximum(a: integer, b: integer): integer if a > b then return a end; return b end
M.WEBSITE = "https://bee.wippy.ai"
-- bee_version is the installed Bee pack version once Hub status is read.
local function bee_version(live: live_updates.Status?): string
    if not live then return "" end
    for _, item in ipairs(live.modules) do
        if item.component == "bee/bee" then return item.installed_version end
    end
    return ""
end

-- pack_status is a pack's update state in a word or two.
local function pack_status(item: live_updates.Pack, live: live_updates.Status): string
    if item.component == "bee/bee" and live.bee_update and live.bee_update.needs_new_binary then return "needs newer binary" end
    if item.available_version == "" then return "not on Hub" end
    if item.update_available then return "update available" end
    return "current"
end

-- pack_role colors a pack row by its update state.
local function pack_role(status: string): string
    if status == "needs newer binary" then return "warn" end
    if status == "update available" then return "accent" end
    if status == "not on Hub" then return "muted" end
    return "text"
end

local LABEL_WIDTH = 8

-- about_details is the About document at width: the build, then the Bee
-- packs with their Hub releases, each under its heading.
local function about_details(width: integer, live: live_updates.Status?, pending: boolean?, build: Build?): {frame.Line}
    local lines: {frame.Line} = {}
    local room = maximum(1, width - 4)
    local function field(label: string, value: string, role: string?)
        lines[#lines + 1] = {label = label, value = value, role = role}
    end
    local function text_line(value: string, role: string?)
        lines[#lines + 1] = {value = value, role = role}
    end
    lines[#lines + 1] = {heading = "Build"}
    local installed = bee_version(live)
    field("Bee", installed ~= "" and installed or (pending and "reading…" or "unknown"))
    if build then
        field("Runtime", build.runtime)
        field("Lua", build.lua)
        field("Node", build.node)
        field("Folder", build.folder)
    end
    field("Website", M.WEBSITE, "accent")
    lines[#lines + 1] = {}
    local summary = ""
    if live and live.state ~= "error" and #live.modules > 0 then
        summary = tostring(#live.modules) .. (#live.modules == 1 and " pack" or " packs")
    end
    lines[#lines + 1] = {heading = "Packs", summary = summary}
    if pending then
        field("Status", "checking installed versions and updates…", "muted")
        return frame.flow(lines, width - 2, LABEL_WIDTH)
    end
    if not live then
        field("Status", "not checked", "muted")
        return frame.flow(lines, width - 2, LABEL_WIDTH)
    end
    if live.state == "error" then
        field("Status", "unavailable · " .. live.message, "error")
        return frame.flow(lines, width - 2, LABEL_WIDTH)
    end
    if #live.modules == 0 then field("Status", "no installed Bee packs were found", "muted") end
    local name_width, installed_width, hub_width = 4, 9, 3
    for _, item in ipairs(live.modules) do
        name_width = maximum(name_width, #item.component)
        installed_width = maximum(installed_width, #item.installed_version)
        hub_width = maximum(hub_width, #item.available_version)
    end
    local function pad(value: string, size: integer): string return value .. string.rep(" ", maximum(0, size - #value)) end
    local tabular = name_width + installed_width + hub_width + 6 + 18 <= room
    if tabular and #live.modules > 0 then
        text_line(pad("PACK", name_width) .. "  " .. pad("INSTALLED", installed_width) .. "  " .. pad("HUB", hub_width) .. "  STATUS", "muted")
    end
    for _, item in ipairs(live.modules) do
        local status = pack_status(item, live)
        local version = item.installed_version ~= "" and item.installed_version or "unknown"
        local hub = item.available_version ~= "" and item.available_version or "—"
        if tabular then
            text_line(pad(item.component, name_width) .. "  " .. pad(version, installed_width) .. "  " .. pad(hub, hub_width) .. "  " .. status,
                pack_role(status))
        else
            text_line(item.component, pack_role(status))
            text_line("  " .. version .. " · Hub " .. hub .. " · " .. status, "muted")
        end
        if item.locked_version ~= "" and item.locked_version ~= item.installed_version then
            text_line("  locked at " .. item.locked_version, "muted")
        end
    end
    if live.message ~= "" then
        lines[#lines + 1] = {}
        field("Hub", live.message, "muted")
    end
    if live.bee_update and live.bee_update.needs_new_binary and live.bee_update.reason ~= "" then
        lines[#lines + 1] = {}
        field("Binary", live.bee_update.reason, "warn")
    end
    return frame.flow(lines, width - 2, LABEL_WIDTH)
end
-- about_count is the number of About detail rows at width.
function M.about_count(width: integer, live: live_updates.Status?, pending: boolean?, build: Build?): integer
    return #about_details(width, live, pending, build)
end

-- about_actions reports whether About has room for its action bar.
local function about_actions(height: integer): boolean return height >= 8 end
-- about_offset clamps a scroll offset of the About details to the rows height shows.
function M.about_offset(offset: integer, width: integer, height: integer, live: live_updates.Status?, pending: boolean?, build: Build?): integer
    local capacity = maximum(0, height - (about_actions(height) and 6 or 5))
    return math.floor(math.max(0, math.min(maximum(0, M.about_count(width, live, pending, build) - capacity), offset)))
end
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
local HINTS = frame.hints({{key = "←→↑↓", verb = "choose"}, {key = "Tab", verb = "switch"}})
local EDIT_HINTS = frame.hints({{key = "E", verb = "enable"}, {key = "D", verb = "disable"}, {key = "Tab", verb = "switch"}})
local ABOUT_HINTS = frame.hints({{key = "R", verb = "check for updates"}, {key = "Tab", verb = "switch"}})
local ABOUT_MORE = frame.hints({{key = "PgUp/PgDn", verb = "scroll"}})
local TABS: {frame.Tab} = {{kind = "theme", label = "Themes", short = "Theme"}, {kind = "background", label = "Backgrounds", short = "BG"},
    {kind = "taskbar", label = "Tabs", short = "Tabs"}, {kind = "edit_mode", label = "Edit mode", short = "Edit"},
    {kind = "about", label = "About", short = "About"}}

-- confirm_message is the one-line question an edit-mode change asks the
-- person: the exact namespaces and duration, or what disabling removes.
function M.confirm_message(input: string, disabling: boolean?): string
    if disabling then
        return "Remove this workspace's super-edit profiles and active overlays? Duration: once; removal persists until edit mode is enabled again."
    end
    return "Enable these exact namespaces and duration: " .. input:gsub("%c", " ")
end
-- count is the number of cards pane shows.
function M.count(pane: Pane, themes: {appearance.Theme}): integer
    if pane == "about" or pane == "edit_mode" then return 0 end
    if pane == "taskbar" then return 2 end
    if pane == "theme" then return #themes end
    return #appearance.backgrounds()
end
function M.draw(width: integer, height: integer, preferences: appearance.Preferences, themes: {appearance.Theme},
    pane: Pane, offset: integer, message: string?, live: live_updates.Status?, live_pending: boolean?, build: Build?): Frame
    local painter = frame.new(width, height, preferences)
    local theme = painter.theme
    local grid = M.grid(width, height)
    local backgrounds = appearance.backgrounds()
    local count = M.count(pane, themes)
    local notice = message or ""
    frame.header(painter, pane == "about" and "BEE SETTINGS · ABOUT"
        or (pane == "edit_mode" and "BEE SETTINGS · EDIT MODE" or "BEE SETTINGS · DISPLAY"))
    if height >= 2 then frame.tabs(painter, 2, TABS, pane) end
    if pane == "edit_mode" then
        frame.document(painter, 4, height - 2, frame.flow({
            {heading = "Edit mode", summary = "this workspace"},
            {value = "Temporary overlay admission is host controlled."},
            {value = "Each activation still needs an explicit person approval."},
            {value = "Enable accepts exact non-kernel namespaces for up to 24h.", role = "muted"},
        }, width - 2, LABEL_WIDTH), 0, LABEL_WIDTH)
        if height >= 3 then frame.footer(painter, notice ~= "" and notice or "Choose E or D to continue", EDIT_HINTS) end
        return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter)}
    end
    if pane == "about" then
        local details = about_details(width, live, live_pending, build)
        local actions = about_actions(height)
        local capacity = math.floor(math.max(0, height - (actions and 6 or 5)))
        local first = M.about_offset(offset, width, height, live, live_pending, build)
        frame.document(painter, 4, 4 + capacity - 1, details, first, LABEL_WIDTH)
        if actions then
            frame.actions(painter, height - 1, {
                {kind = "check", key = "R", label = live_pending and "Checking…" or "Check for updates", enabled = not live_pending, primary = true},
            })
        end
        local page = ""
        local bee_update = live and live.bee_update
        if bee_update and bee_update.update_available and not bee_update.needs_new_binary then
            page = "Bee " .. bee_update.available_version .. " is available · update it in Modules"
        end
        if capacity == 0 then page = "Resize to read build details"
        elseif #details > capacity then
            page = "Details " .. tostring(first + 1) .. "–" .. tostring(math.min(#details, first + capacity)) .. "/" .. tostring(#details)
        end
        if height >= 3 then frame.footer(painter, notice ~= "" and notice or page, ABOUT_HINTS, ABOUT_MORE) end
        return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter)}
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
        return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter)}
    end
    for slot = 1, grid.capacity do
        local index = offset + slot
        if index > count then break end
        local x = 2 + ((slot - 1) % grid.columns) * (grid.card_width + 2)
        local y = 4 + ((slot - 1) // grid.columns) * 6
        local id = pane == "taskbar" and (index == 1 and "labels" or "icons") or (pane == "theme" and themes[index].id or backgrounds[index])
        local title = pane == "theme" and themes[index].title or (id:sub(1, 1):upper() .. id:sub(2))
        local selected = id == (pane == "taskbar" and preferences.taskbar or (pane == "theme" and preferences.theme.id or preferences.background))
        local edge = selected and theme.accent or theme.border
        local inside = grid.card_width - 2
        frame.clip(painter, x, y, "╭" .. string.rep("─", inside) .. "╮", grid.card_width, edge)
        for row = 1, 3 do
            frame.clip(painter, x, y + row, "│" .. string.rep(" ", inside) .. "│", grid.card_width, edge)
        end
        frame.clip(painter, x, y + 4, "╰" .. string.rep("─", inside) .. "╯", grid.card_width, edge)
        frame.put(painter, x + 1, y, " " .. (selected and "✓ " or "") .. title .. " ", inside, selected and theme.accent or theme.text)
        if pane == "taskbar" then
            frame.put(painter, x + 1, y + 2, index == 1 and " Terminal  Settings " or " >_  S  P ", inside, theme.text)
        elseif pane == "background" then
            for row = 1, 3 do
                frame.clip(painter, x + 1, y + row, appearance.background_row(id, inside, row, 3), inside, theme.pattern, theme.ground)
            end
        else
            local candidate = themes[index]
            frame.clip(painter, x + 1, y + 1, string.rep(" ", inside), inside, candidate.text, candidate.ground)
            frame.clip(painter, x + 1, y + 2, "  Aa   Bee" .. string.rep(" ", inside), inside, candidate.text, candidate.surface)
            local band = maximum(1, inside // 3)
            frame.clip(painter, x + 1, y + 3, string.rep(" ", inside), inside, candidate.text, candidate.accent)
            frame.clip(painter, x + 1 + band, y + 3, string.rep(" ", band), band, candidate.text, candidate.border)
            frame.clip(painter, x + 1 + band * 2, y + 3, string.rep(" ", inside - band * 2), inside - band * 2, candidate.text, candidate.muted)
        end
        frame.add_hit(painter, "select", index, id, x, y, grid.card_width, 5)
    end
    local last = math.floor(math.min(count, offset + grid.capacity))
    local range = tostring(offset + 1) .. "–" .. tostring(last) .. "/" .. tostring(count)
    local status = "Theme " .. theme.title .. " · Background " .. preferences.background
    if width < 48 then status = pane == "theme" and ("Theme " .. theme.title) or ("Background " .. preferences.background) end
    if pane == "taskbar" then status = "Tabs " .. (preferences.taskbar == "icons" and "Icons" or "Labels") end
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
    return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter)}
end
return M
