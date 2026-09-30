-- SPDX-License-Identifier: MIT
local test = require("test")
local profiles = require("profiles")
local function docker(): {[string]: unknown}
    return {schema_revision = "bee.placement-profile@1", placement_binding = "bee.placement.docker.binding:binding",
        image_ref = "sha256:" .. string.rep("a", 64), user = "1000:1000", network = "bee-agents",
        interactive_route_ref = "bee.placement.docker:interactive", limits = {memory = 2147483648, cpu = 200000, pids = 256},
        mounts = {{resource = "project", target = "/workspace", access = "write"}}}
end
local function run()
    test.describe("Placement profiles", function()
        test.it("keeps native as the default", function()
            test.eq(profiles.DEFAULT, "bee.placement:native")
            local value, err = profiles.decode({schema_revision = "bee.placement-profile@1", placement_binding = "bee.placement.native.binding:binding"})
            if not value then error(tostring(err)) end
            test.eq(value.placement_binding, "bee.placement.native.binding:binding")
        end)
        test.it("requires an immutable image and non-host network", function()
            local value = docker()
            test.not_nil(profiles.decode(value))
            value.image_ref = "node:24"
            test.is_nil(profiles.decode(value))
            value = docker(); value.network = "host"
            test.is_nil(profiles.decode(value))
            value = docker(); value.user = "0:0"
            test.is_nil(profiles.decode(value))
        end)
        test.it("refuses missing limits and unsafe or duplicate mount targets", function()
            local value = docker(); value.limits = {memory = 0, cpu = 200000, pids = 256}
            test.is_nil(profiles.decode(value))
            value = docker(); value.mounts = {{resource = "project", target = "/../etc", access = "write"}}
            test.is_nil(profiles.decode(value))
            value = docker(); value.mounts = {{resource = "project", target = "/workspace", access = "write"},
                {resource = "cache", target = "/workspace", access = "write"}}
            test.is_nil(profiles.decode(value))
            value = docker(); value.mounts = {{resource = "project", target = "/home/bee", access = "write"}}
            test.is_nil(profiles.decode(value))
        end)
        test.it("does not accept caller paths, secrets or executor references", function()
            for _, key in ipairs({"executor", "environment", "credential_directory", "host_path"}) do
                local value = docker(); value[key] = "caller-controlled"
                test.is_nil(profiles.decode(value))
            end
        end)
    end)
end
return test.run_cases(run)
