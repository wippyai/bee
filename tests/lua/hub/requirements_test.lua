-- MIT. Hub requirement inspection is pure: it displays declared holes and
-- supplied configuration without resolving a dependency or modifying a target.
local test = require("test")
local requirements = require("requirements")

local function package_entries(): {unknown}
    return {
        {id = "demo:required", kind = "ns.requirement", data = {targets = {{entry = "demo:service", path = ".resource_ref"}}}},
        {id = "demo:empty", kind = "ns.requirement", data = {default = "", targets = {{entry = "demo:service", path = ".empty"}}}},
        {id = "demo:false", kind = "ns.requirement", data = {default = false, targets = {{entry = "demo:service", path = "meta.enabled"}}}},
        {id = "demo:selected", kind = "ns.requirement", data = {default = "kept", targets = {{entry = "demo:service", path = ".selected"}}}},
        {id = "demo:ordinary", kind = "library.lua", data = "ignored"},
    }
end

local function parameters(value: unknown): {requirements.Parameter}
    local decoded, err = requirements.parameters(value)
    if not decoded then error(tostring(err)) end
    return decoded
end

local function define_tests()
    test.describe("Hub requirements", function()
        test.it("projects selected migration database holes without changing artifact entries", function()
            local entries: {requirements.Entry} = {
                {id = "demo:first", kind = "function.lua", meta = {type = "migration", target_db = "demo:raw"}, data = {}},
                {id = "demo:ordinary", kind = "library.lua", meta = {target_db = "demo:raw"}, data = {}},
            }
            local hole: requirements.Requirement = {id = "demo:target_db", default = "demo:default", has_default = true,
                has_selected = false, targets = {{entry = "demo:first", path = ".meta.target_db"},
                    {entry = "demo:ordinary", path = ".meta.target_db"}}}
            local resolved: requirements.Result = {requirements = {hole}, missing = {}}
            local defaults, problem = requirements.migration_targets(entries, resolved)
            test.is_nil(problem); test.not_nil(defaults)
            if defaults then test.eq(defaults[1].meta.target_db, "demo:default"); test.eq(defaults[2].meta.target_db, "demo:raw") end
            hole.selected, hole.has_selected = "host:database", true
            local chosen, chosen_problem = requirements.migration_targets(entries, resolved)
            test.is_nil(chosen_problem); test.not_nil(chosen)
            if chosen then test.eq(chosen[1].meta.target_db, "host:database") end
            test.eq(entries[1].meta.target_db, "demo:raw")
            hole.selected = false
            test.is_nil(requirements.migration_targets(entries, resolved))
            hole.selected = "host:database"
            resolved.requirements[2] = {id = "demo:other", default = "host:other", has_default = true,
                has_selected = false, targets = {{entry = "demo:first", path = "meta.target_db"}}}
            test.is_nil(requirements.migration_targets(entries, resolved))
            resolved.requirements[2].targets[1].path = ".data.target_db"
            test.not_nil(requirements.migration_targets(entries, resolved))
        end)
        test.it("keeps declared defaults apart from supplied values and lists missing requirements", function()
            local result, err = requirements.read(package_entries(), parameters({{name = "demo:selected", value = "provided"}}))
            if not result then error(tostring(err)) end
            test.eq(#result.requirements, 4)
            test.eq(result.requirements[2].default, "")
            test.is_true(result.requirements[2].has_default)
            test.eq(result.requirements[3].default, false)
            test.is_true(result.requirements[3].has_default)
            test.eq(result.requirements[4].default, "kept")
            test.eq(result.requirements[4].selected, "provided")
            test.is_true(result.requirements[4].has_selected)
            test.eq(#result.missing, 1)
            test.eq(result.missing[1], "demo:required")
        end)
        test.it("refuses unknown configuration before it can be treated as transitive input", function()
            local decoded = parameters({{name = "other:configuration", value = "value"}})
            local result, err = requirements.read(package_entries(), decoded)
            test.is_nil(result)
            test.eq(err, "parameter names no requirement other:configuration")
        end)
        test.it("addresses owned requirements by bare name the way the native linker does", function()
            local result, err = requirements.read(package_entries(), parameters({{name = "selected", value = "provided"}}))
            if not result then error(tostring(err)) end
            test.eq(result.requirements[4].selected, "provided")
            test.is_true(result.requirements[4].has_selected)
            local unknown, unknown_error = requirements.read(package_entries(), parameters({{name = "configuration", value = "value"}}))
            test.is_nil(unknown)
            test.eq(unknown_error, "parameter names no requirement configuration")
            local malformed, malformed_error = requirements.parameters({{name = "demo:selected:extra", value = "value"}})
            test.is_nil(malformed)
            test.eq(malformed_error, "parameters[1].name must be a requirement name or a qualified identifier")
            test.is_nil(requirements.parameters({{name = "has space", value = "value"}}))
        end)
        test.it("refuses duplicate requirement and parameter names", function()
            local entries = package_entries()
            entries[6] = {id = "demo:required", kind = "ns.requirement", data = {targets = {{entry = "demo:service", path = ".other"}}}}
            local result, err = requirements.read(entries, parameters({}))
            test.is_nil(result)
            test.eq(err, "requirement id demo:required twice")
            local duplicate, duplicate_error = requirements.parameters({{name = "demo:selected", value = "one"}, {name = "demo:selected", value = "two"}})
            test.is_nil(duplicate)
            test.eq(duplicate_error, "parameters name demo:selected twice")
        end)
        test.it("refuses malformed declarations, targets, and bounded collections", function()
            local malformed = package_entries()
            malformed[1] = {id = "demo:required", kind = "ns.requirement", data = {targets = {{entry = "demo:service", path = "bad\npath"}}}}
            local target, target_error = requirements.read(malformed, parameters({}))
            test.is_nil(target)
            test.eq(target_error, "package entries[1].data.targets[1].path must be a bounded target path")
            local bad_data = package_entries()
            bad_data[1] = {id = "demo:required", kind = "ns.requirement", data = {targets = {}, value = "unrecognized"}}
            local declaration, declaration_error = requirements.read(bad_data, parameters({}))
            test.is_nil(declaration)
            test.eq(declaration_error, "package entries[1].data: unknown field value")
            local oversized: {unknown} = {}
            for index = 1, requirements.MAX_PACKAGE_ENTRIES + 1 do oversized[index] = {kind = "library.lua"} end
            local too_many, too_many_error = requirements.read(oversized, parameters({}))
            test.is_nil(too_many)
            test.eq(too_many_error, "package entries exceeds " .. tostring(requirements.MAX_PACKAGE_ENTRIES) .. " items")
            local sparse, sparse_error = requirements.parameters({[2] = {name = "demo:selected", value = "value"}})
            test.is_nil(sparse)
            test.eq(sparse_error, "parameters must be a dense list")
        end)
        test.it("bounds defaults and does not silently drop malformed package entries", function()
            test.is_nil(requirements.read({false}, {}))
            test.is_nil(requirements.read({{id = "bad", kind = "ns.requirement", data = {targets = {}}}}, {}))
            local entries = package_entries()
            entries[1] = {id = "demo:required", kind = "ns.requirement", data = {
                default = string.rep("a", requirements.MAX_PARAMETER_BYTES + 1),
                targets = {{entry = "demo:service", path = ".resource_ref"}},
            }}
            test.is_nil(requirements.read(entries, {}))
        end)
        test.it("preserves typed native dependency values", function()
            local input = parameters({{name = "demo:required", value = 8},
                {name = "demo:selected", value = {workers = 2, enabled = false, names = {"first", "second"}}}})
            local result, problem = requirements.read(package_entries(), input)
            if not result then error(tostring(problem)) end
            test.eq(result.requirements[1].selected, 8)
            test.eq(result.requirements[4].selected, input[2].value)
            test.eq(#result.missing, 0)
            test.is_nil(requirements.parameters({{name = "demo:required", value = function() end}}))
        end)
    end)
end
return test.run_cases(define_tests)
