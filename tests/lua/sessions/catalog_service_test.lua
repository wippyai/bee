-- MIT. The Sessions catalog delegates route availability to host driver locate.
local test = require("test")
local catalog = require("catalog")

type Object = {[string]: unknown}
type Candidate = {ref: string, kind: string, status: string, reasons: {string}}
type Page = {items: {Candidate}, next: string?, complete: boolean, unavailable_count: integer,
    diagnostics: {Object}}

local function listed(include_unavailable: boolean?): Page
    local page, failure = catalog.list({kind = "definition", include_unavailable = include_unavailable}, "catalog-test-workspace")
    if not page then error(failure and failure.message or "Sessions catalog returned no page") end
    return page :: Page
end

local function define_tests()
    test.describe("Sessions catalog route readiness", function()
        test.it("hides unavailable definitions by default and explains them when requested", function()
            local ready = listed(nil)
            local explicitly_ready = listed(false)
            test.eq(#ready.items, #explicitly_ready.items)
            for _, candidate in ipairs(ready.items) do test.eq(candidate.status, "ready") end

            local all = listed(true)
            local claude: Candidate? = nil
            local unavailable = 0
            for _, candidate in ipairs(all.items) do
                if candidate.ref == "bee.driver.claude:default_window" then claude = candidate end
                if candidate.status ~= "ready" then
                    unavailable = unavailable + 1
                    test.is_true(#candidate.reasons > 0)
                end
            end
            test.not_nil(claude)
            test.eq(all.unavailable_count, unavailable)
            test.is_true(#all.items >= #ready.items)
        end)
    end)
end

return test.run_cases(define_tests)
