-- MIT. Session routes bind the methods from one selected bee.driver binding.
local test = require("test")
local route = require("route")

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
    local binding = {kind = "contract.binding", data = {contracts = {{contract = "bee.driver:driver", methods = methods()}}}}
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

        test.it("refuses methods outside the selected binding", function()
            local broken = methods()
            broken.prepare = "bee.driver.codex.binding:prepare"
            local binding = {kind = "contract.binding", data = {contracts = {{contract = "bee.driver:driver", methods = broken}}}}
            local resolved, failure = route.decode(BINDING, binding, function(_: string): (unknown?, string?) return {kind = "function.lua"}, nil end)
            test.is_nil(resolved)
            test.eq(failure, "selected driver binding omits its prepare method")
        end)

        test.it("refuses missing contract methods", function()
            local broken = methods()
            broken.normalize = nil
            local binding = {kind = "contract.binding", data = {contracts = {{contract = "bee.driver:driver", methods = broken}}}}
            local resolved, failure = route.decode(BINDING, binding, function(_: string): (unknown?, string?) return {kind = "function.lua"}, nil end)
            test.is_nil(resolved)
            test.eq(failure, "selected driver binding omits its normalize method")
        end)
    end)
end

return test.run_cases(define_tests)
