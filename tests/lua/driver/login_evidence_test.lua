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
end
return test.run_cases(define_tests)
