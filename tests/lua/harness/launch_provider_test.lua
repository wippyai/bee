-- MIT. Provider launch behaviour.
local test = require("test")
local carrier_fixtures = require("carrier_fixtures")
local principals = require("principals")
local registry = require("registry")
local machine = require("machine")
local placement_store = require("placement_store")
local bounds = require("bounds")
local fixture = require("fixture")
local DEFINITION = fixture.DEFINITION
local SHIPPED_SHAPE_DEFINITION = fixture.SHIPPED_SHAPE_DEFINITION
local SHIPPED_BATCH_POLICY = fixture.SHIPPED_BATCH_POLICY
local POLICY = fixture.POLICY
local fresh = fixture.fresh
local workspace_id = fixture.workspace_id
local scope = fixture.scope
local call = fixture.call
local value = fixture.value
local open_gateway = fixture.open_gateway
local code = fixture.code
local apply = fixture.apply
local carrier_io = fixture.carrier_io
local shell = fixture.shell
local setup = fixture.setup
local function define_tests()
    test.describe("Launch provider", function()
        local workspace = fixture.prepare()
        test.it("defers driver configuration until placement supplies the actual HOME", function()
            local binding = assert(registry.get("bee.driver.claude.binding:binding"))
            local original = binding.data
            binding.data = {contracts = {
                {contract = "bee.driver:driver", methods = {
                    prepare = "bee.driver.claude.binding:prepare", dispatch = "bee.driver.claude.binding:dispatch",
                    normalize = "bee.driver.claude.binding:normalize", configure = "bee.tests.harness:configuration_probe",
                }},
                {contract = "bee.driver:locate_facet", methods = {locate = "bee.driver.claude.binding:locate"}},
            }}
            local ok, failure = pcall(function()
                apply(binding)
                local selected = value(call("bee.tests.harness.admission:resolve", {definition_ref = DEFINITION}))
                local request_id = fresh("complete-config-inputs")
                local admitted = value(call("bee.tests.harness.admission:admit", {request_id = request_id, definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "ping", expected_plan_digest = selected.plan_digest}))
                local io = carrier_io(workspace)
                local planned, plan_error = machine.plan(io, carrier_fixtures.request(admitted.request))
                if not planned then error(tostring(plan_error)) end
                local prepared, prepare_error = machine.prepare_attempt(io, planned)
                if not prepared then error(tostring(prepare_error)) end
                local db = assert(placement_store.open())
                local row = assert(placement_store.row(db, assert(bounds.id(admitted.attempt_id))))
                local stored, stored_error = placement_store.request(row)
                db:release()
                if not stored then error(tostring(stored_error)) end
                local delivery = stored.delivery
                if not delivery then error("delivery missing") end
                test.eq(delivery.arguments[1], "--fixture-home")
                test.is_true(delivery.arguments[2]:match("^/.*[/]home$") ~= nil)
                test.eq(row.execution_state, "intended")
            end)
            binding.data = original
            apply(binding)
            if not ok then error(tostring(failure)) end
        end)
        test.it("keeps Claude's provider config home aligned with a profile that inherits host HOME", function()
            local profile_entry = assert(registry.get("bee.driver.claude.profiles:profiles"))
            local definition_entry = assert(registry.get(SHIPPED_SHAPE_DEFINITION))
            local policy_entry = assert(registry.get(SHIPPED_BATCH_POLICY))
            local original_profiles, original_definition, original_policy = profile_entry.data, definition_entry.data, policy_entry.data

            local profile_data: {[string]: unknown} = {}
            for key, item in pairs(assert(bounds.object(original_profiles))) do profile_data[key] = item end
            local driver = assert(bounds.object(original_profiles.driver))
            local driver_copy: {[string]: unknown} = {}
            for key, item in pairs(driver) do driver_copy[key] = item end
            local profiles: {{[string]: unknown}} = {}
            local batch_profile_found = false
            for _, raw in ipairs(principals.objects(driver.profiles)) do
                local profile: {[string]: unknown} = {}
                for key, item in pairs(raw) do profile[key] = item end
                if raw.id == "batch" then
                    batch_profile_found = true
                    local isolation = assert(bounds.object(raw.isolation_env))
                    local isolation_copy: {[string]: unknown} = {}
                    for key, item in pairs(isolation) do isolation_copy[key] = item end
                    isolation_copy.private_home = false
                    profile.isolation_env = isolation_copy
                end
                profiles[#profiles + 1] = profile
            end
            if not batch_profile_found then error("Claude batch profile is missing") end
            driver_copy.profiles = profiles
            profile_data.driver = driver_copy

            local definition_data: {[string]: unknown} = {}
            for key, item in pairs(assert(bounds.object(original_definition))) do definition_data[key] = item end
            definition_data.profile_id = "batch"
            definition_data.credentials = {}

            local policy_data: {[string]: unknown} = {}
            for key, item in pairs(assert(bounds.object(original_policy))) do policy_data[key] = item end
            policy_data.allow_host_home = true
            policy_data.environment = {CLAUDE_CONFIG_DIR = "/fixture/host-home/.claude"}
            policy_data.environment_refs = {}
            policy_data.executables = {claude = "/bin/true"}
            policy_data.executable_env = {}
            policy_data.gateway_tools = {}
            policy_data.gateway_hooks = {}
            policy_data.hook_command_ref = nil

            profile_entry.data = profile_data
            definition_entry.data = definition_data
            policy_entry.data = policy_data
            local changed = registry.snapshot():changes()
            changed:update(profile_entry)
            changed:update(definition_entry)
            changed:update(policy_entry)
            local applied, apply_error = changed:apply()
            if not applied then error("apply host HOME fixture: " .. tostring(apply_error)) end

            local ok, failure = pcall(function()
                local workspace_id = fresh("claude-host-home")
                setup(workspace_id, SHIPPED_SHAPE_DEFINITION)
                local selected = value(call("bee.tests.harness.admission:resolve", {definition_ref = SHIPPED_SHAPE_DEFINITION}))
                local admitted = value(call("bee.tests.harness.admission:admit", {request_id = fresh("claude-host-home-admit"),
                    definition_ref = SHIPPED_SHAPE_DEFINITION, workspace_id = workspace_id, brief = "host config fixture",
                    expected_plan_digest = selected.plan_digest}))
                local planned, plan_error = machine.plan(carrier_io(workspace), carrier_fixtures.request(admitted.request))
                if not planned then error(tostring(plan_error)) end
                local provider_home = assert(bounds.object(planned.launch.provider_home))
                test.eq(provider_home.variable, "CLAUDE_CONFIG_DIR")
                test.is_false(provider_home.private == true)
                test.eq(planned.placement_request.environment_refs.HOME, "bee.env:machine_home")
                test.eq(planned.placement_request.environment.CLAUDE_CONFIG_DIR, "/fixture/host-home/.claude")
            end)

            profile_entry.data = original_profiles
            definition_entry.data = original_definition
            policy_entry.data = original_policy
            local restore = registry.snapshot():changes()
            restore:update(profile_entry)
            restore:update(definition_entry)
            restore:update(policy_entry)
            local restored, restore_error = restore:apply()
            if not restored then error("restore host HOME fixture: " .. tostring(restore_error)) end
            if not ok then error(tostring(failure)) end
        end)
        test.it("admits inherited Codex configuration and refuses a conflicting private provider", function()
            local definition_entry = assert(registry.get(DEFINITION))
            local policy_entry = assert(registry.get(POLICY))
            local original_definition, original_policy = definition_entry.data, policy_entry.data
            local changed_definition: {[string]: unknown} = {}
            local changed_policy: {[string]: unknown} = {}
            for name, value in pairs(assert(bounds.object(original_definition))) do changed_definition[name] = value end
            for name, value in pairs(assert(bounds.object(original_policy))) do changed_policy[name] = value end
            changed_definition.binding_ref = "bee.driver.codex.binding:binding"
            changed_definition.profile_id = "window"
            changed_definition.default_mode = "window"
            changed_definition.session_resource = "session"
            changed_definition.credentials = {}
            changed_policy.executables = {codex = "/bin/true"}
            changed_policy.prepare_options = {sandbox = "read-only"}
            changed_policy.provider_ref = nil
            local request_id = fresh("missing-provider")
            local ok, failure = pcall(function()
                definition_entry.data = changed_definition
                policy_entry.data = changed_policy
                local changes = registry.snapshot():changes()
                changes:update(definition_entry)
                changes:update(policy_entry)
                local applied, apply_error = changes:apply()
                if not applied then error("configure missing provider: " .. tostring(apply_error)) end
                local unapproved = value(call("bee.tests.harness.admission:admit", {request_id = fresh("unapproved-host-home"), definition_ref = DEFINITION,
                    workspace_id = workspace, brief = ""}))
                local refused_plan, refusal = machine.plan(carrier_io(workspace), carrier_fixtures.request(unapproved.request))
                test.is_nil(refused_plan)
                test.eq(refusal, "launch policy does not authorize host HOME")
                local refused_db = assert(placement_store.open())
                test.is_nil(placement_store.row(refused_db, assert(bounds.id(unapproved.attempt_id))))
                refused_db:release()
                changed_policy.allow_host_home = true
                policy_entry.data = changed_policy
                apply(policy_entry)
                local admitted = value(call("bee.tests.harness.admission:admit", {request_id = request_id, definition_ref = DEFINITION,
                    workspace_id = workspace, brief = ""}))
                local io = carrier_io(workspace)
                local planned, plan_error = machine.plan(io, carrier_fixtures.request(admitted.request))
                if not planned then error(tostring(plan_error)) end
                local prepared, prepare_error = machine.prepare_attempt(io, planned)
                if not prepared then error(tostring(prepare_error)) end
                local db = assert(placement_store.open())
                local row, row_error = placement_store.row(db, assert(bounds.id(admitted.attempt_id)))
                db:release()
                test.is_nil(row_error)
                if not row then error("inherited configuration attempt missing") end
                test.eq(row.execution_state, "intended")
                local stored, stored_error = placement_store.request(row)
                if not stored then error(tostring(stored_error)) end
                if not stored.delivery then error("configuration delivery missing") end
                test.eq(#stored.delivery.files, 0)
                changed_policy.provider_ref = "bee.tests.harness:codex_fixture_provider"
                policy_entry.data = changed_policy
                apply(policy_entry)
                local conflicted = value(call("bee.tests.harness.admission:admit", {request_id = fresh("provider-home-conflict"), definition_ref = DEFINITION,
                    workspace_id = workspace, brief = ""}))
                local refused, refusal = machine.plan(io, carrier_fixtures.request(conflicted.request))
                test.is_nil(refused)
                test.eq(refusal, "selected provider configuration requires a private-home profile")
                local check_db = assert(placement_store.open())
                local unintended = placement_store.row(check_db, assert(bounds.id(conflicted.attempt_id)))
                check_db:release()
                test.is_nil(unintended)
                local saved_id = fresh("provider-private-home")
                value(call("bee.harness.binding:call", {operation = "put", workspace_id = workspace, profile_id = saved_id,
                    expected_revision = 0, idempotency_key = fresh("save"), profile = {schema_revision = "bee.agent-profile@3",
                        name = "Private provider", definition_ref = DEFINITION, driver_binding_ref = "bee.driver.codex.binding:binding",
                        provider = {}, bee = {mcp = {}}, placement = {kind = "native", home = "private"}}}))
                local private_selected = value(call("bee.tests.harness.admission:resolve", {definition_ref = DEFINITION,
                    workspace_id = workspace, saved_profile_id = saved_id, saved_profile_revision = 1}))
                local private = value(call("bee.tests.harness.admission:admit", {request_id = fresh("provider-private-home-admit"),
                    definition_ref = DEFINITION, workspace_id = workspace, brief = "",
                    saved_profile_id = saved_id, saved_profile_revision = 1, expected_plan_digest = private_selected.plan_digest}))
                local private_plan, private_error = machine.plan(io, carrier_fixtures.request(private.request))
                assert(private_plan, tostring(private_error))
                test.is_true(assert(private_plan.launch.provider_home).private)
            end)
            definition_entry.data = original_definition
            policy_entry.data = original_policy
            local restoration = registry.snapshot():changes()
            restoration:update(definition_entry)
            restoration:update(policy_entry)
            local restored, restore_error = restoration:apply()
            if not restored then error("restore missing provider: " .. tostring(restore_error)) end
            if not ok then error(tostring(failure)) end
        end)
        test.it("launches a saved profile that names a Codex config profile and still delivers Bee MCP and hooks", function()
            local definition_entry = assert(registry.get(DEFINITION))
            local codex_policy = assert(registry.get("bee.tests.harness:codex_fixture_policy"))
            local original_definition, original_policy = definition_entry.data, codex_policy.data
            local changed_definition: {[string]: unknown} = {}
            local changed_policy: {[string]: unknown} = {}
            for name, value in pairs(assert(bounds.object(original_definition))) do changed_definition[name] = value end
            for name, value in pairs(assert(bounds.object(original_policy))) do changed_policy[name] = value end
            changed_definition.binding_ref = "bee.driver.codex.binding:binding"
            changed_definition.profile_id = "window"
            changed_definition.default_mode = "window"
            changed_definition.session_resource = "session"
            changed_definition.policy_ref = "bee.tests.harness:codex_fixture_policy"
            changed_definition.credentials = {}
            changed_policy.executables = {codex = "/bin/true"}
            changed_policy.provider_ref = nil
            changed_policy.allow_host_home = true
            changed_policy.profile_restrictions = {["provider.options.config_profile"] = {kind = "text", max_bytes = 64}}
            changed_policy.gateway_tools = {"thread_read", "thread_wait"}
            changed_policy.gateway_hooks = {"SessionStart", "Stop"}
            changed_policy.prepare_options = {sandbox = "read-only"}
            local ok, failure = pcall(function()
                local workspace_id, saved_id = workspace, fresh("named-profile")
                -- The named profile file lives in a throwaway Codex home, never
                -- the owner's. Only existence is checked; the suite writes it.
                local root = shell("pwd"):gsub("%s+$", "")
                local codex_home = root .. "/.wippy/named-profile-" .. saved_id .. "/.codex"
                shell("mkdir -p " .. codex_home)
                -- shell() wraps this in sh -c '...'; a single-quoted printf
                -- would close that wrapper and write nothing.
                shell("printf \"model = \\\"fixture\\\"\\n\" > " .. codex_home .. "/fixture-profile.config.toml")
                -- The throwaway home is committed with the policy, so the
                -- prepared launch never falls back to the runner's own home.
                changed_policy.environment = {CODEX_HOME = codex_home}
                changed_policy.environment_refs = nil
                definition_entry.data = changed_definition
                codex_policy.data = changed_policy
                local changes = registry.snapshot():changes()
                changes:update(definition_entry)
                changes:update(codex_policy)
                local applied, apply_error = changes:apply()
                if not applied then error("configure codex named profile: " .. tostring(apply_error)) end
                value(call("bee.harness.binding:call", {operation = "put", workspace_id = workspace_id, profile_id = saved_id,
                    expected_revision = 0, idempotency_key = fresh("save"),
                    profile = {schema_revision = "bee.agent-profile@3", name = "DeepSeek Flash", definition_ref = DEFINITION, driver_binding_ref = "bee.driver.codex.binding:binding", provider = {options = {config_profile = "fixture-profile"}}, bee = {mcp = {{tool = "thread_read", scope = {}}}}}}))
                local selected = value(call("bee.tests.harness.admission:resolve", {definition_ref = DEFINITION, workspace_id = workspace_id,
                    saved_profile_id = saved_id, saved_profile_revision = 1}))
                local admitted = value(call("bee.tests.harness.admission:admit", {request_id = fresh("named-profile-admit"), definition_ref = DEFINITION,
                    workspace_id = workspace_id, brief = "", saved_profile_id = saved_id, saved_profile_revision = 1,
                    expected_plan_digest = selected.plan_digest}))
                local carrier_request = assert(bounds.object(admitted.request))
                local preferences = assert(bounds.object(carrier_request.preferences))
                test.eq((assert(bounds.object(preferences.options))).config_profile, "fixture-profile")
                open_gateway()
                local io = carrier_io(workspace)
                local planned, plan_error = machine.plan(io, carrier_fixtures.request(admitted.request))
                if not planned then error(tostring(plan_error)) end
                -- Codex layers the named profile on its base user config.
                test.eq(planned.launch.argv[1], "--profile")
                test.eq(planned.launch.argv[2], "fixture-profile")
                local prepared, prepare_error = machine.prepare_attempt(io, planned)
                if not prepared then error(tostring(prepare_error)) end
                local db = assert(placement_store.open())
                local row = assert(placement_store.row(db, assert(bounds.id(admitted.attempt_id))))
                local stored, stored_error = placement_store.request(row)
                db:release()
                if not stored then error(tostring(stored_error)) end
                if not stored.delivery then error("configuration delivery missing") end
                -- Bee's scoped MCP and hooks still arrive, layered on the named
                -- profile by a later -c override.
                local has_bee_mcp, has_bee_hooks = false, false
                for _, argument in ipairs(stored.delivery.arguments) do
                    if argument:find("mcp_servers.bee=", 1, true) then has_bee_mcp = true end
                    if argument:find("hooks.SessionStart=", 1, true) then has_bee_hooks = true end
                end
                test.is_true(has_bee_mcp)
                test.is_true(has_bee_hooks)
            end)
            definition_entry.data = original_definition
            codex_policy.data = original_policy
            local restoration = registry.snapshot():changes()
            restoration:update(definition_entry)
            restoration:update(codex_policy)
            local restored, restore_error = restoration:apply()
            if not restored then error("restore named profile: " .. tostring(restore_error)) end
            if not ok then error(tostring(failure)) end
        end)
        test.it("fences a selected plan when its host provider changes", function()
            local definition_entry = assert(registry.get(DEFINITION))
            local codex_policy = assert(registry.get("bee.tests.harness:codex_fixture_policy"))
            local provider = assert(registry.get("bee.tests.harness:codex_fixture_provider"))
            local original_definition, original_policy, original_provider = definition_entry.data, codex_policy.data, provider.data
            local changed_definition: {[string]: unknown} = {}
            local changed_policy: {[string]: unknown} = {}
            local changed_provider: {[string]: unknown} = {}
            for name, value in pairs(assert(bounds.object(original_definition))) do changed_definition[name] = value end
            for name, value in pairs(assert(bounds.object(original_policy))) do changed_policy[name] = value end
            for name, value in pairs(assert(bounds.object(original_provider))) do changed_provider[name] = value end
            changed_definition.binding_ref = "bee.driver.codex.binding:binding"
            changed_definition.profile_id = "window"
            changed_definition.default_mode = "window"
            changed_definition.session_resource = "session"
            changed_definition.policy_ref = "bee.tests.harness:codex_fixture_policy"
            changed_definition.credentials = {}
            changed_policy.executables = {codex = "/bin/true"}
            local request_id = fresh("provider-fenced")
            local ok, failure = pcall(function()
                definition_entry.data = changed_definition
                codex_policy.data = changed_policy
                local initial = registry.snapshot():changes()
                initial:update(definition_entry)
                initial:update(codex_policy)
                local applied, apply_error = initial:apply()
                if not applied then error("configure provider fence: " .. tostring(apply_error)) end
                local selected = value(call("bee.tests.harness.admission:resolve", {definition_ref = DEFINITION}))
                changed_provider.model = "gpt-5.1"
                provider.data = changed_provider
                local update = registry.snapshot():changes()
                update:update(provider)
                local updated, update_error = update:apply()
                if not updated then error("change provider: " .. tostring(update_error)) end
                local refused = call("bee.tests.harness.admission:admit", {request_id = request_id, definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "", expected_plan_digest = selected.plan_digest})
                test.eq(code(refused), "CONFLICT")
                test.eq(code(call("bee.threads.binding:get", {thread_id = "thread:" .. request_id})), "NOT_FOUND")
            end)
            definition_entry.data = original_definition
            codex_policy.data = original_policy
            provider.data = original_provider
            local restoration = registry.snapshot():changes()
            restoration:update(definition_entry)
            restoration:update(codex_policy)
            restoration:update(provider)
            local restored, restore_error = restoration:apply()
            if not restored then error("restore provider fence: " .. tostring(restore_error)) end
            if not ok then error(tostring(failure)) end
        end)
        fixture.restore_host()
    end)
end
return test.run_cases(define_tests)
