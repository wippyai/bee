local test = require("test")
local tty = require("tty")
local view = require("view")
local frames = require("frames")
local appearance = require("appearance")
local interaction = require("interaction")
local live_updates = require("live_updates")
local build_info = require("build_info")
local function define_tests()
    test.describe("Appearance chooser", function()
        test.it("shows errors in compact settings without losing selection controls", function()
            local frame = view.draw(28, 6, appearance.defaults(), "theme", 0, "Permission denied")
            test.is_true(table.concat(frame.rows, "\n"):find("Permission denied", 1, true) ~= nil)
            local steps = 0
            for _, hit in ipairs(frame.hits) do if hit.kind == "step" then steps = steps + 1 end end
            test.eq(steps, 2)
            for _, row in ipairs(frame.rows) do test.eq(tty.text.width(row), 28) end
        end)
        test.it("keeps cards, tabs and hits inside every terminal size", function()
            for _, width in ipairs({1, 12, 18, 28, 47, 48, 49, 62, 80, 100, 120}) do
                for _, height in ipairs({1, 8, 18, 24, 30, 36}) do
                    for _, pane in ipairs({"theme", "background", "taskbar"}) do
                        local frame = view.draw(width, height, appearance.defaults(), pane == "theme" and "theme" or (pane == "background" and "background" or "taskbar"), 0)
                        test.eq(#frame.rows, height)
                        for _, row in ipairs(frame.rows) do test.eq(tty.text.width(row), width) end
                        for _, hit in ipairs(frame.hits) do
                            test.is_true(hit.x >= 1 and hit.y >= 1)
                            test.is_true(hit.x + hit.width - 1 <= width)
                            test.is_true(hit.y + hit.height - 1 <= height)
                            test.is_true(frames.hit(frame.hits, hit.x, hit.y) ~= nil)
                        end
                        test.is_nil(frames.hit(frame.hits, width + 1, 1))
                    end
                end
            end
        end)
        test.it("puts the pager on the action row and status with key hints on the final row", function()
            local drawn = view.draw(80, 24, appearance.defaults(), "theme", 0)
            local rows: {string} = {}
            for index, row in ipairs(drawn.rows) do rows[index] = row:gsub("\27%[[0-9;]*m", "") end
            test.is_true(rows[23]:find("‹ 1–9/16 ›", 1, true) ~= nil)
            test.is_true(rows[24]:find("Theme: Honey", 1, true) ~= nil)
            test.is_true(rows[24]:find("Tab switch", 1, true) ~= nil)
            test.is_true(rows[1]:find("Use node default (D)", 1, true) ~= nil)
            local pages = 0
            for _, hit in ipairs(drawn.hits) do if hit.kind == "page" then pages = pages + 1; test.eq(hit.y, 23) end end
            test.eq(pages, 1)
            for _, pane in ipairs({"theme", "background"}) do
                for _, row in ipairs(view.draw(80, 24, appearance.defaults(), pane, 0).rows) do
                    test.eq(tty.text.width(row), 80)
                end
            end
            local about = view.draw(80, 12, appearance.defaults(), "about", 0)
            test.is_true(about.rows[12]:find("Tab switch", 1, true) ~= nil)
        end)
        test.it("allows browsing past the selection and reveals it only on request", function()
            local grid = view.grid(62, 18)
            test.eq(grid.columns, 2)
            test.eq(grid.capacity, 4)
            test.eq(view.offset(1, 2, grid, 14, false), 2)
            test.eq(view.offset(1, 2, grid, 14, true), 0)
            local end_offset = view.offset(14, 0, grid, 14, true)
            test.is_true(14 > end_offset and 14 <= end_offset + grid.capacity)
        end)
        test.it("shows binary native identity and the project website in About", function()
            for _, width in ipairs({1, 18, 28, 62, 80, 100, 120}) do
                for _, height in ipairs({1, 4, 8, 18, 24, 36}) do
                    local frame = view.draw(width, height, appearance.defaults(), "about", 0)
                    test.eq(#frame.rows, height)
                    for _, row in ipairs(frame.rows) do test.eq(tty.text.width(row), width) end
                    for _, hit in ipairs(frame.hits) do
                        test.is_true(hit.x >= 1 and hit.y >= 1)
                        test.is_true(hit.x + hit.width - 1 <= width)
                        test.is_true(hit.y + hit.height - 1 <= height)
                    end
                end
            end
            local text = table.concat(view.draw(100, 18, appearance.defaults(), "about", 0).rows, "\n")
            test.is_true(text:find("BEE SETTINGS · ABOUT", 1, true) ~= nil)
            test.is_true(text:find("development source (unknown)", 1, true) ~= nil)
            test.is_true(text:find("https://bee.wippy.ai", 1, true) ~= nil)
            local compact: {string} = {}
            for offset = 0, view.about_count(40) do
                compact[#compact + 1] = table.concat(view.draw(40, 8, appearance.defaults(), "about", offset).rows, "\n")
            end
            local scrolled = table.concat(compact, "\n")
            test.is_true(scrolled:find("Binary native version", 1, true) ~= nil)
            test.is_true(scrolled:find("Binary native module", 1, true) ~= nil)
            test.is_true(scrolled:find("Binary runtime commit", 1, true) ~= nil)
            test.is_true(scrolled:find("Website", 1, true) ~= nil)
            test.is_true(scrolled:find("Live Bee packs", 1, true) ~= nil)
        end)
        test.it("shows live pack versions, available updates and native compatibility in About", function()
            local status = live_updates.decode({ok = true, replayed = false, value = {
                modules = {
                    {component = "bee/bee", installed_version = "1.0.0", locked_version = "0.9.0", available_version = "2.0.0", update_available = true},
                    {component = "bee/application", installed_version = "1.0.0", locked_version = "0.9.0", available_version = "2.0.0", update_available = true},
                },
                bee_update = {installed_version = "1.0.0", available_version = "2.0.0", update_available = true,
                    needs_new_binary = true, reason = "needs a newer Bee binary: native/launch requires 2.0.0"},
                binary = {native_module = "github.com/wippyai/bee/native", native_version = "v1.2.3",
                    runtime_commit = "0123456789abcdef0123456789abcdef01234567"},
                catalog_error = "",
            }})
            local identity = status.binary
            local info = build_info.info(identity and identity.native_module, identity and identity.native_version,
                identity and identity.runtime_commit)
            local text = table.concat(view.draw(100, 24, appearance.defaults(), "about", 0, nil, status, false, info).rows, "\n")
            test.is_nil((text:find("Binary version", 1, true)))
            test.is_true(text:find("Binary native version", 1, true) ~= nil)
            test.is_true(text:find("v1.2.3", 1, true) ~= nil)
            test.is_true(text:find("Binary runtime commit", 1, true) ~= nil)
            test.is_true(text:find("Live Bee packs", 1, true) ~= nil)
            test.is_true(text:find("bee/application", 1, true) ~= nil)
            test.is_true(text:find("installed 1.0.0", 1, true) ~= nil)
            test.is_true(text:find("Lock pin", 1, true) ~= nil)
            test.is_true(text:find("0.9.0", 1, true) ~= nil)
            test.is_true(text:find("Hub 2.0.0", 1, true) ~= nil)
            test.is_true(text:find("update available", 1, true) ~= nil)
            test.is_true(text:find("needs a newer Bee binary", 1, true) ~= nil)
            test.is_true(view.about_count(100, status, false) > view.about_count(100, nil, false))
        end)
        test.it("rejects malformed live Hub status at the Settings boundary", function()
            local valid = {ok = true, replayed = false, value = {modules = {},
                bee_update = {installed_version = "1.0.0", available_version = "1.0.0", update_available = false,
                    needs_new_binary = false, reason = ""}, binary = {native_module = "github.com/wippyai/bee/native",
                    native_version = "v1.2.3", runtime_commit = "0123456789abcdef0123456789abcdef01234567"}, catalog_error = ""}}
            test.eq(live_updates.decode(valid).state, "ready")
            valid.unexpected = true
            test.eq(live_updates.decode(valid).state, "error")
            valid.unexpected = nil
            valid.value.modules = {{component = "example/app", installed_version = "1.0.0",
                available_version = "2.0.0", update_available = true}}
            test.eq(live_updates.decode(valid).state, "error")
            valid.value.modules = {}
            valid.value.binary.runtime_commit = "invalid"
            test.eq(live_updates.decode(valid).state, "error")
        end)
        test.it("accepts an empty Bee deployment root before the first Hub self-update", function()
            local status = live_updates.decode({ok = true, replayed = false, value = {modules = {},
                bee_update = {installed_version = "", available_version = "", update_available = false,
                    needs_new_binary = false, reason = ""}, catalog_error = ""}})
            test.eq(status.state, "ready")
            test.eq(status.bee_update and status.bee_update.installed_version, "")
        end)
        test.it("shows person-confirmed, bounded edit mode controls at every terminal size", function()
            for _, width in ipairs({1, 12, 28, 48, 80}) do
                for _, height in ipairs({1, 3, 6, 12}) do
                    local frame = view.draw(width, height, appearance.defaults(), "edit_mode", 0)
                    test.eq(#frame.rows, height)
                    for _, row in ipairs(frame.rows) do test.eq(tty.text.width(row), width) end
                    for _, hit in ipairs(frame.hits) do
                        test.is_true(hit.x >= 1 and hit.y >= 1)
                        test.is_true(hit.x + hit.width - 1 <= width)
                        test.is_true(hit.y + hit.height - 1 <= height)
                    end
                end
            end
            local text = table.concat(view.draw(80, 12, appearance.defaults(), "edit_mode", 0).rows, "\n")
            test.is_true(text:find("Temporary overlay admission is host controlled.", 1, true) ~= nil)
            test.is_true(text:find("explicit person approval", 1, true) ~= nil)
            test.is_true(text:find("up to 24h", 1, true) ~= nil)
            local tabs = view.draw(80, 12, appearance.defaults(), "theme", 0).hits
            local has_edit_tab = false
            for _, hit in ipairs(tabs) do if hit.kind == "edit_mode" then has_edit_tab = true end end
            test.is_true(has_edit_tab)
        end)
        test.it("builds a decoder-valid single-line edit-mode confirmation", function()
            local message = view.confirm_message("bee.ux_demo --for 1m")
            test.is_nil((message:find("%c")))
            local spec = interaction.spec({version = 1, request_id = "r-1", id = "bee.settings:edit",
                instance_id = "settings", kind = "confirm", title = "Confirm edit mode",
                message = message, accept = "Enable", initial = ""})
            test.not_nil(spec)
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
