-- MIT. Window launches declare where their provider looks for login evidence.
local test = require("test")
local codex = require("codex_launch")
local claude = require("claude_launch")
local agy = require("agy_launch")
local grok = require("grok_launch")
local muse = require("muse_launch")
local opencode = require("opencode_launch")

local function define_tests()
    test.describe("Provider window login declarations", function()
        local cases = {
            {launch = codex.specification(assert(codex.decode({profile_id = "window", brief = ""}))), provider = "codex", command = "codex login", variable = "CODEX_HOME", directory = ".codex", path = "auth.json"},
            {launch = claude.specification(assert(claude.decode({profile_id = "window", brief = ""}))), provider = "claude", command = "claude", variable = "CLAUDE_CONFIG_DIR", directory = ".claude", path = ".credentials.json"},
            {launch = agy.specification(assert(agy.decode({profile_id = "window", brief = ""}))), provider = "agy", command = "agy", variable = "HOME", path = ".gemini/antigravity-cli/antigravity-oauth-token"},
            {launch = grok.specification(assert(grok.decode({profile_id = "window", brief = ""}))), provider = "grok", command = "grok", variable = "GROK_HOME", directory = ".grok", path = "auth.json"},
            {launch = muse.specification(assert(muse.decode({profile_id = "window", brief = ""}))), provider = "muse", command = "muse", variable = "HOME", path = ".config/muse/auth.json"},
            {launch = opencode.specification(assert(opencode.decode({profile_id = "window", brief = ""}))), provider = "opencode", command = "opencode auth login", variable = "HOME", path = ".local/share/opencode/auth.json"},
        }
        for _, case in ipairs(cases) do
            test.it(case.provider .. " declares its window login evidence", function()
                local login = case.launch.login
                if not login then error("missing login declaration") end
                test.eq(login.provider, case.provider)
                test.eq(login.command, case.command)
                test.eq(#login.files, 1)
                test.eq(login.files[1].variable, case.variable)
                test.eq(login.files[1].default_directory, case.directory)
                test.eq(login.files[1].path, case.path)
            end)
        end
    end)
    test.describe("Provider private-home declarations", function()
        local cases = {
            {provider = "claude", launch = claude.specification(assert(claude.decode({profile_id = "batch", brief = "fixture"}))),
                paths = {{".claude/.credentials.json", ".claude/.credentials.json", "login", true},
                    {".claude/settings.json", ".claude/settings.json", "config", false},
                    {"", ".claude.json", "state", false}}},
            {provider = "codex", launch = codex.specification(assert(codex.decode({profile_id = "batch", brief = "fixture"}))),
                paths = {{".codex/auth.json", ".codex/auth.json", "login", true}, {".codex/config.toml", ".codex/config.toml", "config", false}}},
            {provider = "agy", launch = agy.specification(assert(agy.decode({profile_id = "batch", brief = "fixture"}))),
                paths = {{".gemini/antigravity-cli/antigravity-oauth-token", ".gemini/antigravity-cli/antigravity-oauth-token", "login", true},
                    {".gemini/antigravity-cli/cache/onboarding.json", ".gemini/antigravity-cli/cache/onboarding.json", "config", false}}},
            {provider = "grok", launch = grok.specification(assert(grok.decode({profile_id = "batch", brief = "fixture", permission_mode = "default", turn_budget = 1}))),
                paths = {{".grok/auth.json", ".grok/auth.json", "login", true}, {".grok/config.toml", ".grok/.bee-global-config.toml", "config", false}}},
            {provider = "muse", launch = muse.specification(assert(muse.decode({profile_id = "batch", brief = "fixture", approval_mode = "never"}))),
                paths = {{".config/muse/auth.json", ".config/muse/auth.json", "login", true},
                    {".config/muse/settings.json", ".config/muse/.bee-global-settings.json", "config", false}}},
            {provider = "opencode", launch = opencode.specification(assert(opencode.decode({profile_id = "batch", brief = "fixture"}))),
                paths = {{".local/share/opencode/auth.json", ".local/share/opencode/auth.json", "login", true},
                    {".config/opencode/opencode.json", ".config/opencode/.bee-global-opencode.json", "config", false}}},
        }
        for _, case in ipairs(cases) do
            test.it(case.provider .. " declares its exact private provider files", function()
                local home = case.launch.provider_home :: {[string]: unknown}
                test.eq(home.provider, case.provider)
                test.eq(home.private, true)
                local files = home.files :: {{[string]: unknown}}
                test.eq(#files, #case.paths)
                for index, expected in ipairs(case.paths) do
                    if expected[1] == "" then test.is_nil(files[index].source_path)
                    else test.eq(files[index].source_path, expected[1]) end
                    test.eq(files[index].path, expected[2])
                    test.eq(files[index].kind, expected[3])
                    test.eq(files[index].write_back, expected[4])
                    test.eq(files[index].optional, true)
                end
            end)
        end
        test.it("places OpenCode XDG config and data roots inside the private home", function()
            local home = opencode.specification(assert(opencode.decode({profile_id = "batch", brief = "fixture"}))).provider_home :: {[string]: unknown}
            local variables = home.extra_variables :: {{[string]: unknown}}
            test.eq(#variables, 2)
            test.eq(variables[1].variable, "XDG_CONFIG_HOME")
            test.eq(variables[1].directory, ".config")
            test.eq(variables[2].variable, "XDG_DATA_HOME")
            test.eq(variables[2].directory, ".local/share")
        end)
    end)
end
return test.run_cases(define_tests)
