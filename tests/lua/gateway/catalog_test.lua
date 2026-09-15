-- MIT. Component tool declarations never grant authority by themselves.
local test = require("test")
local catalog = require("catalog")
local function sample()
    return {tools = {{name = "measure", operation = "research:measure", description = "Run the admitted benchmark",
        policies = {"research:measure_policy"}, schema = {type = "object"}, annotations = {readOnlyHint = false}}},
        traits = {{id = "research:benchmark", title = "Benchmark", prompt = "Measure first", tools = {"measure"}},
            {id = "research:compare", title = "Compare", prompt = "Compare samples", tools = {"measure"}}}}
end
local function define_tests()
    test.describe("Configurable MCP catalog", function()
        test.it("copies two traits sharing a tool without sharing configuration tables", function()
            local raw = sample()
            local decoded = catalog.decode(raw)
            if not decoded then error("valid catalog refused") end
            test.eq(#decoded.traits, 2)
            raw.tools[1].policies[1] = "foreign:policy"
            test.eq(decoded.tools[1].policies[1], "research:measure_policy")
        end)
        test.it("rejects aliases, unknown references and permission-shaped extra fields", function()
            local duplicate = sample()
            duplicate.tools[2] = duplicate.tools[1]
            test.is_nil(catalog.decode(duplicate))
            local missing = sample()
            missing.traits[1].tools = {"unadmitted"}
            test.is_nil(catalog.decode(missing))
            test.is_nil(catalog.decode({tools = {}, traits = {}, authority = "root"}))
            local invalid = sample()
            invalid.tools[1].policies = {}
            test.is_nil(catalog.decode(invalid))
        end)
        test.it("rejects sparse lists and oversized configuration", function()
            test.is_nil(catalog.decode({tools = {[2] = sample().tools[1]}, traits = {}}))
            local large = sample()
            large.traits[1].prompt = string.rep("x", 16385)
            test.is_nil(catalog.decode(large))
        end)
        test.it("unions activated traits within the independent tool ceiling", function()
            local decoded = catalog.decode(sample())
            if not decoded then error("catalog") end
            local tools = catalog.select(decoded, {"measure"}, {}, {"research:benchmark", "research:compare"},
                {"research:benchmark", "research:compare"})
            if not tools then error("select") end
            test.eq(#tools, 1)
            test.is_nil(catalog.select(decoded, {}, {}, {"research:benchmark"}, {"research:benchmark"}))
            test.is_nil(catalog.select(decoded, {"measure"}, {}, {}, {"research:benchmark"}))
            local inactive = catalog.select(decoded, {"measure"}, {}, {"research:benchmark"}, {})
            if not inactive then error("inactive") end
            test.eq(#inactive, 0)
        end)
    end)
end
return require("test").run_cases(define_tests)
