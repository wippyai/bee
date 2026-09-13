-- SPDX-License-Identifier: MIT
local test = require("test")
local configuration = require("configuration")
type Object = {[string]: unknown}
local function input(): Object
    local image = "sha256:" .. string.rep("a", 64)
    return {image = image, user = "1000:1000", network = "bee-agents", apparmor = "docker-default",
        memory = 536870912, nano_cpus = 1000000000, pids_limit = 128,
        command = {"/usr/bin/codex", "a task with spaces"}, home_source = "/private/session/home", home_target = "/home/bee",
        workspace_source = "/projects/demo", workspace_target = "/workspace", workspace_access = "read", working_directory = "/workspace/src",
        labels = {["bee.actor_ref"] = "actor", ["bee.revision_digest"] = string.rep("b", 64), ["bee.attempt_id"] = "attempt",
            ["bee.request_digest"] = string.rep("c", 64), ["bee.lease_fence"] = "1", ["bee.image_digest"] = image}}
end
local function define_tests()
    test.describe("Docker preparation", function()
        test.it("projects explicit mounts and preserves command arguments without a shell", function()
            local raw = input()
            local config, err = configuration.build(raw)
            if not config then error(tostring(err)) end
            test.eq(config.Cmd[2], "a task with spaces")
            test.eq(config.Env[1], "HOME=/home/bee")
            test.eq(config.WorkingDir, "/workspace/src")
            test.eq(config.HostConfig.Binds[1], "/private/session/home:/home/bee:rw")
            test.eq(config.HostConfig.Binds[2], "/projects/demo:/workspace:ro")
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
            test.eq(config.Cmd[1], "/usr/bin/codex")
            test.eq(config.Labels["bee.attempt_id"], "attempt")
            raw.workspace_access = "write"
            local writable = configuration.build(raw)
            if not writable then error("write access refused") end
            test.eq(writable.HostConfig.Binds[2], "/projects/demo:/workspace:rw")
        end)
        test.it("refuses mount escapes, overlap and private home exposure", function()
            local cases: {{field: string, value: unknown}} = {
                {field = "workspace_source", value = "/private"},
                {field = "home_source", value = "/projects/demo/.wippy/home"},
                {field = "workspace_source", value = "/"},
                {field = "workspace_source", value = "/run/docker.sock"},
                {field = "workspace_source", value = "/projects/../private"},
                {field = "workspace_target", value = "/home"},
                {field = "workspace_target", value = "/tmp/project"},
                {field = "home_target", value = "/workspace/home"},
                {field = "working_directory", value = "/workspace-other"},
                {field = "working_directory", value = "/workspace/../home"},
                {field = "home_source", value = "/private:rw"},
                {field = "home_source", value = "/private\nhome"},
            }
            for _, case in ipairs(cases) do
                local raw = input(); raw[case.field] = case.value
                local config, err = configuration.build(raw)
                test.is_nil(config); test.is_true(err ~= nil)
            end
        end)
        test.it("refuses implicit authority, mutable images and malformed profile values", function()
            local cases: {{field: string, value: unknown}} = {
                {field = "image", value = "alpine:latest"}, {field = "user", value = "0:0"},
                {field = "apparmor", value = "unconfined"}, {field = "network", value = "host"},
                {field = "network", value = "bridge"}, {field = "network", value = "container:other"},
                {field = "memory", value = 0}, {field = "nano_cpus", value = 0.5},
                {field = "pids_limit", value = -1}, {field = "workspace_access", value = "owner"},
                {field = "environment", value = {TOKEN = "not-admitted"}}, {field = "privileged", value = true},
                {field = "command", value = {"relative"}}, {field = "command", value = {[1] = "/bin/sh", [3] = "gap"}},
            }
            for _, case in ipairs(cases) do
                local raw = input(); raw[case.field] = case.value
                local config, err = configuration.build(raw)
                test.is_nil(config); test.is_true(err ~= nil)
            end
            local raw = input()
            local labels = raw.labels :: Object
            labels["bee.image_digest"] = "sha256:" .. string.rep("b", 64)
            test.is_nil(configuration.build(raw))
        end)
    end)
end
return test.run_cases(define_tests)
