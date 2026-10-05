-- MIT. The desktop paints like Bee always has: the BEE menu, tabs and the
-- desktop label on the top bar, the wallpaper pattern, rounded windows with
-- their controls, the Start panel under the bar, context menus where the
-- pointer was and the workspace menu at the right.
local test = require("test")
local model = require("model")
local layout = require("layout")
local menu = require("menu")
local render = require("render")
local workspace_menu = require("workspace_menu")
local appearance = require("appearance")

local function plain(value: string): string return (string.gsub(value, "\27%[[0-9;]*m", "")) end

local apps_menu: menu.Placement = {id = "sample:apps", title = "Apps", location = "start", order = 10}
local system_menu: menu.Placement = {id = "sample:system", title = "System", location = "start", order = 20}
local desktop_menu: menu.Placement = {id = "sample:desktop", title = "Desktop", location = "desktop", order = 10}
local catalog: {menu.Descriptor} = {
    {definition_id = "sample:settings", title = "Settings", menus = {system_menu, desktop_menu}},
    {definition_id = "sample:terminal", title = "Terminal", menus = {apps_menu}},
    {definition_id = "sample:hidden", title = "Hidden", menus = {}},
}

local function draw(scene: model.Scene, order: {string}, overlays: render.Overlays): {string}
    local frame = render.draw(scene, order, {}, nil, nil, "", "bee · Desktop 1", appearance.defaults(), overlays)
    local rows: {string} = {}
    for index, row in ipairs(frame.rows) do rows[index] = plain(row) end
    return rows
end

