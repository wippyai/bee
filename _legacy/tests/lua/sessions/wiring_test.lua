-- MIT. The composed journal must resolve every scheduler operation.
local test = require("test")
local journal = require("journal")
local registry = require("registry")
local security = require("security")
local function define_tests()
    test.describe("Sessions composition", function()
        test.it("admits exact session operations and rejects namespaced impostors", function()
            local actor = security.new_actor("fixture:caller", {})
            local scope = security.new_scope({assert(security.policy("bee.security.gateway:gateway_tool_session_policy"))})
            test.eq(scope:evaluate(actor, "funcs.call", "bee.sessions.binding:run"), "allow")
            test.eq(scope:evaluate(actor, "contract.open", "bee.sessions:contract"), "allow")
            test.is_false(scope:evaluate(actor, "funcs.call", "bee.sessions.binding:unadmitted") == "allow")
            test.is_false(scope:evaluate(actor, "contract.open", "bee.sessions:unadmitted") == "allow")
            local probe = security.new_scope({assert(security.policy("bee.harness.security:launch_locate_probe_policy"))})
            test.eq(probe:evaluate(actor, "env.get", "bee.driver.claude.env:executable"), "allow")
            test.is_false(probe:evaluate(actor, "env.get", "bee.driver.claude.env:executable.extra") == "allow")
        end)
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
