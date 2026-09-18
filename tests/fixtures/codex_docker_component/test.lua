-- SPDX-License-Identifier: MIT
local test = require("test")
local registry = require("registry")
local definitions = require("definitions")
local policies = require("policies")
local selection = require("selection")

local IMAGE = "sha256:d529dd0c6e5597ac7e4a3e2dea65c3fcc6173f4cae713c409265c1dd9914a11b"
local USER = "1001:1002"

local function entry(ref: string): {[string]: unknown}
    local found, err = registry.get(ref)
    if not found then error(ref .. ": " .. tostring(err)) end
    return found :: {[string]: unknown}
end

local function run()
    test.describe("Optional Codex Docker component", function()
        test.it("links host requirements into one ordinary Agent definition", function()
            local raw_policy = entry("bee.driver.codex.docker:policy")
            local data = raw_policy.data :: {[string]: unknown}
            local options = data.placement_options :: {[string]: unknown}
            test.eq(options.image, IMAGE)
            test.eq(options.user, USER)
            test.eq(data.placement_binding, "bee.placement.docker:binding")
            test.eq(data.allow_host_home, nil)
            local mounts = options.mounts :: {{[string]: unknown}}
            test.eq(#mounts, 1)
            test.eq(mounts[1].resource, "project")
            test.eq(mounts[1].target, "/workspace")
            test.eq(mounts[1].access, "write")
            local decoded_policy, policy_error = policies.decode("bee.driver.codex.docker:policy", raw_policy)
            if not decoded_policy then error(tostring(policy_error)) end
            test.eq(decoded_policy.executables.codex, "/usr/local/bin/codex")

            local raw_launch = entry("bee.driver.codex.docker:launch")
            local launch, launch_error = definitions.decode("bee.driver.codex.docker:launch", raw_launch)
            if not launch then error(tostring(launch_error)) end
            test.eq(launch.binding_ref, "bee.driver.codex.docker:binding")
            test.eq(launch.policy_ref, "bee.driver.codex.docker:policy")
            test.eq(launch.workdir_policy.kind, "declared_resource")
            test.eq(launch.workdir_policy.resource_ref, "project")
            test.eq(launch.session_resource, "session")
            test.eq(#launch.credentials, 1)
            test.eq(launch.credentials[1], "codex_login")

            local raw_profiles = entry("bee.driver.codex.docker:profiles")
            local driver = (raw_profiles.data :: {[string]: unknown}).driver :: {[string]: unknown}
            local profiles = driver.profiles :: {{[string]: unknown}}
            test.eq(#profiles, 1)
            local isolation = profiles[1].isolation_env :: {[string]: unknown}
            test.eq(isolation.private_home, true)

            local command, command_error = selection.command("codex-docker")
            if not command then error(tostring(command_error)) end
            test.eq(command.definition_ref, "bee.driver.codex.docker:launch")
            local native, native_error = selection.command("codex")
            if not native then error(tostring(native_error)) end
            test.eq(native.definition_ref, "bee.driver.codex:default_window")

            local listed, list_error = selection.snapshot()
            if not listed then error(tostring(list_error)) end
            local native_item: {[string]: unknown}? = nil
            local docker_item: {[string]: unknown}? = nil
            for _, item in ipairs(listed.items) do
                if item.definition_ref == "bee.driver.codex:default_window" then native_item = item end
                if item.definition_ref == "bee.driver.codex.docker:launch" then docker_item = item end
            end
            test.not_nil(native_item)
            test.not_nil(docker_item)
            local unavailable = docker_item and docker_item.unavailable
            test.is_true(type(unavailable) == "string" and (unavailable :: string):find("placement", 1, true) ~= nil)
        end)
    end)
end

return {run = run}
