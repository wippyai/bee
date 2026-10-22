-- SPDX-License-Identifier: MIT
local test = require("test")
local registry = require("registry")
local bounds = require("bounds")
local locate = require("locate")
local BINDING = "bee.drivers.claude.binding:binding"
local OTHER = "bee.drivers.codex.descriptor:cli"
local function update(entries: {{id: string | {name: string, ns: string}, kind: string, data?: any, meta?: {[string]: any}}})
    local changes = assert(registry.snapshot()):changes()
    for _, entry in ipairs(entries) do changes:update(entry) end
    assert(changes:apply())
end
return test.run_cases(function()
    test.describe("Driver executable variable", function()
        test.it("sits beside the binding namespace for library and overlay drivers", function()
            test.eq(locate.executable_ref("bee.drivers.claude.binding:binding"), "bee.drivers.claude.env:executable")
            test.eq(locate.executable_ref("bee.driver.gemini.binding:binding"), "bee.driver.gemini.env:executable")
            test.is_nil(locate.executable_ref("bee.driver.gemini:binding"))
        end)
    end)
    test.describe("Bound descriptor discovery", function()
        test.it("reads the binding's descriptor without decoding unrelated providers", function()
            local original_binding = assert(registry.get(BINDING))
            local original_other = assert(registry.get(OTHER))
            local binding = assert(registry.get(BINDING))
            local contracts = assert(bounds.object(binding.data)).contracts
            local kept = {}
            for _, contract in ipairs(contracts) do
                if contract.contract ~= "bee.drivers:locate_facet" then kept[#kept + 1] = contract end
            end
            binding.data.contracts = kept
            local other = assert(registry.get(OTHER))
            other.data = {}
            update({binding, other})
            local ok, err = pcall(function()
                local result = assert(locate.locate(assert(registry.snapshot()), BINDING, "window", locate.new_cache()))
                test.eq(result.status, "incompatible", tostring(result.reason))
                test.eq(result.reason, "the active driver does not bind bee.drivers:locate_facet")
                update({original_other})
                binding.meta.descriptor_ref = OTHER
                update({binding})
                local mismatch = assert(locate.locate(assert(registry.snapshot()), BINDING, "window", locate.new_cache()))
                test.eq(mismatch.status, "unknown")
                test.eq(mismatch.reason, "driver binding descriptor provider does not match driver_id")
            end)
            update({original_binding, original_other})
            if not ok then error(tostring(err)) end
        end)
    end)
end)
