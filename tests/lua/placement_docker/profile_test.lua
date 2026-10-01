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
        test.it("admits a host-selected image recipe without accepting a mutable tag", function()
            local value = docker(); value.image_ref = nil; value.image_recipe_ref = "bee.placement.docker:coding_recipe"
            local decoded = assert(profiles.decode(value))
            test.eq(decoded.image_recipe_ref, "bee.placement.docker:coding_recipe")
            value.image_ref = "sha256:" .. string.rep("a", 64)
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
        test.it("narrows canonical overrides without changing the host template", function()
            local base = assert(profiles.decode(docker()))
            local resolved = {ref = "bee.placement.docker:coding", digest = string.rep("a", 64), profile = base}
            local tuned = assert(profiles.tune(resolved, {limits = {memory_bytes = 1073741824, cpu_millicpus = 500, pids = 16},
                mounts = {{resource = "project", subpath = "", target = "/workspace", access = "read"}}}))
            test.eq(tuned.profile.limits.memory, 1073741824)
            test.eq(tuned.profile.limits.cpu, 50000)
            test.eq(tuned.profile.mounts[1].access, "read")
            test.eq(base.limits.cpu, 200000)
            test.eq(base.mounts[1].access, "write")
            test.is_nil(profiles.tune(resolved, {limits = {cpu_millicpus = 2001}}))
            test.is_nil(profiles.tune(resolved, {image = {kind = "digest", ref = "sha256:" .. string.rep("b", 64)}}))
            test.is_nil(profiles.tune(resolved, {mounts = {{resource = "project", target = "/workspace", access = "write"},
                {resource = "project", target = "/workspace", access = "read"}}}))
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