local function define_tests()
    test.describe("desktop", function()
        test.it("puts the BEE menu and the desktop label on the top bar", function()
            local rows = draw(model.new(100, 30), {}, {})
            test.eq(#rows, 30)
            test.contains(rows[1], " BEE ▾ ")
            test.contains(rows[1], "bee · Desktop 1 ▾")
        end)

        test.it("paints the wallpaper pattern below the bar", function()
            local rows = draw(model.new(100, 30), {}, {})
            test.contains(table.concat(rows, "\n", 2), "·")
        end)

        test.it("draws a window with rounded corners, its title and controls below the bar", function()
            local scene = model.add(model.new(100, 30), "one", "one", "Terminal")
            local rows = draw(scene, {"one"}, {})
            local win = scene.windows[1]
            local rect = layout.rectangle(scene, win, nil, nil)
            test.is_true(rect.y >= 2)
            test.contains(rows[rect.y], "╭")
            test.contains(rows[rect.y], "Terminal")
            test.contains(rows[rect.y], " − ")
            test.contains(rows[rect.y], " □ ")
            test.contains(rows[rect.y], " × ")
            test.contains(rows[rect.y + rect.height - 1], "╰")
            test.contains(rows[1], "Terminal")
        end)

        test.it("opens the Start panel under the bar with the declared menus, workspaces and exit", function()
            local rows = draw(model.new(100, 30), {}, {start = {selected = 1, offset = 0}, catalog = catalog})
            local panel = table.concat(rows, "\n", 2, 12)
            test.contains(rows[1], " BEE ▴ ")
            test.contains(panel, "Apps")
            test.contains(panel, "Bees")
            test.contains(panel, "Exit")
            test.contains(panel, "System")
            test.is_nil((panel:find("Open application", 1, true)))
        end)

        test.it("separates the Start panel's app menus, the workspace menu and exit with rules", function()
            local rows = draw(model.new(100, 30), {}, {start = {selected = 1, offset = 0}, catalog = catalog})
            local plain: {string} = {}
            for index, row in ipairs(rows) do plain[index] = row:gsub("\27%[[0-9;]*m", "") end
            local function at(label: string): integer
                for index, row in ipairs(plain) do if row:find("│ " .. label, 1, true) then return index end end
                return 0
            end
            local system, bees, exit = at("System"), at("Bees"), at("Exit")
            test.is_true(system > 0 and bees == system + 2 and exit == bees + 2)
            test.contains(plain[system + 1], "├")
            test.contains(plain[bees + 1], "├")
        end)

        test.it("places each app in the menus its catalog entry names, menus in their declared order", function()
            local items = menu.items({
                {definition_id = "sample:settings", title = "Settings", menus = {system_menu}},
                {definition_id = "sample:terminal", title = "Terminal", menus = {apps_menu}},
                {definition_id = "sample:hidden", title = "Hidden", menus = {}},
            })
            local shown: {string} = {}
            for _, item in ipairs(items) do
                local children: {string} = {}
                for _, child in ipairs(item.children or {}) do children[#children + 1] = child.label end
                shown[#shown + 1] = item.label .. (#children > 0 and "(" .. table.concat(children, ",") .. ")" or "")
            end
            test.eq(table.concat(shown, " "), "Apps(Terminal) System(Settings) Bees Exit")
        end)

        test.it("offers the apps placed in the desktop menu, a new desktop and the workspace menu on the desktop's context menu", function()
            local scene = model.new(100, 30)
            local items = menu.entries({selected = 1, offset = 0, kind = "desktop", x = 10, y = 10}, scene, catalog)
            local labels: {string} = {}
            for _, item in ipairs(items) do labels[#labels + 1] = item.label end
            test.eq(labels[1], "Settings")
            test.is_nil((table.concat(labels, ","):find("Terminal", 1, true)))
            test.contains(table.concat(labels, ","), "New desktop")
            test.contains(table.concat(labels, ","), "Bees")
        end)

        test.it("offers the window actions on a window's context menu", function()
            local scene = model.add(model.new(100, 30), "one", "one", "Terminal")
            local items = menu.entries({selected = 1, offset = 0, kind = "window", target = "one", x = 10, y = 10}, scene, catalog)
            local labels: {string} = {}
            for _, item in ipairs(items) do labels[#labels + 1] = item.label end
            local joined = table.concat(labels, ",")
            for _, label in ipairs({"Minimize", "Snap left", "Snap right", "Collapse", "Rename…", "Select text", "Accent", "Close"}) do
                test.contains(joined, label)
            end
            local moves = menu.entries({selected = 1, offset = 0, kind = "window", target = "one", x = 10, y = 10}, scene, catalog,
                {{id = "d2", title = "Desktop 2"}})
            local targets: {string} = {}
            for _, item in ipairs(moves) do
                if item.action == "group:move" then
                    for _, child in ipairs(item.children or {}) do targets[#targets + 1] = child.action end
                end
            end
            test.eq(table.concat(targets, ","), "move:d2")
        end)

        test.it("shows the desktops, marking the shown one, then the folders, marking the one in use, each with its action row", function()
            local desktops: {workspace_menu.Desktop} = {
                {id = "d1", title = "Desktop 1", workspace = "w1", shown = true},
                {id = "d2", title = "Desktop 2", workspace = "w2", shown = true},
            }
            local workspaces: {workspace_menu.Workspace} = {
                {id = "w1", path = "/home/a/bee", label = "bee"},
                {id = "w2", path = "/home/a/site", label = "site"},
            }
            local opened = workspace_menu.new("d2", desktops, workspaces, {d1 = 2}, {"n1"}, "n1")
            local rows = draw(model.new(100, 30), {}, {workspaces = opened})
            local text = table.concat(rows, "\n")
            test.contains(text, " Bees ")
            test.contains(text, "DESKTOPS")
            test.contains(text, "Desktop 1")
            test.contains(text, "2 apps")
            test.contains(text, "other display")
            test.contains(text, "● Desktop 2")
            test.contains(text, "this display")
            test.contains(text, "+ New desktop")
            test.contains(text, "FOLDERS")
            test.contains(text, "✓ site")
            test.contains(text, "/home/a/site")
            test.contains(text, "+ Add folder…")
            test.contains(text, "Shown here · R rename")
            test.is_nil((text:find("NODES", 1, true)))
            test.eq(workspace_menu.describe(desktops, workspaces, "d1"), "Desktop 1 · bee")
        end)
    end)

    test.describe("workspace menu", function()
        local desktops: {workspace_menu.Desktop} = {
            {id = "d1", title = "One", workspace = "w1", shown = true},
            {id = "d2", title = "Two", workspace = "w1", shown = false},
        }
        local workspaces: {workspace_menu.Workspace} = {
            {id = "w1", path = "/a", label = "a"},
            {id = "w2", path = "/b", label = "b"},
        }
        local function key(name: string): unknown
            if #name == 1 then return {type = "key", key = name, key_type = "runes", action = "press"} end
            return {type = "key", key = name, key_type = name, action = "press"}
        end

        test.it("shows another desktop on Enter", function()
            local opened = workspace_menu.new("d1", desktops, workspaces, {}, {"n1"}, "n1")
            workspace_menu.respond(opened, key("down"))
            local response = workspace_menu.respond(opened, key("enter"))
            test.eq(response.switch, "d2")
            test.is_true(response.close)
        end)

        test.it("keeps a desktop another display shows off this display", function()
            local taken: {workspace_menu.Desktop} = {
                {id = "d1", title = "One", workspace = "w1", shown = true},
                {id = "d2", title = "Two", workspace = "w1", shown = true},
            }
            local opened = workspace_menu.new("d1", taken, workspaces, {}, {"n1"}, "n1")
            workspace_menu.respond(opened, key("down"))
            local response = workspace_menu.respond(opened, key("enter"))
            test.is_nil(response.switch)
            test.is_false(response.close)
            test.eq(opened.status, "Two is on another display")
        end)

        test.it("makes the shown desktop work in a chosen folder", function()
            local opened = workspace_menu.new("d1", desktops, workspaces, {}, {"n1"}, "n1")
            for _ = 1, 4 do workspace_menu.respond(opened, key("down")) end
            test.eq(workspace_menu.respond(opened, key("enter")).use, "w2")
        end)

        test.it("asks for a new desktop and for a folder to add, by key and from their rows", function()
            local opened = workspace_menu.new("d1", desktops, workspaces, {}, {"n1"}, "n1")
            test.is_true(workspace_menu.respond(opened, key("n")).create)
            test.is_true(workspace_menu.respond(opened, key("a")).add)
            for _ = 1, 2 do workspace_menu.respond(opened, key("down")) end
            test.eq(opened.rows[opened.selected].kind, "new_desktop")
            test.is_true(workspace_menu.respond(opened, key("enter")).create)
            workspace_menu.respond(opened, key("end"))
            test.eq(opened.rows[opened.selected].kind, "add_folder")
            test.is_true(workspace_menu.respond(opened, key("enter")).add)
        end)

        test.it("refuses to close the shown desktop and asks to close another", function()
            local opened = workspace_menu.new("d1", desktops, workspaces, {}, {"n1"}, "n1")
            test.is_nil(workspace_menu.respond(opened, key("x")).remove)
            workspace_menu.respond(opened, key("down"))
            test.eq((workspace_menu.respond(opened, key("x")).remove or {id = ""}).id, "d2")
        end)

        test.it("browses another node's desktops on the node strip and shows one of them here", function()
            local opened = workspace_menu.new("d1", desktops, workspaces, {}, {"n1", "n2"}, "n1")
            workspace_menu.label(opened, "n1", "bee")
            workspace_menu.label(opened, "n2", "site")
            test.eq((opened.rows[opened.selected].desktop or {id = ""}).id, "d1")
            local response = workspace_menu.respond(opened, key("right"))
            test.eq(response.browse, "n2")
            test.is_nil(response.node)
            test.eq(#opened.rows, 0)
            test.eq(opened.status, "Asking site…")
            workspace_menu.update(opened, "n1", desktops, workspaces, {})
            test.eq(#opened.rows, 0)
            workspace_menu.update(opened, "n2", {{id = "e1", title = "Remote", workspace = "v1", shown = false}},
                {{id = "v1", path = "/r", label = "r"}}, {e1 = 1})
            test.eq((opened.rows[1].desktop or {id = ""}).id, "e1")
            test.is_false(workspace_menu.respond(opened, key("n")).create)
            local text = table.concat(draw(model.new(100, 30), {}, {workspaces = opened}), "\n")
            test.contains(text, " bee ● ")
            test.contains(text, " site ")
            test.contains(text, "Remote")
            test.contains(text, "Enter show here (this display moves to site)")
            local shown = workspace_menu.respond(opened, key("enter"))
            test.eq(shown.node, "n2")
            test.eq(shown.switch, "e1")
            test.is_true(shown.close)
        end)

        test.it("returns to the shown node's catalog from the strip", function()
            local opened = workspace_menu.new("d1", desktops, workspaces, {}, {"n1", "n2"}, "n1")
            workspace_menu.respond(opened, key("right"))
            test.eq(workspace_menu.respond(opened, key("left")).browse, "n1")
        end)

        test.it("asks to forget a selected folder", function()
            local opened = workspace_menu.new("d1", desktops, workspaces, {}, {"n1"}, "n1")
            for _ = 1, 4 do workspace_menu.respond(opened, key("down")) end
            test.eq((workspace_menu.respond(opened, key("x")).forget or {id = ""}).id, "w2")
        end)

        test.it("filters desktops and workspaces by search", function()
            local opened = workspace_menu.new("d1", desktops, workspaces, {}, {"n1"}, "n1")
            workspace_menu.respond(opened, key("/"))
            workspace_menu.respond(opened, key("T"))
            workspace_menu.respond(opened, key("w"))
            test.eq(#opened.rows, 1)
            test.eq((opened.rows[1].desktop or {id = ""}).id, "d2")
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
