-- MIT. Protected host policy composition keeps ordinary apps restricted.
local test = require("test")
local registry = require("registry")
local security = require("security")
local funcs = require("funcs")
local BASE = {"bee:base_app_policy", "bee:app_boundary_policy", "bee:core_spawn_boundary", "bee:workspace_storage_boundary"}
local function probe(names: {string}): {[string]: boolean}
    local policies: {security.Policy} = {}
    for _, name in ipairs(BASE) do
        local policy = security.policy(name)
        if not policy then error("missing " .. name) end
        policies[#policies + 1] = policy
    end
    for _, name in ipairs(names) do
        local policy = security.policy(name)
        if not policy then error("missing " .. name) end
        policies[#policies + 1] = policy
    end
    local raw, err = funcs.new():with_scope(security.new_scope(policies)):call("bee.harness.catalog:execution_scope_probe")
    if err then error(tostring(err)) end
    if type(raw) ~= "table" then error("access probe returned no object") end
    local result: {[string]: boolean} = {}
    for key, value in pairs(raw :: {[string]: unknown}) do
        if type(value) ~= "boolean" then error("access result is not boolean") end
        result[key] = value
    end
    return result
end
local function define_tests()
    test.describe("Execution component admission", function()
        test.it("keeps every ordinary binding's subsystem deny effective even against a broad allow", function()
            local entry = registry.get("bee:application_admission")
            if not entry then error("missing application admission") end
            local data = entry.data :: {bindings: {{definition_id: string, policies: {string}}}}
            for _, binding in ipairs(data.bindings) do
                if binding.definition_id ~= "bee.harness.window:app" then
                    local names: {string} = {"bee.harness.catalog:scope_probe_allow", "bee.harness.catalog:scope_probe_broad_store"}
                    for _, name in ipairs(binding.policies) do names[#names + 1] = name end
                    local access = probe(names)
                    for _, resource in ipairs({"bee:workspace_db", "bee:client_db", "bee.placement.native:db", "bee.resources:db", "bee.credentials:db"}) do
                        if access[resource] then error(binding.definition_id .. " opened " .. resource) end
                    end
                end
            end
        end)
        test.it("checks the managed window's actual binding without granting core store access", function()
            local entry = registry.get("bee:application_admission")
            if not entry then error("missing application admission") end
            local data = entry.data :: {bindings: {{definition_id: string, policies: {string}}}}
            local found = false
            for _, binding in ipairs(data.bindings) do
                if binding.definition_id == "bee.harness.window:app" then
                    found = true
                    local names: {string} = {"bee.harness.catalog:scope_probe_allow"}
                    for _, name in ipairs(binding.policies) do names[#names + 1] = name end
                    local access = probe(names)
                    test.is_true(access["bee.placement.native:db"])
                    for _, resource in ipairs({"bee:workspace_db", "bee:client_db", "bee.resources:db", "bee.credentials:db"}) do
                        test.is_false(access[resource])
                    end
                    names[#names + 1] = "bee.harness.catalog:scope_probe_broad_store"
                    local broad = probe(names)
                    test.is_false(broad["bee:workspace_db"])
                    test.is_false(broad["bee:client_db"])
                end
            end
            test.is_true(found)
        end)
        test.it("requires explicit execution access and always denies the core stores", function()
            local denied = probe({"bee.harness.catalog:scope_probe_allow"})
            test.is_false(denied["bee.placement.native:db"])
            local allowed = probe({"bee.harness.catalog:scope_probe_allow", "bee:placement_store_policy"})
            test.is_true(allowed["bee.placement.native:db"])
            test.is_false(allowed["bee.resources:db"])
            test.is_false(allowed["bee.credentials:db"])
            local broad = probe({"bee.harness.catalog:scope_probe_allow", "bee.harness.catalog:scope_probe_broad_store"})
            test.is_false(broad["bee:workspace_db"])
            test.is_false(broad["bee:client_db"])
        end)
    end)
end
return test.run_cases(define_tests)
