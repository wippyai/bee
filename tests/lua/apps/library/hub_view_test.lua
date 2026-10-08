-- MIT. The Hub package screens scale down without allowing package text to escape the canvas.
local test = require("test")
local tty = require("tty")
local appearance = require("appearance")
local model = require("model")
local view = require("view")
local contents = require("contents")

local CHROME = {tabs = {{kind = "tab_installed", label = "Installed", short = "I"},
    {kind = "tab_shared", label = "Shared", short = "S"}, {kind = "tab_history", label = "History", short = "H"}},
    active = "tab_shared", technical = false}

local function draw(width: integer, height: integer, state: model.State, offset: integer, status: string, reading: boolean?,
    editor: {field: string, buffer: string, name: string?}?, content: contents.State?)
    return view.draw(width, height, appearance.defaults(), state, offset, status, reading, editor, content, CHROME)
end

local function define_tests()
    test.describe("Library package screens", function()
        test.it("keeps configuration dialogs inside the canvas and captures clicks", function()
            for _, width in ipairs({28, 40, 100}) do
                local frame = draw(width, 18, model.new(), 0, "", false,
                    {field = "parameter_value", name = "example:enabled", buffer = "false"})
                local rendered = table.concat(frame.rows, "\n")
                test.is_true(rendered:find("Configure package", 1, true) ~= nil)
                test.is_true(rendered:find("false", 1, true) ~= nil)
                for _, hit in ipairs(frame.hits) do
                    test.is_true(hit.kind == "save_editor" or hit.kind == "cancel_editor")
                    test.is_true(hit.x + hit.width - 1 <= width and hit.y + hit.height - 1 <= 18)
                end
            end
        end)
        test.it("keeps an active editor visible and modal after a compact resize", function()
            for _, size in ipairs({{1, 1}, {12, 8}, {27, 13}}) do
                local frame = draw(size[1], size[2], model.new(), 0, "", false,
                    {field = "parameter_value", name = "example:enabled", buffer = "false"})
                test.eq(#frame.rows, size[2])
                for _, row in ipairs(frame.rows) do test.eq(tty.text.width(row), size[1]) end
                local rendered = table.concat(frame.rows, "\n")
                if size[1] >= 12 then
                    test.is_true(rendered:find("EDIT", 1, true) ~= nil)
                    test.is_true(rendered:find("false", 1, true) ~= nil)
                end
                for _, hit in ipairs(frame.hits) do
                    test.is_true(hit.kind == "save_editor" or hit.kind == "cancel_editor")
                    test.is_true(hit.x >= 1 and hit.y >= 1)
                    test.is_true(hit.x + hit.width - 1 <= size[1] and hit.y + hit.height - 1 <= size[2])
                end
            end
        end)
        test.it("keeps package browsing within narrow and short canvases", function()
            local state, content = model.new(), contents.new()
            model.select(state, "bee/example")
            model.apply_details(state, {ok = true, replayed = false, value = {component = "bee/example", title = "Example", description = "Package",
                readme = "Guide", versions = {{version = "1.0.0", yanked = false}}, page = 1, total_versions = 1}})
            contents.start(content, "bee/example", "1.0.0")
            contents.apply(content, "state", {ok = true, replayed = false, value = {component = "bee/example", version = "1.0.0", digest = string.rep("a", 64),
                entries = {{id = "example:main", kind = "function.lua"}}, resources = {}}})
            for _, width in ipairs({1, 12, 40, 100}) do
                for _, height in ipairs({1, 8, 18}) do
                    local frame = draw(width, height, state, 0, "", false, nil, content)
                    test.eq(#frame.rows, height)
                    for _, row in ipairs(frame.rows) do test.eq(tty.text.width(row), width) end
                    for _, hit in ipairs(frame.hits) do test.is_true(hit.x >= 1 and hit.y >= 1 and hit.x + hit.width - 1 <= width and hit.y + hit.height - 1 <= height) end
                end
            end
        end)
        test.it("renders multiline package documentation", function()
            local state = model.new()
            model.select(state, "bee/example")
            model.apply_details(state, {ok = true, code = nil, message = nil, replayed = false, value = {
                component = "bee/example", title = "Example", description = "Package", readme = "# Guide\nUsage instructions\n```lua\n    enabled = false\n```",
                versions = {{version = "1.0.0", yanked = false}}, page = 1, total_versions = 1,
            }})
            local frame = draw(80, 24, state, 0, "", true)
            test.is_true(table.concat(frame.rows, "\n"):find("Usage instructions", 1, true) ~= nil)
            test.is_true(table.concat(frame.rows, "\n"):find("    enabled = false", 1, true) ~= nil)
        end)
        test.it("says why a package README is unavailable and still offers its versions", function()
            local state = model.new()
            model.select(state, "bee/example")
            model.apply_details(state, {ok = true, code = nil, message = nil, replayed = false, value = {
                component = "bee/example", title = "Example", description = "Package", readme = "",
                readme_error = "internal: failed to get readme",
                versions = {{version = "1.0.0", yanked = false}}, page = 1, total_versions = 1,
            }})
            test.eq(state.phase, "details")
            test.eq(state.selected_version, "1.0.0")
            local frame = draw(100, 24, state, 0, "", true)
            test.is_true(table.concat(frame.rows, "\n"):find("README unavailable: internal: failed to get readme", 1, true) ~= nil)
        end)
        test.it("shows why Update Bee retains a selected component", function()
            local state = model.new()
            model.select(state, "bee/bee")
            model.select_version(state, "2.0.0")
            model.apply_installed(state, {ok = true, replayed = false, value = {modules = {}, roots = {}}})
            model.set_action(state, "update")
            model.apply_plan(state, {ok = true, replayed = false, value = {
                digest = string.rep("a", 64), ready = true, base_revision = 1,
                modules = {{component = "bee/bee", version = "2.0.0", change = "update"},
                    {component = "bee/settings", version = "1.0.0", change = "keep", reason = "pinned by acme/app"}},
                missing = {}, migrations = {}, starts = {}, capabilities = {},
                request = {action = "update", component = "bee/bee", version = "2.0.0", parameters = {}, migration_policy = "none"},
            }})
            local drawn = draw(120, 28, state, 0, "")
            local shown = table.concat(drawn.rows, "\n")
            test.is_true(shown:find("bee/settings", 1, true) ~= nil)
            test.is_true(shown:find("pinned by acme/app", 1, true) ~= nil)
            test.is_nil(model.confirm(state))
            local intent = model.confirm_intent(state)
            test.not_nil(intent)
            if intent then test.eq(intent.expected_digest, string.rep("a", 64)) end
        end)
        test.it("scrolls every change without changing confirmation", function()
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
            local first = draw(70, 18, state, 0, "")
            test.is_true(table.concat(first.rows, "\n"):find("acme/package1", 1, true) ~= nil)
            test.is_true(table.concat(first.rows, "\n"):find("acme:capability", 1, true) == nil)
            test.is_nil(model.confirm(state))
            local last = draw(70, 18, state, 999, "")
            test.is_true(table.concat(last.rows, "\n"):find("Applies once", 1, true) ~= nil)
            test.is_true(table.concat(last.rows, "\n"):find("acme:capability", 1, true) ~= nil)
            test.is_true(table.concat(last.rows, "\n"):find("acme:migrate", 1, true) ~= nil)
            test.eq(state.phase, "confirm")
            test.not_nil(model.confirm_intent(state))
        end)
        test.it("shows the plan digest only in the details view", function()
            local state = model.new()
            model.select(state, "bee/example")
            model.select_version(state, "1.0.0")
            model.apply_plan(state, {ok = true, replayed = false, value = {
                digest = string.rep("a", 64), ready = true, base_revision = 1, modules = {}, missing = {},
                migrations = {}, starts = {}, capabilities = {},
                request = {action = "install", component = "bee/example", version = "1.0.0", parameters = {}, migration_policy = "none"},
            }})
            local person = table.concat(draw(100, 24, state, 0, "").rows, "\n")
            test.is_true(person:find("aaaaaaaaaaaa", 1, true) == nil)
            test.is_true(person:find("Changes this package makes", 1, true) ~= nil)
            local technical = table.concat(view.draw(100, 24, appearance.defaults(), state, 0, "", false, nil, nil,
                {tabs = CHROME.tabs, active = CHROME.active, technical = true}).rows, "\n")
            test.is_true(technical:find("Plan aaaaaaaaaaaa", 1, true) ~= nil)
        end)
        test.it("shows a failed operation's whole reason above its state", function()
            local state = model.new()
            local reason = "failed to expand changeset: dependency resolution failed: bee/application@0.1.0-dev: module not found"
            model.apply_result(state, {ok = false, code = "FAILED", message = reason, replayed = false, value = {state = "failed"}})
            local frame = draw(64, 22, state, 0, "")
            local body = ""
            for _, row in ipairs(frame.rows) do
                local plain = row:gsub("\27%[[0-9;]*m", "")
                body = body .. plain:sub(2, 63)
            end
            local status_at = body:find("Not completed: FAILED", 1, true)
            local reason_at = body:find(reason, 1, true)
            local state_at = body:find("State: failed", 1, true)
            test.not_nil(status_at)
            test.not_nil(reason_at)
            test.not_nil(state_at)
            test.is_true(status_at < reason_at and reason_at < state_at)
        end)
        test.it("lists a recorded change's receipt lines and keeps the digest for details", function()
            local state = model.new()
            model.apply_history(state, {ok = true, code = nil, message = nil, replayed = false, value = {
                page = 1, total = 1, page_size = 25, operations = {{digest = string.rep("f", 64), component = "bee/recover", action = "update",
                    state = "recovery_required", message = "migration paused", baseline_revision = 8,
                    request = {action = "update", component = "bee/recover", version = "2.0.0", parameters = {}, migration_policy = "up"},
                    migration_work = {rows = {{id = "bee.recover:01", target_db = "app:db", module = "bee/recover", status = "applied"}}}}},
            }})
            local operation = state.operations[1]
            local person = table.concat(view.receipt_lines(operation, false), "\n")
            test.is_true(person:find("bee/recover", 1, true) ~= nil)
            test.is_true(person:find("migration paused", 1, true) ~= nil)
            test.is_true(person:find("ffffffffffffffff", 1, true) == nil)
            local technical = table.concat(view.receipt_lines(operation, true), "\n")
            test.is_true(technical:find("ffffffffffffffff", 1, true) ~= nil)
            test.is_true(technical:find("bee.recover:01", 1, true) ~= nil)
            test.is_true(technical:find("version 2.0.0", 1, true) ~= nil)
        end)
        test.it("reviews a recovery with the recorded change and no digest until details", function()
            local state = model.new()
            model.apply_history(state, {ok = true, code = nil, message = nil, replayed = false, value = {
                page = 1, total = 1, page_size = 25, operations = {{digest = string.rep("f", 64), component = "bee/recover", action = "update",
                    state = "recovery_required", message = "migration paused", baseline_revision = 8,
                    request = {action = "update", component = "bee/recover", version = "2.0.0", parameters = {}, migration_policy = "up"},
                    migration_work = {rows = {{id = "bee.recover:01", target_db = "app:db", module = "bee/recover", status = "applied"}}}}},
            }})
            local selected, problem = model.select_operation(state, string.rep("f", 64))
            test.not_nil(selected)
            test.is_nil(problem)
            test.is_nil(model.recover(state))
            local review = table.concat(draw(100, 24, state, 0, "").rows, "\n")
            test.is_true(review:find("Finish an interrupted change", 1, true) ~= nil)
            test.is_true(review:find("repeats exactly the recorded change", 1, true) ~= nil)
            test.is_true(review:find("bee.recover:01", 1, true) ~= nil)
            test.is_true(review:find(string.rep("f", 64), 1, true) == nil)
        end)
    end)
end
return test.run_cases(define_tests)
