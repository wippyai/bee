-- MIT. Credentials launch behaviour.
local test = require("test")
local principals = require("principals")
local registry = require("registry")
local env = require("env")
local admission = require("admission")
local definitions = require("definitions")
local bounds = require("bounds")
local json = require("json")
local fixture = require("fixture")
local DEFINITION = fixture.DEFINITION
local RETAINED_DEFINITION = fixture.RETAINED_DEFINITION
local POLICY = fixture.POLICY
local ROOT = fixture.ROOT
local SECOND_ROOT = fixture.SECOND_ROOT
local ALTERNATE_SOURCE = fixture.ALTERNATE_SOURCE
local fresh = fixture.fresh
local workspace_id = fixture.workspace_id
local call = fixture.call
local call_setup = fixture.call_setup
local value = fixture.value
local code = fixture.code
local apply = fixture.apply
local setup = fixture.setup
local associations = fixture.associations
local with_host_project_root = fixture.with_host_project_root
local with_overrides = fixture.with_overrides
local function define_tests()
    test.describe("Launch credentials", function()
        local workspace = fixture.prepare()
        test.it("applies credential selectors and independent narrowed gateway file grants", function()
            for _, refs in ipairs({{}, {"anthropic"}}) do
                local saved_id = fresh("credential-profile")
                value(call("bee.harness.binding:call", {operation = "put", workspace_id = workspace, profile_id = saved_id,
                    expected_revision = 0, idempotency_key = fresh("save"), profile = {schema_revision = "bee.agent-profile@3", name = "Selected credentials",
                        definition_ref = DEFINITION, driver_binding_ref = "bee.drivers.claude.binding:binding", provider = {},
                        bee = {mcp = {}, credential_refs = refs, files = {{workspace_id = workspace, resource = "project", subpath = "", access = "read"}}}}}))
                local plan = value(call("bee.tests.harness.launch:resolve", {definition_ref = DEFINITION, workspace_id = workspace,
                    saved_profile_id = saved_id, saved_profile_revision = 1}))
                local admitted = value(call("bee.tests.harness.launch:admit", {request_id = fresh("credential-admit"), definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "Fixture", saved_profile_id = saved_id, saved_profile_revision = 1, expected_plan_digest = plan.plan_digest}))
                local request = assert(bounds.object(admitted.request))
                test.eq(#assert(bounds.array(request.projections, 64)), #refs)
                local grants = assert(bounds.array(request.profile_grants, 64))
                test.eq(#grants, 1)
                test.eq(assert(bounds.object(grants[1])).access, "read")
                test.eq(assert(bounds.object(grants[1])).workspace_id, workspace)
                local resources = assert(bounds.array(request.resources, 64))
                test.eq(#resources, 1)
                test.eq(assert(bounds.object(resources[1])).access, "write")
            end
            local saved_id = fresh("undeclared-credential")
            value(call("bee.harness.binding:call", {operation = "put", workspace_id = workspace, profile_id = saved_id,
                expected_revision = 0, idempotency_key = fresh("save"), profile = {schema_revision = "bee.agent-profile@3", name = "Undeclared",
                    definition_ref = DEFINITION, driver_binding_ref = "bee.drivers.claude.binding:binding", provider = {}, bee = {credential_refs = {"undeclared"}, mcp = {}}}}))
            local refused = call("bee.tests.harness.launch:resolve", {definition_ref = DEFINITION, workspace_id = workspace, saved_profile_id = saved_id, saved_profile_revision = 1})
            test.eq(code(refused), "DENIED")
        end)
        test.it("honors credential environment destinations and rejects retargeting or literal conflicts", function()
            local listed = value(call("bee.credentials.binding:list", {workspace_id = workspace}))
            local definitions = assert(bounds.array(listed.definitions, 64))
            local destination = assert(bounds.id(assert(bounds.object(definitions[1])).destination))
            local descriptor_ref = "bee.drivers.claude.descriptor:cli"
            local declaration = assert(registry.get(descriptor_ref))
            local policy_entry = assert(registry.get(POLICY))
            local saved_descriptor, saved_policy = assert(json.encode(declaration.data)), assert(json.encode(policy_entry.data))
            local fields = assert(bounds.object(assert(bounds.object(assert(bounds.object(declaration.data)).options)).fields))
            local properties: {[string]: unknown} = {}
            local value_schema = {type = "object", additionalProperties = false, required = {"kind"}, properties = {
                kind = {type = "string", enum = {"credential", "literal"}}, credential_ref = {type = "string", maxLength = 128}, value = {type = "string", maxLength = 128}}}
            properties[destination], properties.OTHER_PROVIDER_TOKEN = value_schema, value_schema
            fields.env = {id = "env", group = "advanced", security_class = "host-ceiling", path = "provider.env", value_schema = {type = "object", additionalProperties = false, properties = properties},
                label = "Environment", description = "Fixture environment", section = "advanced", order = 999, contexts = {"first_turn"},
                support = {config_schema_ref = "fixture:environment"}, render = {{kind = "env", contexts = {"first_turn"}, name = destination, value = {field = "provider.env." .. destination}}}}
            assert(bounds.object(policy_entry.data)).profile_restrictions = {["provider.env"] = {kind = "declared"}}
            apply(declaration); apply(policy_entry)
            local replies: {admission.Reply} = {}
            for index, item in ipairs({{name = destination, literal = false}, {name = "OTHER_PROVIDER_TOKEN", literal = false}, {name = destination, literal = true}}) do
                local saved_id = fresh("credential-env")
                local environment: {[string]: unknown} = {}
                environment[item.name] = item.literal and {kind = "literal", value = "fixture-value"} or {kind = "credential", credential_ref = "anthropic"}
                value(call("bee.harness.binding:call", {operation = "put", workspace_id = workspace, profile_id = saved_id,
                    expected_revision = 0, idempotency_key = fresh("save"), profile = {schema_revision = "bee.agent-profile@3", name = "Environment",
                        definition_ref = DEFINITION, driver_binding_ref = "bee.drivers.claude.binding:binding", provider = {env = environment}, bee = {credential_refs = {"anthropic"}, mcp = {}}}}))
                local plan = value(call("bee.tests.harness.launch:resolve", {definition_ref = DEFINITION, workspace_id = workspace, saved_profile_id = saved_id, saved_profile_revision = 1}))
                replies[index] = call("bee.tests.harness.launch:admit", {request_id = fresh("env-admit"), definition_ref = DEFINITION, workspace_id = workspace,
                    brief = "Fixture", saved_profile_id = saved_id, saved_profile_revision = 1, expected_plan_digest = plan.plan_digest})
            end
            declaration.data = assert(json.decode(saved_descriptor)); policy_entry.data = assert(json.decode(saved_policy))
            apply(declaration); apply(policy_entry)
            test.eq(replies[1].ok, true)
            test.eq(code(replies[2]), "DENIED"); test.eq(code(replies[3]), "DENIED")
        end)
        test.it("admits placement overrides only at both host ceilings and pins the selected home", function()
            local resolved = admission.resolve(DEFINITION)
            local original = assert(resolved)
            local refused = admission.resolve(DEFINITION, nil, nil, nil, nil, nil, nil, nil, {kind = "native", home = "private"})
            test.is_nil(refused)
            with_overrides({"brief", "placement"}, {"placement"}, function()
                local resolved = admission.resolve(DEFINITION, nil, nil, nil, nil, nil, nil, nil, {kind = "native", home = "private"})
                local selected = assert(resolved)
                test.neq(selected.plan_digest, original.plan_digest)
                test.eq(selected.placement_kind, "native")
                test.eq(selected.effective_profile and selected.effective_profile.placement and selected.effective_profile.placement.home, "private")
                local refused = admission.resolve(DEFINITION, nil, nil, nil, nil, nil, nil, nil, {kind = "native", home = "machine"})
                test.is_nil(refused)
            end)
            with_overrides({"brief", "placement"}, {}, function()
                local refused = admission.resolve(DEFINITION, nil, nil, nil, nil, nil, nil, nil, {kind = "native", home = "private"})
                test.is_nil(refused)
            end)
        end)
        test.it("sets selected resources once, then admission grants the exact associations", function()
            local first_workspace = fresh("setup")
            local first = setup(first_workspace, RETAINED_DEFINITION)
            test.is_true(first.ok == true)
            test.eq(#(principals.items(first.resources)), 2)
            local before = associations(first_workspace)
            test.eq(#before, 2)
            test.eq(before[1].name, "project")
            test.eq(before[1].revision, 1)
            test.eq(before[2].name, "session")
            test.eq(before[2].revision, 1)
            local retry = setup(first_workspace, RETAINED_DEFINITION)
            test.is_true(retry.ok == true)
            local after = associations(first_workspace)
            test.eq(after[1].association_id, before[1].association_id)
            test.eq(after[1].revision, before[1].revision)
            test.eq(after[2].association_id, before[2].association_id)
            test.eq(after[2].revision, before[2].revision)
            local defined = value(call("bee.credentials.binding:list", {workspace_id = first_workspace}))
            local definitions = principals.objects(defined.definitions)
            test.eq(#definitions, 1)
            test.eq(definitions[1].name, "anthropic")
            test.eq(definitions[1].revision, 1)
            test.eq(#(principals.items(first.credentials)), 1)
            local admitted = value(call("bee.tests.harness.launch:admit", {request_id = fresh("setup-admit"), definition_ref = RETAINED_DEFINITION,
                workspace_id = first_workspace, brief = "ping"}))
            local request = assert(bounds.object(admitted.request))
            local resources = principals.objects(request.resources)
            test.eq(#resources, 2)
            test.eq(resources[1].root_ref, ROOT)
            test.eq(resources[2].root_ref, ROOT)
        end)
        test.it("refreshes a setup association after its admitted root definition changes", function()
            local target = fresh("setup-root-refresh")
            test.is_true(setup(target, RETAINED_DEFINITION).ok == true)
            local before = associations(target)
            local prior_revision = before[1].revision
            if type(prior_revision) ~= "number" then error("setup association revision is invalid") end
            local root = assert(registry.get(ROOT))
            local original = root.data
            local changed: {[string]: unknown} = {}
            for key, item in pairs(assert(bounds.object(original))) do changed[key] = item end
            changed.meta = "setup-refresh"
            local ok, failure = pcall(function()
                root.data = changed
                apply(root)
                test.is_true(setup(target, RETAINED_DEFINITION).ok == true)
                local after = associations(target)
                test.eq(after[1].revision, prior_revision + 1)
                test.neq(after[1].association_id, before[1].association_id)
                local admitted = value(call("bee.tests.harness.launch:admit", {request_id = fresh("setup-root-refresh-admit"),
                    definition_ref = RETAINED_DEFINITION, workspace_id = target, brief = "ping"}))
                test.eq(#(principals.items((assert(bounds.object(admitted.request))).resources)), 2)
            end)
            root.data = original
            apply(root)
            if not ok then error(tostring(failure)) end
        end)
        test.it("rebinds a stale setup association to the current host-selected root", function()
            local target = fresh("setup-host-root-reconcile")
            test.is_true(setup(target, RETAINED_DEFINITION).ok == true)
            local before = associations(target)
            local project_before = before[1]
            local session_before = before[2]
            if project_before.name ~= "project" or session_before.name ~= "session" then error("setup associations are not ordered") end
            local project_revision = project_before.revision
            if type(project_revision) ~= "number" then error("project association revision is invalid") end
            with_host_project_root(SECOND_ROOT, function()
                local refreshed = setup(target, RETAINED_DEFINITION)
                test.is_true(refreshed.ok == true)
                local after = associations(target)
                test.eq(#after, 2)
                test.eq(after[1].root_ref, SECOND_ROOT)
                test.eq(after[1].subpath, "")
                test.eq(after[1].allowed_access, "write")
                test.eq(after[1].revision, project_revision + 1)
                test.neq(after[1].association_id, project_before.association_id)
                test.eq(after[2].root_ref, session_before.root_ref)
                test.eq(after[2].revision, session_before.revision)
                test.eq(after[2].association_id, session_before.association_id)
                test.is_true(setup(target, RETAINED_DEFINITION).ok == true)
                local repeated = associations(target)
                test.eq(repeated[1].revision, after[1].revision)
                test.eq(repeated[1].association_id, after[1].association_id)
            end)
        end)
        test.it("preserves customized paths and read-only scopes when the host root changes", function()
            local target = fresh("setup-host-root-custom")
            test.is_true(setup(target, RETAINED_DEFINITION).ok == true)
            local initial = associations(target)
            local project = initial[1]
            if project.name ~= "project" then error("project association is missing") end
            local revision = project.revision
            if type(revision) ~= "number" then error("project association revision is invalid") end
            value(call("bee.resources.binding:associate", {workspace_id = target, name = "project", root_ref = ROOT,
                subpath = "custom", allowed_access = "write", expected_revision = revision}))
            with_host_project_root(SECOND_ROOT, function()
                local reply = setup(target, RETAINED_DEFINITION)
                test.is_true(reply.ok == false)
                test.eq(reply.error, "existing association project differs from host setup")
                local after = associations(target)
                test.eq(after[1].root_ref, ROOT)
                test.eq(after[1].subpath, "custom")
                test.eq(after[1].allowed_access, "write")
                test.eq(after[1].revision, revision + 1)
            end)

            local read_only = fresh("setup-host-root-read-only")
            test.is_true(setup(read_only, RETAINED_DEFINITION).ok == true)
            local read_project = associations(read_only)[1]
            local read_revision = read_project.revision
            if type(read_revision) ~= "number" then error("read-only association revision is invalid") end
            value(call("bee.resources.binding:associate", {workspace_id = read_only, name = "project", root_ref = ROOT,
                subpath = "", allowed_access = "read", expected_revision = read_revision}))
            local read_after = associations(read_only)[1]
            local readonly_revision = read_after.revision
            if type(readonly_revision) ~= "number" then error("read-only association revision is invalid") end
            with_host_project_root(SECOND_ROOT, function()
                local reply = setup(read_only, RETAINED_DEFINITION)
                test.is_true(reply.ok == false)
                test.eq(reply.error, "existing association project differs from host setup")
                local retained = associations(read_only)[1]
                test.eq(retained.root_ref, ROOT)
                test.eq(retained.subpath, "")
                test.eq(retained.allowed_access, "read")
                test.eq(retained.revision, readonly_revision)
            end)
        end)
        test.it("preserves optional login policy on setup retry and refuses a required definition", function()
            local entry = registry.get("bee.harness.launch:harness_setup")
            if not entry then error("host setup") end
            local original = entry.data
            local changed: {[string]: unknown} = {}
            for key, item in pairs(assert(bounds.object(original))) do changed[key] = item end
            local source = {kind = "fs_directory", ref = "bee.tests.credentials:claude_login_fixture"}
            changed.credentials = {anthropic = {provider = "claude", source = source, optional = true}}
            local ok, failure = pcall(function()
                entry.data = changed
                apply(entry)
                local target = fresh("setup-optional-login")
                test.is_true(setup(target, RETAINED_DEFINITION).ok == true)
                test.is_true(setup(target, RETAINED_DEFINITION).ok == true)
                local listed = value(call("bee.credentials.binding:list", {workspace_id = target}))
                local definitions = principals.objects(listed.definitions)
                test.eq(#definitions, 1)
                test.eq(definitions[1].optional, true)
                test.eq(definitions[1].revision, 1)
                local conflict = fresh("setup-required-login")
                value(call("bee.credentials.binding:define", {workspace_id = conflict, name = "anthropic", provider = "claude", source = source}))
                local reply = setup(conflict, RETAINED_DEFINITION)
                test.is_false(reply.ok == true)
                test.eq(reply.error, "existing credential anthropic differs from host setup")
                local retained = value(call("bee.credentials.binding:list", {workspace_id = conflict}))
                local unchanged = principals.objects(retained.definitions)
                test.eq(unchanged[1].optional, false)
                test.eq(unchanged[1].revision, 1)
            end)
            entry.data = original
            apply(entry)
            if not ok then error(tostring(failure)) end
        end)
        test.it("redefines a setup credential once after the host changes its credential format", function()
            local target = fresh("setup-format-change")
            test.is_true(setup(target, RETAINED_DEFINITION).ok == true)
            local before = principals.objects(value(call("bee.credentials.binding:list", {workspace_id = target})).definitions)
            test.eq(before[1].revision, 1)
            local sources_entry = assert(registry.get("bee.credentials.env:credential_sources"))
            local format_ref = tostring(assert(bounds.object(assert(bounds.object(sources_entry.data)).formats)).claude)
            local entry = assert(registry.get(format_ref))
            local original = entry.data
            local changed: {[string]: unknown} = {}
            for key, item in pairs(assert(bounds.object(original))) do changed[key] = item end
            local environments = principals.strings(changed.environments)
            environments[#environments + 1] = "BEE_TEST_ADDED_TOKEN"
            changed.environments = environments
            local ok, failure = pcall(function()
                entry.data = changed
                apply(entry)
                test.is_true(setup(target, RETAINED_DEFINITION).ok == true)
                local after = principals.objects(value(call("bee.credentials.binding:list", {workspace_id = target})).definitions)
                test.eq(#after, 1)
                test.eq(after[1].revision, 2)
                test.eq(after[1].source_ref, before[1].source_ref)
                local format = assert(bounds.object(after[1].format))
                test.eq(principals.strings(format.environments)[#environments], "BEE_TEST_ADDED_TOKEN")
                test.is_true(setup(target, RETAINED_DEFINITION).ok == true)
                local retried = principals.objects(value(call("bee.credentials.binding:list", {workspace_id = target})).definitions)
                test.eq(retried[1].revision, 2)
                local admitted = value(call("bee.tests.harness.launch:admit", {request_id = fresh("setup-format-change-admit"),
                    definition_ref = RETAINED_DEFINITION, workspace_id = target, brief = "ping"}))
                test.eq(#(principals.items((assert(bounds.object(admitted.request))).projections)), 1)
            end)
            entry.data = original
            apply(entry)
            if not ok then error(tostring(failure)) end
        end)
        test.it("never replaces a different existing credential during first-use setup", function()
            local target = fresh("setup-existing-credential")
            local existing = value(call("bee.credentials.binding:define", {workspace_id = target, name = "anthropic", provider = "claude",
                source = {kind = "env_variable", ref = ALTERNATE_SOURCE}, expected_revision = 0}))
            local reply = setup(target, RETAINED_DEFINITION)
            test.is_false(reply.ok == true)
            test.eq(reply.error, "existing credential anthropic differs from host setup")
            local listed = value(call("bee.credentials.binding:list", {workspace_id = target}))
            local definitions = principals.objects(listed.definitions)
            test.eq(#definitions, 1)
            test.eq(definitions[1].definition_id, existing.definition_id)
            test.eq(definitions[1].revision, 1)
            test.eq(definitions[1].source_ref, ALTERNATE_SOURCE)
        end)
        test.it("refuses missing host credential setup before creating resources", function()
            local entry = registry.get("bee.harness.launch:harness_setup")
            if not entry then error("host setup") end
            local original = entry.data
            local changed: {[string]: unknown} = {}
            for key, item in pairs(assert(bounds.object(original))) do changed[key] = item end
            changed.credentials = {}
            local target = fresh("setup-no-credential")
            local ok, failure = pcall(function()
                entry.data = changed
                apply(entry)
                local reply = setup(target, RETAINED_DEFINITION)
                test.is_false(reply.ok == true)
                test.eq(#associations(target), 0)
                local listed = value(call("bee.credentials.binding:list", {workspace_id = target}))
                test.eq(#(principals.items(listed.definitions)), 0)
            end)
            entry.data = original
            apply(entry)
            if not ok then error(tostring(failure)) end
        end)
        test.it("refuses changed or conflicting selected setup without replacing an association", function()
            local conflicting_workspace = fresh("setup-conflict")
            value(call("bee.resources.binding:associate", {workspace_id = conflicting_workspace, name = "project", root_ref = ROOT, subpath = "", allowed_access = "read", expected_revision = 0}))
            local conflict = setup(conflicting_workspace, DEFINITION)
            test.is_false(conflict.ok == true)
            test.eq(#associations(conflicting_workspace), 1)
            local plan = value(call("bee.tests.harness.launch:resolve", {definition_ref = DEFINITION}))
            local changed_workspace = fresh("setup-changed")
            local entry = assert(registry.get(DEFINITION))
            local original = entry.data
            local changed: {[string]: unknown} = {}
            for key, item in pairs(assert(bounds.object(original))) do changed[key] = item end
            changed.title = "Changed before setup"
            local ok, failure = pcall(function()
                entry.data = changed
                apply(entry)
                local reply = call_setup({workspace_id = changed_workspace, definition_ref = DEFINITION, expected_plan_digest = plan.plan_digest})
                test.is_false((reply).ok == true)
                test.eq(#associations(changed_workspace), 0)
            end)
            entry.data = original
            apply(entry)
            if not ok then error(tostring(failure)) end
        end)
        fixture.restore_host()
    end)
end
return test.run_cases(define_tests)
