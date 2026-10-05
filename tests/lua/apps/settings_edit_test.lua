-- MIT. Settings edit mode: the pane states that overlay admission stays host
-- controlled and person approved, fits every terminal size, and its
-- confirmations are single-line questions the interaction decoder accepts.
local test = require("test")
local tty = require("tty")
local appearance = require("appearance")
local interaction = require("interaction")
local view = require("view")

local function define_tests()
    test.describe("Settings edit mode", function()
        test.it("shows person-confirmed, bounded edit mode controls at every terminal size", function()
            for _, width in ipairs({1, 12, 28, 48, 80}) do
                for _, height in ipairs({1, 3, 6, 12}) do
                    local drawn = view.draw(width, height, appearance.defaults(), {}, "edit_mode", 0)
                    test.eq(#drawn.rows, height)
                    for _, row in ipairs(drawn.rows) do test.eq(tty.text.width(row), width) end
                    for _, hit in ipairs(drawn.hits) do
                        test.is_true(hit.x >= 1 and hit.y >= 1)
                        test.is_true(hit.x + hit.width - 1 <= width)
                        test.is_true(hit.y + hit.height - 1 <= height)
                    end
                end
            end
            local text = table.concat(view.draw(80, 12, appearance.defaults(), {}, "edit_mode", 0).rows, "\n")
            test.is_true(text:find("Temporary overlay admission is host controlled.", 1, true) ~= nil)
            test.is_true(text:find("explicit person approval", 1, true) ~= nil)
            test.is_true(text:find("up to 24h", 1, true) ~= nil)
            local tabs = view.draw(80, 12, appearance.defaults(), {}, "theme", 0).hits
            local has_edit_tab = false
            for _, hit in ipairs(tabs) do if hit.kind == "edit_mode" then has_edit_tab = true end end
            test.is_true(has_edit_tab)
        end)
        test.it("states the workspace scope and duration of overlay removal in a decoder-valid confirmation", function()
            local message = view.confirm_message("", true)
            test.is_true(message:find("Remove this workspace", 1, true) ~= nil)
            test.is_true(message:find("Duration: once", 1, true) ~= nil)
            test.is_true(message:find("until edit mode is enabled again", 1, true) ~= nil)
            test.is_nil((message:find("%c")))
            test.not_nil(interaction.spec({version = 1, request_id = "r-2", id = "bee.settings:edit",
                instance_id = "settings", kind = "confirm", title = "Disable edit mode",
                message = message, accept = "Disable", initial = ""}))
        end)
        test.it("builds a decoder-valid single-line edit-mode confirmation", function()
            local message = view.confirm_message("bee.ux_demo --for 1m")
            test.is_nil((message:find("%c")))
            test.not_nil(interaction.spec({version = 1, request_id = "r-1", id = "bee.settings:edit",
                instance_id = "settings", kind = "confirm", title = "Confirm edit mode",
                message = message, accept = "Enable", initial = ""}))
        end)
    end)
end
return test.run_cases(define_tests)
