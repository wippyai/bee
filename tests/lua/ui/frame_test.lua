-- MIT. Pointer gestures the shared frame recognizes.
local test = require("test")
local frame = require("frame")
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
