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
        test.it("renders paged operation history, selected migration rows, and recovery review hit", function()
            local state = model.new()
            model.apply_history(state, {ok = true, code = nil, message = nil, replayed = false, value = {
                page = 1, total = 26, page_size = 25, operations = {{digest = string.rep("f", 64), component = "bee/recover", action = "update",
                    state = "recovery_required", message = "migration paused", baseline_revision = 8,
                    request = {action = "update", component = "bee/recover", version = "2.0.0", parameters = {}, migration_policy = "up"},
                    migration_work = {rows = {{id = "bee.recover:01", target_db = "app:db", module = "bee/recover", status = "applied"}}}}},
            }})
            local selected, problem = model.select_operation(state, string.rep("f", 64))
            test.not_nil(selected)
            test.is_nil(problem)
            local frame = view.draw(100, 24, appearance.defaults(), state, 0, "")
            local rendered = table.concat(frame.rows, "\n")
            test.is_true(rendered:find("Actor%-owned operation history") ~= nil)
            test.is_true(rendered:find("bee.recover:01", 1, true) ~= nil)
            local has_recover = false
            for _, hit in ipairs(frame.hits) do if hit.kind == "recover" then has_recover = true end end
            test.is_true(has_recover)
            test.is_nil(model.recover(state))
            local review = view.draw(100, 24, appearance.defaults(), state, 0, "")
            local review_text = table.concat(review.rows, "\n")
            test.is_true(review_text:find("Review recovery", 1, true) ~= nil)
            test.is_true(review_text:find("exact stored request", 1, true) ~= nil)
        end)
        test.it("scrolls through every receipt on a full history page", function()
            local state = model.new()
            local operations: {{[string]: unknown}} = {}
            for index = 1, 25 do
                operations[index] = {digest = string.format("%064x", index), component = "bee/package" .. tostring(index),
                    action = "install", state = "complete", message = "done", baseline_revision = index}
            end
            model.apply_history(state, {ok = true, code = nil, message = nil, replayed = false, value = {page = 1, total = 25, page_size = 25, operations = operations}})
            local first = view.draw(100, 12, appearance.defaults(), state, 0, "")
            local last = view.draw(100, 12, appearance.defaults(), state, 24, "")
            test.is_true(table.concat(first.rows, "\n"):find("bee/package1 ", 1, true) == nil)
            test.is_true(table.concat(last.rows, "\n"):find("bee/package25", 1, true) == nil)
            test.is_true(table.concat(last.rows, "\n"):find("bee/package1", 1, true) ~= nil)
        end)
    end)
end
return test.run_cases(define_tests)
