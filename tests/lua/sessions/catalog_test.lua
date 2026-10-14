local test = require("test")
local catalog = require("catalog")
local DEFINITION = "bee.driver.codex.profiles:default_window"

local function refused(value: unknown)
    local page, failure = catalog.list(value, "catalog-request-workspace")
    test.is_nil(page)
    test.eq(failure and failure.code, "INVALID")
end

local function define_tests()
    test.describe("Sessions catalog request", function()
        test.it("accepts the MCP catalog fields", function()
            local page, failure = catalog.list({kind = "definition", include_unavailable = true, definition_ref = DEFINITION}, "catalog-request-workspace")
            test.is_nil(failure)
            local items = assert(page).items
            test.eq(#items, 1)
            test.eq(items[1].kind, "definition")
            test.eq(items[1].ref, DEFINITION)
        end)

        test.it("defaults to available entries and closes the request", function()
            local page = assert((catalog.list({definition_ref = DEFINITION}, "catalog-request-workspace")))
            for _, item in ipairs(page.items) do
                test.eq(item.status, "ready")
                test.eq(item.ref, DEFINITION)
            end
            refused({after = "cursor"})
        end)

        test.it("rejects malformed catalog fields", function()
            refused({kind = "thread"})
            refused({include_unavailable = "true"})
            refused({cursor = string.rep("x", 2049)})
        end)
    end)
end

return test.run_cases(define_tests)
