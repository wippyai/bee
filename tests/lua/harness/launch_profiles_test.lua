-- MIT. Profiles launch behaviour.
local test = require("test")
local carrier_fixtures = require("carrier_fixtures")
local principals = require("principals")
local funcs = require("funcs")
local registry = require("registry")
local admission = require("admission")
local definitions = require("definitions")
local trait_access = require("trait_access")
local machine = require("machine")
local bounds = require("bounds")
local json = require("json")
local fixture = require("fixture")
local REQUESTER = fixture.REQUESTER
local DEFINITION = fixture.DEFINITION
local AGENT_DEFINITION = fixture.AGENT_DEFINITION
local AGENT_POLICY = fixture.AGENT_POLICY
local POLICY = fixture.POLICY
local fresh = fixture.fresh
local workspace_id = fixture.workspace_id
local scope = fixture.scope
local call = fixture.call
local profile_call = fixture.profile_call
local call_setup = fixture.call_setup
local value = fixture.value
local code = fixture.code
local apply = fixture.apply
local with_entry = fixture.with_entry
local with_provider_source = fixture.with_provider_source
local carrier_io = fixture.carrier_io
local function define_tests()
    test.describe("Launch profiles", function()
        local workspace = fixture.prepare()
        test.it("routes every placement method a session uses, including the activity check that idles agents", function()
            local plan = assert((admission.resolve("bee.driver.claude.profiles:default_window", "window")))
            local methods = assert(bounds.object(plan.placement_methods))
            for _, name in ipairs({"prepare", "start", "status", "stop", "reconcile", "cleanup", "activity"}) do
                test.not_nil(methods[name], name)
            end
            test.eq(methods.activity, "bee.placement.native.binding:activity")
        end)
        test.it("decodes dedicated worktrees without mutable or untyped definition options", function()
            local entry = assert(registry.get(DEFINITION))
            local data = assert(bounds.object(entry.data))
            data.options = {worktree = "dedicated"}
            local decoded = assert(definitions.decode(DEFINITION, entry))
            test.eq(decoded.options and decoded.options.worktree, "dedicated")
            data.options = {worktree = "dedicated", path = "/outside"}
            local invalid, err = definitions.decode(DEFINITION, entry)
            test.is_nil(invalid); test.not_nil(err)
            data.options = nil
            data.worktree = "dedicated"
            decoded = assert(definitions.decode(DEFINITION, entry))
            test.eq(decoded.options and decoded.options.worktree, "dedicated")
            test.is_nil(data.options)
            data.options = {worktree = "dedicated"}
            invalid, err = definitions.decode(DEFINITION, entry)
            test.is_nil(invalid); test.not_nil(err)
        end)
        test.it("sets up and admits private-home credentials when a saved window has no machine-home credentials", function()
            with_entry(DEFINITION, function(data)
                data.credentials = {}
                data.private_credentials = {"anthropic"}
            end, function()
                local target, saved_id = fresh("private-provider-workspace"), fresh("private-provider-profile")
                value(call("bee.harness.binding:call", {operation = "put", workspace_id = target, profile_id = saved_id,
                    expected_revision = 0, idempotency_key = fresh("save"), profile = {schema_revision = "bee.agent-profile@3",
                        name = "Custom provider", definition_ref = DEFINITION, driver_binding_ref = "bee.driver.claude.binding:binding",
                        provider = {}, bee = {mcp = {}}, placement = {kind = "native", home = "private"}}}))
                local plan = value(call("bee.tests.harness.admission:resolve", {definition_ref = DEFINITION, workspace_id = target,
                    saved_profile_id = saved_id, saved_profile_revision = 1}))
                local prepared = call_setup({workspace_id = target, definition_ref = DEFINITION, expected_plan_digest = plan.plan_digest,
                    saved_profile_id = saved_id, saved_profile_revision = 1})
                test.is_true(prepared.ok, tostring(prepared.error))
                test.eq(assert(bounds.array(prepared.credentials, 64))[1], "anthropic")
                local admitted = value(call("bee.tests.harness.admission:admit", {request_id = fresh("private-provider-admit"),
                    definition_ref = DEFINITION, workspace_id = target, brief = "Fixture", expected_plan_digest = plan.plan_digest,
                    saved_profile_id = saved_id, saved_profile_revision = 1}))
                test.eq(#assert(bounds.array(assert(bounds.object(admitted.request)).projections, 64)), 1)
            end)
        end)
        test.it("admits an OpenCode custom-provider profile and stores its entered key outside the profile", function()
            with_provider_source("opencode", function()
            with_entry("bee.driver.opencode.security:launch_policy_opencode_window", function(policy)
                policy.executable_env = {}
                policy.executables = {opencode = "/usr/bin/true"}
            end, function()
            local target, saved_id = workspace_id("custom-opencode"), fresh("custom-profile")
            local ref = "bee.driver.opencode.profiles:default_window"
            local decoded = assert(definitions.load(ref))
            local secret = "fixture-custom-opencode-key"
            local raw, call_error = funcs.new():with_actor(principals.actor(REQUESTER, target)):with_scope(scope())
                :call("bee.harness.binding:set_credential", {workspace_id = target, definition_ref = ref,
                    expected_definition_digest = decoded.digest, name = "opencode_api_key", value = secret})
            test.is_nil(call_error)
            local entered_reply = assert(bounds.object(raw))
            assert(entered_reply.ok == true, assert(json.encode(entered_reply)))
            local profile = {schema_revision = "bee.agent-profile@3", name = "Local models", definition_ref = ref,
                driver_binding_ref = "bee.driver.opencode.binding:binding", provider = {model = "local_model/gemma", options = {
                    enabled_providers = {"local_model"}, providers = {local_model = {npm = "@ai-sdk/openai-compatible", name = "Local",
                        options = {baseURL = "https://models.example.test/v1", apiKey = "{env:OPENAI_API_KEY}"}, models = {gemma = {name = "gemma"}}}}}},
                bee = {mcp = {}}, placement = {kind = "native", home = "private"}}
            value(call("bee.harness.binding:call", {operation = "put", workspace_id = target, profile_id = saved_id,
                expected_revision = 0, idempotency_key = fresh("save"), profile = profile}))
            local plan = value(call("bee.tests.harness.admission:resolve", {workspace_id = target, definition_ref = ref,
                saved_profile_id = saved_id, saved_profile_revision = 1}))
            local setup_reply = call_setup({workspace_id = target, definition_ref = ref, expected_plan_digest = plan.plan_digest,
                saved_profile_id = saved_id, saved_profile_revision = 1})
            assert(setup_reply.ok == true, tostring(setup_reply.error))
            local admitted = value(call("bee.tests.harness.admission:admit", {workspace_id = target, definition_ref = ref, request_id = fresh("custom-admit"),
                expected_plan_digest = plan.plan_digest, saved_profile_id = saved_id, saved_profile_revision = 1, brief = "Fixture"}))
            test.eq(#assert(bounds.array(assert(bounds.object(admitted.request)).projections, 64)), 2)
            local saved = value(call("bee.harness.binding:call", {operation = "get", workspace_id = target, profile_id = saved_id}))
            test.is_nil((assert(json.encode(saved)):find(secret, 1, true)))
            test.is_nil((assert(json.encode(admitted)):find(secret, 1, true)))
            test.is_nil((assert(json.encode(value(call("bee.credentials.binding:list", {workspace_id = target})))):find(secret, 1, true)))
            end)
            end)
        end)
        test.it("carries saved trait selections through admission and carrier policy on both routes", function()
            for _, route in ipairs({{definition = DEFINITION, policy = POLICY}, {definition = AGENT_DEFINITION, policy = AGENT_POLICY}}) do
                local entry = assert(registry.get(route.policy))
                local original = assert(bounds.object(entry.data))
                local changed: {[string]: unknown} = {}
                for key, item in pairs(original) do changed[key] = item end
                changed.gateway_surface = {access = {policy = "agent-access", traits = {"bee.tests.memory:trait"}}}
                if route.definition == AGENT_DEFINITION then
                    local tools: {{[string]: unknown}} = {}
                    for _, id in ipairs({"bee.tests.harness:agent_read_tool", "bee.tests.harness:agent_report_tool"}) do
                        local meta = assert(bounds.object(assert(registry.get(id)).meta))
                        tools[#tools + 1] = {name = meta.llm_alias, operation = id, description = meta.llm_description,
                            policies = {"bee.tests.harness:launch_client_policy"}, schema = json.decode(tostring(meta.input_schema)), annotations = {}}
                    end
                                        changed.gateway_surface = {tools = tools, traits = {assert(trait_access.load("bee.tests.memory:trait"))},
                        base_tools = {"FileRead", "FileReport"}, active_traits = {}, fixed_context = {}, dynamic_keys = {},
                        access = {policy = "agent-access", traits = {"bee.tests.memory:trait"}}}
                end
                entry.data = changed; apply(entry)
                local ok, err = pcall(function()
                    local saved_id = fresh("trait-profile")
                    value(call("bee.harness.binding:call", {operation = "put", workspace_id = workspace, profile_id = saved_id,
                        expected_revision = 0, idempotency_key = fresh("save"), profile = {schema_revision = "bee.agent-profile@3",
                            name = "Remember", definition_ref = route.definition, driver_binding_ref = "bee.driver.claude.binding:binding",
                            provider = {}, bee = {mcp = {}}, active_traits = {"bee.tests.memory:trait"},
                            role = "Remember facts", context = {project = "Bee", readonly = false}}}))
                    local measured = value(call("bee.tests.harness.admission:resolve", {definition_ref = route.definition, workspace_id = workspace,
                        saved_profile_id = saved_id, saved_profile_revision = 1}))
                    local admitted = value(call("bee.tests.harness.admission:admit", {request_id = fresh("trait-admission"), definition_ref = route.definition, expected_plan_digest = measured.plan_digest,
                        workspace_id = workspace, brief = "remember", saved_profile_id = saved_id, saved_profile_revision = 1}))
                    local requested = assert(bounds.object(admitted.request))
                    local preferences = assert(bounds.object(requested.preferences))
                    test.eq(assert(bounds.ids(preferences.active_traits, true))[1], "bee.tests.memory:trait")
                    local planned, problem = machine.plan(carrier_io(workspace), carrier_fixtures.request(requested))
                    test.not_nil(planned, tostring(problem))
                    local configured = assert(assert(planned).policy.gateway_surface)
                    test.eq(assert(bounds.ids(configured.active_traits, true))[1], "bee.tests.memory:trait")
                    test.eq(assert(bounds.object(configured.fixed_context)).project, "Bee")
                    test.eq(assert(bounds.object(configured.fixed_context)).readonly, false)
                end)
                entry.data = original; apply(entry)
                if not ok then error(tostring(err)) end
            end
        end)
        test.it("fences a saved profile revision before admission and rejects preferences outside host policy", function()
            local workspace_id, saved_id = workspace, fresh("profile")
            local function save(revision: integer, title: string, options: {[string]: unknown})
                value(call("bee.harness.binding:call", {operation = "put", workspace_id = workspace_id, profile_id = saved_id,
                    expected_revision = revision, idempotency_key = fresh("save"), profile = {schema_revision = "bee.agent-profile@3", name = title, definition_ref = DEFINITION, driver_binding_ref = "bee.driver.claude.binding:binding", provider = {permission_mode = options.permission_mode, model = options.model}, bee = {mcp = {}}}}))
            end
            save(0, "First profile", {})
            local original = value(call("bee.tests.harness.admission:resolve", {definition_ref = DEFINITION, workspace_id = workspace_id,
                saved_profile_id = saved_id, saved_profile_revision = 1}))
            test.eq(original.saved_profile_id, saved_id)
            test.eq(original.saved_profile_revision, 1)
            test.is_nil(original.preferences)
            local admitted = value(call("bee.tests.harness.admission:admit", {request_id = fresh("saved-profile-admit"), definition_ref = DEFINITION,
                workspace_id = workspace_id, brief = "profile fixture", saved_profile_id = saved_id, saved_profile_revision = 1,
                expected_plan_digest = original.plan_digest}))
            local carrier_request = assert(bounds.object(admitted.request))
            local preferences = assert(bounds.object(carrier_request.preferences))
            test.eq(preferences.instructions, "")
            test.eq(#(principals.items(preferences.mcp_tools)), 0)
            save(1, "Revised profile", {})
            local refused = call("bee.tests.harness.admission:admit", {request_id = fresh("stale-profile"), definition_ref = DEFINITION,
                workspace_id = workspace_id, brief = "never launch", saved_profile_id = saved_id, saved_profile_revision = 1,
                expected_plan_digest = original.plan_digest})
            test.eq(code(refused), "CONFLICT")
            local updated = value(call("bee.tests.harness.admission:resolve", {definition_ref = DEFINITION, workspace_id = workspace_id,
                saved_profile_id = saved_id, saved_profile_revision = 2}))
            test.neq(original.plan_digest, updated.plan_digest)
            local unsafe = profile_call({operation = "put", workspace_id = workspace_id, profile_id = saved_id,
                expected_revision = 2, idempotency_key = fresh("save"), profile = {schema_revision = "bee.agent-profile@3", name = "Forbidden option",
                    definition_ref = DEFINITION, driver_binding_ref = "bee.driver.claude.binding:binding", provider = {permission_mode = "dontAsk"}, bee = {mcp = {}}}})
            test.eq(unsafe.ok, false)
            test.eq(unsafe.code, "DENIED")
            local unchanged = value(call("bee.tests.harness.admission:resolve", {definition_ref = DEFINITION, workspace_id = workspace_id,
                saved_profile_id = saved_id, saved_profile_revision = 2}))
            test.eq(unchanged.plan_digest, updated.plan_digest)
        end)
        fixture.restore_host()
    end)
end
return test.run_cases(define_tests)
