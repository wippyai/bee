-- MIT. The shared frame keeps every row at the canvas width, keeps the header
-- summary off the title, puts status and hints on one footer row, marks the
-- selected row without color and folds a narrow table into one summary line.
local test = require("test")
local tty = require("tty")
local frame = require("frame")
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
    local rows = frame.rows(painter)
    test.eq(#rows, painter.height)
    for _, row in ipairs(rows) do test.eq(tty.text.width(row), painter.width) end
    for _, hit in ipairs(painter.hits) do
        test.is_true(hit.x >= 1 and hit.y >= 1)
        test.is_true(hit.x + hit.width - 1 <= painter.width)
        test.is_true(hit.y + hit.height - 1 <= painter.height)
    end
end
local function rgb(hex: string): string
    return tostring(tonumber(hex:sub(2, 3), 16)) .. ";" .. tostring(tonumber(hex:sub(4, 5), 16)) .. ";" .. tostring(tonumber(hex:sub(6, 7), 16))
end
-- The foreground and background in effect where needle starts in a styled row.
type Cell = {fg: string, bg: string}
local function style_at(row: string, needle: string): Cell?
    local fg, bg = "", ""
    local position = 1
    while position <= #row do
        local first, last, codes = row:find("\27%[([0-9;]*)m", position)
        local plain_end = first and first - 1 or #row
        local found = row:sub(position, plain_end):find(needle, 1, true)
        if found then return {fg = fg, bg = bg} end
        if not first or not last or not codes then return nil end
        if codes == "" or codes == "0" then fg, bg = "", "" end
        local fg_code = codes:match("38;2;(%d+;%d+;%d+)")
        local bg_code = codes:match("48;2;(%d+;%d+;%d+)")
        if fg_code then fg = fg_code end
        if bg_code then bg = bg_code end
        position = last + 1
    end
    return nil
end
local function columns(): {frame.Column}
    return {{title = "Name", width = 0}, {title = "State", width = 10}, {title = "Steps", width = 7, align = "right"}}
end
local function cells(): {{string}}
    return {{"bee.host:main", "idle", "96"}, {"bee.apps:broker\27[2J", "running\r", "70"}, {"bee.desktop.service:main", "idle", "16"}}
end
local function golden(painter: frame.Painter, expected: {string})
    local rows = text(painter)
    test.eq(#rows, #expected)
    for index, row in ipairs(expected) do test.eq(rows[index], row) end
end
local BADGE: {string} = {
    "  OK                "}
local TOAST: {string} = {
    "            Saved             "}
local MODAL: {string} = {
    "                              ",
    "                              ",
    "     ┌─ Confirm ────────┐     ",
    "     │                  │     ",
    "     │                  │     ",
    "     │                  │     ",
    "     │                  │     ",
    "     └──────────────────┘     ",
    "                              ",
    "                              "}
local TREE: {string} = {
    " ▾ root                       ",
    "›    child                    ",
    "                              ",
    "                              ",
    "                              "}
local KV: {string} = {
    "›Node    fire-01              ",
    " Status  ready                ",
    "                              ",
    "                              "}
local LOG: {string} = {
    " boot ok                      ",
    "›error: timeout               ",
    "                              "}
local PALETTE: {string} = {
    "                              ",
    "                              ",
    "   ┌─ Command Palette ────┐   ",
    "   │ › de█                │   ",
    "   │                      │   ",
    "   │›Deploy Board         │   ",
    "   │ Deps                 │   ",
    "   │                      │   ",
    "   │                      │   ",
    "   └──────────────────────┘   ",
    "                              ",
    "                              "}

local function define_tests()
    test.describe("Advanced actions", function()
        test.it("keeps explicit secondary actions in More at both frame sizes", function()
            for _, size in ipairs({{120, 36}, {80, 24}}) do
                local painter = frame.new(size[1], size[2], appearance.defaults())
                frame.actions(painter, size[2] - 1, {{kind = "approve", key = "A", label = "Approve", enabled = true, primary = true},
                    {kind = "deny", key = "D", label = "Deny", enabled = true},
                    {kind = "lease", key = "L", label = "Lease", enabled = true, more = true}})
                local controls = frame.controls(painter)
                test.eq(#controls.overflow, 1)
                test.eq(controls.overflow[1].kind, "lease")
            end
        end)
    end)

    test.describe("Application frame", function()
        test.it("fits every responsive geometry and strips hostile text", function()
            for _, width in ipairs({1, 20, 40, 80, 120}) do
                for _, height in ipairs({1, 6, 12, 24}) do
                    local painter = frame.new(width, height, appearance.defaults())
                    frame.header(painter, "PROCESSES", "Live · 3 processes \27[31m")
                    frame.tabs(painter, 2, {{kind = "a", label = "Processes", short = "P"}, {kind = "b", label = "Services", short = "S"}}, "a")
                    frame.table(painter, 3, height - 2, {columns = columns(), cells = cells(), kind = "row", selected = 2, offset = 0})
                    frame.actions(painter, height - 1, {{kind = "stop", label = "Stop app", key = "Del", enabled = true, primary = true},
                        {kind = "sort", label = "Sort", enabled = false}})
                    frame.footer(painter, "Stopped \7", frame.hints({{key = "↑↓", verb = "select"}, {key = "Esc", verb = "close"}}))
                    sized(painter)
                    for _, row in ipairs(frame.rows(painter)) do
                        local rendered = plain(row)
                        test.is_nil((rendered:find("\27", 1, true)))
                        test.is_nil((rendered:find("\r", 1, true)))
                        test.is_nil((rendered:find("\7", 1, true)))
                    end
                end
            end
        end)
        test.it("draws a form field after switching from tabs to a dialog", function()
            local painter = frame.new(160, 48, appearance.defaults())
            local layout = frame.layout(painter, false, true)
            frame.header(painter, "AUTO RESEARCH", "0 loops running")
            frame.field(painter, layout.work.y + 2, "Title", "▏", 16, true, 1, nil)
            frame.actions(painter, layout.actions, {{kind = "submit", key = "Enter", label = "Save and start", enabled = true, primary = true}})
            frame.footer(painter, "State a research goal", frame.hints({{key = "↑↓", verb = "field"}, {key = "Enter", verb = "save and start"}}))
            sized(painter)
            local hit = frame.hit(painter.hits, 4, layout.work.y + 2)
            test.eq(hit and hit.kind, "field")
        end)
        test.it("truncates the header summary before it reaches the title", function()
            local painter = frame.new(40, 3, appearance.defaults())
            frame.header(painter, "MODULES  CATALOG", "wippy/a-very-long-package-name-that-overflows")
            local row = text(painter)[1]
            test.eq(row:sub(1, 18), " MODULES  CATALOG ")
            test.is_true(row:find("…", 1, true) ~= nil)
            local narrow = frame.new(20, 3, appearance.defaults())
            frame.header(narrow, "MODULES  CATALOG", "Browse the Hub")
            test.eq(text(narrow)[1], " MODULES  CATALOG   ")
        end)
        test.it("draws the header summary in the muted role, not the accent", function()
            local painter = frame.new(60, 3, appearance.defaults())
            frame.header(painter, "HIVE MANAGER", "1 node · 1 ready")
            local theme = appearance.theme("honey")
            local cell = style_at(frame.rows(painter)[1], "1 node")
            test.not_nil(cell)
            test.eq(cell and cell.fg or "", rgb(theme.muted))
        end)
        test.it("reserves hints and help while a long status is shown at both frame sizes", function()
            local sizes: {{integer}} = {{80, 24}, {120, 36}}
            for _, size in ipairs(sizes) do
                local painter = frame.new(size[1], size[2], appearance.defaults())
                frame.footer(painter, string.rep("Starting Agent… ", 12), "↑↓ select · Enter open · N new · E edit · R refresh · Esc close")
                local rendered = text(painter)
                local row = rendered[size[2]]
                test.is_true(row:find("Starting Agent", 1, true) ~= nil)
                test.is_true(row:find("Enter open", 1, true) ~= nil)
                test.is_true(row:find("? help", 1, true) ~= nil)
                sized(painter)
            end
        end)
        test.it("keeps primary actions and exposes overflowing actions through More", function()
            for _, size in ipairs({{80, 24}, {120, 36}}) do
                local painter = frame.new(size[1], size[2], appearance.defaults())
                local buttons: {frame.Button} = {}
                for index = 1, 12 do buttons[index] = {kind = "action" .. tostring(index), label = "Action " .. tostring(index), enabled = true} end
                buttons[12].primary = true
                frame.actions(painter, size[2] - 1, buttons)
                local row = text(painter)[size[2] - 1]
                test.is_true(row:find("Action 12", 1, true) ~= nil)
                test.is_true(row:find("F10 More", 1, true) ~= nil)
                local more = false
                for _, hit in ipairs(painter.hits) do if hit.kind == "frame_more" then more = true end end
                test.is_true(more)
                sized(painter)
            end
        end)
        test.it("opens shared More and Help with keyboard and mouse and shields the screen", function()
            for _, size in ipairs({{80, 24}, {120, 36}}) do
                local menu = frame.menu()
                local function draw(): frame.View
                    local painter = frame.new(size[1], size[2], appearance.defaults())
                    local buttons: {frame.Button} = {}
                    for index = 1, 14 do buttons[index] = {kind = "action" .. tostring(index), label = "Action " .. tostring(index), enabled = index ~= 14} end
                    buttons[13] = {kind = "leases", label = "Leases", key = "V", enabled = true}
                    frame.actions(painter, size[2] - 1, buttons)
                    frame.footer(painter, "Waiting for a decision", "↑↓ select · Enter open · Esc back")
                    local drawn: frame.View = {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter)}
                    frame.render(drawn, menu, appearance.defaults())
                    for _, row in ipairs(drawn.rows) do test.eq(tty.text.width(row), size[1]) end
                    return drawn
                end
                draw()
                local routed, changed = frame.route(menu, {type = "key", action = "press", key_type = "f10"})
                test.is_nil(routed); test.is_true(changed)
                local more = draw()
                test.is_true(plain(more.rows[1]):find("MORE ACTIONS", 1, true) ~= nil)
                test.is_true(table.concat(more.rows):find("Leases", 1, true) ~= nil)
                routed, changed = frame.route(menu, {type = "key", action = "press", key_type = "runes", key = "v"})
                test.eq(routed and routed.type, "mouse")
                local hit = routed and frame.hit(more.hits, routed.x or 0, routed.y or 0)
                test.eq(hit and hit.kind, "leases")
                draw()
                routed = frame.route(menu, {type = "key", action = "press", key_type = "runes", key = "?"})
                test.is_nil(routed)
                local help = draw()
                test.is_true(plain(help.rows[1]):find("HELP", 1, true) ~= nil)
                test.is_true(table.concat(help.rows):find("Action 14", 1, true) ~= nil)
                test.is_true(table.concat(help.rows):find("unavailable", 1, true) ~= nil)
                routed = frame.route(menu, {type = "mouse", action = "press", button = "left", x = 1, y = 5})
                test.is_nil(routed)
                routed = frame.route(menu, {type = "key", action = "press", key_type = "esc"})
                test.is_nil(routed); test.eq(menu.mode, "")
                local screen = draw()
                for _, target in ipairs(screen.hits) do
                    if target.kind == "frame_more" then
                        routed = frame.route(menu, {type = "mouse", action = "press", button = "left", x = target.x, y = target.y})
                        test.is_nil(routed); test.eq(menu.mode, "more")
                    end
                end
            end
        end)
        test.it("normalizes shortcuts while preserving typed text and ignores releases", function()
            local menu = frame.menu()
            local key = {type = "key", action = "press", key_type = "runes", key = "R"}
            local routed = frame.route(menu, key)
            test.eq(routed and routed.key, "r")
            routed = frame.route(menu, {type = "key", action = "press", key_type = "runes", key = "R"}, true)
            test.eq(routed and routed.key, "R")
            routed = frame.route(menu, {type = "key", action = "press", key_type = "runes", key = "?"}, true)
            test.eq(routed and routed.key, "?")
            routed = frame.route(menu, {type = "key", action = "release", key_type = "runes", key = "?"})
            test.not_nil(routed); test.eq(menu.mode, "")
        end)
        test.it("collects individually drawn buttons into the shared overflow bar", function()
            for _, size in ipairs({{80, 24}, {120, 36}}) do
                local painter = frame.new(size[1], size[2], appearance.defaults())
                local x = 2
                for index = 1, 15 do
                    x = frame.button(painter, x, size[2] - 1, {kind = "choice" .. tostring(index), label = "Choice " .. tostring(index), enabled = true})
                end
                local rows = text(painter)
                test.is_true(rows[size[2] - 1]:find("F10 More", 1, true) ~= nil)
                test.eq(#frame.controls(painter).buttons, 15)
                test.is_true(#frame.controls(painter).overflow > 0)
                sized(painter)
                test.eq(#frame.controls(painter).buttons, 15)
            end
        end)
        test.it("selects More with the mouse, refuses disabled choices and closes Help with the mouse", function()
            for _, size in ipairs({{80, 24}, {120, 36}}) do
                local menu = frame.menu()
                local function draw(): frame.View
                    local painter = frame.new(size[1], size[2], appearance.defaults())
                    local buttons: {frame.Button} = {}
                    for index = 1, 10 do buttons[index] = {kind = "choice" .. tostring(index), label = "Long action " .. tostring(index), enabled = true} end
                    buttons[9].enabled = false
                    frame.actions(painter, size[2] - 1, buttons)
                    frame.footer(painter, string.rep("Status message ", 20), "Enter choose · Esc close")
                    local view: frame.View = {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter)}
                    frame.render(view, menu, appearance.defaults())
                    return view
                end
                draw()
                frame.route(menu, {type = "key", action = "press", key_type = "f10"})
                local more = draw()
                local unavailable: frame.Hit? = nil
                local enabled: frame.Hit? = nil
                for _, hit in ipairs(more.hits) do
                    if hit.kind == "frame_choice" then
                        local button = menu.controls.overflow[hit.index]
                        if button.enabled then enabled = hit else unavailable = hit end
                    end
                end
                test.not_nil(unavailable); test.not_nil(enabled)
                if unavailable then
                    local result = frame.route(menu, {type = "mouse", action = "press", button = "left", x = unavailable.x, y = unavailable.y})
                    test.is_nil(result); test.eq(menu.mode, "more")
                end
                if enabled then
                    local expected = menu.controls.overflow[enabled.index].kind
                    local result = frame.route(menu, {type = "mouse", action = "press", button = "left", x = enabled.x, y = enabled.y})
                    local selected = result and frame.hit(more.hits, result.x or 0, result.y or 0)
                    test.eq(selected and selected.kind, expected)
                    test.eq(menu.mode, "")
                end
                draw()
                frame.route(menu, {type = "key", action = "press", key_type = "runes", key = "?"})
                local help = draw()
                for _, hit in ipairs(help.hits) do
                    if hit.kind == "frame_back" then
                        local result = frame.route(menu, {type = "mouse", action = "press", button = "left", x = hit.x, y = hit.y})
                        test.is_nil(result)
                        test.eq(menu.mode, "")
                    end
                end
            end
        end)
        test.it("rejects malformed input before changing overlay state", function()
            local menu = frame.menu()
            local result = frame.route(menu, {type = "key", action = "press", key_type = "f10", ctrl = "yes"})
            test.is_nil(result)
            result = frame.route(menu, {type = "mouse", action = "press", button = "left", x = -1, y = 1})
            test.is_nil(result)
            result = frame.route(menu, {type = "resize", width = 80, height = "24"})
            test.is_nil(result)
            test.eq(menu.mode, "")
        end)
        test.it("marks the selected row in column 1 and keeps its text", function()
            local painter = frame.new(60, 8, appearance.defaults())
            local window = frame.table(painter, 2, 7, {columns = columns(), cells = cells(), kind = "row", selected = 2, offset = 0})
            test.eq(window.capacity, 5)
            local rows = text(painter)
            test.is_true(rows[2]:find("NAME", 1, true) ~= nil and rows[2]:find("STATE", 1, true) ~= nil)
            test.eq(rows[3]:sub(1, 2), " b")
            test.eq(rows[4]:sub(1, #"›"), "›")
            test.is_true(rows[4]:find("bee.apps:broker", 1, true) ~= nil)
            local hit = frame.hit(painter.hits, 30, 4)
            test.not_nil(hit)
            test.eq(hit and hit.index or 0, 2)
        end)
        test.it("confines a table to its area beside another pane", function()
            local painter = frame.new(60, 8, appearance.defaults())
            frame.put(painter, 30, 4, "DETAIL PANE", 20)
            local window = frame.table(painter, 2, 7, {columns = columns(), cells = cells(), kind = "row", selected = 2, offset = 0,
                area = {x = 2, y = 2, width = 26, height = 6}})
            test.eq(window.capacity, 5)
            local rows = text(painter)
            for _, row in ipairs(rows) do test.eq(tty.text.width(row), 60) end
            test.eq(rows[4]:sub(1, #"›"), "›")
            test.is_true(rows[4]:find("DETAIL PANE", 1, true) ~= nil)
            test.is_true(rows[2]:find("NAME", 1, true) ~= nil)
            local inside = frame.hit(painter.hits, 20, 4)
            test.eq(inside and inside.index or 0, 2)
            test.is_nil(frame.hit(painter.hits, 40, 4))
            for _, hit in ipairs(painter.hits) do test.is_true(hit.x >= 1 and hit.x + hit.width - 1 <= 27) end
        end)
        test.it("aligns table columns and right-aligns numbers", function()
            local painter = frame.new(60, 6, appearance.defaults())
            frame.table(painter, 1, 5, {columns = columns(), cells = cells(), kind = "row", selected = 0, offset = 0})
            local rows = text(painter)
            local state_at = rows[1]:find("STATE", 1, true)
            test.eq(rows[2]:find("idle", 1, true), state_at)
            test.eq(rows[4]:find("idle", 1, true), state_at)
            test.eq(rows[2]:sub(-3), "96 ")
            test.eq(rows[4]:sub(-3), "16 ")
        end)
        test.it("folds a narrow table into a first cell and a dotted summary", function()
            local painter = frame.new(30, 6, appearance.defaults())
            frame.table(painter, 1, 5, {columns = columns(), cells = cells(), kind = "row", selected = 0, offset = 0})
            local rows = text(painter)
            test.eq(rows[1], " NAME · STATE · STEPS         ")
            test.eq(rows[2], " bee.host:main · idle · 96    ")
            test.is_true(rows[3]:find("…", 1, true) ~= nil)
        end)
        test.it("keeps the selection inside the list window", function()
            local window = frame.window(20, 5, 12, 0)
            test.eq(window.offset, 7)
            test.eq(frame.window(20, 5, 3, 10).offset, 2)
            test.eq(frame.window(3, 5, 0, 9).offset, 0)
            test.eq(frame.window(3, 0, 2, 0).capacity, 0)
        end)
        test.it("fills only the primary action and gives disabled buttons no target", function()
            local painter = frame.new(60, 3, appearance.defaults())
            local theme = appearance.theme("honey")
            frame.actions(painter, 2, {{kind = "open", label = "Open", enabled = true, primary = true},
                {kind = "refresh", label = "Refresh", key = "R", enabled = true}, {kind = "deny", label = "Deny", enabled = false}})
            local row = frame.rows(painter)[2]
            local open, refresh, deny = style_at(row, " Open "), style_at(row, " R Refresh "), style_at(row, " Deny ")
            test.eq(open and (open.fg .. "/" .. open.bg) or "", rgb(appearance.selection_text(theme)) .. "/" .. rgb(theme.accent))
            test.eq(refresh and (refresh.fg .. "/" .. refresh.bg) or "", rgb(theme.accent) .. "/" .. rgb(theme.surface))
            test.eq(deny and (deny.fg .. "/" .. deny.bg) or "", rgb(theme.muted) .. "/" .. rgb(theme.surface))
            local kinds: {string} = {}
            for _, hit in ipairs(painter.hits) do kinds[#kinds + 1] = hit.kind end
            test.eq(table.concat(kinds, ","), "open,refresh")
        end)
        test.it("clips decoration without an ellipsis and bounds it to the canvas", function()
            local painter = frame.new(10, 2, appearance.defaults())
            test.eq(frame.clip(painter, 3, 1, string.rep("─", 40), 20), 8)
            test.eq(text(painter)[1], "  ────────")
            test.eq(frame.put(painter, 3, 2, string.rep("x", 40), 20), 8)
            test.eq(text(painter)[2], "  xxxxxxx…")
        end)
        test.it("states what is empty and the next action", function()
            local painter = frame.new(50, 6, appearance.defaults())
            frame.empty(painter, 3, "No requests", "Requests from agents appear here · R refresh")
            local rows = text(painter)
            test.eq(rows[3]:sub(1, 13), " No requests ")
            test.is_true(rows[4]:find("R refresh", 1, true) ~= nil)
        end)
        test.it("fills a status badge and a one-row toast in their role's color", function()
            local badge = frame.new(20, 1, appearance.defaults())
            test.eq(frame.badge(badge, 2, 1, "OK", "ok"), 4)
            golden(badge, BADGE)
            local theme = appearance.theme("honey")
            local badge_cell = style_at(frame.rows(badge)[1], "OK")
            test.eq(badge_cell and badge_cell.bg or "", rgb(theme.ok))

            local toast = frame.new(30, 1, appearance.defaults())
            frame.toast(toast, 1, {text = "Saved"})
            golden(toast, TOAST)
            local toast_cell = style_at(frame.rows(toast)[1], "Saved")
            test.eq(toast_cell and toast_cell.bg or "", rgb(theme.accent))
        end)
        test.it("centers a bordered modal and returns its inner content rectangle", function()
            local painter = frame.new(30, 10, appearance.defaults())
            local inner = frame.modal(painter, 20, 6, "Confirm")
            test.eq(inner.x .. "," .. inner.y .. "," .. inner.width .. "," .. inner.height, "8,4,16,4")
            golden(painter, MODAL)

            local tiny = frame.new(2, 2, appearance.defaults())
            local none = frame.modal(tiny, 20, 6, "Confirm")
            test.eq(none.width, 0)
            test.eq(none.height, 0)
        end)
        test.it("indents a flattened tree by depth and marks expand state", function()
            local painter = frame.new(30, 5, appearance.defaults())
            local window = frame.tree(painter, 1, 5, {rows = {
                {label = "root", depth = 0, expandable = true, expanded = true},
                {label = "child", depth = 1, expandable = false},
            }, selected = 2, offset = 0})
            test.eq(window.offset, 0)
            test.eq(window.capacity, 5)
            golden(painter, TREE)
            local hit = frame.hit(painter.hits, 5, 2)
            test.eq(hit and (hit.kind .. ":" .. hit.index) or "", "tree:2")
        end)
        test.it("pads key-value labels and colors the value by role", function()
            local painter = frame.new(30, 4, appearance.defaults())
            frame.kv(painter, 1, 4, {entries = {{label = "Node", value = "fire-01"}, {label = "Status", value = "ready", role = "ok"}},
                selected = 1, offset = 0})
            golden(painter, KV)
            local theme = appearance.theme("honey")
            local status_cell = style_at(frame.rows(painter)[2], "ready")
            test.eq(status_cell and status_cell.fg or "", rgb(theme.ok))
        end)
        test.it("virtualizes a log window and highlights a case-insensitive search", function()
            local painter = frame.new(30, 3, appearance.defaults())
            local window = frame.log(painter, 1, 3, {lines = {{text = "boot ok"}, {text = "error: timeout", role = "error"}},
                selected = 2, offset = 0, query = "time"})
            test.eq(window.offset, 0)
            test.eq(window.capacity, 3)
            golden(painter, LOG)
            local theme = appearance.theme("honey")
            local match_cell = style_at(frame.rows(painter)[2], "time")
            test.eq(match_cell and match_cell.bg or "", rgb(theme.accent))
            local hit = frame.hit(painter.hits, 2, 2)
            test.eq(hit and (hit.kind .. ":" .. hit.index) or "", "log:2")
        end)
        test.it("filters a command palette with a subsequence score and shows its choices", function()
            test.eq(frame.fuzzy("dpl", "Deploy Board"), 4)
            test.is_nil(frame.fuzzy("xyz", "Deploy Board"))
            test.eq(frame.fuzzy("", "Deploy Board"), 0)

            local painter = frame.new(30, 12, appearance.defaults())
            local window = frame.palette(painter, 24, 8, {query = "de", choices = {{label = "Deploy Board"}, {label = "Deps"}}, selected = 1, offset = 0})
            test.eq(window.offset, 0)
            test.eq(window.capacity, 4)
            golden(painter, PALETTE)

            local empty_palette = frame.new(30, 12, appearance.defaults())
            local empty_window = frame.palette(empty_palette, 24, 8, {query = "zz", choices = {}, selected = 0, offset = 0})
            test.eq(empty_window.capacity, 0)
        end)
        test.it("keeps an empty palette inside a short modal", function()
            for height = 3, 6 do
                local painter = frame.new(30, 12, appearance.defaults())
                frame.palette(painter, 24, height, {query = "zz", choices = {}, selected = 0, offset = 0})
                local rows = text(painter)
                local top = (12 - height) // 2 + 1
                test.is_true(rows[top + height - 1]:find("└", 1, true) ~= nil)
            end
        end)
        test.it("confines a log, tree and inspector to their area", function()
            local painter = frame.new(60, 6, appearance.defaults())
            for row = 1, 6 do frame.put(painter, 1, row, string.rep("#", 60), 60) end
            frame.log(painter, 2, 5, {lines = {{text = "boot ok"}, {text = "error: timeout"}}, selected = 1, offset = 0, query = "ok",
                area = {x = 32, y = 2, width = 20, height = 4}})
            frame.tree(painter, 2, 5, {rows = {{label = "root", depth = 0, expandable = true, expanded = true}, {label = "child", depth = 1}}, selected = 2, offset = 0,
                area = {x = 32, y = 2, width = 20, height = 4}})
            frame.kv(painter, 2, 5, {entries = {{label = "name", value = "bee"}, {label = "state", value = "running"}}, selected = 1, offset = 0,
                area = {x = 32, y = 2, width = 20, height = 4}})
            for row, line in ipairs(text(painter)) do
                test.eq(tty.text.cut(line, 0, 30), string.rep("#", 30))
                test.eq(tty.text.cut(line, 52, 60), string.rep("#", 8))
                if row == 1 or row == 6 then test.eq(line, string.rep("#", 60)) end
            end
            for _, hit in ipairs(painter.hits) do test.is_true(hit.x >= 31 and hit.x + hit.width - 1 <= 51) end
        end)
        test.it("keeps zero-width log and row areas from painting or capturing input", function()
            local painter = frame.new(60, 4, appearance.defaults())
            frame.log(painter, 1, 4, {lines = {{text = "hidden log"}}, selected = 1, offset = 0,
                area = {x = 3, y = 1, width = 0, height = 4}})
            frame.tree(painter, 1, 4, {rows = {{label = "hidden row", depth = 0, expandable = false}}, selected = 1, offset = 0,
                area = {x = 32, y = 1, width = 0, height = 4}})
            test.eq(text(painter)[1], string.rep(" ", 60))
            test.eq(#painter.hits, 0)
            test.is_nil(frame.hit(painter.hits, 2, 1))
            test.is_nil(frame.hit(painter.hits, 31, 1))
        end)
        test.it("draws a selectable card as a hit with the selection marker", function()
            local painter = frame.new(30, 8, appearance.defaults())
            local inner = frame.card(painter, {x = 3, y = 2, width = 12, height = 4}, "card", 2, "Load", true)
            test.eq(inner.y, 3)
            test.eq(inner.height, 3)
            local hit = frame.hit(painter.hits, 5, 4)
            test.eq(hit and (hit.kind .. ":" .. hit.index .. ":" .. hit.key) or "", "card:2:Load")
            test.is_true(text(painter)[2]:find("›LOAD", 1, true) ~= nil)
            local empty = frame.card(painter, {x = 3, y = 2, width = 0, height = 4}, "card", 3, "None", false)
            test.eq(empty.width, 0)
            test.eq(#painter.hits, 1)
        end)
        test.it("lays cards in a grid and shows only the selected card on narrow canvases", function()
            local wide = frame.new(120, 36, appearance.defaults())
            local drawn: {integer} = {}
            frame.cards(wide, {x = 2, y = 4, width = 100, height = 20}, 4, 1, function(cell: frame.Rect, index: integer)
                drawn[#drawn + 1] = index
                test.is_true(cell.width < 100)
            end)
            test.eq(#drawn, 4)
            local narrow = frame.new(60, 20, appearance.defaults())
            local only: {integer} = {}
            frame.cards(narrow, {x = 2, y = 4, width = 56, height = 10}, 4, 3, function(cell: frame.Rect, index: integer)
                only[#only + 1] = index
                test.eq(cell.width, 56)
            end)
            test.eq(#only, 1)
            test.eq(only[1], 3)
        end)
        test.it("splits a list and detail pane only on canvases that fit both", function()
            local roomy = frame.new(120, 36, appearance.defaults())
            local list, detail = frame.master_detail(roomy, {x = 2, y = 4, width = 100, height = 20})
            test.eq(list.width, 60)
            test.eq(detail and detail.width or 0, 38)
            local small = frame.new(80, 24, appearance.defaults())
            local whole, none = frame.master_detail(small, {x = 2, y = 4, width = 78, height = 16})
            test.eq(whole.width, 78)
            test.is_nil(none)
        end)
        test.it("ranks palette choices by match score and keeps list order among ties", function()
            local labels = {"Show logs", "Deploy edge-api", "Deploy board", "Open inbox"}
            local all = frame.ranked("", labels)
            test.eq(#all, 4)
            test.eq(all[1].label, "Show logs")
            local found = frame.ranked("deploy", labels)
            test.eq(#found, 2)
            test.eq(found[1].label, "Deploy edge-api")
            test.eq(found[2].key, "Deploy board")
            test.eq(#frame.ranked("zzz", labels), 0)
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
