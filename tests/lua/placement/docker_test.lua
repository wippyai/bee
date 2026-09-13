-- SPDX-License-Identifier: MIT
local test = require("test")
local configuration = require("configuration")
type Object = {[string]: unknown}
local function input(): Object
    local image = "sha256:" .. string.rep("a", 64)
    return {image = image, user = "1000:1000", network = "bee-agents", apparmor = "docker-default",
        memory = 536870912, nano_cpus = 1000000000, pids_limit = 128,
        command = {"/usr/bin/codex", "a task with spaces"}, home_source = "/private/session/home", home_target = "/home/bee",
        mounts = {{source = "/projects/demo", target = "/workspace", access = "read"},
            {source = "/projects/output", target = "/output", access = "write"}}, working_directory = "/workspace/src",
        labels = {["bee.actor_ref"] = "actor", ["bee.revision_digest"] = string.rep("b", 64), ["bee.attempt_id"] = "attempt",
            ["bee.request_digest"] = string.rep("c", 64), ["bee.lease_fence"] = "1", ["bee.image_digest"] = image}}
end
local function define_tests()
    test.describe("Portable Docker profile", function()
        test.it("keeps baseline isolation when no AppArmor profile is selected", function()
            local raw = input()
            raw.apparmor = nil
            raw.network = "bridge"
            local config, err = configuration.build(raw)
            if not config then error(tostring(err)) end
            test.eq(#config.HostConfig.SecurityOpt, 1)
            test.eq(config.HostConfig.SecurityOpt[1], "no-new-privileges:true")
            test.eq(config.HostConfig.CapDrop[1], "ALL")
            test.is_true(config.HostConfig.ReadonlyRootfs)
            test.is_false(config.HostConfig.Privileged)
            test.eq(config.HostConfig.PidsLimit, raw.pids_limit)
            test.eq(config.HostConfig.NetworkMode, "bridge")
        end)
    end)
    test.describe("Docker preparation", function()
        test.it("preserves an empty argument while refusing an empty executable", function()
            local raw = input()
            raw.command = {"/bin/sh", "-c", "printf '%s' \"$1\"", "fixture", ""}
            local config, err = configuration.build(raw)
            if not config then error(tostring(err)) end
            test.eq(#config.Cmd, 5)
            test.eq(config.Cmd[5], "")
            raw.command = {"", "argument"}
            test.is_nil(configuration.build(raw))
        end)
        test.it("projects explicit mounts and preserves command arguments without a shell", function()
            local raw = input()
            local config, err = configuration.build(raw)
            if not config then error(tostring(err)) end
            test.eq(config.Cmd[2], "a task with spaces")
            test.eq(config.Env[1], "HOME=/home/bee")
            test.eq(config.WorkingDir, "/workspace/src")
            test.eq(config.HostConfig.Binds[1], "/private/session/home:/home/bee:rw")
            test.eq(config.HostConfig.Binds[2], "/projects/demo:/workspace:ro")
            test.eq(config.HostConfig.Binds[3], "/projects/output:/output:rw")
            test.is_true(config.HostConfig.ReadonlyRootfs)
            test.is_false(config.HostConfig.Privileged)
            test.is_false(config.HostConfig.AutoRemove)
            test.eq(config.HostConfig.CapDrop[1], "ALL")
            test.eq(config.HostConfig.SecurityOpt[1], "no-new-privileges:true")
            test.eq(config.HostConfig.Memory, 536870912)
            test.eq(config.HostConfig.NetworkMode, "bee-agents")
            test.is_true(config.Tty)
            local command = raw.command :: {string}
            local labels = raw.labels :: {[string]: string}
            command[1] = "/changed"
            labels["bee.attempt_id"] = "changed"
            local mounts = raw.mounts :: {Object}
            mounts[2].target = "/changed-output"
            test.eq(config.Cmd[1], "/usr/bin/codex")
            test.eq(config.Labels["bee.attempt_id"], "attempt")
            test.eq(config.HostConfig.Binds[3], "/projects/output:/output:rw")
            mounts[1].access = "write"
            local writable = configuration.build(raw)
            if not writable then error("write access refused") end
            test.eq(writable.HostConfig.Binds[2], "/projects/demo:/workspace:rw")
            local second_workdir = input(); second_workdir.working_directory = "/output/build"
            local second_config = configuration.build(second_workdir)
            if not second_config then error("second mount workdir refused") end
            test.eq(second_config.WorkingDir, "/output/build")
            local max = input()
            local max_mounts = max.mounts :: {Object}
            for index = 3, 15 do
                max_mounts[index] = {source = "/projects/mount" .. tostring(index), target = "/mount" .. tostring(index), access = index % 2 == 0 and "read" or "write"}
            end
            local bounded = configuration.build(max)
            if not bounded then error("15 mounts refused") end
            test.eq(#bounded.HostConfig.Binds, 16)
            max_mounts[16] = {source = "/projects/mount16", target = "/mount16", access = "read"}
            test.is_nil(configuration.build(max))
        end)
        test.it("refuses mount escapes, overlap and private home exposure", function()
            local cases: {{field: string, value: unknown}} = {
                {field = "mounts", value = {{source = "/private", target = "/workspace", access = "read"}}},
                {field = "home_source", value = "/projects/demo/.wippy/home"},
                {field = "mounts", value = {{source = "/projects/demo", target = "/", access = "read"}}},
                {field = "mounts", value = {{source = "/run/docker.sock", target = "/workspace", access = "read"}}},
                {field = "mounts", value = {{source = "/projects/../private", target = "/workspace", access = "read"}}},
                {field = "mounts", value = {{source = "/projects/other", target = "/home", access = "read"}}},
                {field = "mounts", value = {{source = "/projects/other", target = "/tmp/project", access = "read"}}},
                {field = "home_target", value = "/tmp"},
                {field = "home_target", value = "/workspace/home"},
                {field = "working_directory", value = "/workspace-other"},
                {field = "working_directory", value = "/workspace/../home"},
                {field = "home_source", value = "/private:rw"},
                {field = "home_source", value = "/private\nhome"},
                {field = "mounts", value = {{source = "/projects/one", target = "/workspace", access = "read"},
                    {source = "/projects/two", target = "/workspace/nested", access = "write"}}},
                {field = "mounts", value = {[1] = {source = "/projects/one", target = "/workspace", access = "read"}, [3] = {source = "/projects/two", target = "/output", access = "write"}}},
                {field = "mounts", value = {{source = "/projects/one", target = "/workspace", access = "read", metadata = "ignored"}}},
                {field = "mounts", value = {[1] = {source = "/projects/one", target = "/workspace", access = "read"}, metadata = "ignored"}},
            }
            for _, case in ipairs(cases) do
                local raw = input(); raw[case.field] = case.value
                local config, err = configuration.build(raw)
                test.is_nil(config); test.is_true(err ~= nil)
            end
        end)
        test.it("delivers admitted environment without changing it or container-owned paths", function()
            local raw = input()
            raw.home_target = raw.home_source
            local environment: Object = {HOME = raw.home_source, BEE_GATEWAY_TOKEN = "fixture-token", EMPTY = "", VALUE = "a=b\nsecond line"}
            local config, err = configuration.build(raw, environment)
            if not config then error(tostring(err)) end
            test.eq(config.HostConfig.Binds[1], "/private/session/home:/private/session/home:rw")
            test.eq(config.Env[1], "BEE_GATEWAY_TOKEN=fixture-token")
            test.eq(config.Env[2], "EMPTY=")
            test.eq(config.Env[3], "HOME=/private/session/home")
            test.eq(config.Env[4], "TMPDIR=/tmp")
            test.eq(config.Env[5], "VALUE=a=b\nsecond line")
            test.is_nil(raw.environment)
            environment.BEE_GATEWAY_TOKEN = "changed"
            test.eq(config.Env[1], "BEE_GATEWAY_TOKEN=fixture-token")
            test.is_nil(rawget(environment, "TMPDIR"))
            local maximum: Object = {}
            for index = 1, 62 do maximum["VAR_" .. tostring(index)] = "" end
            local bounded = configuration.build(raw, maximum)
            if not bounded then error("64 environment entries refused") end
            test.eq(#bounded.Env, 64)
            maximum.EXTRA = ""
            test.is_nil(configuration.build(raw, maximum))
            local invalid: {unknown} = {
                "not an object", {HOME = "/other"}, {TMPDIR = "/other"}, {TOKEN = "a\0b"},
                {TOKEN = 3}, {["A=B"] = "bad"}, {[1] = "bad"}, {TOKEN = string.rep("a", 16385)},
                {A = string.rep("a", 16384), B = string.rep("a", 16384), C = string.rep("a", 16384), D = string.rep("a", 16384)},
            }
            for _, value in ipairs(invalid) do
                test.is_nil(configuration.build(raw, value))
            end
            raw.environment = environment
            test.is_nil(configuration.build(raw))
        end)
        test.it("refuses implicit authority, mutable images and malformed profile values", function()
            local cases: {{field: string, value: unknown}} = {
                {field = "image", value = "alpine:latest"}, {field = "user", value = "0:0"},
                {field = "apparmor", value = "unconfined"}, {field = "network", value = "host"},
                {field = "network", value = "default"}, {field = "network", value = "container:other"},
                {field = "memory", value = 0}, {field = "nano_cpus", value = 0.5},
                {field = "pids_limit", value = -1},
                {field = "mounts", value = {{source = "/projects/one", target = "/workspace", access = "owner"}}},
                {field = "mounts", value = {}},
                {field = "mounts", value = {[1] = {source = "/projects/one", target = "/workspace", access = "read"}, [16] = {source = "/projects/sixteen", target = "/sixteen", access = "read"}}},
                {field = "privileged", value = true},
                {field = "command", value = {"relative"}}, {field = "command", value = {[1] = "/bin/sh", [3] = "gap"}},
            }
            for _, case in ipairs(cases) do
                local raw = input(); raw[case.field] = case.value
                local config, err = configuration.build(raw)
                test.is_nil(config); test.is_true(err ~= nil)
            end
            for _, field in ipairs({"workspace_source", "workspace_target", "workspace_access"}) do
                local raw = input(); raw[field] = "/legacy"
                test.is_nil(configuration.build(raw))
            end
            local raw = input()
            local labels = raw.labels :: Object
            labels["bee.image_digest"] = "sha256:" .. string.rep("b", 64)
            test.is_nil(configuration.build(raw))
        end)
    end)
end
return test.run_cases(define_tests)
