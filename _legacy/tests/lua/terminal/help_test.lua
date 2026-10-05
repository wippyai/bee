-- MIT. Help exposes the desktop keys at both supported frame sizes.
local test = require("test")
local help = require("help")
local frame = require("frame")
local appearance = require("appearance")
local function define_tests()
    test.describe("Desktop help", function()
        test.it("opens the frame keyboard guide instead of Settings", function()
            for _, size in ipairs({{120, 36}, {80, 24}}) do
                local menu = frame.menu()
                local shown = help.draw(size[1], size[2], appearance.defaults(), menu)
                local text = table.concat(shown.rows, "\n")
                test.is_true(text:find("HELP", 1, true) ~= nil)
                test.is_true(text:find("Alt+Tab", 1, true) ~= nil)
                test.is_true(text:find("Ctrl+Q", 1, true) ~= nil)
                test.is_nil((text:find("BEE SETTINGS", 1, true)))
                frame.route(menu, {type = "key", action = "press", key_type = "esc"})
                test.eq(menu.mode, "")
            end
        end)
    end)
end
return test.run_cases(define_tests)
