-- SPDX-License-Identifier: MIT
local test = require("test")
local registry = require("registry")
local bounds = require("bounds")
local locate = require("locate")
local BINDING = "bee.drivers.claude.binding:binding"
local OTHER = "bee.drivers.codex.descriptor:cli"
local POLICY = "bee.tests.harness:locate_policy"
local function update(entries: {{id: string | {name: string, ns: string}, kind: string, data?: any, meta?: {[string]: any}}})
    local changes = assert(registry.snapshot()):changes()
    for _, entry in ipairs(entries) do changes:update(entry) end
    assert(changes:apply())
end
return test.run_cases(function()
    test.describe("Driver executable", function()
        test.it("probes the executable the launch policy binds, not the PATH name", function()
            local function probe(executable: string): (string, string)
                local changes = assert(registry.snapshot()):changes()
                local entry = {id = POLICY, kind = "registry.entry", meta = {type = "bee.launch_policy"},
                    data = {executables = {claude = executable}}}
                if registry.get(POLICY) then changes:update(entry) else changes:create(entry) end
                assert(changes:apply())
                local result = assert(locate.locate(assert(registry.snapshot()), BINDING, "window", locate.new_cache(), nil, POLICY))
                return result.status, tostring(result.reason)
            end
            local ok, err = pcall(function()
                local on_path = assert(locate.locate(assert(registry.snapshot()), BINDING, "window", locate.new_cache()))
                test.eq(on_path.status, "ready", tostring(on_path.reason))
                local absent, absent_reason = probe("/nonexistent/bee-locate-claude")
                test.is_true(absent ~= "ready", "the policy's binding replaces the PATH executable: " .. absent_reason)
            end)
            local changes = assert(registry.snapshot()):changes()
            changes:delete(POLICY)
            assert(changes:apply())
            if not ok then error(tostring(err)) end
        end)
    end)
    test.describe("Account-free CLI", function()
        test.it("is ready without login evidence", function()
            local descriptor_ref = "bee.drivers.claude.descriptor:cli"
            local original = assert(registry.get(descriptor_ref))
            local changed = assert(registry.get(descriptor_ref))
            local data = assert(bounds.object(changed.data))
            data.login_evidence = nil
            local templates = assert(bounds.object(data.argv_templates))
            local window = assert(bounds.object(templates.window))
            window.login = nil
            update({changed})
            local ok, err = pcall(function()
                local result = assert(locate.locate(assert(registry.snapshot()), BINDING, "window", locate.new_cache()))
                test.eq(result.status, "ready", tostring(result.reason))
                test.eq(result.login.evidence, "not_required")
            end)
            update({original})
            if not ok then error(tostring(err)) end
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
