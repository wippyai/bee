-- SPDX-License-Identifier: MIT
local test = require("test")
local cases = require("cases")
local descriptors = require("descriptors")
local effective = require("effective")
local universal = require("universal")
local configuration = require("configuration")
local controls = require("controls")
local profiles = require("profiles")
local protocol = require("protocol")
local bounds = require("bounds")
local canonical = require("canonical")
local registry = require("registry")
local json = require("json")
local toml = require("toml")
type Object = {[string]: unknown}
local placement = "bee.placement.docker.profiles:coding"
local function object(value: unknown): Object return assert(bounds.object(value)) end
local function sequence(value: unknown): {unknown} return assert(bounds.array(value, 128)) end
local function path_value(value: unknown, path: {unknown}): unknown
    for _, key in ipairs(path) do value = object(value)[tostring(key)] end
    return value
end
local function contiguous(argv: {string}, expected: {unknown}): integer?
    for index = 1, #argv - #expected + 1 do
        local match = true
        for offset, token in ipairs(expected) do if argv[index + offset - 1] ~= token then match = false end end
        if match then return index end
    end
    return nil
end
local function with_ceiling(run: () -> ())
    local entry = assert(registry.get(placement))
    local original = assert(json.encode(entry.meta))
    local meta = object(entry.meta)
    local ceilings = object(meta.option_ceilings)
    ceilings.claude = ceilings.claude or {}
    for _, raw in ipairs(cases) do
        local case = object(raw)
        if case.security_class == "host-ceiling" then
            object(ceilings[tostring(case.driver)])[tostring(case.id)] = {"profile-option"}
        end
    end
    local changes = registry.snapshot():changes(); assert(changes:update(entry)); assert(changes:apply())
    local ok, err = pcall(run)
    entry.meta = assert(json.decode(original))
    changes = registry.snapshot():changes(); assert(changes:update(entry)); assert(changes:apply())
    assert(ok, tostring(err))
end
local function edit(values: Object, name: string, schema: Object, selected: unknown)
    for _ = 1, 128 do
        if canonical.encode(values[name]) == canonical.encode(selected) then return end
        local changed = false
        for _, row in ipairs(controls.rows(name, schema, values[name])) do
            local expected: unknown = selected
            for _, key in ipairs(row.path) do
                if type(expected) == "table" then expected = expected[key] else expected = nil end
            end
            local kinds = bounds.ids(row.schema.type, true)
            local kind = type(expected)
            if kind == "table" then
                kind = bounds.array(expected, 64) and (next(expected) ~= nil or canonical.encode(expected) == "[]") and "array" or "object"
            end
            if row.kind == "choice" and kinds then
                if expected ~= nil and row.value ~= kind then
                    assert(controls.change(values, row) == nil); changed = true; break
                end
            elseif row.kind == "create" and type(expected) == "table" then
                assert(controls.change(values, row) == nil); changed = true; break
            elseif row.kind == "append" then
                local desired, present = bounds.array(expected, 64), bounds.array(row.value, 64)
                local current: unknown = values[name]
                for _, key in ipairs(row.path) do if type(current) == "table" then current = current[key] end end
                present = bounds.array(current, 64)
                if desired and present and #present < #desired then assert(controls.change(values, row) == nil); changed = true; break end
            elseif row.kind == "key" then
                local desired = bounds.object(expected)
                local current: unknown = values[name]
                for _, key in ipairs(row.path) do if type(current) == "table" then current = current[key] end end
                local present = bounds.object(current)
                if desired and present then
                    for key in pairs(desired) do
                        if present[key] == nil then assert(controls.change(values, row, key) == nil); changed = true; break end
                    end
                end
                if changed then break end
            elseif expected ~= nil and canonical.encode(row.value) ~= canonical.encode(expected)
                and (row.kind == "text" or row.kind == "choice") then
                assert(controls.change(values, row, row.kind == "text" and tostring(expected) or nil) == nil)
                changed = true; break
            end
        end
        assert(changed, "Editor cannot reach " .. name)
    end
    error("Editor change bound exceeded for " .. name)
