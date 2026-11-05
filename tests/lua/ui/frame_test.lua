-- MIT. Pointer gestures the shared frame recognizes.
local test = require("test")
local frame = require("frame")
local paint = require("paint")
local appearance = require("appearance")
local tty = require("tty")

local function define_tests()
    test.describe("List cards", function()
        test.it("highlights every line with one mouse target and a bold title", function()
            local prefs = appearance.defaults()
            local painter = frame.new(80, 12, prefs)
            frame.list_card(painter, 3, 3, {glyph = "◷", title = "Read owned threads", requester = "Claude", summary = "Can read this workspace", meta = "pending · once · expires soon"}, true, "request", 2, "read")
            local rows = frame.rows(painter)
            test.is_true(rows[3]:find("\27%[[%d;]*;1m") ~= nil or rows[3]:find("\27[1m", 1, true) ~= nil)
            test.contains(tty.text.plain(rows[3]), "Claude")
            local background = assert(appearance.style(appearance.selection_text(prefs.theme), appearance.selection_background(prefs.theme)):match("\27%[([^m]*)m$"))
            for y = 3, 5 do
                test.contains(rows[y], background)
                local hit = assert(frame.hit(painter.hits, 80, y))
                test.eq(hit.key, "read")
                test.eq(hit.index, 2)
                test.eq(hit.height, 3)
            end
            test.is_nil(frame.hit(painter.hits, 2, 6))
        end)
    end)
    test.describe("Toolkit surface", function()
        test.it("keeps every call installed and Hub applications make on bee.ui:frame", function()
            local surface = frame :: {[string]: unknown}
            for _, name in ipairs({"fit", "pad", "tagged", "new", "rows", "put", "clip", "fill", "line", "rule", "add_hit", "hit",
                "header", "tabs", "button", "controls", "actions", "hints", "footer", "window", "row", "list_card", "table", "size",
                "layout", "split", "stack", "grid", "section", "panel", "flow", "document", "card", "cards", "master_detail",
                "field", "steps", "empty", "tree", "kv", "log", "badge", "toast", "modal", "row_actions", "menu", "render",
                "route", "clicks", "double_click"}) do
                test.eq(type(surface[name]), "function", name)
            end
            test.eq(frame.DOUBLE_CLICK_MS, 400)
        end)
    end)
    test.describe("Area bands", function()
        test.it("confines a row to the area's columns with the marker column before it", function()
            local painter = frame.new(40, 4, appearance.defaults())
            frame.line(painter, 2, string.rep("x", 38))
            paint.band(painter, {x = 11, y = 1, width = 10, height = 4}, 2, "inside the band area")
            local plain = tty.text.plain(frame.rows(painter)[2])
            test.eq(tty.text.width(plain), 40)
            test.eq(plain:sub(1, 22), " xxxxxxxx inside th…")
            test.eq(plain:sub(23, 24), "xx")
        end)
        test.it("marks a selected row with MARKER in column 1", function()
            local painter = frame.new(20, 3, appearance.defaults())
            frame.row(painter, 2, "chosen", true, "item", 1, "")
            local plain = tty.text.plain(frame.rows(painter)[2])
            test.eq(plain:sub(1, #paint.MARKER), paint.MARKER)
        end)
    end)
    test.describe("Application footer", function()
        test.it("keeps complete actions left and hints right on one row", function()
            for _, width in ipairs({24, 40, 80, 120, 160}) do
                local painter = frame.new(width, 12, appearance.defaults())
                local buttons: {frame.Button} = {
                    {kind = "open", key = "Enter", label = "Open", enabled = true, primary = true},
                    {kind = "edit", key = "E", label = "Edit", enabled = true},
                }
                frame.footer(painter, "", "/ search", nil, buttons)
                local rows = frame.rows(painter)
                test.eq(tty.text.width(rows[12]), width)
                test.is_true(rows[12]:find("Enter Open", 1, true) ~= nil)
                test.is_nil((rows[11]:find("Enter Open", 1, true)))
                for _, hit in ipairs(painter.hits) do test.eq(hit.y, 12) end
                local plain = rows[12]:gsub("\27%[[0-9;]*m", "")
                test.is_nil((plain:find("…", 1, true)))
                if width >= 80 then
                    test.is_true(plain:find("/ search", 1, true) > plain:find("E Edit", 1, true))
                    test.is_true(plain:find("? help", 1, true) ~= nil)
                else test.is_nil((plain:find("/ search", 1, true))) end
            end
        end)
        test.it("keeps More visible beside a primary action on a narrow footer", function()
            local painter = frame.new(28, 16, appearance.defaults())
            frame.footer(painter, "", "? help", nil, {
                {kind = "platform", key = "Enter", label = "Packages", enabled = true, primary = true},
                {kind = "technical", key = "T", label = "Technical", enabled = true},
                {kind = "refresh", key = "R", label = "Refresh", enabled = true},
            })
            local rows = frame.rows(painter)
            test.is_true(rows[16]:find("Enter Packages", 1, true) ~= nil)
            test.is_true(rows[16]:find("More", 1, true) ~= nil)
            test.eq(#painter.controls.overflow, 2)
            local more = false
            for _, hit in ipairs(painter.hits) do
                if hit.kind == "frame_more" then more = true; test.eq(hit.y, 16) end
            end
            test.is_true(more)
        end)

        test.it("shares the footer row with the canonical action geometry", function()
            local layout = frame.layout(frame.new(80, 24, appearance.defaults()), true, true)
            test.eq(layout.actions, layout.footer)
            test.eq(layout.work.y + layout.work.height, layout.footer)
        end)
    end)
    test.describe("Row actions", function()
        local prefs = appearance.defaults()
        -- A list of three sessions, each offering its own actions; the third
        -- cannot be closed.
        local function listing(selected: integer): frame.View
            local painter = frame.new(60, 14, prefs)
            for index = 1, 3 do
                frame.row(painter, 2 + index, "Session " .. tostring(index), index == selected, "session", index, "s" .. tostring(index))
                frame.row_actions(painter, {kind = "session", index = index, key = "s" .. tostring(index), selected = index == selected, actions = {
                    {kind = "rename", key = "E", label = "Rename", enabled = true},
                    {kind = "close", key = "X", label = "Close", enabled = index ~= 3},
                    {kind = "delete", key = "D", label = "Delete…", enabled = true},
                }})
            end
            frame.footer(painter, "", "Esc back")
            return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter)}
        end
        local function plain(view: frame.View): string
            return tty.text.plain(table.concat(view.rows, "\n"))
        end
        local function right(x: integer, y: integer): {[string]: unknown}
            return {type = "mouse", action = "press", button = "right", x = x, y = y}
        end
        local function press(key_type: string, key: string?, shift: boolean?): {[string]: unknown}
            return {type = "key", action = "press", key_type = key_type, key = key or "", shift = shift == true}
        end

        test.it("names the keyboard gesture in the footer when rows offer actions", function()
            test.contains(plain(listing(1)), "Shift+F10 actions")
            local painter = frame.new(60, 14, prefs)
            frame.footer(painter, "", "Esc back")
            test.is_nil((tty.text.plain(table.concat(frame.rows(painter), "\n")):find("Shift+F10", 1, true)))
        end)

        test.it("opens the right-clicked row's actions anchored at the clicked cell", function()
            local menu = frame.menu()
            local view = listing(1)
            frame.render(view, menu, prefs)
            local event, handled = frame.route(menu, right(10, 4))
            test.is_true(handled)
            local selecting = assert(event)
            test.eq(selecting.button, "left")
            local row = assert(frame.hit(view.hits, assert(selecting.x), assert(selecting.y)))
            test.eq(row.kind, "session")
            test.eq(row.index, 2)
            view = listing(2)
            frame.render(view, menu, prefs)
            local rows = tty.text.plain(table.concat(view.rows, "\n"))
            test.contains(rows, "Rename")
            test.contains(rows, "Delete…")
            test.contains(view.rows[4], "Session 2")
            local panel_top = 0
            for y, row in ipairs(view.rows) do
                if panel_top == 0 and tty.text.plain(row):find("╭", 1, true) then panel_top = y end
            end
            test.eq(panel_top, 5)
            test.eq(tty.text.width(assert(tty.text.plain(view.rows[panel_top]):match("^(.-)╭"))), 9)
            test.contains(view.rows[3], "Session 1")
            local marked = 0
            for _, line in ipairs(view.rows) do if tty.text.plain(line):sub(1, #"›") == "›" then marked = marked + 1 end end
            test.eq(marked, 1)
            test.eq(tty.text.plain(view.rows[4]):sub(1, #"›"), "›")
        end)

        test.it("chooses an action through the app's mouse path with the row it belongs to", function()
            local menu = frame.menu()
            local view = listing(1)
            frame.render(view, menu, prefs)
            frame.route(menu, right(10, 4))
            view = listing(1)
            frame.render(view, menu, prefs)
            frame.route(menu, press("down"))
            view = listing(1)
            frame.render(view, menu, prefs)
            local event, handled = frame.route(menu, press("enter"))
            test.is_true(handled)
            local chosen = assert(event)
            test.eq(chosen.type, "mouse")
            test.eq(chosen.button, "left")
            local hit = assert(frame.hit(view.hits, assert(chosen.x), assert(chosen.y)))
            test.eq(hit.kind, "close")
            test.eq(hit.index, 2)
            test.eq(hit.key, "s2")
            test.eq(menu.mode, "")
        end)

        test.it("chooses an action by its key and refuses a disabled one", function()
            local menu = frame.menu()
            local view = listing(3)
            frame.render(view, menu, prefs)
            frame.route(menu, right(10, 5))
            view = listing(3)
            frame.render(view, menu, prefs)
            local refused, held = frame.route(menu, press("runes", "x"))
            test.is_nil(refused)
            test.is_true(held)
            test.eq(menu.mode, "context")
            local event = assert((frame.route(menu, press("runes", "d"))))
            local hit = assert(frame.hit(view.hits, assert(event.x), assert(event.y)))
            test.eq(hit.kind, "delete")
            test.eq(hit.index, 3)
        end)

        test.it("opens the selected row's actions on Shift+F10 and closes on Escape", function()
            local menu = frame.menu()
            local view = listing(2)
            frame.render(view, menu, prefs)
            local _, handled = frame.route(menu, press("f10", "", true))
            test.is_true(handled)
            test.eq(menu.mode, "context")
            view = listing(2)
            frame.render(view, menu, prefs)
            test.contains(plain(view), "Rename")
            local event = assert((frame.route(menu, press("enter"))))
            local hit = assert(frame.hit(view.hits, assert(event.x), assert(event.y)))
            test.eq(hit.kind, "rename")
            test.eq(hit.index, 2)
            frame.route(menu, press("f10", "", true))
            frame.render(listing(2), menu, prefs)
            frame.route(menu, press("esc"))
            test.eq(menu.mode, "")
            view = listing(2)
            frame.render(view, menu, prefs)
            test.is_nil((plain(view):find("Rename", 1, true)))
        end)

        test.it("closes the menu on a click outside it and passes nothing to the app", function()
            local menu = frame.menu()
            frame.render(listing(1), menu, prefs)
            frame.route(menu, right(10, 3))
            frame.render(listing(1), menu, prefs)
            local event, handled = frame.route(menu, {type = "mouse", action = "press", button = "left", x = 2, y = 13})
            test.is_nil(event)
            test.is_true(handled)
            test.eq(menu.mode, "")
        end)

        test.it("leaves a right click on a row without actions to the app", function()
            local menu = frame.menu()
            local painter = frame.new(60, 14, prefs)
            frame.row(painter, 3, "Plain", true, "plain", 1, "")
            frame.footer(painter, "", "Esc back")
            local view: frame.View = {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter)}
            frame.render(view, menu, prefs)
            local event, handled = frame.route(menu, right(5, 3))
            test.is_false(handled)
            test.eq(assert(event).button, "right")
            test.eq(menu.mode, "")
        end)
    end)
    test.describe("Help", function()
        test.it("names each key once, puts the tabs on one line and lists keyless buttons as clicks", function()
            local prefs = appearance.defaults()
            local function screen(): frame.View
                local painter = frame.new(80, 20, prefs)
                frame.tabs(painter, 2, {{kind = "installed", label = "Installed"}, {kind = "shared", label = "Shared"}}, "installed")
                frame.footer(painter, "", "Tab view · / search", frame.hints({{key = "Enter", verb = "start agent"}, {key = "Esc", verb = "back"}}), {
                    {kind = "open", key = "Enter", label = "Start agent", enabled = true, primary = true},
                    {kind = "apply", label = "Apply", enabled = false},
                    {kind = "close", key = "Esc", label = "Sessions", enabled = true},
                })
                return {rows = frame.rows(painter), hits = painter.hits, controls = frame.controls(painter)}
            end
            local menu = frame.menu()
            frame.render(screen(), menu, prefs)
            frame.route(menu, {type = "key", action = "press", key_type = "runes", key = "?"})
            local view = screen()
            frame.render(view, menu, prefs)
            local shown = tty.text.plain(table.concat(view.rows, "\n"))
            test.contains(shown, "Tabs  Installed · Shared")
            test.contains(shown, "Enter  Start agent")
            test.contains(shown, "Esc  Sessions")
            test.contains(shown, "Click  Apply · unavailable")
            test.contains(shown, "/  search")
            test.is_nil((shown:find("start agent", 1, true)))
            test.is_nil((shown:find("Esc  back", 1, true)))
            test.is_nil((shown:find("?  Help", 1, true)))
            test.is_nil((shown:find("F10  More actions", 1, true)))
        end)
    end)
    test.describe("Frame gestures", function()
        test.it("treats a second press on the same row within the double-click window as a double click", function()
            local memory = frame.clicks()
            test.is_false(frame.double_click(memory, "choice", 2, 1000))
            test.is_true(frame.double_click(memory, "choice", 2, 1000 + frame.DOUBLE_CLICK_MS))
            test.is_false(frame.double_click(memory, "choice", 2, 1000 + frame.DOUBLE_CLICK_MS + 10))
            test.is_false(frame.double_click(memory, "choice", 3, 5000))
            test.is_false(frame.double_click(memory, "choice", 2, 5010))
            test.is_false(frame.double_click(memory, "session", 2, 9000))
            test.is_false(frame.double_click(memory, "session", 2, 9000 + frame.DOUBLE_CLICK_MS + 1))
        end)
    end)
end

return test.run_cases(define_tests)
