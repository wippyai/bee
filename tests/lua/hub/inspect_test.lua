-- MIT. Requests cannot turn a package reader into a credential destination.
local test = require("test")
local inspect = require("inspect")
local function define_tests()
    test.describe("Hub inspection request", function()
        test.it("requires an exact version and refuses alternate authority inputs", function()
            for _, version in ipairs({"latest", "*", "^1.2.3", ">=1.2.3", "1.2", "1.2.3 || 2.0.0"}) do
                local request = inspect.decode({component = "acme/tool", version = version})
                test.is_nil(request)
            end
            for _, field in ipairs({"registry", "token", "actor", "scope", "path", "approval"}) do
                local raw: {[string]: unknown} = {component = "acme/tool", version = "1.2.3"}
                raw[field] = "caller-selected"
                test.is_nil(inspect.decode(raw))
            end
        end)
        test.it("retains the exact selected version and qualified bindings", function()
            local request, problem = inspect.decode({component = "acme/tool", version = "v1.2.3-beta.1+build.4",
                parameters = {{name = "acme.tool:database", value = "app:database"}}})
            test.is_nil(problem)
            test.not_nil(request)
            if not request then return end
            test.eq(request.version, "v1.2.3-beta.1+build.4")
            test.eq(request.parameters[1].value, "app:database")
        end)
        test.it("refuses malformed parameter values before opening a package", function()
            local result, problem = inspect.read({component = "acme/tool", version = "1.2.3", parameters = false})
            test.is_nil(result)
            test.not_nil(problem)
            test.is_nil(inspect.decode({component = "acme/tool", version = "1.2.3",
                parameters = {{name = "acme.tool:db", value = "app:a"}, {name = "acme.tool:db", value = "app:b"}}}))
            test.is_nil(inspect.decode({component = "https://example.com/tool", version = "1.2.3"}))
        end)
    end)
end
return test.run_cases(define_tests)
