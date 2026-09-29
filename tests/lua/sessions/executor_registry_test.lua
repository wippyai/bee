-- MIT. Host selection is the only source of executable bindings, and exact
-- executor identities have one binding in a registry snapshot.
local test = require("test")
local registry = require("registry")

local CONTRACT = "bee.sessions:executor"
local METHODS = {
    "describe", "locate", "negotiate", "prepare", "activate",
    "pull_turn", "accept_turn", "observe", "reconcile", "cancel",
}

local function binding(executor_id: string): {[string]: unknown}
    local methods: {[string]: string} = {}
    for _, name in ipairs(METHODS) do methods[name] = "bee.fake.executor:" .. name end
    return {
        kind = "contract.binding",
        meta = {type = "bee.sessions.executor_binding", executor_id = executor_id, version = "1"},
        data = {contracts = {{contract = CONTRACT, methods = methods}}},
    }
end

local function define_tests()
    test.describe("Executor registry", function()
        test.it("resolves only host-selected bindings", function()
            local chosen = binding("external")
            local spare = binding("native")
            local built, err = registry.build({["bee.fake:chosen"] = chosen, ["bee.fake:spare"] = spare}, {"bee.fake:chosen"})
            test.is_nil(err)
            test.not_nil(built)
            local selected, selected_error = registry.get(built :: registry.Registry, "external")
            test.is_nil(selected_error)
            test.eq((selected :: registry.Binding).ref, "bee.fake:chosen")
            local absent, absent_error = registry.get(built :: registry.Registry, "native")
            test.is_nil(absent)
            test.eq(absent_error, "NOT_FOUND")
        end)

        test.it("rejects two host bindings for the same exact executor identity", function()
            local entries = {
                ["bee.fake:first"] = binding("external"),
                ["bee.fake:second"] = binding("external"),
            }
            local built, err = registry.build(entries, {"bee.fake:first", "bee.fake:second"})
            test.is_nil(built)
            test.eq(err, "CONFLICT: duplicate executor binding for external")
        end)

        test.it("rejects a selected binding with an incomplete executor contract", function()
            local broken = binding("external")
            local data = broken.data :: {[string]: unknown}
            local contracts = data.contracts :: {unknown}
            local contract = contracts[1] :: {[string]: unknown}
            (contract.methods :: {[string]: string}).activate = "invalid target"
            local built, err = registry.build({["bee.fake:broken"] = broken}, {"bee.fake:broken"})
            test.is_nil(built)
            test.eq(err, "INVALID: executor binding bee.fake:broken does not bind activate")
        end)
    end)
end

return test.run_cases(define_tests)
