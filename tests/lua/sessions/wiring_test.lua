-- MIT. The composed journal must resolve every scheduler operation.
local test = require("test")
local journal = require("journal")
local registry = require("registry")
local function define_tests()
    test.describe("Sessions composition", function()
        test.it("registers every callable journal method", function()
            for _, name in ipairs(journal.METHODS) do
                local target, err = journal.target(name)
                test.is_nil(err)
                test.eq(target, "bee.threads.binding:" .. name)
            end
        end)
        test.it("registers the real owner and catalog bindings", function()
            for _, ref in ipairs({"bee.sessions.binding:owner_binding", "bee.sessions.binding:catalog_binding"}) do
                local entry = assert(registry.get(ref))
                test.not_nil(entry.data.contracts[1].methods)
            end
        end)
    end)
end
return test.run_cases(define_tests)
