-- SPDX-License-Identifier: MIT
local test = require("test")
local registry = require("registry")
local descriptors = require("descriptors")
local effective = require("effective")
local universal = require("universal")
local profiles = require("profiles")
local profile_values = require("profile_values")
local bounds = require("bounds")
local placement_profiles = require("placement_profiles")
type Case = {driver: string, values: {[string]: unknown}, argv: {string}}
local cases: {Case} = {
    {driver = "claude", values = {permission_mode = "bypassPermissions"}, argv = {"--permission-mode", "bypassPermissions"}},
    {driver = "claude", values = {permission_bypass = true}, argv = {"--dangerously-skip-permissions"}},
    {driver = "codex", values = {dangerously_bypass_approvals_and_sandbox = true}, argv = {"--dangerously-bypass-approvals-and-sandbox"}},
    {driver = "codex", values = {sandbox = "danger-full-access", approval_policy = "never"}, argv = {"--sandbox", "danger-full-access"}},
    {driver = "agy", values = {dangerously_skip_permissions = true, sandbox = false}, argv = {"--dangerously-skip-permissions"}},
    {driver = "grok", values = {permission_mode = "bypassPermissions"}, argv = {"--permission-mode", "bypassPermissions"}},
    {driver = "muse", values = {yolo = true}, argv = {"--yolo"}},
    {driver = "opencode", values = {auto = true}, argv = {"--auto"}},
}
local function define_tests()
    test.describe("Person-saved all-allowed driver profiles", function()
        for _, placement in ipairs({"bee.placement.profiles:native", "bee.placement.docker.profiles:coding"}) do
            for _, case in ipairs(cases) do
                test.it(case.driver .. " " .. case.argv[1] .. " in " .. placement, function()
                    local ref = "bee.drivers." .. case.driver .. ".descriptor:cli"
                    local binding = "bee.drivers." .. case.driver .. ".binding:binding"
                    local cli = assert(descriptors.load(ref))
                    local placed = assert(placement_profiles.placement(placement))
                    local compiled, err = effective.compile(cli, nil, nil, case.values, "person", nil, nil, placed)
                    assert(compiled, tostring(err))
                    for _, writer in ipairs({"agent", "delegated"}) do
                        local denied, reason = effective.compile(cli, nil, nil, case.values, writer, nil, nil, placed)
                        test.is_nil(denied)
                        assert(reason and reason:find("person", 1, true), tostring(reason))
                    end
                    test.not_nil(profile_values.person_only(binding, {schema_ref = ref, values = case.values}))
                    test.is_nil(effective.compile(cli, {prepare_options = case.values}, nil, nil, "person", nil, nil, placed))
                    local stored = {schema_ref = ref, schema_revision = cli.schema_revision, values = case.values}
                    local profile = assert(profiles.profile({schema_revision = profiles.SCHEMA, name = "All allowed", definition_ref = "bee.driver." .. case.driver .. ".profiles:default_window",
                        driver_binding_ref = binding, provider = stored, bee = {}, placement = placement == "bee.placement.profiles:native" and {kind = "native", home = "private"} or {kind = "docker", profile_ref = placement}}))
                    local saved = assert(profiles.preferences(assert(profiles.profile(assert(profiles.storage(profile))))))
                    local review = assert(effective.review(cli, saved.options, placed))
                    assert(review:find("All allowed", 1, true), review)
                    for _, context in ipairs({"window", "first_turn", "resume"}) do
                        local policy_ref = "bee.driver." .. case.driver .. ".security:launch_policy_" .. case.driver .. (context == "window" and "_window" or "_batch")
                        local policy = assert(bounds.object(assert(registry.get(policy_ref)).data))
                        local applied, invalid = effective.apply(policy, saved, cli, placed)
                        assert(applied, tostring(invalid))
                        local request: {[string]: unknown} = {}
                        for name, value in pairs(assert(bounds.object(applied.prepare_options))) do request[name] = value end
                        request.profile_id, request.brief, request.placement = context == "window" and "window" or "batch", "Fixture", placed
                        if context == "resume" then request.resume_ref = "fixture-session" end
                        local reply = universal.prepare(ref)(request)
                        assert(reply.ok == true, tostring(reply.error))
                        local argv = assert(bounds.ids(assert(bounds.object(reply.launch)).argv, false))
                        local found = false
                        for index, token in ipairs(argv) do
                            if token == case.argv[1] then
                                found = true
                                for offset, expected in ipairs(case.argv) do test.eq(argv[index + offset - 1], expected) end
                            end
                        end
                        test.is_true(found, table.concat(argv, " "))
                    end
                end)
            end
        end
        test.it("retains unrelated option ceilings", function()
            for _, placement in ipairs({"bee.placement.profiles:native", "bee.placement.docker.profiles:coding"}) do
                local cli = assert(descriptors.load("bee.drivers.claude.descriptor:cli"))
                local placed = assert(placement_profiles.placement(placement))
                test.is_nil(effective.compile(cli, nil, nil, {system_prompt = "Replacement"}, "person", nil, nil, placed))
                test.is_nil(effective.compile(cli, {option_constraints = {permission_mode = {capabilities = {"read"}}}}, nil,
                    {permission_mode = "bypassPermissions"}, "person", nil, nil, placed))
            end
        end)
    end)
end
return test.run_cases(define_tests)
