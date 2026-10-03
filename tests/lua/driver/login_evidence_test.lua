-- MIT. Window launches declare where their provider looks for login evidence.
local test = require("test")
local principals = require("principals")
local bounds = require("bounds")
local codex = require("codex_launch")
local claude = require("claude_launch")
local agy = require("agy_launch")
local grok = require("grok_launch")
local muse = require("muse_launch")
local opencode = require("opencode_launch")
local registry = require("registry")
local universal = require("universal")
local materialization = require("materialization")
local placement_types = require("placement_types")

local function define_tests()
    test.describe("Provider window login declarations", function()
        local cases = {
            {launch = codex.specification(assert(codex.decode({profile_id = "window", brief = ""}))), provider = "codex", command = "codex login", variable = "CODEX_HOME", directory = ".codex", path = "auth.json"},
            {launch = claude.specification(assert(claude.decode({profile_id = "window", brief = ""}))), provider = "claude", command = "claude auth login", variable = "CLAUDE_CONFIG_DIR", directory = ".claude", path = ".credentials.json"},
            {launch = agy.specification(assert(agy.decode({profile_id = "window", brief = ""}))), provider = "agy", command = "agy", variable = "HOME", path = ".gemini/antigravity-cli/antigravity-oauth-token"},
            {launch = grok.specification(assert(grok.decode({profile_id = "window", brief = ""}))), provider = "grok", command = "grok login", variable = "GROK_HOME", directory = ".grok", path = "auth.json"},
            {launch = muse.specification(assert(muse.decode({profile_id = "window", brief = ""}))), provider = "muse", command = "muse login", variable = "XDG_CONFIG_HOME", directory = ".config", path = "muse/auth.json"},
            {launch = opencode.specification(assert(opencode.decode({profile_id = "window", brief = ""}))), provider = "opencode", command = "opencode auth login", variable = "XDG_DATA_HOME", directory = ".local/share", path = "opencode/auth.json"},
        }
        for _, case in ipairs(cases) do
            test.it(case.provider .. " declares its window login evidence", function()
                local login = case.launch.login
                if not login then error("missing login declaration") end
                local entry = assert(registry.get("bee.driver." .. case.provider .. ".profiles:default_window"))
                local definition = assert(bounds.object(entry.data))
                local policy = assert(registry.get(tostring(definition.policy_ref)))
                local policy_data = policy.data
                local private = case.provider == "grok"
                if private then
                    local credentials = principals.strings(definition.credentials)
                    test.eq(credentials[1], "grok_login")
                    test.is_true(policy_data.allow_host_home ~= true)
                else test.eq(policy_data.allow_host_home, true) end
                local home = assert(case.launch.provider_home)
                test.eq(home.private, private)
                local profiles = assert(registry.get("bee.driver." .. case.provider .. ".profiles:profiles"))
                local profile_data = profiles.data
                for _, profile in ipairs(profile_data.driver.profiles) do
                    if profile.id == "window" then test.eq(profile.isolation_env.private_home, private) end
                end
                test.eq(login.provider, case.provider)
                test.eq(login.command, case.command)
                test.is_true(#login.files >= 1)
                test.not_nil(login.any_of)
                test.eq(login.files[1].variable, case.variable)
                test.eq(login.files[1].default_directory, case.directory)
                test.eq(login.files[1].path, case.path)
                local found = assert(universal.locate("bee.driver." .. case.provider .. ".descriptor:cli")({
                    profile_id = "window", configured = true, executable = {present = true, version = "1.2.3"},
                    login_checks = (function(): {{present: boolean?, exit_code: integer?}}
                        local checks: {{present: boolean?, exit_code: integer?}} = {}
                        for index in ipairs(login.any_of or {}) do checks[index] = {present = index == 1 and true or nil} end
                        return checks
                    end)(), platform = {os = "linux", arch = "x86_64", compatible = true}}))
                test.eq(found.status, "ready")
                local request: placement_types.LaunchRequest = {
                    idempotency_key = "default-login", attempt_id = "default-login", action_id = "default-login",
                    owner_id = "bee.test.default-login", owner_incarnation = 1,
                    binding_ref = tostring(definition.binding_ref), policy_ref = tostring(definition.policy_ref),
                    profile_id = "window", binding_digest = string.rep("b", 64), profile_digest = string.rep("c", 64),
                    launch = case.launch, resources = {}, environment = {}, projections = {},
                    environment_refs = private and {} or {HOME = "bee.env:machine_home"}, required_cleanup = "process_group",
                    required_exit_observation = "independent",
                    timeouts = {stop_grace_ms = 100, drain_ms = 1000, retain_ms = 1000}}
                local selected_home = private and "/fixture-attempt-home" or "/fixture-machine-home"
                local expected = selected_home .. "/" .. (case.directory and (case.directory .. "/") or "") .. case.path
                local notice = materialization.login_notice(request, selected_home, function(path: string): boolean
                    test.eq(path, expected)
                    return true
                end)
                test.is_nil(notice)
                if private then
                    test.is_nil(materialization.login_notice(request, selected_home, function(_path: string): boolean
                        error("projected login must not require another host read")
                    end, expected))
                end
                local missing = materialization.login_notice(request, selected_home, function(_path: string): boolean
                    return false
                end)
                test.is_nil(missing, "unobserved environment/status alternatives cannot establish missing login")
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
                paths = {{".codex/auth.json", ".codex/auth.json", "login", true}, {".codex/config.toml", ".codex/.bee-user-config.toml", "config", false}}},
            {provider = "agy", launch = agy.specification(assert(agy.decode({profile_id = "batch", brief = "fixture"}))),
                paths = {{".gemini/antigravity-cli/antigravity-oauth-token", ".gemini/antigravity-cli/antigravity-oauth-token", "login", true},
                    {".gemini/antigravity-cli/cache/onboarding.json", ".gemini/antigravity-cli/cache/onboarding.json", "config", false}}},
            {provider = "grok", launch = grok.specification(assert(grok.decode({profile_id = "batch", brief = "fixture", permission_mode = "default"}))),
                paths = {{".grok/auth.json", ".grok/auth.json", "login", true}, {".grok/config.toml", ".grok/.bee-global-config.toml", "config", false}}},
            {provider = "muse", launch = muse.specification(assert(muse.decode({profile_id = "batch", brief = "fixture", approval_mode = "never"}))),
                paths = {{".config/muse/auth.json", ".config/muse/auth.json", "login", true},
                    {".config/muse/settings.json", ".config/muse/.bee-global-settings.json", "config", false}}},
            {provider = "opencode", launch = opencode.specification(assert(opencode.decode({profile_id = "batch", brief = "fixture"}))),
                paths = {{".local/share/opencode/auth.json", ".local/share/opencode/auth.json", "login", true},
                    {".config/opencode/opencode.json", ".config/opencode/.bee-global-opencode.json", "config", false},
                    {".config/opencode/towers.key", ".config/opencode/towers.key", "config", false}}},
        }
        for _, case in ipairs(cases) do
            test.it(case.provider .. " declares its exact private provider files", function()
                local home = assert(bounds.object(case.launch.provider_home))
                test.eq(home.provider, case.provider)
                test.eq(home.private, true)
                local files = principals.objects(home.files)
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
            local home = assert(bounds.object(opencode.specification(assert(opencode.decode({profile_id = "batch", brief = "fixture"}))).provider_home))
            local variables = principals.objects(home.extra_variables)
            test.eq(#variables, 2)
            test.eq(variables[1].variable, "XDG_CONFIG_HOME")
            test.eq(variables[1].directory, ".config")
            test.eq(variables[2].variable, "XDG_DATA_HOME")
            test.eq(variables[2].directory, ".local/share")
        end)
    end)
end
return test.run_cases(define_tests)
