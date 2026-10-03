-- SPDX-License-Identifier: MIT
local test = require("test")
local registry = require("registry")
local security = require("security")
local funcs = require("funcs")
local materializer = require("materializer")
local activation = require("activation")
local bounds = require("bounds")
local resolver = require("resolver")
local OWNER = "bee.gov:driver-link-proof"
local function values(): {unknown}
    local entry = assert(registry.get(activation.TARGET))
    return assert(bounds.dense_list(entry.data.bindings, 128, "driver bindings"))
end
local function define_tests()
    test.describe("Approved driver host selection", function()
        test.it("keeps raw requirements declarative and derives owned approved bindings", function()
            local baseline = values()
            local builtin = assert(registry.get("bee.driver.claude.binding:binding"))
            local entries: {{[string]: unknown}} = {
                {id = "bee.driver.link.binding:binding", kind = "contract.binding", meta = {type = "harness.driver"}, data = builtin.data},
                {id = "bee.driver.link.binding:activation", kind = "ns.requirement", meta = {value_kind = "contract.binding"},
                    data = {default = "bee.driver.link.binding:binding", targets = {{entry = activation.TARGET, path = ".bindings +="}}}},
            }
            assert(materializer.reconcile(OWNER, entries))
            local selected, problem = activation.bindings(entries)
            test.is_nil(problem)
            test.eq(#assert(selected), 1)
            test.eq(assert(selected)[1], "bee.driver.link.binding:binding")
            local active, active_error = resolver.active(assert(resolver.pin()))
            test.is_nil(active_error)
            test.is_nil(assert(active)["bee.driver.link.binding:binding"])
            local unlinked = values()
            test.eq(#unlinked, #baseline)
            for index, value in ipairs(baseline) do test.eq(unlinked[index], value) end
            assert(materializer.reconcile(OWNER, {}))
            test.eq(#assert(activation.bindings({})), 0)
        end)
        test.it("lets each owning launch scope read admitted drivers", function()
            local probe_policy = assert(security.policy("bee.gov:admission_probe_call"))
            for _, id in ipairs({"bee.sessions.security:owner_admission_policy", "bee.executor.external.security:driver_placement_calls",
                "bee.placement.native.security:placement_store_policy", "bee.harness.security:launch_locate_probe_policy",
                "bee.harness.security:harness_setup_policy", "bee.harness.security:profile_store_policy"}) do
                local policy = assert(security.policy(id))
                local scope = security.new_scope({policy, probe_policy})
                local caller = funcs.new():with_scope(scope)
                local allowed, problem = caller:call("bee.gov:admission_scope_probe")
                test.is_nil(problem)
                if allowed ~= true then error("driver admission reader is denied by " .. id) end
                local bindings, read_error = caller:call("bee.gov.binding:driver_bindings")
                test.is_nil(read_error)
                test.is_true(bounds.ids(bindings, true) ~= nil)
            end
        end)
        test.it("refuses a host-list replacement and a foreign binding before projection", function()
            for _, path in ipairs({".bindings", ".bindings +="}) do
                local entries = {{id = "bee.driver.link.binding:activation", kind = "ns.requirement",
                    data = {default = "bee.driver.claude.binding:binding", targets = {{entry = activation.TARGET, path = path}}}}}
                local result = activation.bindings(entries)
                test.is_nil(result)
            end
        end)
    end)
end
return test.run_cases(define_tests)
