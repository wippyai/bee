-- MIT. A saved Codex config profile is only usable where the host offers the
-- field AND the launch can see the inherited Codex home. This pins the shipped
-- policy wiring (the reachability gap a rendering assertion cannot see) and
-- the refusals that must hold without a provider.
local test = require("test")
local registry = require("registry")
local policy = require("policy")
local preferences = require("preferences")
local launch = require("launch")
local claude_launch = require("claude_launch")
local materialization = require("materialization")
local machine = require("machine")
local types = require("types")
local driver_types = require("driver_types")

local CODEX_WINDOW = "bee:launch_policy_codex_window"
local CODEX_BATCH = "bee:launch_policy_codex_batch"
local CODEX_NAMED_BATCH = "bee:launch_policy_codex_named_batch"
local CLAUDE_WINDOW = "bee:launch_policy_claude_window"
local CLAUDE_BATCH = "bee:launch_policy_claude_batch"
local PROFILE = "ds-flash"

local function raw_policy(ref: string): {[string]: unknown}
    local entry = registry.get(ref)
    if not entry then error("missing launch policy " .. ref) end
    local data = entry.data :: {[string]: unknown}
    if not data then error("launch policy " .. ref .. " has no data") end
    return data
end

local function decoded(ref: string): policy.Policy
    local value, err = policy.decode(ref, registry.get(ref))
    if not value then error(ref .. ": " .. tostring(err)) end
    return value
end

local function selected(): preferences.Value
    local value, err = preferences.decode({options = {config_profile = PROFILE}, mcp_tools = {}, instructions = ""})
    if not value then error(tostring(err)) end
    return value
end

local function launch_request(required: {driver_types.RequiredFile}?, environment: {[string]: string}?, refs: {[string]: string}?): types.LaunchRequest
    local value: driver_types.Launch = {executable = "codex", argv = {}, environment = {}, readiness = "terminal:attached"}
    if required then value.required_files = required end
    local request: types.LaunchRequest = {idempotency_key = "k", attempt_id = "a", owner_id = "bee.harness.catalog:codex_profile_test", owner_incarnation = 1, action_id = "a",
        binding_ref = "bee.driver.codex:binding", policy_ref = CODEX_NAMED_BATCH, profile_id = "named_batch", binding_digest = string.rep("b", 64),
        profile_digest = string.rep("c", 64), launch = value, resources = {}, environment = environment or {}, environment_refs = refs or {}, projections = {},
        required_cleanup = "process_group", required_exit_observation = "independent",
        timeouts = {start_ms = 1000, stop_grace_ms = 100, drain_ms = 1000, retain_ms = 1000}}
    return request
end

