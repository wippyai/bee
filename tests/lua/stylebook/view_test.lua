local test = require("test")
local tty = require("tty")
local view = require("view")
local appearance = require("appearance")

local function define_tests()
    test.describe("Bee UI Guide", function()
        test.it("keeps every frame and hit inside compact and wide canvases", function()
            for _, width in ipairs({1, 20, 40, 80, 120}) do
                for _, height in ipairs({1, 2, 3, 4, 6, 9, 11, 12, 13, 24}) do
                    for section = 1, view.section_count() do
                        local frame = view.draw(width, height, appearance.defaults(), section, view.item_count(section))
                        test.eq(#frame.rows, height)
                        for _, row in ipairs(frame.rows) do test.eq(tty.text.width(row), width) end
                        for _, hit in ipairs(frame.hits) do
                            test.is_true(hit.x >= 1 and hit.y >= 1)
                            test.is_true(hit.x + hit.width - 1 <= width)
                            test.is_true(hit.y + hit.height - 1 <= height)
                            test.not_nil(view.hit(frame.hits, hit.x, hit.y))
                            test.is_true(height < 2 or hit.y < height)
                        end
                        if width >= 20 and height >= 5 then
                            local selected = section == 1 and "Muted" or (section == 2 and "Name" or (section == 3 and "Empty" or "Actions"))
                            test.is_true(table.concat(frame.rows, "\n"):find(selected, 1, true) ~= nil)
                        end
                    end
                end
            end
        end)
        test.it("preserves identity, state words and actions across layouts", function()
            local compact = table.concat(view.draw(40, 12, appearance.defaults(), 3, 4).rows, "\n")
            test.is_true(compact:find("BEE UI GUIDE", 1, true) ~= nil)
            test.is_true(compact:find("Unavailable", 1, true) ~= nil)
            test.is_true(compact:find("Tab Section", 1, true) ~= nil)
            local wide = table.concat(view.draw(100, 20, appearance.defaults(), 2, 2).rows, "\n")
            test.is_true(wide:find("HONEY SYSTEM", 1, true) ~= nil)
            test.is_true(wide:find("one clear primary action", 1, true) ~= nil)
        end)
        test.it("uses every configured theme without changing interaction geometry", function()
            for _, theme in ipairs(appearance.themes()) do
                local preferences = {theme = theme.id, background = "dots", taskbar = "labels"}
                local frame = view.draw(80, 18, preferences, 1, 3)
                test.eq(#frame.hits, 8)
                for _, row in ipairs(frame.rows) do test.eq(tty.text.width(row), 80) end
            end
        end)
        test.it("keeps the disabled example inert", function()
            local frame = view.draw(80, 18, appearance.defaults(), 2, 1)
            local text = table.concat(frame.rows, "\n")
            test.is_true(text:find("Disabled", 1, true) ~= nil)
            for _, hit in ipairs(frame.hits) do
                test.is_false(hit.y == 6)
            end
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
