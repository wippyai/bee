-- SPDX-License-Identifier: MIT
local test = require("test")
local format = require("format")
local function decode(file: unknown): format.Format?
    return format.decode({schema_revision = format.REVISION, file = file})
end
local function define_tests()
    test.describe("Host-selected credential formats", function()
        test.it("keeps environment and nested opaque login formats declarative", function()
            local environment, env_error = format.decode({schema_revision = format.REVISION, environments = {"ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN"}})
            if not environment then error(tostring(env_error)) end
            test.eq(#environment.environments, 2)
            test.eq(environment.environments[1], "ANTHROPIC_API_KEY")
            test.eq(environment.environments[2], "CLAUDE_CODE_OAUTH_TOKEN")
            test.is_nil(environment.file)
            local login = decode({path = ".gemini/antigravity-cli/antigravity-oauth-token", content_format = "opaque"})
            if not login or not login.file then error("nested opaque format rejected") end
            test.eq(login.file.path, ".gemini/antigravity-cli/antigravity-oauth-token")
            test.eq(#login.file.initialize, 0)
            local initialized = decode({path = ".claude/.credentials.json", content_format = "json",
                initialize = {{path = ".claude.json", content = '{"hasCompletedOnboarding":true}'}}})
            if not initialized or not initialized.file then error("initialization rejected") end
            test.eq(initialized.file.initialize[1].path, ".claude.json")
        end)
        test.it("refuses ambiguous, escaping and unbounded destinations", function()
            for _, path in ipairs({"", "/token", "../token", "a/../token", "a/./token", "a//token", "a/", "a\\token", "a\0token", string.rep("a", 513)}) do
                test.is_nil(decode({path = path, content_format = "opaque"}))
            end
            test.is_nil(decode({path = "token", content_format = "unknown"}))
            test.is_nil(decode({path = "token", content_format = "json", extra = true}))
            test.is_nil(format.decode({schema_revision = format.REVISION, environments = {"bad-name"}}))
            test.is_nil(format.decode({schema_revision = format.REVISION, environments = {string.rep("A", 129)}}))
            test.is_nil(format.decode({schema_revision = format.REVISION, environments = {"A", "B", "C", "D", "E", "F", "G", "H", "I"}}))
            test.is_nil(format.decode({schema_revision = format.REVISION, environments = "KEY"}))
            test.is_nil(format.decode({schema_revision = format.REVISION}))
            test.is_nil(format.decode({schema_revision = format.REVISION, environments = {}}))
            test.is_nil(format.decode({schema_revision = "bee.credential-format@1", environment_destination = "KEY"}))
        end)
        test.it("bounds initialization and refuses collisions and sparse lists", function()
            test.is_nil(decode({path = "token", content_format = "opaque", initialize = {{path = "token", content = "x"}}}))
            test.is_nil(decode({path = "token", content_format = "opaque", initialize = {{path = "state", content = "a"}, {path = "state", content = "b"}}}))
            test.is_nil(decode({path = "token", content_format = "opaque", initialize = {[2] = {path = "state", content = "a"}}}))
            test.is_nil(decode({path = "token", content_format = "opaque", initialize = {unexpected = true}}))
            test.not_nil(decode({path = "token", content_format = "opaque", initialize = {{path = "state", content = string.rep("x", 65536)}}}))
            test.is_nil(decode({path = "token", content_format = "opaque", initialize = {{path = "state", content = string.rep("x", 65537)}}}))
            test.is_nil(decode({path = "token", content_format = "opaque", initialize = {{path = "state", content = "x", on_missing_login = "yes"}}}))
            local files: {{path: string, content: string}} = {}
            for index = 1, 5 do files[index] = {path = "state" .. tostring(index), content = ""} end
            test.is_nil(decode({path = "token", content_format = "opaque", initialize = files}))
            local large: {{path: string, content: string}} = {}
            for index = 1, 3 do large[index] = {path = "state" .. tostring(index), content = string.rep("x", 22000)} end
            test.is_nil(decode({path = "token", content_format = "opaque", initialize = large}))
        end)
        test.it("refuses file and directory collisions in either declaration order", function()
            test.is_nil(decode({path = "login/token", content_format = "opaque", initialize = {{path = "login", content = "x"}}}))
            test.is_nil(decode({path = "login", content_format = "opaque", initialize = {{path = "login/state", content = "x"}}}))
            for _, paths in ipairs({{"state", "state/config"}, {"state/config", "state"}}) do
                test.is_nil(decode({path = "token", content_format = "opaque", initialize = {
                    {path = paths[1], content = "x"}, {path = paths[2], content = "y"}}}))
            end
            local siblings = decode({path = "login/token", content_format = "opaque", initialize = {
                {path = "login/state", content = "x"}, {path = "login-extra/state", content = "y"}}})
            if not siblings then error("nonoverlapping files rejected") end
        end)
    end)
end
return test.run_cases(define_tests)
