-- SPDX-License-Identifier: MIT
local test = require("test")
local view = require("view")
local appearance = require("appearance")
local function define_tests()
    test.describe("External client list", function()
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