end
local function define_tests()
    test.describe("Installed Claude and Codex option coverage", function()
        test.it("declares every verified version fixture with native mappings and security metadata", function()
            for _, raw in ipairs(cases) do
                local case = object(raw)
                local cli = assert(descriptors.load("bee.driver." .. tostring(case.driver) .. ".descriptor:cli"))
                local field = object(object(cli.options.fields)[tostring(case.id)])
                test.eq(field.id, case.id); test.eq(field.group, case.group); test.eq(field.security_class, case.security_class)
                test.eq(object(field.support).version_range, ">=" .. tostring(case.version))
                test.not_nil(descriptors.decode_option(tostring(case.id), field, case.value))
            end
        end)
        test.it("captures argv and private config for every option and supported context", function()
            with_ceiling(function()
                for _, raw in ipairs(cases) do
                    local case = object(raw)
                    local driver, id = tostring(case.driver), tostring(case.id)
                    local cli = assert(descriptors.load("bee.driver." .. driver .. ".descriptor:cli"))
                    local field = object(object(cli.options.fields)[id])
                    for _, context in ipairs(sequence(case.contexts)) do
                        local request: Object = {profile_id = context == "window" and "window" or "batch", brief = "Fixture", placement_profile_ref = placement}
                        request[id] = case.value
                        for name, value in pairs(bounds.object(case.companions) or {}) do request[name] = value end
                        if context == "resume" then request.resume_ref = "fixture-thread" end
                        local reply = universal.prepare("bee.driver." .. driver .. ".descriptor:cli")(request)
                        assert(reply.ok == true, driver .. "." .. id .. "/" .. tostring(context) .. ": " .. tostring(reply.error))
                        local argv = assert(bounds.ids(object(reply.launch).argv, false))
                        if case.argv then
                            local value, invalid = descriptors.decode_option(id, field, case.value)
                            assert(invalid == nil, tostring(invalid))
                            local render_request: universal.Request = {profile_id = context == "window" and "window" or "batch", brief = "Fixture"}
                            render_request[id] = value
                            local captured = assert(universal.render_argv({{render = id, context = context}}, render_request, cli))
                            test.eq(canonical.encode(captured), canonical.encode(case.argv))
                            local start = contiguous(argv, sequence(case.argv))
                            assert(start, driver .. "." .. id .. ": " .. table.concat(argv, " "))
                            for index, token in ipairs(argv) do if token == "--" then test.is_true(assert(start) < index) end end
                        else
                            local delivery, err = configuration.call("bee.driver." .. driver .. ".binding:binding", "bee.driver." .. driver .. ".binding:configure",
                                {fixture = true, private_home = true, context = tostring(context), option_values = {[id] = case.value}, placement_profile_ref = placement})
                            assert(delivery, driver .. "." .. id .. ": " .. tostring(err))
                            local captured: unknown = nil
                            for _, file in ipairs(delivery.files) do if file.path == ".codex/config.toml" then captured = toml.decode(file.content) end end
                            test.eq(canonical.encode(path_value(captured, sequence(case.config_path))), canonical.encode(case.value))
                        end
                    end
                end
            end)
        end)
        test.it("enforces every host option through host policy and placement ceilings", function()
            with_ceiling(function()
                for _, raw in ipairs(cases) do
                    local case = object(raw)
                    if case.security_class == "host-ceiling" then
                        local driver, id = tostring(case.driver), tostring(case.id)
                        local cli = assert(descriptors.load("bee.driver." .. driver .. ".descriptor:cli"))
                        local field = object(object(cli.options.fields)[id])
                        local policy = {profile_restrictions = {[tostring(field.path)] = {kind = "declared"}}, option_constraints = {[id] = {capabilities = {}}}}
                        local denied = effective.compile(cli, policy, nil, {[id] = case.value}, "person", nil, nil, placement)
                        if case.baseline ~= true and case.safe ~= case.value then test.is_nil(denied) end
                        if case.baseline ~= true and case.safe ~= case.value then
                            test.is_nil(effective.compile(cli, nil, nil, {[id] = case.value}, "person", nil, nil, "bee.placement.profiles:native"))
                        end
                        policy.option_constraints[id] = {locked = true, reason = "Host lock"}
                        test.is_nil(effective.compile(cli, policy, nil, {[id] = case.value}, "person", nil, nil, placement))
                    end
                end
            end)
        end)
        test.it("retains false, enforces native contexts and renders the native USD budget minimum", function()
            local ref = "bee.driver.claude.descriptor:cli"
            local cli = assert(descriptors.load(ref))
            local policy = {profile_restrictions = {["provider.options.budget_usd"] = {kind = "declared"}}, option_constraints = {budget_usd = {maximum = 0.05}}}
            local applied = assert(effective.apply(policy, {options = {budget_usd = "1.25"}}, cli))
            local options = object(applied.prepare_options)
            options.profile_id, options.brief = "batch", "Fixture"
            local reply = universal.prepare(ref)(options)
            assert(reply.ok == true, tostring(reply.error))
            local argv = assert(bounds.ids(object(reply.launch).argv, false))
            test.not_nil(contiguous(argv, {"--max-budget-usd", "0.05"}))
            test.eq(universal.prepare(ref)({profile_id = "window", brief = "Fixture", budget_usd = "0.05"}).ok, false)
            reply = universal.prepare(ref)({profile_id = "batch", brief = "Fixture", prompt_suggestions = false, fallback_models = {}})
            assert(reply.ok == true, tostring(reply.error))
            argv = assert(bounds.ids(object(reply.launch).argv, false))
            test.not_nil(contiguous(argv, {"--prompt-suggestions", "false"}))
            test.is_nil(bounds.member("--fallback-model", argv))
            with_ceiling(function()
                reply = universal.prepare(ref)({profile_id = "batch", brief = "Fixture", placement_profile_ref = placement, tools = {}})
                assert(reply.ok == true, tostring(reply.error))
                test.not_nil(bounds.member("--tools=", assert(bounds.ids(object(reply.launch).argv, false))))
            end)
            test.eq(universal.prepare("bee.driver.codex.descriptor:cli")({profile_id = "batch", resume_ref = "fixture-thread", brief = "Fixture", color = "never"}).ok, false)
            reply = universal.prepare(ref)({profile_id = "window", brief = "Fixture", chrome = false})
            assert(reply.ok == true, tostring(reply.error))
            test.not_nil(bounds.member("--no-chrome", assert(bounds.ids(object(reply.launch).argv, false))))
            local fields = object(cli.options.fields)
            for _, value in ipairs({"auto", "100k", "1M", "150000"}) do test.not_nil(descriptors.decode_option("autocompact", object(fields.autocompact), value)) end
            for _, value in ipairs({"99k", "2M", "infinite", ""}) do test.is_nil(descriptors.decode_option("autocompact", object(fields.autocompact), value)) end
            for _, value in ipairs({"{", "[]", "null", 5}) do test.is_nil(descriptors.decode_option("json_schema", object(fields.json_schema), value)) end
        end)
        test.it("keeps optional values inside their own flag and refuses variadic flag injection", function()
            local ref = "bee.driver.claude.descriptor:cli"
            local reply = universal.prepare(ref)({profile_id = "window", brief = "Fixture", debug = "--dangerously-skip-permissions"})
            assert(reply.ok == true, tostring(reply.error))
            local argv = assert(bounds.ids(object(reply.launch).argv, false))
            test.not_nil(bounds.member("--debug=--dangerously-skip-permissions", argv))
            test.is_nil(bounds.member("--dangerously-skip-permissions", argv))
            with_ceiling(function()
                reply = universal.prepare(ref)({profile_id = "window", brief = "Fixture", placement_profile_ref = placement,
                    additional_dirs = {"/workspace", "--dangerously-skip-permissions"}})
                test.eq(reply.ok, false)
            end)
        end)
        test.it("does not use empty replacements to bypass a host ceiling", function()
            local claude = assert(descriptors.load("bee.driver.claude.descriptor:cli"))
            test.is_true(effective.compile(claude, nil, nil, {system_prompt = ""}, "person", nil, nil, "bee.placement.profiles:native") == nil)
            local codex = assert(descriptors.load("bee.driver.codex.descriptor:cli"))
            for _, name in ipairs({"hooks", "mcp_servers", "model_providers", "features", "writable_roots", "images"}) do
                test.is_true(effective.compile(codex, nil, nil, {[name] = {}}, "person", nil, nil, "bee.placement.profiles:native") == nil)
            end
        end)
        test.it("locks every option whose installed version capability is absent", function()
            with_ceiling(function()
                for _, raw in ipairs(cases) do
                    local case = object(raw)
                    local cli = assert(descriptors.load("bee.driver." .. tostring(case.driver) .. ".descriptor:cli"))
                    local fields = object(cli.options.fields)
                    local capabilities: {[string]: effective.Capability} = {}
                    for _, raw_field in pairs(fields) do
                        local field = object(raw_field)
                        if field.path then capabilities[tostring(field.path)] = {supported = true} end
                    end
                    local id = tostring(case.id)
                    capabilities[tostring(object(fields[id]).path)] = {supported = false, reason = "Version below verified fixture"}
                    local compiled, err = effective.compile(cli, nil, capabilities, {[id] = case.value}, "person", nil, nil, placement)
                    test.is_nil(compiled); test.is_true(tostring(err):find("Version below", 1, true) ~= nil)
                end
            end)
        end)
        test.it("round trips the editor and schema storage in every group for each driver", function()
            with_ceiling(function()
                local groups: {[string]: boolean} = {}
                for _, raw in ipairs(cases) do
                    local case = object(raw)
                    local id, driver = tostring(case.id), tostring(case.driver)
                    local values: Object = {}
                    edit(values, id, object(case.schema), case.value)
                    for name, value in pairs(bounds.object(case.companions) or {}) do values[name] = value end
                    local stored = assert(profiles.encode("bee.driver." .. driver .. ".binding:binding", {options = values}, placement))
                    local checked, invalid = protocol.profile({schema_revision = protocol.SCHEMA, name = "Coverage",
                        definition_ref = "bee.driver." .. driver .. ".profiles:default_window", driver_binding_ref = "bee.driver." .. driver .. ".binding:binding",
                        provider = stored, bee = {}, placement = {kind = "docker", profile_ref = placement}})
                    assert(checked, driver .. "." .. id .. ": " .. tostring(invalid))
                    local reopened = assert(profiles.decode("bee.driver." .. driver .. ".binding:binding", object(json.decode(assert(json.encode(stored)))), placement))
                    test.eq(canonical.encode(assert(profiles.flatten(reopened))[id]), canonical.encode(case.value))
                    local persisted = assert(protocol.storage(assert(checked)))
                    local restored = assert(protocol.profile(json.decode(assert(json.encode(persisted)))))
                    test.eq(canonical.encode(assert(protocol.preferences(restored)).options[id]), canonical.encode(case.value))
                    groups[driver .. "/" .. tostring(case.group)] = true
                end
                for _, driver in ipairs({"claude", "codex"}) do
                    for _, group in ipairs({"model/provider", "behavior", "access/trust", "tools/integrations", "advanced"}) do test.eq(groups[driver .. "/" .. group], true) end
                end
            end)
        end)
    end)
end
return test.run_cases(define_tests)
