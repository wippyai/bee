local test = require("test")
local controls = require("controls")
local bounds = require("bounds")
local function define_tests()
    test.describe("Typed driver option controls", function()
        test.it("edits structured entries and preserves explicit false", function()
            local schema = {type = "object", additionalProperties = {type = "object", properties = {
                endpoint = {type = "string"}, enabled = {type = "boolean"}, limit = {type = "integer", minimum = 1}}}}
            local values: {[string]: unknown} = {}
            local rows = controls.rows("providers", schema, nil)
            test.is_nil(controls.change(values, rows[1]))
            rows = controls.rows("providers", schema, values.providers)
            test.is_nil(controls.change(values, rows[1], "local"))
            for _, row in ipairs(controls.rows("providers", schema, values.providers)) do
                if row.label == "providers / local / enabled" then test.is_nil(controls.change(values, row)) end
                if row.label == "providers / local / endpoint" then test.is_nil(controls.change(values, row, "http://localhost:8080")) end
                if row.label == "providers / local / limit" then
                    test.not_nil(controls.change(values, row, "infinite"))
                    test.is_nil(controls.change(values, row, "3"))
                end
            end
            local provider = assert(bounds.object(assert(bounds.object(values.providers))["local"]))
            test.eq(provider.enabled, false)
            test.eq(provider.limit, 3)
            test.eq(provider.endpoint, "http://localhost:8080")
        end)
    end)
end
return test.run_cases(define_tests)
