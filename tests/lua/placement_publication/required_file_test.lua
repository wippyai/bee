-- SPDX-License-Identifier: MIT
-- A named Codex config profile is a host file outside the private home.
-- Placement checks existence only, through the read-only host volume, and
-- refuses a launch whose named profile is absent.
local test = require("test")
local types = require("types")
local driver_types = require("driver_types")
local materialization = require("materialization")
local function request(required: {driver_types.RequiredFile}?, environment: {[string]: string}?): types.LaunchRequest
    local launch: driver_types.Launch = {executable = "codex", argv = {}, environment = {}, readiness = "terminal:attached"}
    if required then launch.required_files = required end
    local value: types.LaunchRequest = {idempotency_key = "k", attempt_id = "a", owner_id = "bee.test.required_file",
        owner_incarnation = 1, action_id = "a", binding_ref = "bee.driver.codex:binding", policy_ref = "bee.test:policy",
        profile_id = "window", binding_digest = string.rep("b", 64), profile_digest = string.rep("c", 64),
        launch = launch, resources = {}, environment = environment or {}, environment_refs = {}, projections = {},
        required_cleanup = "process_group", required_exit_observation = "independent",
        timeouts = {start_ms = 1000, stop_grace_ms = 100, drain_ms = 1000, retain_ms = 1000}}
    return value
end
local function define_tests()
    test.describe("Codex named profile host-file refusal", function()
        test.it("refuses a missing named profile and admits an installed one", function()
            local absent_files: {driver_types.RequiredFile} = {{variable = "CODEX_HOME", path = "definitely-missing-bee-profile.config.toml"}}
            local missing = materialization.required_file_missing(request(absent_files, {CODEX_HOME = "/etc"}))
            test.not_nil(missing)
            test.is_true(missing:find("definitely-missing-bee-profile", 1, true) ~= nil)
            local present_files: {driver_types.RequiredFile} = {{variable = "CODEX_HOME", path = "hostname"}}
            local installed = materialization.required_file_missing(request(present_files, {CODEX_HOME = "/etc"}))
            test.is_nil(installed)
        end)

        test.it("resolves the default directory from the inherited home", function()
            local defaulted: {driver_types.RequiredFile} = {{variable = "CODEX_HOME", path = "missing.config.toml", default_directory = "."}}
            local missing = materialization.required_file_missing(request(defaulted, {HOME = "/etc"}))
            test.not_nil(missing)
            local installed_default: {driver_types.RequiredFile} = {{variable = "CODEX_HOME", path = "hostname", default_directory = "."}}
            local installed = materialization.required_file_missing(request(installed_default, {HOME = "/etc"}))
            test.is_nil(installed)
        end)

        test.it("reports an unavailable home rather than starting", function()
            local no_home: {driver_types.RequiredFile} = {{variable = "CODEX_HOME", path = "x.config.toml", default_directory = ".codex"}}
            local absent = materialization.required_file_missing(request(no_home, {}))
            test.not_nil(absent)
        end)

        test.it("needs no host file when the launch declares none", function()
            test.is_nil(materialization.required_file_missing(request(nil, {})))
        end)
    end)
end
return test.run_cases(define_tests)
