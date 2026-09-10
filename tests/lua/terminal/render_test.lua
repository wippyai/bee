local test = require("test")
local chrome = require("chrome")
local tty = require("tty")
local model = require("model")
local layout = require("layout")
local render = require("render")
local bindings = require("bindings")
local menu = require("menu")
local selection = require("selection")
local appearance = require("appearance")
local surface = require("surface")
local function plain_text(value: string): string return string.gsub(value, "\27%[[0-9;]*m", "") end
local catalog: {menu.Descriptor} = {
    {definition_id = "sample:settings", title = "Settings", group = "Tools", role = "appearance"},
    {definition_id = "sample:processes", title = "Process Manager", group = "Tools", role = "inspection"},
}
local function define_tests()
    test.describe("Desktop presentation boundaries", function()
        test.it("keeps Classic terminals dark without changing application panels", function()
            local theme = appearance.theme("classic")
            local terminal = appearance.page(theme, true)
            local panel = appearance.page(theme, false)
            test.eq(terminal.background, "#0c0c0c")
            test.eq(terminal.foreground, "#cccccc")
            test.eq(panel.background, "#c0c0c0")
            test.eq(panel.foreground, "#000000")
            local honey = appearance.theme("honey")
            test.eq(appearance.page(honey, true).background, honey.surface)
        end)
        test.it("marks Start open only for launcher navigation", function()
            local scene = model.add(model.new(80, 24), "one", "app", "One")
            local contents: {[string]: render.Content} = {}
            local function arrow(state: menu.State?): string
                local frame = render.draw(scene, {"one"}, contents, nil, nil, "", "workspace", nil, state, false, catalog)
                return frame.rows[1]
            end
            test.is_true(arrow(nil):find("BEE ▾", 1, true) ~= nil)
            test.is_true(arrow({selected = 1, offset = 0}):find("BEE ▴", 1, true) ~= nil)
            test.is_true(arrow({selected = 1, offset = 0, path = {1}}):find("BEE ▴", 1, true) ~= nil)
            for _, kind in ipairs({"desktop", "window"}) do
                test.is_true(arrow({selected = 1, offset = 0, kind = kind, target = "one", x = 30, y = 10}):find("BEE ▾", 1, true) ~= nil)
            end
        end)

        test.it("keeps the boot mark inside compact and full-size terminals", function()
            for _, width in ipairs({1, 8, 23, 24, 80, 120}) do
                for _, height in ipairs({1, 2, 5, 13, 14, 30}) do
                    local rows = chrome.boot(width, height)
                    test.eq(#rows, height)
                    for _, row in ipairs(rows) do test.eq(tty.text.width(row), width) end
                    if width >= 24 and height >= 14 then
                        test.is_true(table.concat(rows):find("╰──╲ ╱──╯", 1, true) ~= nil)
                    end
                    test.is_true(table.concat(rows):find("bee", 1, true) == nil)
                    test.is_true(table.concat(rows):find("b e e", 1, true) == nil)
                end
            end
        end)

        test.it("maps a focused cursor through the frame and hides clipped or collapsed cursors", function()
            local scene = model.add(model.new(80, 24), "one", "app", "One")
            scene = model.place(scene, "one", {x = 5, y = 4, width = 20, height = 10})
            local rows: {string} = {"text"}
            local content: render.Content = {rows = rows, cursor = {x = 3, y = 2, visible = true}}
            local contents: {[string]: render.Content} = {one = content}
            local frame = render.draw(scene, {"one"}, contents, nil, nil, "", "workspace")
            test.is_true(frame.cursor.visible)
            test.eq(frame.cursor.x, 8)
            test.eq(frame.cursor.y, 6)
            contents.one = {rows = rows, cursor = {x = 19, y = 2, visible = true}}
            test.is_false(render.draw(scene, {"one"}, contents, nil, nil, "", "workspace").cursor.visible)
            contents.one = {rows = rows, cursor = {x = 1, y = 1, visible = true}}
            scene = model.collapse(scene, "one")
            test.is_false(render.draw(scene, {"one"}, contents, nil, nil, "", "workspace").cursor.visible)
        end)
        test.it("freezes and highlights only the selected window body", function()
            local scene = model.add(model.new(80, 24), "one", "app", "One")
            scene = model.add(scene, "two", "app", "Two")
            scene = model.place(scene, "one", {x = 5, y = 4, width = 20, height = 8})
            scene = model.place(scene, "two", {x = 35, y = 4, width = 20, height = 8})
            local first = scene.windows[1]
            local body = layout.interior(first, model.bounds(scene, first))
            local frozen: {string} = {}
            for row = 1, body.height do frozen[row] = row == 1 and "frozen \27[31m界\27[0m" or "row " .. row end
            local active, err = selection.capture({view_id = "one", attachment = "mount-one", mount_generation = 1,
                width = body.width, height = body.height}, frozen)
            test.is_nil(err)
            test.not_nil(active)
            if not active then error("selection capture failed") end
            active = selection.drag(selection.press(active, 1, 1), 9, 2)
            local contents: {[string]: render.Content} = {}
            local changed: {string} = {"changed live content"}
            local neighbor: {string} = {"neighbor stays live"}
            contents.one = {rows = changed, cursor = {x = 1, y = 1, visible = true}}
            contents.two = {rows = neighbor}
            local frame = render.draw(scene, {"one", "two"}, contents, nil, nil, "", "workspace", nil, nil, false,
                nil, nil, nil, nil, active)
            local text = plain_text(table.concat(frame.rows, "\n"))
            test.is_true(text:find("frozen 界", 1, true) ~= nil)
            test.is_true(text:find("neighbor stays", 1, true) ~= nil)
            test.is_true(text:find("changed live content", 1, true) == nil)
            test.is_false(frame.cursor.visible)
            test.is_true(frame.rows[body.y]:find("48;2;255;201;99", 1, true) ~= nil)
            test.is_true(frame.rows[body.y]:find("\27[31m", 1, true) == nil)
        end)
        test.it("shares half-open hit bounds with window interiors", function()
            local scene = model.add(model.new(80, 24), "one", "app", "One")
            local win = scene.windows[1]
            local rect = model.bounds(scene, win)
            local body = layout.interior(win, rect)
            test.is_false(layout.contains(body, rect.x, rect.y))
            test.is_true(layout.contains(body, body.x + body.width - 1, body.y + body.height - 1))
            test.is_false(layout.contains(body, body.x + body.width, body.y))
            test.eq(layout.edge(rect, rect.x, rect.y), "lt")
            test.eq(layout.edge(rect, rect.x + rect.width - 1, rect.y + rect.height - 1), "rb")
            test.eq(layout.edge(rect, rect.x + rect.width, rect.y), "")
        end)
        test.it("preserves app keys when an optional shell shortcut is unavailable", function()
            test.eq(bindings.action("n", "", true, false, false, false), "")
            test.eq(bindings.action("n", "", true, false, true, false), "initial")
            test.eq(bindings.action("", "tab", false, false, true, true), "")
            test.eq(bindings.action("", "tab", false, true, true, true), "next")
            test.eq(bindings.action("", "tab", false, true, true, true, true), "previous")
            test.eq(bindings.action("", "f9", false, true, false, false), "minimize")
            test.eq(bindings.action("", "f9", false, false, false, false), "")
        end)
        test.it("scrolls the Start panel within the terminal and excludes borders from hits", function()
            local items = menu.items(true, false, true, catalog)
            local panel = menu.panel(22, 7, #items)
            local state = menu.fit({selected = #items, offset = 0}, panel, #items)
            test.is_true(panel.x + panel.width - 1 <= 22)
            test.is_true(panel.y + panel.height - 1 <= 7)
            test.eq(state.offset + panel.capacity, #items)
            test.is_nil(menu.hit(panel, state, panel.x, panel.y + 2, #items))
            test.is_nil(menu.hit(panel, state, panel.x + panel.width - 1, panel.y + 2, #items))
            test.eq(menu.hit(panel, state, panel.x + 1, panel.y + panel.height - 2, #items), #items)
            local paste = menu.respond(state, panel, items, {type = "paste", text = "private app input"})
            test.eq(paste.action, "")
            local enter = menu.respond(state, panel, items, {type = "key", key_type = "enter", action = "press"})
            test.eq(enter.action, "quit")
            local right = menu.respond(state, panel, items, {type = "key", key_type = "right", action = "press"})
            test.eq(right.action, "")
        end)
        test.it("validates appearance and keeps the empty Start menu concise", function()
            test.is_nil(appearance.decode({theme = "unknown", background = "solid"}))
            test.is_nil(appearance.decode({theme = "honey", background = "unknown"}))
            local preferences = appearance.defaults()
            for _ = 1, #appearance.themes() do preferences = appearance.cycle(preferences, "theme") end
            test.eq(preferences.theme, "honey")
            local items = menu.items(false, false, false, catalog)
            test.eq(#items, 2)
            for _, item in ipairs(items) do test.is_true(item.enabled) end
        end)
        test.it("keeps Start small with apps open and anchors contextual actions", function()
            local scene = model.add(model.new(80, 24), "one", "app", "One")
            test.eq(#menu.items(true, false, true, catalog), 2)
            local state: menu.State = {selected = 1, offset = 0, kind = "window", target = "one", x = 79, y = 23}
            local items = menu.entries(state, scene, false, catalog)
            local selectable = false
            for _, item in ipairs(items) do if item.action == "select_text" and item.label == "Select text" then selectable = true end end
            test.is_true(selectable)
            local panel = menu.panel(80, 24, #items, state)
            test.is_true(panel.x + panel.width - 1 <= 80)
            test.is_true(panel.y + panel.height - 1 <= 24)
            local hover = menu.respond(state, panel, items, {type = "mouse", action = "motion", x = panel.x + 2, y = panel.y + 2})
            test.eq(hover.state.selected, 2)
            test.eq(hover.action, "")
            test.eq(hover.state.target, "one")
            local disabled = menu.respond(hover.state, panel, items, {type = "mouse", action = "motion", x = panel.x + 2, y = panel.y + 1})
            test.eq(disabled.state.selected, 2)
            local enter = menu.respond(hover.state, panel, items, {type = "key", action = "press", key_type = "enter"})
            test.eq(enter.action, "minimize")
            test.eq(enter.state.target, "one")
            local next_state = menu.respond(hover.state, panel, items, {type = "key", action = "press", key_type = "end"})
            test.eq(next_state.state.kind, "window")
            test.eq(next_state.state.x, 79)
        end)
        test.it("enters and leaves nested groups without launching on hover", function()
            local scene = model.new(80, 24)
            local state: menu.State = {selected = 1, offset = 0}
            local items = menu.entries(state, scene, false, catalog)
            local panel = menu.panel(80, 24, #items, state)
            local opened = menu.respond(state, panel, items, {type = "key", action = "press", key_type = "right"})
            test.eq(opened.action, "")
            local tools = menu.entries(opened.state, scene, false, catalog)
            test.eq(tools[1].action, "open:sample:settings")
            test.eq(tools[2].action, "open:sample:processes")
            local nested_panel = menu.panel(80, 24, #tools, opened.state)
            test.eq(nested_panel.inset, 1)
            test.is_nil(menu.hit(nested_panel, opened.state, 3, nested_panel.y + 1, #tools))
            local back = menu.respond(opened.state, nested_panel, tools, {type = "key", action = "press", key_type = "left"})
            test.eq(#menu.entries(back.state, scene, false, catalog), 2)
            test.eq(back.state.selected, 1)
            test.is_false(back.close)
        end)
        test.it("reserves title controls without consuming any resize corner", function()
            local scene = model.add(model.new(80, 24), "one", "app", "Long application title")
            local win = scene.windows[1]
            local rect = model.bounds(scene, win)
            local controls = layout.controls(win, rect)
            test.eq(#controls, 3)
            test.eq(controls[1].action, "minimize")
            test.eq(controls[2].action, "fullscreen")
            test.eq(controls[3].action, "close")
            for _, control in ipairs(controls) do
                for x = control.x, control.x + control.width - 1 do
                    test.eq(layout.control_at(win, rect, x, rect.y), control.action)
                    test.is_nil(layout.control_at(win, rect, x, rect.y + 1))
                end
            end
            test.is_nil(layout.control_at(win, rect, rect.x, rect.y))
            test.is_nil(layout.control_at(win, rect, rect.x + rect.width - 1, rect.y))
            test.eq(layout.edge(rect, rect.x + rect.width - 1, rect.y), "rt")
            local small: model.Rect = {x = 1, y = 2, width = 8, height = 5}
            test.eq(#layout.controls(win, small), 1)
            test.eq(layout.controls(win, small)[1].action, "close")
        end)
        test.it("keeps fullscreen restoration separate from application focus", function()
            local scene = model.add(model.new(80, 24), "one", "app", "One")
            scene = model.toggle_fullscreen(scene, "one")
            local contents: {[string]: render.Content} = {}
            local frame = render.draw(scene, {"one"}, contents, nil, nil, "", "local")
            local focus_hit, restore_hit = false, false
            for _, hit in ipairs(frame.tabs) do
                if hit.id == "one" then
                    if hit.action == "fullscreen" then restore_hit = true elseif not hit.action then focus_hit = true end
                end
            end
            test.is_true(focus_hit)
            test.is_true(restore_hit)
            test.eq(model.bounds(scene, scene.windows[1]).height, 23)
        end)
        test.it("renders admitted icons without losing focused and minimized tab hits", function()
            local scene = model.add(model.new(80, 24), "one", "one", "Application One", "界")
            scene = model.add(scene, "two", "two", "Application Two", "T")
            scene = model.minimize(scene, "one")
            local preferences = appearance.decode({theme = "classic", background = "solid", taskbar = "icons"})
            if not preferences then error("Invalid icon preferences") end
            local frame = render.draw(scene, {"one", "two"}, {}, nil, nil, "", "workspace", preferences)
            test.is_true(frame.rows[1]:find("界", 1, true) ~= nil)
            test.is_true(frame.rows[1]:find("Application", 1, true) == nil)
            test.eq(#frame.tabs, 2)
            test.eq(frame.tabs[1].id, "one")
            test.eq(frame.tabs[2].id, "two")
            test.eq(appearance.cycle(preferences, "theme").taskbar, "icons")
            test.eq(assert(appearance.decode({theme = "honey", background = "dots"})).taskbar, "labels")
            test.is_nil(appearance.decode({theme = "honey", background = "dots", taskbar = "invalid"}))
        end)
        test.it("renders status badges in taskbar labels and window chrome without changing titles", function()
            local scene = model.add(model.new(80, 24), "one", "one", "Application One", "界")
            local badges: {[string]: surface.Badge} = {one = {glyph = "◐", text = "Waiting on you", tone = "warning"}}
            local preferences = appearance.defaults()
            local plain = render.draw(scene, {"one"}, {}, nil, nil, "", "workspace", preferences)
            local frame = render.draw(scene, {"one"}, {}, nil, nil, "", "workspace", preferences, nil, false, nil, nil, nil, badges)
            local text = table.concat(frame.rows, "\n")
            test.is_true(text:find("◐", 1, true) ~= nil)
            test.is_true(text:find("Waiting on you", 1, true) ~= nil)
            test.is_true(text:find("Application One", 1, true) ~= nil)
            test.eq(model.display_title(scene.windows[1]), "Application One")
            test.eq(frame.tabs[1].x, plain.tabs[1].x)
            test.eq(frame.tabs[1].width, plain.tabs[1].width + 2)

            local collapsed = model.collapse(scene, "one")
            local recap = render.draw(collapsed, {"one"}, {}, nil, nil, "", "workspace", preferences, nil, false, nil, nil, nil, badges)
            local recap_text = table.concat(recap.rows, "\n")
            test.is_true(recap_text:find("◐ Waiting on you", 1, true) ~= nil)

            local modes = {
                {name = "fullscreen", scene = model.toggle_fullscreen(scene, "one"), marker = "▣ ◐"},
                {name = "minimized", scene = model.minimize(scene, "one"), marker = "− ◐"},
                {name = "collapsed", scene = model.collapse(scene, "one"), marker = "▸ ◐"},
            }
            for _, item in ipairs(modes) do
                local plain_mode = render.draw(item.scene, {"one"}, {}, nil, nil, "", "workspace", preferences)
                local badge_mode = render.draw(item.scene, {"one"}, {}, nil, nil, "", "workspace", preferences, nil, false, nil, nil, nil, badges)
                test.is_true(plain_text(table.concat(badge_mode.rows, "\n")):find(item.marker, 1, true) ~= nil)
                test.eq(badge_mode.tabs[1].x, plain_mode.tabs[1].x)
                test.eq(badge_mode.tabs[1].width, plain_mode.tabs[1].width + 2)
            end
        end)
        test.it("keeps the active tab reachable when the taskbar overflows", function()
            local scene = model.new(24, 12)
            local order: {string} = {}
            for index = 1, 8 do
                local id = tostring(index)
                scene = model.add(scene, id, id, "Application " .. id)
                order[#order + 1] = id
            end
            local contents: {[string]: render.Content} = {}
            local frame = render.draw(scene, order, contents, nil, nil, "", "workspace")
            local reachable = false
            for _, hit in ipairs(frame.tabs) do
                test.is_true(hit.x >= 1 and hit.x + hit.width - 1 <= 24)
                if hit.id == "8" then reachable = true end
            end
            test.is_true(reachable)
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
