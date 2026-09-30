local test = require("test")
local catalog = require("catalog")

local function define_tests()
    test.describe("Sessions catalog request", function()
        test.it("accepts the MCP catalog fields", function()
            local request, failure = catalog.parse_request({kind = "definition", include_unavailable = true})
            test.is_nil(failure)
            test.eq(request and request.kind, "definition")
            test.eq(request and request.include_unavailable, true)
            test.is_nil(request and request.cursor)
        end)

        test.it("defaults the kind and closes the request", function()
            local request = assert(catalog.parse_request({}))
            test.eq(request.kind, "definition")
            test.eq(request.include_unavailable, false)
            test.is_nil(catalog.parse_request({after = "cursor"}))
        end)

        test.it("rejects malformed catalog fields", function()
            test.is_nil(catalog.parse_request({kind = "thread"}))
            test.is_nil(catalog.parse_request({include_unavailable = "true"}))
            test.is_nil(catalog.parse_request({cursor = string.rep("x", 2049)}))
        end)
    end)
end

return test.run_cases(define_tests)
