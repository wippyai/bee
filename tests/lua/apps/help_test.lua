-- MIT. Keyboard help shows each tab's bindings at both supported frame sizes,
-- scrolls within its table and lists under System in the Start menu.
local test = require("test")
local view = require("view")
local menu = require("menu")
local appearance = require("appearance")
local function define_tests()
    test.describe("Keyboard help", function()
        test.it("shows the bindings of each tab at both supported sizes", function()
            for _, size in ipairs({{120, 36}, {80, 24}}) do
                for _, pane in ipairs(view.PANES) do
                    local shown = view.draw(size[1], size[2], appearance.defaults(), pane :: view.Pane, 0)
                    local text = table.concat(shown.rows, "\n")
                    test.contains(text, "BEE KEYBOARD HELP")
                    for _, binding in ipairs(view.bindings(pane :: view.Pane)) do test.contains(text, binding.key) end
                end
            end
            local desktop = table.concat(view.draw(80, 24, appearance.defaults(), "desktop", 0).rows, "\n")
            test.contains(desktop, "Alt+Tab")
            test.contains(desktop, "Ctrl+Q")
        end)

        test.it("lists each tab's bindings under a heading per group", function()
            for _, pane in ipairs(view.PANES) do
                local text = table.concat(view.draw(120, 36, appearance.defaults(), pane :: view.Pane, 0).rows, "\n")
                local seen: {[string]: boolean} = {}
                for _, binding in ipairs(view.bindings(pane :: view.Pane)) do
                    if not seen[binding.group] then test.contains(text, string.upper(binding.group)) end
                    seen[binding.group] = true
                end
            end
        end)

        test.it("scrolls a tab that is taller than the window", function()
            local rows = view.capacity(60, 8)
            test.is_true(rows < #view.bindings("workspaces"))
            -- Two lines down, past the first group's heading and its first binding.
            local shown = table.concat(view.draw(60, 8, appearance.defaults(), "workspaces", 2).rows, "\n")
            test.is_nil((shown:find("Enter ", 1, true)))
            test.contains(shown, view.bindings("workspaces")[2].action)
        end)

        test.it("lists under the System menu its catalog entry names", function()
            local system: menu.Placement = {id = "bee.shell:system_menu", title = "System", location = "start", order = 20}
            local items = menu.items({
                {definition_id = "bee.apps.help:app", title = "Keyboard help", menus = {system}},
                {definition_id = "bee.apps.settings:app", title = "Settings", menus = {system}},
            })
            local labels: {string} = {}
            for _, item in ipairs(items) do
                if item.action == "group:bee.shell:system_menu" then
                    for _, child in ipairs(item.children or {}) do labels[#labels + 1] = child.label end
                end
            end
            test.eq(table.concat(labels, ","), "Keyboard help,Settings")
        end)
    end)
end
return test.run_cases(define_tests)
