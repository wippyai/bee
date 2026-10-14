-- SPDX-License-Identifier: MIT
local test = require("test")
local view = require("view")
local manuals = require("manuals")
local tty = require("tty")
local appearance = require("appearance")
local function define_tests()
    test.describe("External client list", function()
        test.it("keeps the connection page and its actions within the canvas", function()
            local guide = assert(manuals.connect())
            for _, width in ipairs({1, 20, 40, 80, 120}) do
                for _, height in ipairs({1, 6, 12, 24, 40}) do
                    local shown = view.draw(width, height, appearance.defaults(), {}, 0, "", nil, guide, 0)
                    test.eq(#shown.rows, height)
                    for _, row in ipairs(shown.rows) do test.eq(tty.text.width(row), width) end
                    for _, hit in ipairs(shown.hits) do
                        test.is_true(hit.x >= 1 and hit.y >= 1)
                        test.is_true(hit.x + hit.width - 1 <= width)
                        test.is_true(hit.y + hit.height - 1 <= height)
                    end
                end
            end
            local rows: {view.Client} = {{client_id = "client-1", name = "Paired client", status = "connected", thread_id = "thread-1", expires_at = "2026-10-13T00:00:00Z"}}
            local clients = view.draw(120, 40, appearance.defaults(), rows, 1, "", nil)
            local reachable = false
            for _, hit in ipairs(clients.hits) do if hit.kind == "connect" then reachable = true end end
            test.is_true(reachable)
            test.contains(table.concat(clients.rows), "H How to connect")
            local page = view.draw(40, 12, appearance.defaults(), rows, 1, "", nil, guide, 8)
            test.is_true(page.offset > 0)
        end)
        test.it("shows the corpus connection steps when no client is paired", function()
            local guide = assert(manuals.connect())
            local shown = view.draw(120, 40, appearance.defaults(), {}, 0, "", nil, guide, 0)
            local content = tty.text.plain(table.concat(shown.rows, " ")):gsub("%s+", " ")
            for _, phrase in ipairs({"HOW TO CONNECT", "bee mcp connect --name <name>", "Needs you", "claude mcp add --transport http", ".mcp.json", "config.toml", "bearer_token_env_var", "24 hours", "Revoke"}) do
                test.contains(content, phrase)
            end
        end)
        test.it("shows named clients and enables revoke only for a live binding", function()
            local rows = {{client_id = "client-1", name = "Terminal Claude", status = "connected", thread_id = "client-thread", expires_at = "2026-10-08T00:00:00Z"}}
            local shown = view.draw(100, 20, appearance.defaults(), rows, 1, "", nil)
            local revoke = false
            for _, hit in ipairs(shown.hits) do if hit.kind == "revoke" then revoke = true end end
            test.is_true(revoke)
            test.is_true(table.concat(shown.rows):find("Terminal Claude", 1, true) ~= nil)
            rows[1].status = "revoked"
            local ended = view.draw(100, 20, appearance.defaults(), rows, 1, "", nil)
            for _, hit in ipairs(ended.hits) do test.is_false(hit.kind == "revoke") end
        end)
        test.it("renders thread call records without a secret-bearing configuration", function()
            local shown = view.draw(100, 20, appearance.defaults(), {}, 0, "", "MCP tool: docs")
            test.is_true(table.concat(shown.rows):find("MCP tool: docs", 1, true) ~= nil)
        end)
    end)
end
return test.run_cases(define_tests)
