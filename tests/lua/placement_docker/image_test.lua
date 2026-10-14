-- SPDX-License-Identifier: MIT
local test = require("test")
local image = require("image")
local daemon = require("daemon")
local function recipe(): {[string]: unknown}
    return {schema_revision = "bee.runtime-recipe@1", base = "node@sha256:" .. string.rep("a", 64),
        artifacts = {{name = "fixture", executable_ref = "bee.test:executable", candidates = {"../vendor/bin/fixture"}}}}
end
local function run()
    test.describe("Runtime image recipes", function()
        test.it("waits for a slow daemon operation and preserves a command's exact failure", function()
            local output, err = daemon.command({"/bin/sh", "-c", "sleep 6; printf ready"})
            test.eq(output, "ready"); test.is_nil(err)
            output, err = daemon.command({"/bin/sh", "-c", "printf 'daemon denied fixture operation' >&2; exit 42"})
            test.is_nil(output)
            test.not_nil(err)
            test.is_true(assert(err):find("exit 42: daemon denied fixture operation", 1, true) ~= nil)
        end)
        test.it("distinguishes a daemon's absent image from daemon failures without guessing elapsed time", function()
            local value, err, absent = daemon.decode_response('{"message":"No such image: fixture"}\n404')
            test.is_nil(value); test.eq(absent, true); test.eq(err, "Docker HTTP 404: No such image: fixture")
            value, err, absent = daemon.decode_response('{"message":"daemon failed inspecting fixture"}\n500')
            test.is_nil(value); test.eq(absent, false); test.eq(err, "Docker HTTP 500: daemon failed inspecting fixture")
            value, err = daemon.decode_response('{"Id":"fixture"}\n200')
            test.not_nil(value); test.is_nil(err)
        end)
        test.it("retains multiline build failures instead of returning an empty successful result", function()
            local detail = "docker exit 1: failed to fetch digest-pinned base\nconnection refused\n"
            for _, operation in ipairs({"build", "environment"}) do
                local output, route, failure = image.decode_result({error = detail}, operation == "build" and nil or operation)
                test.is_nil(output); test.is_nil(route); test.eq(failure, detail)
            end
        end)
        test.it("measures Linux ELF architecture rather than assuming the host platform", function()
            local prefix = "\127ELF" .. string.char(2, 1) .. string.rep("\0", 12)
            test.eq(image.artifact_arch(prefix .. string.char(62, 0)), "amd64")
            test.eq(image.artifact_arch(prefix .. string.char(183, 0)), "arm64")
            test.is_nil(image.artifact_arch("#!/bin/sh"))
            test.is_nil(image.artifact_arch(prefix .. string.char(3, 0)))
        end)
        test.it("refuses a replaced cached tag or mismatched artifact labels", function()
            local digest = string.rep("a", 64)
            local inputs = {{name = "fixture", source = "/host/fixture", digest = string.rep("b", 64)}}
            local labels: {[string]: string} = {["bee.actor_ref"] = "bee.runtime-image", ["bee.attempt_id"] = digest,
                ["bee.runtime.fixture"] = inputs[1].digest}
            local value = {Id = "sha256:" .. string.rep("c", 64), Os = "linux", Architecture = "amd64", Config = {Labels = labels}}
            test.eq(image.verified_image(value, digest, inputs, "amd64"), value.Id)
            test.is_nil(image.verified_image(value, digest, inputs, "arm64"))
            labels["bee.runtime.fixture"] = string.rep("d", 64)
            test.is_nil(image.verified_image(value, digest, inputs, "amd64"))
        end)
        test.it("requires an immutable base and bounded installed executable sources", function()
            test.not_nil(image.decode(recipe()))
            local value = recipe(); value.base = "node:latest"
            test.is_nil(image.decode(value))
            value = recipe(); value.artifacts = {{name = "fixture", executable_ref = "bee.test:executable", candidates = {"/host/secret"}}}
            test.is_nil(image.decode(value))
            value = recipe(); value.credentials = "host-home"
            test.is_nil(image.decode(value))
        end)
    end)
end
return test.run_cases(run)
