-- MIT. Session routes bind the methods from one selected bee.driver binding.
local test = require("test")
local route = require("route")
local registry = require("registry")
local bounds = require("bounds")
local materializer = require("materializer")

local BINDING = "bee.driver.claude.binding:binding"
local PREFIX = "bee.driver.claude.binding:"

local function methods(): {[string]: string}
    return {prepare = PREFIX .. "prepare", dispatch = PREFIX .. "dispatch",
        normalize = PREFIX .. "normalize", configure = PREFIX .. "configure"}
end

local function decode(overrides: {[string]: unknown}?): (route.Methods?, string?)
    local entries: {[string]: unknown} = {}
    for _, name in ipairs(route.METHODS) do entries[PREFIX .. name] = {kind = "function.lua"} end
    if overrides then for name, value in pairs(overrides) do entries[name] = value end end
    local binding = {kind = "contract.binding", meta = {type = "harness.driver", driver_id = "fixture"}, data = {contracts = {{contract = "bee.driver:driver", methods = methods()}}}}
    return route.decode(BINDING, binding, function(ref: string): (unknown?, string?) return entries[ref], nil end)
end

local function define_tests()
    test.describe("Session driver route", function()
        test.it("resolves the selected driver's external turn methods", function()
            local resolved, failure = decode()
            test.is_nil(failure)
            test.eq(resolved and resolved.prepare, PREFIX .. "prepare")
            test.eq(resolved and resolved.dispatch, PREFIX .. "dispatch")
            test.eq(resolved and resolved.normalize, PREFIX .. "normalize")
            test.eq(resolved and resolved.configure, PREFIX .. "configure")
        end)

        test.it("preserves every shipped driver's declared targets", function()
            for _, provider in ipairs({"claude", "codex", "agy", "grok", "muse", "opencode", "wippy"}) do
                local prefix = "bee.driver." .. provider .. ".binding:"
                local resolved, failure = route.resolve(prefix .. "binding")
                test.is_nil(failure)
                test.not_nil(resolved)
                local selected = assert(resolved)
                test.eq(selected.prepare, prefix .. "prepare")
                test.eq(selected.dispatch, prefix .. "dispatch")
                test.eq(selected.normalize, prefix .. "normalize")
                test.eq(selected.configure, prefix .. "configure")
            end
        end)

        test.it("refuses dangling and noncallable method targets", function()
            for _, entry in ipairs({{kind = "library.lua"}, {kind = "registry.entry"}}) do
                local resolved, failure = decode({[PREFIX .. "normalize"] = entry})
                test.is_nil(resolved)
                test.eq(failure, "selected driver target normalize is unavailable")
            end
            local binding = {kind = "contract.binding", meta = {type = "harness.driver", driver_id = "fixture"}, data = {contracts = {{contract = "bee.driver:driver", methods = methods()}}}}
            local resolved, failure = route.decode(BINDING, binding, function(_: string): (unknown?, string?)
                return nil, "missing"
            end)
            test.is_nil(resolved)
            test.eq(failure, "selected driver target prepare is unavailable")
        end)

        test.it("resolves declared methods in another package namespace", function()
            local broken = methods()
            broken.prepare = "vendor.operations:start"
            local binding = {kind = "contract.binding", meta = {type = "harness.driver", driver_id = "fixture"}, data = {contracts = {{contract = "bee.driver:driver", methods = broken}}}}
            local resolved, failure = route.decode("vendor.agents:custom", binding, function(_: string): (unknown?, string?) return {kind = "function.lua"}, nil end)
            test.is_nil(failure)
            test.eq(resolved and resolved.prepare, "vendor.operations:start")
        end)

        test.it("refuses metadata discovery without exact host activation", function()
            local resolved, failure = route.resolve("bee.harness.catalog:fake_binding")
            test.is_nil(resolved)
            test.eq(failure, "binding bee.harness.catalog:fake_binding is not activated")
        end)

        test.it("resolves a third-party binding only while the host selects its exact identity", function()
            local ref = "bee.harness.catalog:fake_binding"
            local activation = assert(registry.get("bee.harness.launch:harness_activation"))
            local original = activation.data
            local data = assert(bounds.object(original))
            local bindings = assert(bounds.ids(data.bindings, true))
            bindings[#bindings + 1] = ref
            activation.data = {schema_revision = data.schema_revision, bindings = bindings}
            local changes = registry.snapshot():changes()
            assert(changes:update(activation)); assert(changes:apply())
            local ok, failure = pcall(function()
                local resolved = assert(route.resolve(ref))
                test.eq(resolved.prepare, PREFIX .. "prepare")
                test.eq(resolved.normalize, PREFIX .. "normalize")
            end)
            activation.data = original
            local cleanup = registry.snapshot():changes()
            assert(cleanup:update(activation)); assert(cleanup:apply())
            assert(ok, tostring(failure))
            test.is_nil(route.resolve(ref))
        end)

        test.it("uses an admitted overlay normalizer for new routes and preserves pinned routes", function()
            local before = assert(route.resolve(BINDING))
            local pinned = assert(registry.snapshot())
            local original = assert(pinned:get(BINDING))
            local data = assert(bounds.object(original.data))
            local contracts = assert(bounds.dense_list(data.contracts, 16, "contracts"))
            local contract = assert(bounds.object(contracts[1]))
            local mapped = assert(bounds.object(contract.methods))
            local changed: {[string]: unknown} = {}
            for name, target in pairs(mapped) do changed[name] = target end
            changed.normalize = "bee.driver.codex.binding:normalize"
            local installed, install_error = materializer.reconcile("bee.tests.sessions:driver-overlay",
                {{id = BINDING, kind = original.kind, meta = original.meta,
                    data = {contracts = {{contract = route.CONTRACT, methods = changed}}}}})
            assert(installed, tostring(install_error))
            local ok, failure = pcall(function()
                local after = assert(route.resolve(BINDING))
                test.eq(after.normalize, "bee.driver.codex.binding:normalize")
                test.eq(before.normalize, PREFIX .. "normalize")
                local retained = assert(route.decode(BINDING, original, function(target: string): (unknown?, string?) return pinned:get(target) end))
                test.eq(retained.normalize, PREFIX .. "normalize")
            end)
            local cleanup = assert(registry.overlay("bee.tests.sessions:driver-overlay")):changes()
            assert(cleanup:delete(BINDING)); assert(cleanup:apply())
            assert(ok, tostring(failure))
        end)

        test.it("uses an authorized binding target update for new routes", function()
            local pinned = assert(registry.snapshot())
            local original = assert(pinned:get(BINDING))
            local declared = methods()
            declared.normalize = "bee.driver.codex.binding:normalize"
            local changed = assert(registry.get(BINDING))
            local contracts: {unknown} = {}
            for _, raw in ipairs(assert(bounds.dense_list(assert(bounds.object(original.data)).contracts, 16, "contracts"))) do
                local contract = assert(bounds.object(raw))
                contracts[#contracts + 1] = contract.contract == route.CONTRACT
                    and {contract = route.CONTRACT, methods = declared} or contract
            end
            changed.data = {contracts = contracts}
            local changes = registry.snapshot():changes()
            assert(changes:update(changed)); assert(changes:apply())
            local ok, failure = pcall(function()
                test.eq(assert(route.resolve(BINDING)).normalize, declared.normalize)
                test.eq(assert(route.decode(BINDING, original, function(target: string): (unknown?, string?) return pinned:get(target) end)).normalize,
                    PREFIX .. "normalize")
            end)
            local cleanup = registry.snapshot():changes()
            assert(cleanup:update(original)); assert(cleanup:apply())
            assert(ok, tostring(failure))
        end)

        test.it("refuses missing contract methods", function()
            local broken = methods()
            broken.normalize = nil
            local binding = {kind = "contract.binding", meta = {type = "harness.driver", driver_id = "fixture"}, data = {contracts = {{contract = "bee.driver:driver", methods = broken}}}}
            local resolved, failure = route.decode(BINDING, binding, function(_: string): (unknown?, string?) return {kind = "function.lua"}, nil end)
            test.is_nil(resolved)
            test.eq(failure, "selected driver binding omits its normalize method")
        end)
    end)
end

return test.run_cases(define_tests)
