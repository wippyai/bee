-- SPDX-License-Identifier: MIT
local test = require("test")
local projection = require("projection")
local formats = require("formats")
local types = require("types")
local function home(clean: string?): types.ProviderHome
    return {provider = "fixture", private = true, variable = nil, directory = nil, files = {
        {source_path = "login.json", path = "login.json", kind = "login", optional = true, write_back = true},
        {source_path = "config.toml", path = "config.toml", kind = "config", optional = true, write_back = false, container_content = clean}}}
end
local function format(content: string): formats.Format
    return {schema_revision = "bee.credential-format@1", file = {path = "login.json", content_format = "json",
        initialize = {{path = "config.toml", source_path = "config.toml", content = content}}}}
end
local function run()
    test.describe("Container provider projections", function()
        test.it("uses declared clean config without changing the broker format or login", function()
            local original = format('key_command = ["cat", "/host/key"]')
            local result = assert(projection.container(home(""), original, {"/workspace"}))
            test.eq(assert(result.file).initialize[1].content, "")
            test.eq(assert(original.file).initialize[1].content, 'key_command = ["cat", "/host/key"]')
            test.eq(assert(result.file).path, "login.json")
        end)
        test.it("refuses commands and host paths before child creation without exposing config values", function()
            for _, content in ipairs({'key_command = ["cat", "/host/key"]', 'include = "/host/key"', 'file = "~/host-key"', 'file = "/workspace/../host/key"'}) do
                local result, reason = projection.container(home(nil), format(content), {"/workspace"})
                test.is_nil(result); test.not_nil(reason)
                test.is_nil((assert(reason):find("/host/key", 1, true)))
            end
        end)
        test.it("keeps portable admitted inline config and mounted container paths", function()
            local result = assert(projection.container(home(nil), format('model = "fixture"\nworkdir = "/workspace"'), {"/workspace"}))
            test.eq(assert(result.file).initialize[1].content, 'model = "fixture"\nworkdir = "/workspace"')
        end)
    end)
end
return test.run_cases(run)
