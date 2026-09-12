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
