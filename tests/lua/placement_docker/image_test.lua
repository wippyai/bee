-- SPDX-License-Identifier: MIT
local test = require("test")
local image = require("image")
local function recipe(): {[string]: unknown}
    return {schema_revision = "bee.runtime-recipe@1", base = "node@sha256:" .. string.rep("a", 64),
        artifacts = {{name = "fixture", executable_ref = "bee.test:executable", candidates = {"../vendor/bin/fixture"}}}}
end
local function run()
    test.describe("Runtime image recipes", function()
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
