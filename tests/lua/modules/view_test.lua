-- MIT. The frame scales down without allowing catalog text to escape the canvas.
local test = require("test")
local tty = require("tty")
local appearance = require("appearance")
local model = require("model")
local view = require("view")
local function define_tests()
    test.describe("Modules frame", function()
        test.it("renders multiline package documentation", function()
            local state = model.new()
            model.select(state, "bee/example")
            model.apply_details(state, {ok = true, code = nil, message = nil, replayed = false, value = {
                component = "bee/example", title = "Example", description = "Package", readme = "# Guide\nUsage instructions",
                versions = {{version = "1.0.0", yanked = false}}, page = 1, total_versions = 1,
            }})
            local frame = view.draw(80, 24, appearance.defaults(), state, 0, "", true)
            test.is_true(table.concat(frame.rows, "\n"):find("Usage instructions", 1, true) ~= nil)
        end)
        test.it("scrolls every plan effect without changing confirmation", function()
            local state = model.new()
            model.select(state, "bee/example")
            model.select_version(state, "1.0.0")
            local modules: {{[string]: unknown}} = {}
            for index = 1, 30 do modules[index] = {change = "install", component = "acme/package" .. tostring(index), version = "1.0.0"} end
            model.apply_plan(state, {ok = true, code = nil, message = nil, replayed = false, value = {
                digest = string.rep("a", 64), ready = true, base_revision = 1, modules = modules, missing = {},
                migrations = {{id = "acme:migrate", target_db = "acme:db"}}, starts = {"acme:service"}, capabilities = {"acme:capability"},
                request = {action = "install", component = "bee/example", version = "1.0.0", parameters = {}, migration_policy = "none"},
            }})
            local first = view.draw(70, 18, appearance.defaults(), state, 0, "")
            test.is_true(table.concat(first.rows, "\n"):find("acme/package1", 1, true) ~= nil)
            test.is_true(table.concat(first.rows, "\n"):find("acme:capability", 1, true) == nil)
            test.is_nil(model.confirm(state))
            local last = view.draw(70, 18, appearance.defaults(), state, 999, "")
            test.is_true(table.concat(last.rows, "\n"):find("acme:capability", 1, true) ~= nil)
            test.is_true(table.concat(last.rows, "\n"):find("acme:migrate", 1, true) ~= nil)
            test.eq(state.phase, "confirm")
            test.not_nil(model.confirm_intent(state))
        end)
        test.it("keeps rows and hits within every compact canvas", function()
            local state = model.new()
            model.apply_catalog(state, {ok = true, code = nil, message = nil, replayed = false, value = {total = 1, items = {
                {component = "userspace/docker", title = "Docker \27[31m", description = "container \7b", latest_version = "0.5.12"},
            }}})
            for _, width in ipairs({1, 12, 40, 100}) do
                for _, height in ipairs({1, 3, 8, 24}) do
                    local frame = view.draw(width, height, appearance.defaults(), state, 0, "")
                    test.eq(#frame.rows, height)
                    for _, row in ipairs(frame.rows) do
                        test.eq(tty.text.width(row), width)
                        test.is_nil(row:find("\27[31m", 1, true))
                        test.is_nil(row:find("\7", 1, true))
                    end
                    for _, hit in ipairs(frame.hits) do test.is_true(hit.x >= 1 and hit.y >= 1 and hit.x + hit.width - 1 <= width and hit.y + hit.height - 1 <= height) end
                end
            end
        end)
    end)
end
return test.run_cases(define_tests)
