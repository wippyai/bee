-- MIT. Settings About shows the project website and the live Bee packs with
-- their Hub releases, and refuses malformed Hub status at its boundary.
local test = require("test")
local tty = require("tty")
local view = require("view")
local appearance = require("appearance")
local live_updates = require("live_updates")

local function text(rows: {string}): string
    return (table.concat(rows, "\n"):gsub("\27%[[0-9;]*m", ""))
end

local function define_tests()
    test.describe("Settings About", function()
        test.it("decodes host-selected package updates without a brand prefix", function()
            local reply = {ok = true, replayed = false, value = {
                modules = {{component = "vendor/selected", installed_version = "1.0.0", locked_version = "1.0.0",
                    available_version = "1.1.0", update_available = true}},
                bee_update = {installed_version = "1.0.0", available_version = "", update_available = false,
                    needs_new_binary = false, reason = ""}, catalog_error = ""}}
            local status = live_updates.decode(reply)
            test.eq(status.state, "ready")
            test.eq(status.modules[1].component, "vendor/selected")
            reply.value.modules[1].component = "unqualified"
            test.eq(live_updates.decode(reply).state, "error")
        end)
        test.it("shows the build, the installed Bee pack and a check for updates button", function()
            local build: view.Build = {runtime = "v0.1.14-runtime", lua = "Lua 5.1", node = "node-id", folder = "/home/a/bee"}
            local status = live_updates.decode({ok = true, replayed = false, value = {
                modules = {{component = "bee/bee", installed_version = "0.1.0", locked_version = "", available_version = "0.2.0",
                    update_available = true}},
                bee_update = {installed_version = "0.1.0", available_version = "0.2.0", update_available = true,
                    needs_new_binary = false, reason = ""}, catalog_error = ""}})
            local drawn = view.draw(100, 30, appearance.defaults(), {}, "about", 0, nil, status, false, build)
            local shown = text(drawn.rows)
            for _, expected in ipairs({"BUILD", "Bee       0.1.0", "Runtime   v0.1.14-runtime", "Lua       Lua 5.1", "Node      node-id",
                "Folder    /home/a/bee", "INSTALLED", "update available", "PACKS", "Check for updates", "Bee 0.2.0 is available"}) do
                test.contains(shown, expected)
            end
            local check = false
            for _, hit in ipairs(drawn.hits) do
                if hit.kind == "check" then check = true end
            end
            test.is_true(check)
            local checking = text(view.draw(100, 30, appearance.defaults(), {}, "about", 0, nil, nil, true, build).rows)
            test.contains(checking, "Checking…")
            test.contains(checking, "Bee       reading…")
        end)

        test.it("offers About as a tab beside the appearance panes", function()
            local found = false
            for _, hit in ipairs(view.draw(80, 24, appearance.defaults(), {}, "theme", 0).hits) do
                if hit.kind == "about" then found = true end
            end
            test.is_true(found)
            local about = view.draw(80, 12, appearance.defaults(), {}, "about", 0)
            test.is_true(text(about.rows):find("Tab switch", 1, true) ~= nil)
        end)
        test.it("shows the project website and live packs at every terminal size", function()
            for _, width in ipairs({1, 18, 28, 62, 80, 100, 120}) do
                for _, height in ipairs({1, 4, 8, 18, 24, 36}) do
                    local frame = view.draw(width, height, appearance.defaults(), {}, "about", 0)
                    test.eq(#frame.rows, height)
                    for _, row in ipairs(frame.rows) do test.eq(tty.text.width(row), width) end
                    for _, hit in ipairs(frame.hits) do
                        test.is_true(hit.x >= 1 and hit.y >= 1)
                        test.is_true(hit.x + hit.width - 1 <= width)
                        test.is_true(hit.y + hit.height - 1 <= height)
                    end
                end
            end
            local shown = text(view.draw(100, 18, appearance.defaults(), {}, "about", 0).rows)
            test.is_true(shown:find("BEE SETTINGS · ABOUT", 1, true) ~= nil)
            test.is_true(shown:find(view.WEBSITE, 1, true) ~= nil)
            test.is_true(shown:find("Status    not checked", 1, true) ~= nil)
            local compact: {string} = {}
            for offset = 0, view.about_count(40, nil, false) do
                compact[#compact + 1] = text(view.draw(40, 8, appearance.defaults(), {}, "about", offset).rows)
            end
            local scrolled = table.concat(compact, "\n")
            test.is_true(scrolled:find("Website", 1, true) ~= nil)
            test.is_true(scrolled:find("PACKS", 1, true) ~= nil)
        end)
        test.it("shows a pending check while the Hub status is read", function()
            local shown = text(view.draw(100, 18, appearance.defaults(), {}, "about", 0, nil, nil, true).rows)
            test.is_true(shown:find("checking installed versions and updates", 1, true) ~= nil)
        end)
        test.it("clamps the About scroll offset to the rows the height shows", function()
            test.eq(view.about_offset(-3, 80, 24, nil, false), 0)
            local count = view.about_count(80, nil, false)
            test.eq(view.about_offset(999, 80, 6, nil, false), math.max(0, count - 1))
        end)
        test.it("shows live pack versions, available updates and native compatibility in About", function()
            local status = live_updates.decode({ok = true, replayed = false, value = {
                modules = {
                    {component = "bee/bee", installed_version = "1.0.0", locked_version = "0.9.0", available_version = "2.0.0", update_available = true},
                    {component = "bee/application", installed_version = "1.0.0", locked_version = "0.9.0", available_version = "2.0.0", update_available = true},
                },
                bee_update = {installed_version = "1.0.0", available_version = "2.0.0", update_available = true,
                    needs_new_binary = true, reason = "needs a newer Bee binary: native/launch requires 2.0.0"},
                catalog_error = "",
            }})
            local shown = text(view.draw(100, 24, appearance.defaults(), {}, "about", 0, nil, status, false).rows)
            test.is_true(shown:find("PACKS", 1, true) ~= nil)
            test.is_true(shown:find("bee/application", 1, true) ~= nil)
            test.is_true(shown:find("bee/application  1.0.0", 1, true) ~= nil)
            test.is_true(shown:find("locked at 0.9.0", 1, true) ~= nil)
            test.is_true(shown:find("0.9.0", 1, true) ~= nil)
            test.is_true(shown:find("2.0.0", 1, true) ~= nil)
            test.is_true(shown:find("update available", 1, true) ~= nil)
            test.is_true(shown:find("needs a newer Bee binary", 1, true) ~= nil)
            test.is_true(view.about_count(100, status, false) > view.about_count(100, nil, false))
        end)
        test.it("shows an unavailable Hub status with its reason", function()
            local status = live_updates.failure("UNAVAILABLE: catalog unreachable")
            local shown = text(view.draw(100, 18, appearance.defaults(), {}, "about", 0, nil, status, false).rows)
            test.is_true(shown:find("unavailable · UNAVAILABLE: catalog unreachable", 1, true) ~= nil)
        end)
        test.it("rejects malformed live Hub status at the Settings boundary", function()
            local valid = {ok = true, replayed = false, value = {modules = {},
                bee_update = {installed_version = "1.0.0", available_version = "1.0.0", update_available = false,
                    needs_new_binary = false, reason = ""}, catalog_error = ""}}
            test.eq(live_updates.decode(valid).state, "ready")
            valid.unexpected = true
            test.eq(live_updates.decode(valid).state, "error")
            valid.unexpected = nil
            valid.value.modules = {{component = "example/app/extra", installed_version = "1.0.0",
                available_version = "2.0.0", update_available = true}}
            test.eq(live_updates.decode(valid).state, "error")
            valid.value.modules = {}
            valid.value.binary = {native_module = "github.com/wippyai/bee/native"}
            test.eq(live_updates.decode(valid).state, "error")
        end)
        test.it("accepts an empty Bee deployment root before the first Hub self-update", function()
            local status = live_updates.decode({ok = true, replayed = false, value = {modules = {},
                bee_update = {installed_version = "", available_version = "", update_available = false,
                    needs_new_binary = false, reason = ""}, catalog_error = ""}})
            test.eq(status.state, "ready")
            test.eq(status.bee_update and status.bee_update.installed_version, "")
        end)
    end)
end
return test.run_cases(define_tests)