local function define_tests()
    test.describe("Saved Codex config profile reachability", function()
        test.it("offers the field only on Codex policies whose launch can see the inherited Codex home", function()
            -- The field is Codex-only and only meaningful where the named
            -- file can exist: a policy that inherits the host Codex home.
            test.eq((raw_policy(CODEX_WINDOW).profile_options :: {[string]: unknown}).config_profile.kind, "text")
            test.eq((raw_policy(CODEX_NAMED_BATCH).profile_options :: {[string]: unknown}).config_profile.kind, "text")
            -- A Claude policy must never advertise a Codex-only field.
            test.is_nil((raw_policy(CLAUDE_WINDOW).profile_options :: {[string]: unknown}).config_profile)
            test.is_nil((raw_policy(CLAUDE_BATCH).profile_options :: {[string]: unknown}).config_profile)
            -- The Codex window profile inherits the host home, so the named
            -- file it declares can resolve there.
            local codex, codex_error = registry.get("bee.driver.codex:profiles")
            if not codex then error(tostring(codex_error)) end
            local driver = (codex.data :: {[string]: unknown}).driver :: {[string]: unknown}
            local window: {[string]: unknown}? = nil
            for _, item in ipairs(driver.profiles :: {{[string]: unknown}}) do
                if item.id == "window" then window = item end
            end
            if not window then error("codex window profile is missing") end
            test.is_false((window.isolation_env :: {[string]: unknown}).private_home)
        end)

        test.it("accepts the named profile into the shipped Codex window policy and refuses it on Claude", function()
            local accepted, accepted_error = preferences.apply(raw_policy(CODEX_WINDOW), selected())
            if not accepted then error("codex window refused the named profile: " .. tostring(accepted_error)) end
            test.eq((accepted.prepare_options :: {[string]: unknown}).config_profile, PROFILE)
            local named, named_error = preferences.apply(raw_policy(CODEX_NAMED_BATCH), selected())
            if not named then error("codex named batch refused the named profile: " .. tostring(named_error)) end
            test.eq((named.prepare_options :: {[string]: unknown}).config_profile, PROFILE)
            -- A non-Codex driver refuses the field: its policy never enables
            -- it, and its driver has no such launch field.
            test.is_nil(preferences.apply(raw_policy(CLAUDE_WINDOW), selected()))
            test.is_nil(preferences.apply(raw_policy(CLAUDE_BATCH), selected()))
            local claude, claude_error = claude_launch.decode({profile_id = "window", brief = "", permission_mode = "default", max_turns = 1, config_profile = PROFILE})
            test.is_nil(claude)
            test.is_true(tostring(claude_error):find("config_profile", 1, true) ~= nil)
            -- Even if a host accidentally offers the generic text option on a
            -- Claude policy, Claude's own decoder refuses the Codex-only
            -- launch field before it can become a command-line argument.
            local offered_policy: {[string]: unknown} = {}
            for key, item in pairs(raw_policy(CLAUDE_WINDOW)) do offered_policy[key] = item end
            offered_policy.profile_options = {config_profile = {kind = "text", max_bytes = 64}}
            local offered, offered_error = preferences.apply(offered_policy, selected())
            if not offered then error(tostring(offered_error)) end
            local _, offered_launch_error = claude_launch.decode({profile_id = "window", brief = "", permission_mode = "default",
                config_profile = (offered.prepare_options :: {[string]: unknown}).config_profile})
            test.is_true(tostring(offered_launch_error):find("config_profile", 1, true) ~= nil)
        end)

        test.it("keeps the private-home Codex route refusing the named profile, as the design decided", function()
            -- The batch Codex profile runs in a private home and still offers
            -- the field, so the refusal names the profile the driver declared
            -- rather than a vague policy message. This is the documented
            -- private-home behavior: such a home never carries the named file.
            test.eq((raw_policy(CODEX_BATCH).profile_options :: {[string]: unknown}).config_profile.kind, "text")
            local codex, codex_error = registry.get("bee.driver.codex:profiles")
            if not codex then error(tostring(codex_error)) end
            local driver = (codex.data :: {[string]: unknown}).driver :: {[string]: unknown}
            local batch: {[string]: unknown}? = nil
            for _, item in ipairs(driver.profiles :: {{[string]: unknown}}) do
                if item.id == "batch" then batch = item end
            end
            if not batch then error("codex batch profile is missing") end
            test.is_true((batch.isolation_env :: {[string]: unknown}).private_home)
            local spec = launch.specification(assert(launch.decode({profile_id = "batch", brief = "work", sandbox = "read-only", config_profile = PROFILE})))
            local refusal = machine.required_file_refusal(spec, true)
            test.not_nil(refusal)
            test.is_true(refusal:find(PROFILE, 1, true) ~= nil)
            test.is_true(refusal:find("private home does not carry it", 1, true) ~= nil)
        end)

        test.it("plans the named flag and declares the file only where the home is inherited", function()
            local codex, codex_error = launch.decode({profile_id = "named_batch", brief = "work", sandbox = "read-only", config_profile = PROFILE})
            if not codex then error(tostring(codex_error)) end
            local spec = launch.specification(codex)
            test.eq(spec.argv[1], "--profile")
            test.eq(spec.argv[2], PROFILE)
            local file = (spec.required_files :: {driver_types.RequiredFile})[1]
            test.eq(file.variable, "CODEX_HOME")
            test.eq(file.path, PROFILE .. ".config.toml")
            test.eq(file.default_directory, ".codex")
            -- An inherited-home launch is allowed; a private home is refused
            -- with a diagnostic that names the profile the driver declared.
            test.is_nil(machine.required_file_refusal(spec, false))
            local refusal = machine.required_file_refusal(spec, true)
            test.not_nil(refusal)
            test.is_true(refusal:find(PROFILE, 1, true) ~= nil)
            -- A launch with no named profile is never refused for one.
            local plain = launch.specification(assert(launch.decode({profile_id = "named_batch", brief = "work", sandbox = "read-only"})))
            test.is_nil(machine.required_file_refusal(plain, true))
        end)

        test.it("binds every shipped window policy executable through the host environment resolver", function()
            -- The shipped window policies name their executable through
            -- executable_env, which the host environment resolves (a bare name
            -- is a PATH lookup, native/launch/environment.go). A runner without
            -- the CLI therefore makes the route unavailable; this pins that the
            -- resolution happens through that resolver and not a literal path.
            local windows: {{policy_ref: string, executable: string, variable: string}} = {
                {policy_ref = "bee:launch_policy_claude_window", executable = "claude", variable = "bee.driver.claude:executable"},
                {policy_ref = "bee:launch_policy_codex_window", executable = "codex", variable = "bee.driver.codex:executable"},
                {policy_ref = "bee:launch_policy_muse_window", executable = "muse", variable = "bee.driver.muse:executable"},
                {policy_ref = "bee:launch_policy_agy_window", executable = "agy", variable = "bee.driver.agy:executable"},
                {policy_ref = "bee:launch_policy_grok_window", executable = "grok", variable = "bee.driver.grok:executable"},
            }
            for _, window in ipairs(windows) do
                local entry = registry.get(window.policy_ref)
                if not entry then error("missing shipped policy " .. window.policy_ref) end
                local resolved, resolve_error = policy.decode(window.policy_ref, entry,
                    function(ref: string): (string?, string?)
                        if ref == window.variable then return "/opt/host/" .. window.executable, nil end
                        -- The companions (config home, host environment) are
                        -- optional; an empty value leaves them absent.
                        return "", nil
                    end)
                if not resolved then error(tostring(resolve_error)) end
                test.eq((resolved.executables :: {[string]: string})[window.executable], "/opt/host/" .. window.executable)
                -- An unavailable host executable leaves the declaration
                -- unavailable rather than binding a relative or empty name.
                local absent, absent_error = policy.decode(window.policy_ref, entry,
                    function(ref: string): (string?, string?)
                        if ref == window.variable then return nil, "environment variable not found" end
                        return "", nil
                    end)
                test.is_nil(absent)
                test.is_true(tostring(absent_error):find("executable_env." .. window.executable, 1, true) ~= nil)
            end
        end)

        test.it("wires every shipped window executable to a live host environment variable", function()
            -- The executable_env reference must name a real env.variable served
            -- by the host environment storage; a rename on either side would
            -- otherwise only surface as a route that silently goes unavailable.
            local bindings: {{policy_ref: string, executable: string, variable: string}} = {
                {policy_ref = "bee:launch_policy_claude_window", executable = "claude", variable = "bee.driver.claude:executable"},
                {policy_ref = "bee:launch_policy_codex_window", executable = "codex", variable = "bee.driver.codex:executable"},
                {policy_ref = "bee:launch_policy_muse_window", executable = "muse", variable = "bee.driver.muse:executable"},
                {policy_ref = "bee:launch_policy_agy_window", executable = "agy", variable = "bee.driver.agy:executable"},
                {policy_ref = "bee:launch_policy_grok_window", executable = "grok", variable = "bee.driver.grok:executable"},
            }
            for _, binding in ipairs(bindings) do
                local policy_entry = registry.get(binding.policy_ref)
                if not policy_entry then error("missing shipped policy " .. binding.policy_ref) end
                local declared = ((policy_entry.data :: {[string]: unknown}).executable_env :: {[string]: string})[binding.executable]
                test.eq(declared, binding.variable)
                local variable_entry = registry.get(binding.variable)
                if not variable_entry then error("missing executable variable " .. binding.variable) end
                test.eq(variable_entry.kind, "env.variable")
                test.eq((variable_entry.data :: {[string]: unknown}).storage, "bee.harness.host:environment")
            end
        end)

        test.it("checks the committed CODEX_HOME rather than the inherited home", function()
            -- Placement must read the home the policy committed, not the process
            -- HOME. A runner whose own ~/.codex lacks the file still admits a
            -- launch whose committed home carries it, and names the committed
            -- home when it does not.
            local installed: {driver_types.RequiredFile} = {{variable = "CODEX_HOME", path = "hostname"}}
            local admitted = materialization.required_file_missing(launch_request(installed, {CODEX_HOME = "/etc", HOME = "/definitely-missing-bee-home"}))
            test.is_nil(admitted)
            local absent: {driver_types.RequiredFile} = {{variable = "CODEX_HOME", path = "definitely-missing-bee-profile.config.toml"}}
            local refused = materialization.required_file_missing(launch_request(absent, {CODEX_HOME = "/etc", HOME = "/definitely-missing-bee-home"}))
            test.not_nil(refused)
            test.is_true(refused:find("/etc", 1, true) ~= nil)
            test.is_true(refused:find("definitely-missing-bee-home", 1, true) == nil)
        end)

        test.it("reports an absent committed home instead of guessing the profile is missing", function()
            local declared: {driver_types.RequiredFile} = {{variable = "CODEX_HOME", path = PROFILE .. ".config.toml", default_directory = ".codex"}}
            local absent_home = materialization.required_file_missing(launch_request(declared, nil, nil))
            test.not_nil(absent_home)
            test.is_true(absent_home:find("host home is unavailable", 1, true) ~= nil)
        end)

        test.it("refuses a named profile that is not installed, naming it", function()
            local declared: {driver_types.RequiredFile} = {{variable = "CODEX_HOME", path = PROFILE .. ".config.toml", default_directory = ".codex"}}
            -- /etc exists and carries no such profile, so the refusal is about
            -- the missing name rather than an unavailable home.
            local missing = materialization.required_file_missing(launch_request(declared, {CODEX_HOME = "/etc"}))
            test.not_nil(missing)
            test.is_true(missing:find(PROFILE, 1, true) ~= nil)
            test.is_true(missing:find("not installed", 1, true) ~= nil)
            -- A profile name that could escape the home never reaches the
            -- driver, so placement never opens a path outside it.
            for _, name in ipairs({"a.b", "a/b", "..", "-x", "a b", "x;rm", ""}) do
                test.is_nil(launch.decode({profile_id = "named_batch", brief = "", sandbox = "read-only", config_profile = name}))
            end
        end)
    end)
end
return test.run_cases(define_tests)
