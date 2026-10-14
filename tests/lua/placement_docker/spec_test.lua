-- SPDX-License-Identifier: MIT
local test = require("test")
local spec = require("spec")
local HOME = "/placement/attempts/owned/home"
local IMAGE_ID = "sha256:" .. string.rep("e", 64)
local function admitted(): spec.Spec
    return {profile_ref = "bee.test:docker", profile_digest = string.rep("a", 64), image = "node@sha256:" .. string.rep("b", 64),
        interactive_route_ref = nil, user = "1000:1000", network = "bee-agents", limits = {memory = 2147483648, cpu = 200000, pids = 256}, mounts = {},
        attempt_id = "attempt-1"}
end
local function inspect(value: spec.Spec): {[string]: unknown}
    return {Id = string.rep("d", 64), Image = IMAGE_ID,
        Config = {Image = value.image, Env = {"HOME=/home/bee", "BEE_ATTEMPT_ID=" .. value.attempt_id}},
        Mounts = {{Type = "bind", Source = HOME, Destination = "/home/bee", RW = true}},
        State = {Status = "exited", ExitCode = 137}}
end
local function run()
    test.describe("Docker ownership evidence", function()
        test.it("requires attempt environment and the exact provider home mount without labels", function()
            local value = admitted()
            local raw = inspect(value)
            test.not_nil(spec.inspect(raw, value, HOME, IMAGE_ID))
            raw.Config = {Image = value.image, Env = {"BEE_ATTEMPT_ID=foreign"}}
            test.is_nil(spec.inspect(raw, value, HOME, IMAGE_ID))
            raw = inspect(value)
            raw.Mounts = {{Type = "bind", Source = "/foreign/home", Destination = "/home/bee", RW = true}}
            test.is_nil(spec.inspect(raw, value, HOME, IMAGE_ID))
        end)
        test.it("runs a host-user profile as the node's own uid and gid, never as root", function()
            test.eq(spec.container_user("host", 501, 20), "501:20")
            test.eq(spec.container_user("1000:1000", 501, 20), "1000:1000")
            local root, refused = spec.container_user("host", 0, 0)
            test.is_nil(root)
            test.is_true(tostring(refused):find("root", 1, true) ~= nil)
            local missing, unavailable = spec.container_user("host", nil, nil)
            test.is_nil(missing)
            test.is_true(tostring(unavailable):find("host user", 1, true) ~= nil)
        end)
        test.it("requires an immutable container ID and verifies actual image bytes", function()
            local value = admitted()
            local raw = inspect(value)
            raw.Id = "bee-current"
            test.is_nil(spec.inspect(raw, value, HOME, IMAGE_ID))
            raw = inspect(value)
            raw.Image = "sha256:" .. string.rep("f", 64)
            test.is_nil(spec.inspect(raw, value, HOME, IMAGE_ID))
            raw = inspect(value)
            raw.Config = {Image = "other:latest", Env = {"BEE_ATTEMPT_ID=" .. value.attempt_id}}
            test.is_nil(spec.inspect(raw, value, HOME, IMAGE_ID))
        end)
        test.it("rejects duplicate identity environment and malformed exit status", function()
            local value = admitted()
            local raw = inspect(value)
            raw.Config = {Image = value.image, Env = {"BEE_ATTEMPT_ID=" .. value.attempt_id, "BEE_ATTEMPT_ID=foreign"}}
            test.is_nil(spec.inspect(raw, value, HOME, IMAGE_ID))
            raw = inspect(value)
            local observed = assert(spec.inspect(raw, value, HOME, IMAGE_ID))
            test.eq(observed.observed_image_digest, IMAGE_ID)
            test.eq(observed.exit_code, 137)
            raw.State = {Status = "exited", ExitCode = "zero"}
            test.is_nil(spec.inspect(raw, value, HOME, IMAGE_ID))
        end)
    end)
end
return test.run_cases(run)
