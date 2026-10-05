-- MIT. Launch admission against the Claude protocol fixture: a definition
-- resolves to one measured plan with no effects, admission obtains the
-- attempt-bound grant and projection in the requester's own authority,
-- start runs the carrier to settlement, and a retried start recovers the
-- same attempt without a second action, attempt, turn or receipt.
local test = require("test")
local carrier_fixtures = require("carrier_fixtures")
local principals = require("principals")
local funcs = require("funcs")
local security = require("security")
local process = require("process")
local channel = require("channel")
local registry = require("registry")
local env = require("env")
local exec = require("exec")
local time = require("time")
local hash = require("hash")
local admission = require("admission")
local definitions = require("definitions")
local launch_policy = require("launch_policy")
local machine = require("machine")
local checkpoint = require("checkpoint")
local hook_records = require("hook_records")
local placement_store = require("placement_store")
local capability_grants = require("capability_grants")
local capability_catalog = require("capability_catalog")
local sends = require("sends")
local bounds = require("bounds")
local json = require("json")
local REQUESTER = "bee.test.launcher"
local DEFINITION = "bee.harness.catalog:fixture_definition"
local SHIPPED_SHAPE_DEFINITION = "bee.harness.catalog:shipped_shape_definition"
local SHIPPED_BATCH_POLICY = "bee.driver.claude.security:launch_policy_claude_batch"
local AGENT_DEFINITION = "bee.harness.catalog:agent_fixture_definition"
local AGENT_POLICY = "bee.harness.catalog:agent_fixture_policy"
local AGENT_REVIEWER = "bee.harness.catalog:agent_reviewer"
local AGENT_TRAIT = "bee.harness.catalog:agent_repository_trait"
local RETAINED_DEFINITION = "bee.harness.catalog:retained_fixture_definition"
local EMPTY_DEFINITION = "bee.harness.catalog:setup_empty_definition"
local POLICY = "bee.harness.catalog:fixture_policy"
local ROOT = "bee.harness.catalog:project_fixture"
local SECOND_ROOT = "bee.harness.catalog:git_project_fixture"
local SOURCE = "bee.harness.catalog:launch_sentinel_key"
local ALTERNATE_SOURCE = "bee.harness.catalog:alternate_setup_key"
local counter = 0
local function fresh(prefix: string): string
    counter = counter + 1
    return prefix .. "-" .. tostring(math.floor(time.now():unix_nano() / 1000)) .. "-" .. tostring(counter)
end
local function workspace_id(prefix: string): string
    return assert(hash.sha256(fresh(prefix))):sub(1, 32)
end
local scope_names = {"bee.harness.catalog:saved_profile_test_policy", "bee.harness.catalog:launch_client_policy", "bee.harness.catalog:launch_recovery_client_policy", "bee.harness.catalog:launch_recovery_runtime_policy", "bee.harness.catalog:carrier_client_policy", "bee.security.threads:thread_create_policy", "bee.security.threads:thread_observe_policy",
    "bee.security.threads:thread_lifecycle_policy", "bee.security.threads:thread_carrier_policy", "bee.harness.security:carrier_policy", "bee.harness.catalog:carrier_spawn_policy", "bee.resources.security:resource_manage_policy",
    "bee.resources.security:resource_grant_policy", "bee.credentials.security:credential_manage_policy", "bee.credentials.security:credential_issue_policy", "bee.harness.security:launch_spawn_policy", "bee.harness.security:interactive_session_policy", "bee.harness.catalog:setup_client_policy"}
local function scope(extra: {string}?): security.Scope
    local policies: {security.Policy} = {}
    for index, name in ipairs(scope_names) do
        local policy, err = security.policy(name)
        if err or not policy then error("policy " .. name .. ": " .. tostring(err)) end
        policies[index] = policy
    end
    for _, name in ipairs(extra or {}) do
        local policy, err = security.policy(name)
        if err or not policy then error("policy " .. name .. ": " .. tostring(err)) end
        policies[#policies + 1] = policy
    end
    return security.new_scope(policies)
end
local actor = security.new_actor(REQUESTER)
local function call(target: string, request: unknown): admission.Reply
    local result, err = funcs.new():with_actor(principals.actor(REQUESTER, principals.workspace(request))):with_scope(scope()):call(target, request)
    if err then error(target .. ": " .. tostring(err)) end
    return principals.reply(result)
end
local function call_setup(request: unknown): {[string]: unknown}
    local raw, err = funcs.new():with_actor(principals.actor(REQUESTER, principals.workspace(request)))
        :with_scope(scope()):call("bee.harness.binding:setup", request)
    if err then error("bee.harness.binding:setup: " .. tostring(err)) end
    local reply = assert(bounds.object(raw))
    assert(type(reply.ok) == "boolean" and (reply.error == nil or type(reply.error) == "string"))
    return reply
end
local function call_as_bound(actor_id: string, target: string, request: unknown, workspace_id: unknown,
    extra_policies: {string}?): admission.Reply
    local result, err = funcs.new():with_actor(principals.actor(actor_id, workspace_id))
        :with_scope(scope(extra_policies)):call(target, request)
    if err then error(target .. ": " .. tostring(err)) end
    return principals.reply(result)
end
local function call_as_with_policies(actor_id: string, target: string, request: unknown, extra_policies: {string}): admission.Reply
    return call_as_bound(actor_id, target, request, principals.workspace(request), extra_policies)
end
local function call_as(actor_id: string, target: string, request: unknown): admission.Reply
    return call_as_with_policies(actor_id, target, request, {})
end
local function value(reply: admission.Reply): {[string]: unknown}
    if not reply.ok then error(tostring(reply.error and reply.error.code) .. ": " .. tostring(reply.error and reply.error.message)) end
    return assert(bounds.object(reply.value))
end
-- The host opens the gateway listener; a case whose attempt reaches gateway
-- admission opens it here as the host would, under the manage authority
-- only this call holds.
local function open_gateway()
    local endpoint = registry.get("bee.gateway.api:gateway_endpoint")
    if not endpoint then error("gateway endpoint entry") end
    local policies: {security.Policy} = {}
    for index, name in ipairs({"bee.harness.catalog:gateway_client_policy", "bee.security.gateway:gateway_manage_policy"}) do
        local policy, err = security.policy(name)
        if err or not policy then error("policy " .. name .. ": " .. tostring(err)) end
        policies[index] = policy
    end
    local reply, err = funcs.new():with_actor(actor):with_scope(security.new_scope(policies)):call("bee.gateway.binding:open",
        {address = tostring((assert(bounds.object(endpoint.data))).address)})
    if err then error("bee.gateway.binding:open: " .. tostring(err)) end
    value(principals.reply(reply))
end
local function code(reply: admission.Reply): string
    if reply.ok then error("expected a failure, got success") end
    return reply.error and reply.error.code or ""
end
local function apply(entry: {[string]: unknown})
    local changes = registry.snapshot():changes()
    changes:update(entry)
    local applied, err = changes:apply()
    if not applied then error("apply: " .. tostring(err)) end
end
-- Temporarily replaces one entry's data, restoring it whatever the body does.
local function with_entry(ref: string, mutate: (changed: {[string]: unknown}) -> (), body: () -> ())
    local entry = assert(registry.get(ref))
    local original = entry.data
    local changed: {[string]: unknown} = {}
    for key, item in pairs(assert(bounds.object(original))) do changed[key] = item end
    mutate(changed)
    entry.data = changed
    apply(entry)
    local ok, failure = pcall(body)
    entry.data = original
    apply(entry)
    if not ok then error(tostring(failure)) end
end
local function refusal_message(reply: admission.Reply): string
    if reply.ok then error("expected a failure, got success") end
    return tostring(reply.error and reply.error.message)
end
local function carrier_io(workspace_id: string): machine.IO
    return {
        call = function(target: string, input: unknown): (unknown, string?)
            return funcs.new():with_actor(principals.actor(REQUESTER, workspace_id)):with_scope(scope()):call(target, input)
        end,
        send = function(target: string, topic: string, input: unknown) end,
        self_pid = function(): string return process.pid() end,
        now_ms = function(): integer return math.floor(time.now():unix_nano() / 1000000) end,
        key = function(): string return fresh("key") end,
    }
end
local function shell(command: string): string
    local executor = assert(exec.get("bee.placement.native.env:placement_executor"))
    local proc, exec_error = executor:exec("sh -c '" .. command .. "'")
    if not proc then error("exec " .. command .. ": " .. tostring(exec_error)) end
    local stdout = proc:stdout_stream()
    local started, start_error = proc:start()
    if not started then error("start " .. command .. ": " .. tostring(start_error)) end
    local output = ""
    while true do
        local chunk: unknown = stdout:read(65536)
        if type(chunk) ~= "string" or chunk == "" then break end
        output = output .. (chunk)
    end
    proc:wait()
    stdout:close()
    executor:release()
    return output
end
local function fixture_paths(): (string, string)
    local bin, bin_error = env.get("bee.harness.catalog:fixture_bin")
    local streams, streams_error = env.get("bee.harness.catalog:fixture_streams")
    if bin_error or type(bin) ~= "string" or streams_error or type(streams) ~= "string" then error("fixture paths are not set for the test runtime") end
    return bin, streams
end
local function prepare_host(workspace: string)
    local bin, streams = fixture_paths()
    local policy_entry = registry.get(POLICY)
    if not policy_entry then error("fixture policy") end
    local policy_data = assert(bounds.object(policy_entry.data))
    policy_data.executables = {claude = bin .. "/claude"}
    policy_data.environment = {BEE_FIXTURE_STREAM = streams .. "/claude/stream-json-2/plain.jsonl"}
    apply(policy_entry)
    local roots_entry = registry.get("bee.resources.env:resource_roots")
    if not roots_entry then error("resource roots") end
    local roots_data = assert(bounds.object(roots_entry.data))
    local roots = principals.objects(roots_data.roots)
    roots_data.roots = roots
    local present = false
    for _, root in ipairs(roots) do
        if root.root_ref == ROOT then present = true end
    end
    if not present then
        roots[#roots + 1] = {root_ref = ROOT, access = "write"}
        apply(roots_entry)
    end
    local native_roots = registry.get("bee.placement.native.env:placement_admitted_roots")
    if not native_roots then error("native admitted roots") end
    local native_data = assert(bounds.object(native_roots.data))
    local admitted = principals.objects(native_data.roots)
    native_data.roots = admitted
    local native_present = false
    for _, root in ipairs(admitted) do if root.root_ref == ROOT then native_present = true end end
    if not native_present then
        admitted[#admitted + 1] = {root_ref = ROOT, access = "write"}
        apply(native_roots)
    end
    local setup_entry = registry.get("bee.harness.launch:harness_setup")
    if not setup_entry then error("harness setup") end
    local setup_data = assert(bounds.object(setup_entry.data))
    setup_data.roots = {project = ROOT, session = ROOT}
    setup_data.credentials = {anthropic = {provider = "claude", source = {kind = "env_variable", ref = SOURCE}}}
    apply(setup_entry)
    local mode_entry = registry.get("bee.placement.native.env:placement_resource_mode")
    if not mode_entry then error("resource mode") end
    local mode_data = assert(bounds.object(mode_entry.data))
    mode_data.mode = "granted"
    apply(mode_entry)
    local sources_entry = registry.get("bee.credentials.env:credential_sources")
    if not sources_entry then error("credential sources") end
    local sources_data = assert(bounds.object(sources_entry.data))
    local sources = principals.objects(sources_data.sources)
    sources_data.sources = sources
    sources[#sources + 1] = {ref = SOURCE, workspace_id = "*", audience = REQUESTER, provider = "claude", projection_kinds = {"environment"}}
    sources[#sources + 1] = {ref = "bee.credentials:claude_login_fixture", workspace_id = "*", audience = REQUESTER, provider = "claude", projection_kinds = {"file"}}
    sources[#sources + 1] = {ref = ALTERNATE_SOURCE, workspace_id = "*", audience = REQUESTER, provider = "claude", projection_kinds = {"environment"}}
    apply(sources_entry)
    value(call("bee.resources.binding:associate", {workspace_id = workspace, name = "project", root_ref = ROOT, subpath = "", allowed_access = "write"}))
    value(call("bee.resources.binding:associate", {workspace_id = workspace, name = "session", root_ref = ROOT, subpath = "", allowed_access = "write"}))
    value(call("bee.credentials.binding:define", {workspace_id = workspace, name = "anthropic", provider = "claude", source = {kind = "env_variable", ref = SOURCE}}))
end
local function setup(workspace: string, definition_ref: string): {[string]: unknown}
    local plan = value(call("bee.harness.binding:resolve", {definition_ref = definition_ref}))
    local reply = call_setup({workspace_id = workspace, definition_ref = definition_ref, expected_plan_digest = plan.plan_digest})
    return reply
end
local function associations(workspace: string): {{[string]: unknown}}
    local listed = value(call("bee.resources.binding:list", {workspace_id = workspace}))
    return principals.objects(listed.associations)
end
local function with_host_project_root(root_ref: string, body: () -> ())
    local roots_entry = assert(registry.get("bee.resources.env:resource_roots"))
    local roots_original = roots_entry.data
    local roots_data: {[string]: unknown} = {}
    for key, item in pairs(assert(bounds.object(roots_original))) do roots_data[key] = item end
    local admitted: {{[string]: unknown}} = {}
    for index, item in ipairs(principals.items(roots_data.roots)) do
        local original = assert(bounds.object(item))
        local root: {[string]: unknown} = {}
        for key, value in pairs(original) do root[key] = value end
        admitted[index] = root
    end
    roots_data.roots = admitted
    local found = false
    for _, root in ipairs(admitted) do if root.root_ref == root_ref then found = true end end
    if not found then admitted[#admitted + 1] = {root_ref = root_ref, access = "write"} end

    local setup_entry = assert(registry.get("bee.harness.launch:harness_setup"))
    local setup_original = setup_entry.data
    local setup_data: {[string]: unknown} = {}
    for key, item in pairs(assert(bounds.object(setup_original))) do setup_data[key] = item end
    local selected_roots: {[string]: unknown} = {}
    for key, item in pairs(assert(bounds.object(setup_data.roots))) do selected_roots[key] = item end
    selected_roots.project = root_ref
    setup_data.roots = selected_roots

    local ok, failure = pcall(function()
        roots_entry.data = roots_data
        setup_entry.data = setup_data
        apply(roots_entry)
        apply(setup_entry)
        body()
    end)
    roots_entry.data = roots_original
    setup_entry.data = setup_original
    apply(roots_entry)
    apply(setup_entry)
    if not ok then error(tostring(failure)) end
end
-- Temporarily sets the fixture definition's and its policy's allowed
-- overrides, restoring both whatever the body does.
local function with_overrides(definition_overrides: {string}, policy_overrides: {string}, body: () -> ())
    local definition_entry = assert(registry.get(DEFINITION))
    local policy_entry = assert(registry.get(POLICY))
    local definition_data, policy_data = assert(bounds.object(definition_entry.data)), assert(bounds.object(policy_entry.data))
    local changed_definition: {[string]: unknown} = {}
    for key, item in pairs(definition_data) do changed_definition[key] = item end
    changed_definition.allowed_overrides = definition_overrides
    local changed_policy: {[string]: unknown} = {}
    for key, item in pairs(policy_data) do changed_policy[key] = item end
    changed_policy.allowed_overrides = policy_overrides
    definition_entry.data, policy_entry.data = changed_definition, changed_policy
    apply(definition_entry)
    apply(policy_entry)
    local ok, failure = pcall(body)
    definition_entry.data, policy_entry.data = definition_data, policy_data
    apply(definition_entry)
    apply(policy_entry)
    if not ok then error(tostring(failure)) end
end
local function restore_host()
    local mode_entry = registry.get("bee.placement.native.env:placement_resource_mode")
    if not mode_entry then error("resource mode") end
    local mode_data = assert(bounds.object(mode_entry.data))
    mode_data.mode = "host_configured"
    apply(mode_entry)
end
-- The durable thread is the settlement oracle. launch:start returns the pid
-- of a carrier it spawned unmonitored, which may have settled and exited
-- before the caller could monitor it; the receipt and the ended checkpoint
-- outlive the process.
local function await_settled(thread_id: string, attempt_id: string): {[string]: unknown}
    local cursor = 0
    local settled = false
    while not settled do
        local page = value(call("bee.threads.binding:read_after", {thread_id = thread_id, cursor = cursor, limit = 64, filter = {kinds = {"receipt"}}}))
        for _, item in ipairs(principals.objects(page.records)) do
            if item.attempt_id == attempt_id then settled = true end
        end
        cursor = math.floor(tonumber(page.scanned_through) or cursor)
        if not settled and page.has_more ~= true then
            value(call("bee.threads.binding:watch", {thread_id = thread_id, after_sequence = cursor, wait_ms = 60000}))
        end
    end
    local stored = value(call("bee.threads.binding:checkpoint", {thread_id = thread_id, attempt_id = attempt_id}))
    test.eq(stored.attempt_state, "ended")
    return assert(bounds.object((assert(bounds.object(stored.checkpoint))).terminal))
end
local function kinds(thread_id: string): {string}
    local page = value(call("bee.threads.binding:read_after", {thread_id = thread_id, cursor = 0, limit = 64}))
    local list: {string} = {}
    for index, item in ipairs(principals.objects(page.records)) do list[index] = tostring(item.kind) end
    return list
end
local function count(list: {string}, wanted: string): integer
    local total = 0
    for _, item in ipairs(list) do
        if item == wanted then total = total + 1 end
    end
    return total
end
local function define_tests()
    test.describe("Launch admission", function()
        local roots_entry = assert(registry.get("bee.resources.env:resource_roots"))
        roots_entry.data.roots[#roots_entry.data.roots + 1] = {root_ref = ROOT, access = "write"}
        apply(roots_entry)
        local catalog_scope = security.new_scope({assert(security.policy("bee.workspace.catalog:call_test_policy")),
            assert(security.policy("bee.security.storage:workspace_catalog_manage_policy"))})
        local catalog_reply, catalog_error = funcs.new():with_actor(assert(security.new_actor(REQUESTER))):with_scope(catalog_scope)
            :call("bee.workspace.binding:create", {label = fresh("launch"), root_ref = "bee.harness.catalog:project_fixture", subpath = fresh("launch-home"), create_directory = true})
        if catalog_error then error(tostring(catalog_error)) end
        local workspace = tostring(value(principals.reply(catalog_reply)).workspace_id)
        prepare_host(workspace)
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
        test.it("fences a saved profile revision before admission and rejects preferences outside host policy", function()
            local workspace_id, saved_id = workspace, fresh("profile")
            local function save(revision: integer, title: string, options: {[string]: unknown})
                value(call("bee.harness.binding:call", {operation = "put", workspace_id = workspace_id, profile_id = saved_id,
                    expected_revision = revision, idempotency_key = fresh("save"), profile = {schema_revision = "bee.agent-profile@2", name = title, definition_ref = DEFINITION, driver_binding_ref = "bee.driver.claude.binding:binding", provider = {permission_mode = options.permission_mode, model = options.model}, bee = {mcp = {}}}}))
            end
            save(0, "First profile", {})
            local original = value(call("bee.harness.binding:resolve", {definition_ref = DEFINITION, workspace_id = workspace_id,
                saved_profile_id = saved_id, saved_profile_revision = 1}))
            test.eq(original.saved_profile_id, saved_id)
            test.eq(original.saved_profile_revision, 1)
            test.is_nil(original.preferences)
            local admitted = value(call("bee.harness.binding:admit", {request_id = fresh("saved-profile-admit"), definition_ref = DEFINITION,
                workspace_id = workspace_id, brief = "profile fixture", saved_profile_id = saved_id, saved_profile_revision = 1,
                expected_plan_digest = original.plan_digest}))
            local carrier_request = assert(bounds.object(admitted.request))
            local preferences = assert(bounds.object(carrier_request.preferences))
            test.eq(preferences.instructions, "")
            test.eq(#(principals.items(preferences.mcp_tools)), 0)
            save(1, "Revised profile", {})
            local refused = call("bee.harness.binding:admit", {request_id = fresh("stale-profile"), definition_ref = DEFINITION,
                workspace_id = workspace_id, brief = "never launch", saved_profile_id = saved_id, saved_profile_revision = 1,
                expected_plan_digest = original.plan_digest})
            test.eq(code(refused), "CONFLICT")
            local updated = value(call("bee.harness.binding:resolve", {definition_ref = DEFINITION, workspace_id = workspace_id,
                saved_profile_id = saved_id, saved_profile_revision = 2}))
            test.neq(original.plan_digest, updated.plan_digest)
            save(2, "Forbidden option", {permission_mode = "dontAsk"})
            local unsafe = call("bee.harness.binding:resolve", {definition_ref = DEFINITION, workspace_id = workspace_id,
                saved_profile_id = saved_id, saved_profile_revision = 3})
            test.is_false(unsafe.ok)
        end)
        test.it("applies credential selectors and independent narrowed gateway file grants", function()
            for _, refs in ipairs({{}, {"anthropic"}}) do
                local saved_id = fresh("credential-profile")
                value(call("bee.harness.binding:call", {operation = "put", workspace_id = workspace, profile_id = saved_id,
                    expected_revision = 0, idempotency_key = fresh("save"), profile = {schema_revision = "bee.agent-profile@2", name = "Selected credentials",
                        definition_ref = DEFINITION, driver_binding_ref = "bee.driver.claude.binding:binding", provider = {},
                        bee = {mcp = {}, credential_refs = refs, files = {{workspace_id = workspace, resource = "project", subpath = "", access = "read"}}}}}))
                local plan = value(call("bee.harness.binding:resolve", {definition_ref = DEFINITION, workspace_id = workspace,
                    saved_profile_id = saved_id, saved_profile_revision = 1}))
                local admitted = value(call("bee.harness.binding:admit", {request_id = fresh("credential-admit"), definition_ref = DEFINITION,
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
                expected_revision = 0, idempotency_key = fresh("save"), profile = {schema_revision = "bee.agent-profile@2", name = "Undeclared",
                    definition_ref = DEFINITION, driver_binding_ref = "bee.driver.claude.binding:binding", provider = {}, bee = {credential_refs = {"undeclared"}, mcp = {}}}}))
            local refused = call("bee.harness.binding:resolve", {definition_ref = DEFINITION, workspace_id = workspace, saved_profile_id = saved_id, saved_profile_revision = 1})
            test.eq(code(refused), "DENIED")
        end)
        test.it("honors credential environment destinations and rejects retargeting or literal conflicts", function()
            local listed = value(call("bee.credentials.binding:list", {workspace_id = workspace}))
            local definitions = assert(bounds.array(listed.definitions, 64))
            local destination = assert(bounds.id(assert(bounds.object(definitions[1])).destination))
            local descriptor_ref = "bee.driver.claude.descriptor:cli"
            local declaration = assert(registry.get(descriptor_ref))
            local policy_entry = assert(registry.get(POLICY))
            local saved_descriptor, saved_policy = assert(json.encode(declaration.data)), assert(json.encode(policy_entry.data))
            local fields = assert(bounds.object(assert(bounds.object(assert(bounds.object(declaration.data)).options)).fields))
            local properties: {[string]: unknown} = {}
            local value_schema = {type = "object", additionalProperties = false, required = {"kind"}, properties = {
                kind = {type = "string", enum = {"credential", "literal"}}, credential_ref = {type = "string", maxLength = 128}, value = {type = "string", maxLength = 128}}}
            properties[destination], properties.OTHER_PROVIDER_TOKEN = value_schema, value_schema
            fields.env = {path = "provider.env", value_schema = {type = "object", additionalProperties = false, properties = properties},
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
                    expected_revision = 0, idempotency_key = fresh("save"), profile = {schema_revision = "bee.agent-profile@2", name = "Environment",
                        definition_ref = DEFINITION, driver_binding_ref = "bee.driver.claude.binding:binding", provider = {env = environment}, bee = {credential_refs = {"anthropic"}, mcp = {}}}}))
                local plan = value(call("bee.harness.binding:resolve", {definition_ref = DEFINITION, workspace_id = workspace, saved_profile_id = saved_id, saved_profile_revision = 1}))
                replies[index] = call("bee.harness.binding:admit", {request_id = fresh("env-admit"), definition_ref = DEFINITION, workspace_id = workspace,
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
            local refused = admission.resolve(DEFINITION, nil, nil, nil, nil, nil, nil, nil, nil, {kind = "native", home = "private"})
            test.is_nil(refused)
            with_overrides({"brief", "placement"}, {"placement"}, function()
                local resolved = admission.resolve(DEFINITION, nil, nil, nil, nil, nil, nil, nil, nil, {kind = "native", home = "private"})
                local selected = assert(resolved)
                test.neq(selected.plan_digest, original.plan_digest)
                test.eq(selected.placement_kind, "native")
                test.eq(selected.effective_profile and selected.effective_profile.placement and selected.effective_profile.placement.home, "private")
                local refused = admission.resolve(DEFINITION, nil, nil, nil, nil, nil, nil, nil, nil, {kind = "native", home = "machine"})
                test.is_nil(refused)
            end)
            with_overrides({"brief", "placement"}, {}, function()
                local refused = admission.resolve(DEFINITION, nil, nil, nil, nil, nil, nil, nil, nil, {kind = "native", home = "private"})
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
            local admitted = value(call("bee.harness.binding:admit", {request_id = fresh("setup-admit"), definition_ref = RETAINED_DEFINITION,
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
                local admitted = value(call("bee.harness.binding:admit", {request_id = fresh("setup-root-refresh-admit"),
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
            local source = {kind = "fs_directory", ref = "bee.credentials:claude_login_fixture"}
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
            local plan = value(call("bee.harness.binding:resolve", {definition_ref = DEFINITION}))
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
        test.it("rejects an unauthorized caller, private backend calls and unknown definitions", function()
            local plan = value(call("bee.harness.binding:resolve", {definition_ref = DEFINITION}))
            local no_setup, no_setup_error = funcs.new():with_actor(security.new_actor("bee.test.setup.denied")):with_scope(security.new_scope({})):call("bee.harness.binding:setup",
                {workspace_id = fresh("setup-denied"), definition_ref = DEFINITION, expected_plan_digest = plan.plan_digest})
            test.is_true(no_setup_error ~= nil or (type(no_setup) == "table" and no_setup.ok == false))
            local call_only = assert(security.policy("bee.harness.catalog:setup_call_only_policy"))
            local denied_workspace = fresh("setup-operation-denied")
            local denied, denied_error = funcs.new():with_actor(principals.actor(REQUESTER, denied_workspace)):with_scope(security.new_scope({call_only})):call("bee.harness.binding:setup",
                {workspace_id = denied_workspace, definition_ref = DEFINITION, expected_plan_digest = plan.plan_digest})
            test.is_nil(denied_error)
            test.is_true(type(denied) == "table")
            if type(denied) ~= "table" then error("missing denied setup reply") end
            test.eq(denied.ok, false)
            test.eq(denied.error, "setup is not authorized")
            test.eq(#associations(denied_workspace), 0)
            local policy, policy_error = security.policy("bee.harness.catalog:setup_client_policy")
            if policy_error or not policy then error(tostring(policy_error)) end
            local private_workspace = fresh("setup-private")
            local private_reply, private_error = funcs.new():with_actor(principals.actor(REQUESTER, private_workspace)):with_scope(security.new_scope({policy})):call("bee.harness.binding:setup_backend",
                {workspace_id = private_workspace, definition_ref = DEFINITION, expected_plan_digest = plan.plan_digest})
            test.is_true(private_error ~= nil or (type(private_reply) == "table" and private_reply.ok == false))
            local unknown = call_setup({workspace_id = fresh("setup-unknown"), definition_ref = "bee.harness.catalog:missing",
                expected_plan_digest = plan.plan_digest})
            test.is_false((unknown).ok == true)
            local empty = setup(fresh("setup-empty"), EMPTY_DEFINITION)
            test.is_true(empty.ok == true)
            test.eq(#(principals.items(empty.resources)), 0)
        end)
        test.it("decodes an empty window prompt but refuses it for a resolved structured launch", function()
            local request = {request_id = fresh("request"), definition_ref = DEFINITION, workspace_id = fresh("workspace"), brief = ""}
            local decoded, decode_error = admission.decode_request(request)
            if not decoded then error(tostring(decode_error)) end
            test.eq(decoded.brief, "")
            local reply = call("bee.harness.binding:admit", request)
            test.eq(code(reply), "INVALID")
            test.eq(reply.error and reply.error.message, "a structured launch needs a nonempty brief")
        end)
        test.it("accepts only a complete bounded origin view in launch requests", function()
            local base = {request_id = fresh("origin-request"), definition_ref = DEFINITION, workspace_id = fresh("origin-workspace"), brief = ""}
            local valid = {}
            for key, item in pairs(base) do valid[key] = item end
            valid.origin_view = {view_id = "view-origin", instance_id = "instance-origin"}
            local decoded, decode_error = admission.decode_request(valid)
            if not decoded then error(tostring(decode_error)) end
            test.eq(decoded.origin_view and decoded.origin_view.view_id, "view-origin")
            test.eq(decoded.origin_view and decoded.origin_view.instance_id, "instance-origin")

            local malformed = {
                {view_id = "view-origin"},
                {instance_id = "instance-origin"},
                {view_id = "view-origin", instance_id = "instance-origin", extra = true},
                "view-origin",
            }
            for _, origin_view in ipairs(malformed) do
                local request = {}
                for key, item in pairs(base) do request[key] = item end
                request.origin_view = origin_view
                local _, invalid = admission.decode_request(request)
                test.eq(invalid == nil, false)
            end
        end)
        test.it("pins explicit machine-login projections for structured default sessions", function()
            for _, provider in ipairs({"claude", "codex", "agy", "muse", "grok", "opencode"}) do
                local ref = "bee.driver." .. provider .. ".profiles:default_window"
                local entry = assert(registry.get(ref))
                local decoded = assert(definitions.decode(ref, entry))
                test.not_nil(decoded.session_credentials)
                local found = false
                for _, name in ipairs(decoded.session_credentials or {}) do
                    if name == provider .. "_login" then found = true end
                end
                test.is_true(found)
            end
            local entry = assert(registry.get("bee.driver.claude.profiles:default_window"))
            local changed = {data = {}}
            for name, value in pairs(entry.data) do changed.data[name] = value end
            changed.data.session_credentials = {false}
            local invalid, err = definitions.decode("bee.driver.claude.profiles:default_window", changed)
            test.is_nil(invalid)
            test.not_nil(err)
        end)
        test.it("ships hidden research routes without harness turn ceilings", function()
            local cases = {
                {definition = "bee.driver.codex.profiles:research_batch", policy = "bee.driver.codex.security:launch_policy_codex_batch",
                    binding = "bee.driver.codex.binding:binding", credential = "codex_login", executable = "bee.driver.codex.env:executable",
                    config = "bee.driver.codex.env:config_home", option = "sandbox", expected = "workspace-write"},
                {definition = "bee.driver.claude.profiles:research_batch", policy = "bee.driver.claude.security:launch_policy_claude_batch",
                    binding = "bee.driver.claude.binding:binding", credential = "claude_api_key", executable = "bee.driver.claude.env:executable",
                    config = "bee.driver.claude.env:config_home", option = "permission_mode", expected = "default"},
                {definition = "bee.driver.agy.profiles:research_batch", policy = "bee.driver.agy.security:launch_policy_agy_batch",
                    binding = "bee.driver.agy.binding:binding", credential = "agy_login", executable = "bee.driver.agy.env:executable",
                    option = "model", expected = "gemini-3.8-flash", additional_options = {effort = "high"}},
                {definition = "bee.driver.muse.profiles:research_batch", policy = "bee.driver.muse.security:launch_policy_muse_batch",
                    binding = "bee.driver.muse.binding:binding", credential = "muse_login", executable = "bee.driver.muse.env:executable",
                    option = "approval_mode", expected = "on-request"},
                {definition = "bee.driver.opencode.profiles:research_batch", policy = "bee.driver.opencode.security:launch_policy_opencode_batch",
                    binding = "bee.driver.opencode.binding:binding", credential = "opencode_login", executable = "bee.driver.opencode.env:executable", unconfined = true},
                {definition = "bee.driver.grok.profiles:research_batch", policy = "bee.driver.grok.security:launch_policy_grok_batch",
                    binding = "bee.driver.grok.binding:binding", credential = "grok_login", executable = "bee.driver.grok.env:executable",
                    option = "permission_mode", expected = "default", unconfined = true},
            }
            for _, selected in ipairs(cases) do
                local entry = assert(registry.get(selected.definition))
                local decoded, definition_error = definitions.decode(selected.definition, entry)
                if not decoded then error(tostring(definition_error)) end
                test.eq(decoded.binding_ref, selected.binding)
                test.eq(decoded.profile_id, "batch")
                test.eq(decoded.default_mode, "batch")
                test.eq(decoded.thread_policy.kind, "caller")
                test.eq(decoded.allowed_overrides[1], "thread")
                test.eq(decoded.allowed_overrides[2], "workdir")
                test.eq(#decoded.allowed_overrides, 2)
                if selected.credential then test.eq(decoded.credentials[1], selected.credential)
                else test.eq(#decoded.credentials, 0) end
                test.is_false(decoded.presentation.start_menu)
                if selected.unconfined then test.is_true(decoded.unconfined)
                else test.is_false(decoded.unconfined) end
                local policy_entry = assert(registry.get(selected.policy))
                local policy, policy_error = launch_policy.decode(selected.policy, policy_entry,
                    function(ref: string): (string?, string?)
                        if ref == selected.executable then return "/usr/bin/research-agent", nil end
                        if selected.config and ref == selected.config then return "", nil end
                        return nil, "unadmitted environment reference"
                    end)
                if not policy then error(tostring(policy_error)) end
                if selected.option then test.eq(policy.prepare_options[selected.option], selected.expected)
                else test.eq(next(policy.prepare_options or {}), nil) end
                test.is_nil(policy.prepare_options.turn_budget)
                test.is_nil(policy.prepare_options.max_turns)
                test.is_nil(policy.prepare_options.max_steps)
                test.is_nil(policy.prepare_options.print_timeout)
                test.eq(table.concat(policy.allowed_overrides, ","), "thread,workdir")
                for option, expected in pairs(selected.additional_options or {}) do
                    test.eq(policy.prepare_options[option], expected)
                end
                -- Every orchestrator-launched worker runs without host HOME
                -- inheritance and without a prompt-free permission mode: the
                -- person chose no host home for these routes.
                test.is_false(policy.allow_host_home)
                for name, item in pairs(policy.prepare_options) do
                    if type(item) == "string" then
                        test.is_true(item ~= "dontAsk" and item ~= "bypassPermissions" and item ~= "never",
                            selected.policy .. "." .. name .. " admits a prompt-free mode")
                    end
                end
                if selected.binding == "bee.driver.agy.binding:binding" then
                    test.eq(#policy.gateway_hooks, 0)
                    test.eq(policy.prepare_options.sandbox, true)
                    local has_thread_message = false
                    for _, tool in ipairs(policy.gateway_tools) do if tool == "thread_message" then has_thread_message = true end end
                    test.is_true(has_thread_message)
                end
                local retained_tools = {
                    session_catalog = true, session_open = true, session_run = true, session_send = true,
                    session_await = true, session_join = true, session_get = true, session_list = true,
                    session_cancel = true, session_close = true, thread_read = true, thread_message = true,
                }
                local seen_tools: {[string]: boolean} = {}
                for _, tool in ipairs(policy.gateway_tools) do
                    test.is_true(retained_tools[tool] == true, selected.policy .. " admits removed tool " .. tool)
                    test.is_false(seen_tools[tool] == true, selected.policy .. " repeats tool " .. tool)
                    seen_tools[tool] = true
                end
                test.eq(#policy.gateway_tools, 12)
                for tool in pairs(retained_tools) do test.is_true(seen_tools[tool] == true, selected.policy .. " omits " .. tool) end
            end
        end)
        test.it("keeps the named Codex profile policy bounded", function()
            -- The named Codex route projects the selected config profile
            -- into its private home while gaining the workspace-write CLI
            -- sandbox.
            local named_entry = assert(registry.get("bee.driver.codex.security:launch_policy_codex_named_batch"))
            local named, named_error = launch_policy.decode("bee.driver.codex.security:launch_policy_codex_named_batch", named_entry,
                function(ref: string): (string?, string?)
                    if ref == "bee.driver.codex.env:executable" then return "/usr/bin/named-agent", nil end
                    if ref == "bee.driver.codex.env:config_home" then return "/home/person/.codex", nil end
                    return nil, "unadmitted environment reference"
                end)
            if not named then error(tostring(named_error)) end
            test.is_false(named.allow_host_home)
            test.eq(named.prepare_options.sandbox, "workspace-write")
        end)
        test.it("ships every driver route with thread and workdir overrides its host policy admits, and no placement override", function()
            local shipped = {
                {"bee.driver.claude.profiles:default_window", "bee.driver.claude.security:launch_policy_claude_window"}, {"bee.driver.claude.profiles:research_batch", "bee.driver.claude.security:launch_policy_claude_batch"},
                {"bee.driver.codex.profiles:default_window", "bee.driver.codex.security:launch_policy_codex_window"}, {"bee.driver.codex.profiles:research_batch", "bee.driver.codex.security:launch_policy_codex_batch"},
                {"bee.driver.codex.profiles:named_batch", "bee.driver.codex.security:launch_policy_codex_named_batch"},
                {"bee.driver.muse.profiles:default_window", "bee.driver.muse.security:launch_policy_muse_window"}, {"bee.driver.muse.profiles:research_batch", "bee.driver.muse.security:launch_policy_muse_batch"},
                {"bee.driver.agy.profiles:default_window", "bee.driver.agy.security:launch_policy_agy_window"}, {"bee.driver.agy.profiles:research_batch", "bee.driver.agy.security:launch_policy_agy_batch"},
                {"bee.driver.grok.profiles:default_window", "bee.driver.grok.security:launch_policy_grok_window"}, {"bee.driver.grok.profiles:research_batch", "bee.driver.grok.security:launch_policy_grok_batch"},
                {"bee.driver.opencode.profiles:default_window", "bee.driver.opencode.security:launch_policy_opencode_window"}, {"bee.driver.opencode.profiles:research_batch", "bee.driver.opencode.security:launch_policy_opencode_batch"},
            }
            for _, pair in ipairs(shipped) do
                local decoded, definition_error = definitions.decode(pair[1], assert(registry.get(pair[1])))
                if not decoded then error(tostring(definition_error)) end
                test.is_true(definitions.allows(decoded, "workdir"), pair[1] .. " allows no workdir override")
                test.is_true(definitions.allows(decoded, "thread"), pair[1] .. " allows no thread override")
                test.is_false(definitions.allows(decoded, "placement"), pair[1] .. " allows a placement override")
                local data = assert(bounds.object(assert(registry.get(pair[2])).data))
                test.eq(table.concat(principals.strings(data.allowed_overrides), ","), "thread,workdir", pair[2] .. " admits other overrides")
            end
        end)
        test.it("admits a shared caller thread only after checking membership and before acquiring launch resources", function()
            local entry = assert(registry.get(DEFINITION))
            local original = entry.data
            local changed: {[string]: unknown} = {}
            for key, item in pairs(assert(bounds.object(original))) do changed[key] = item end
            changed.allowed_overrides = {"thread"}
            changed.thread_policy = {kind = "caller"}
            local ok, failure = pcall(function()
                entry.data = changed
                apply(entry)
                local shared = fresh("research-thread")
                value(call("bee.threads.binding:create", {thread_id = shared, idempotency_key = fresh("create"), title = "Research"}))
                local admitted = value(call("bee.harness.binding:admit", {request_id = fresh("shared-agent"), definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "independent finding", thread_id = shared}))
                test.eq(admitted.thread_id, shared)
                test.eq((assert(bounds.object(admitted.request))).thread_id, shared)

                local foreign_owner = fresh("foreign-owner")
                local foreign_thread = fresh("foreign-thread")
                value(call_as(foreign_owner, "bee.threads.binding:create", {thread_id = foreign_thread,
                    idempotency_key = fresh("foreign-create"), title = "Foreign"}))
                local before = value(call_as(foreign_owner, "bee.threads.binding:read_after", {thread_id = foreign_thread, cursor = 0}))
                local resources_before = value(call("bee.resources.binding:list", {workspace_id = workspace}))
                local credentials_before = value(call("bee.credentials.binding:list", {workspace_id = workspace}))
                local refused = call("bee.harness.binding:admit", {request_id = fresh("foreign-agent"), definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "must not start", thread_id = foreign_thread})
                test.eq(code(refused), "DENIED")
                local after = value(call_as(foreign_owner, "bee.threads.binding:read_after", {thread_id = foreign_thread, cursor = 0}))
                test.eq(#(principals.items(after.records)), #(principals.items(before.records)))
                local resources_after = value(call("bee.resources.binding:list", {workspace_id = workspace}))
                local credentials_after = value(call("bee.credentials.binding:list", {workspace_id = workspace}))
                test.eq(#(principals.items(resources_after.grants)), #(principals.items(resources_before.grants)))
                test.eq(#(principals.items(credentials_after.projections)), #(principals.items(credentials_before.projections)))
            end)
            entry.data = original
            apply(entry)
            if not ok then error(tostring(failure)) end
        end)
        test.it("admits a reopened app through its active stable-family thread membership", function()
            local entry = assert(registry.get(DEFINITION))
            local original = entry.data
            local changed: {[string]: unknown} = {}
            for key, item in pairs(assert(bounds.object(original))) do changed[key] = item end
            changed.allowed_overrides = {"thread"}
            changed.thread_policy = {kind = "caller"}
            local ok, failure = pcall(function()
                entry.data = changed
                apply(entry)
                local alias_workspace = string.rep("b", 32)
                local definition_id = "bee.harness.catalog:stable_family_fixture"
                local stable = "bee.application:" .. alias_workspace .. ":" .. fresh("stable-family")
                local old_app = "bee.application:" .. alias_workspace .. ":" .. fresh("old-app")
                local reopened_app = "bee.application:" .. alias_workspace .. ":" .. fresh("reopened-app")
                local unattested_app = "bee.application:" .. alias_workspace .. ":" .. fresh("unattested-app")
                local broker = "bee.test.alias-broker"
                local alias_policies = {"bee.security.threads:application_thread_alias_call_policy",
                    "bee.security.threads:application_thread_alias_policy"}
                local function attest(instance: string)
                    value(call_as_with_policies(broker, "bee.threads.binding:register_app_alias", {
                        stable = stable, instance = instance, workspace_id = alias_workspace, definition_id = definition_id,
                    }, alias_policies))
                end
                local function retire(instance: string)
                    value(call_as_with_policies(broker, "bee.threads.binding:retire_app_alias", {
                        stable = stable, instance = instance, workspace_id = alias_workspace, definition_id = definition_id,
                    }, alias_policies))
                end
                local function workspace_call(target: string, request: {[string]: unknown})
                    request.workspace_id = alias_workspace
                    value(call(target, request))
                end
                workspace_call("bee.resources.binding:associate", {name = "project", root_ref = ROOT,
                    subpath = "", allowed_access = "write"})
                workspace_call("bee.resources.binding:associate", {name = "session", root_ref = ROOT,
                    subpath = "", allowed_access = "write"})
                workspace_call("bee.credentials.binding:define", {name = "anthropic", provider = "claude",
                    source = {kind = "env_variable", ref = SOURCE}})
                with_entry("bee.credentials.env:credential_sources", function(source_entry)
                    local sources = principals.objects(source_entry.sources)
                    local copied: {{[string]: unknown}} = {}
                    for index, source in ipairs(sources) do
                        local item: {[string]: unknown} = {}
                        for key, value in pairs(source) do item[key] = value end
                        if item.ref == SOURCE then item.audience = "*" end
                        copied[index] = item
                    end
                    source_entry.sources = copied
                end, function()
                    attest(old_app)
                    local shared = fresh("reopened-app-thread")
                    value(call_as_bound(old_app, "bee.threads.binding:create", {thread_id = shared,
                        idempotency_key = fresh("create"), title = "Research"}, alias_workspace, {}))
                    attest(reopened_app)

                    local visible = value(call_as_bound(reopened_app, "bee.threads.binding:get", {thread_id = shared},
                        alias_workspace, {}))
                    local membership = assert(bounds.object(visible.membership))
                    test.eq(membership.member_id, old_app)
                    test.eq(membership.active, true)

                    local admitted = value(call_as(reopened_app, "bee.harness.binding:admit", {
                        request_id = fresh("reopened-app-launch"), definition_ref = DEFINITION,
                        workspace_id = alias_workspace, brief = "continue research", thread_id = shared,
                    }))
                    test.eq(admitted.thread_id, shared)

                    retire(old_app)
                    local reopened_thread = fresh("reopened-app-owned-thread")
                    value(call_as_bound(reopened_app, "bee.threads.binding:create", {thread_id = reopened_thread,
                        idempotency_key = fresh("create"), title = "Reopened app work"}, alias_workspace, {}))
                    test.eq(code(call_as(old_app, "bee.harness.binding:admit", {
                        request_id = fresh("retired-app-launch"), definition_ref = DEFINITION,
                        workspace_id = alias_workspace, brief = "retired callers cannot launch", thread_id = reopened_thread,
                    })), "DENIED")

                    test.eq(code(call_as_bound(unattested_app, "bee.threads.binding:get", {thread_id = shared},
                        alias_workspace, {})), "DENIED")
                    test.eq(code(call_as(unattested_app, "bee.harness.binding:admit", {
                        request_id = fresh("unattested-app-launch"), definition_ref = DEFINITION,
                        workspace_id = alias_workspace, brief = "must remain denied", thread_id = shared,
                    })), "DENIED")
                end)
            end)
            entry.data = original
            apply(entry)
            if not ok then error(tostring(failure)) end
        end)
        test.it("refuses caller environment before admitting a thread", function()
            for _, environment in ipairs({{}, {BEE_PROFILE_VALUE = "caller-value"}}) do
                local request_id = fresh("environment")
                local reply = call("bee.harness.binding:admit", {request_id = request_id, definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "ping", environment = environment})
                test.eq(code(reply), "INVALID")
                test.is_true(reply.error ~= nil and tostring(reply.error.message):find("environment", 1, true) ~= nil)
                local absent = call("bee.threads.binding:get", {thread_id = "thread:" .. request_id})
                test.eq(code(absent), "NOT_FOUND")
            end
        end)
        test.it("refuses an unlinked carrier host before admitting a thread", function()
            local entry = registry.get("bee.harness.env:carrier_host_ref")
            if not entry then error("carrier host reference") end
            local original = entry.data
            entry.data = {}
            apply(entry)
            local request_id = fresh("unlinked")
            local reply = call("bee.harness.binding:start", {request_id = request_id, definition_ref = DEFINITION, workspace_id = workspace, brief = "ping"})
            entry.data = original
            apply(entry)
            test.eq(code(reply), "UNAVAILABLE")
            test.eq(reply.error and reply.error.message, "carrier process host is not linked")
            local absent = call("bee.threads.binding:get", {thread_id = "thread:" .. request_id})
            test.eq(code(absent), "NOT_FOUND")
        end)
        test.it("keeps definition and policy measurements in the selected registry generation", function()
            local pinned, pin_error = registry.snapshot()
            if not pinned then error(tostring(pin_error)) end
            local before, before_error = admission.read(pinned, DEFINITION, nil)
            if not before then error(tostring(before_error and before_error.error and before_error.error.message)) end
            local definition_entry = registry.get(DEFINITION)
            local policy_entry = registry.get(POLICY)
            if not definition_entry or not policy_entry then error("launch fixture entries") end
            local original_definition = definition_entry.data
            local original_policy = policy_entry.data
            local changed_definition: {[string]: unknown} = {}
            local changed_policy: {[string]: unknown} = {}
            for key, item in pairs(assert(bounds.object(original_definition))) do changed_definition[key] = item end
            for key, item in pairs(assert(bounds.object(original_policy))) do changed_policy[key] = item end
            changed_definition.title = "Changed launch title"
            changed_policy.stop_grace_ms = 23456
            local ok, failure = pcall(function()
                definition_entry.data = changed_definition
                policy_entry.data = changed_policy
                local changes = registry.snapshot():changes()
                changes:update(definition_entry)
                changes:update(policy_entry)
                local applied, apply_error = changes:apply()
                if not applied then error(tostring(apply_error)) end
                local retained, retained_error = admission.read(pinned, DEFINITION, nil)
                if not retained then error(tostring(retained_error and retained_error.error and retained_error.error.message)) end
                test.eq(retained.definition_digest, before.definition_digest)
                test.eq(retained.policy_digest, before.policy_digest)
                test.eq(retained.plan_digest, before.plan_digest)
                test.eq(retained.catalog_generation, before.catalog_generation)
                local current, current_error = admission.resolve(DEFINITION, nil)
                if not current then error(tostring(current_error and current_error.error and current_error.error.message)) end
                test.is_true(current.definition_digest ~= before.definition_digest)
                test.is_true(current.policy_digest ~= before.policy_digest)
                test.is_true(current.plan_digest ~= before.plan_digest)
                test.is_true(current.catalog_generation > before.catalog_generation)
                test.eq(current.binding_digest, before.binding_digest)
                test.eq(current.profile_digest, before.profile_digest)
            end)
            definition_entry.data = original_definition
            policy_entry.data = original_policy
            local restoration = registry.snapshot():changes()
            restoration:update(definition_entry)
            restoration:update(policy_entry)
            local restored, restore_error = restoration:apply()
            if not restored then error("restore launch fixture: " .. tostring(restore_error)) end
            if not ok then error(tostring(failure)) end
        end)
        test.it("resolves a definition to one measured plan without effects", function()
            local plan = value(call("bee.harness.binding:resolve", {definition_ref = DEFINITION}))
            test.eq(plan.launch_id, "claude-fixture")
            test.eq(plan.mode, "batch")
            test.eq(#(plan.plan_digest), 64)
            local again = value(call("bee.harness.binding:resolve", {definition_ref = DEFINITION}))
            test.eq(again.plan_digest, plan.plan_digest)
            test.eq(code(call("bee.harness.binding:resolve", {definition_ref = DEFINITION, mode = "window"})), "FORBIDDEN")
            test.eq(code(call("bee.harness.binding:resolve", {definition_ref = "bee.harness.catalog:nothing"})), "NOT_FOUND")
            local entry = registry.get(DEFINITION)
            if not entry then error("definition") end
            local data = assert(bounds.object(entry.data))
            local original = data.title
            data.title = "Retitled fixture"
            apply(entry)
            local moved = value(call("bee.harness.binding:resolve", {definition_ref = DEFINITION}))
            test.neq(moved.plan_digest, plan.plan_digest)
            data.title = original
            apply(entry)
        end)
        test.it("fences admission to the selected plan before creating a thread", function()
            local selected = value(call("bee.harness.binding:resolve", {definition_ref = DEFINITION}))
            local policy_entry = registry.get(POLICY)
            if not policy_entry then error("launch policy") end
            local original_policy = policy_entry.data
            local changed_policy: {[string]: unknown} = {}
            for key, item in pairs(assert(bounds.object(original_policy))) do changed_policy[key] = item end
            changed_policy.stop_grace_ms = 23456

            local mismatch_request = fresh("plan-fenced")
            local ok, failure = pcall(function()
                policy_entry.data = changed_policy
                apply(policy_entry)
                local changed = value(call("bee.harness.binding:resolve", {definition_ref = DEFINITION}))
                test.neq(changed.plan_digest, selected.plan_digest)

                local refused = call("bee.harness.binding:admit", {request_id = mismatch_request, definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "ping", expected_plan_digest = selected.plan_digest})
                test.eq(code(refused), "CONFLICT")
                test.eq(code(call("bee.threads.binding:get", {thread_id = "thread:" .. mismatch_request})), "NOT_FOUND")
            end)

            policy_entry.data = original_policy
            local restoration = registry.snapshot():changes()
            restoration:update(policy_entry)
            local restored, restore_error = restoration:apply()
            if not restored then error("restore launch policy: " .. tostring(restore_error)) end
            if not ok then error(tostring(failure)) end

            local restored_plan = value(call("bee.harness.binding:resolve", {definition_ref = DEFINITION}))
            test.eq(restored_plan.plan_digest, selected.plan_digest)
            local matching_request = fresh("plan-matched")
            local matching = value(call("bee.harness.binding:admit", {request_id = matching_request, definition_ref = DEFINITION,
                workspace_id = workspace, brief = "ping", expected_plan_digest = selected.plan_digest}))
            local matching_plan = assert(bounds.object(matching.plan))
            test.eq(matching_plan.plan_digest, selected.plan_digest)
            test.eq(matching.thread_id, "thread:" .. matching_request)
        end)
        test.it("rejects a malformed expected plan digest", function()
            local request_id = fresh("plan-malformed")
            local refused = call("bee.harness.binding:admit", {request_id = request_id, definition_ref = DEFINITION,
                workspace_id = workspace, brief = "ping", expected_plan_digest = string.rep("A", 64)})
            test.eq(code(refused), "INVALID")
            test.eq(code(call("bee.threads.binding:get", {thread_id = "thread:" .. request_id})), "NOT_FOUND")
        end)
        test.it("defers driver configuration until placement supplies the actual HOME", function()
            local binding = assert(registry.get("bee.driver.claude.binding:binding"))
            local original = binding.data
            binding.data = {contracts = {
                {contract = "bee.driver:driver", methods = {
                    prepare = "bee.driver.claude.binding:prepare", dispatch = "bee.driver.claude.binding:dispatch",
                    normalize = "bee.driver.claude.binding:normalize", configure = "bee.harness.catalog:configuration_probe",
                }},
                {contract = "bee.driver:locate_facet", methods = {locate = "bee.driver.claude.binding:locate"}},
            }}
            local ok, failure = pcall(function()
                apply(binding)
                local selected = value(call("bee.harness.binding:resolve", {definition_ref = DEFINITION}))
                local request_id = fresh("complete-config-inputs")
                local admitted = value(call("bee.harness.binding:admit", {request_id = request_id, definition_ref = DEFINITION,
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
                local selected = value(call("bee.harness.binding:resolve", {definition_ref = SHIPPED_SHAPE_DEFINITION}))
                local admitted = value(call("bee.harness.binding:admit", {request_id = fresh("claude-host-home-admit"),
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
                local unapproved = value(call("bee.harness.binding:admit", {request_id = fresh("unapproved-host-home"), definition_ref = DEFINITION,
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
                local admitted = value(call("bee.harness.binding:admit", {request_id = request_id, definition_ref = DEFINITION,
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
                changed_policy.provider_ref = "bee.harness.catalog:codex_fixture_provider"
                policy_entry.data = changed_policy
                apply(policy_entry)
                local conflicted = value(call("bee.harness.binding:admit", {request_id = fresh("provider-home-conflict"), definition_ref = DEFINITION,
                    workspace_id = workspace, brief = ""}))
                local refused, refusal = machine.plan(io, carrier_fixtures.request(conflicted.request))
                test.is_nil(refused)
                test.eq(refusal, "selected provider configuration requires a private-home profile")
                local check_db = assert(placement_store.open())
                local unintended = placement_store.row(check_db, assert(bounds.id(conflicted.attempt_id)))
                check_db:release()
                test.is_nil(unintended)
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
            local codex_policy = assert(registry.get("bee.harness.catalog:codex_fixture_policy"))
            local original_definition, original_policy = definition_entry.data, codex_policy.data
            local changed_definition: {[string]: unknown} = {}
            local changed_policy: {[string]: unknown} = {}
            for name, value in pairs(assert(bounds.object(original_definition))) do changed_definition[name] = value end
            for name, value in pairs(assert(bounds.object(original_policy))) do changed_policy[name] = value end
            changed_definition.binding_ref = "bee.driver.codex.binding:binding"
            changed_definition.profile_id = "window"
            changed_definition.default_mode = "window"
            changed_definition.session_resource = "session"
            changed_definition.policy_ref = "bee.harness.catalog:codex_fixture_policy"
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
                shell("printf \"model = \\\"fixture\\\"\\n\" > " .. codex_home .. "/ds-flash.config.toml")
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
                    profile = {schema_revision = "bee.agent-profile@2", name = "DeepSeek Flash", definition_ref = DEFINITION, driver_binding_ref = "bee.driver.codex.binding:binding", provider = {options = {config_profile = "ds-flash"}}, bee = {mcp = {{tool = "thread_read", scope = {}}}}}}))
                local selected = value(call("bee.harness.binding:resolve", {definition_ref = DEFINITION, workspace_id = workspace_id,
                    saved_profile_id = saved_id, saved_profile_revision = 1}))
                local admitted = value(call("bee.harness.binding:admit", {request_id = fresh("named-profile-admit"), definition_ref = DEFINITION,
                    workspace_id = workspace_id, brief = "", saved_profile_id = saved_id, saved_profile_revision = 1,
                    expected_plan_digest = selected.plan_digest}))
                local carrier_request = assert(bounds.object(admitted.request))
                local preferences = assert(bounds.object(carrier_request.preferences))
                test.eq((assert(bounds.object(preferences.options))).config_profile, "ds-flash")
                open_gateway()
                local io = carrier_io(workspace)
                local planned, plan_error = machine.plan(io, carrier_fixtures.request(admitted.request))
                if not planned then error(tostring(plan_error)) end
                -- Codex layers the named profile on its base user config.
                test.eq(planned.launch.argv[1], "--profile")
                test.eq(planned.launch.argv[2], "ds-flash")
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
            local codex_policy = assert(registry.get("bee.harness.catalog:codex_fixture_policy"))
            local provider = assert(registry.get("bee.harness.catalog:codex_fixture_provider"))
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
            changed_definition.policy_ref = "bee.harness.catalog:codex_fixture_policy"
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
                local selected = value(call("bee.harness.binding:resolve", {definition_ref = DEFINITION}))
                changed_provider.model = "gpt-5.1"
                provider.data = changed_provider
                local update = registry.snapshot():changes()
                update:update(provider)
                local updated, update_error = update:apply()
                if not updated then error("change provider: " .. tostring(update_error)) end
                local refused = call("bee.harness.binding:admit", {request_id = request_id, definition_ref = DEFINITION,
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
        test.it("admits for the requester, obtaining an attempt-bound grant and projection in the requester's authority", function()
            local request_id = fresh("request")
            local admitted = value(call("bee.harness.binding:admit", {request_id = request_id, definition_ref = DEFINITION, workspace_id = workspace, brief = "ping"}))
            test.eq(admitted.requester, REQUESTER)
            test.eq(admitted.attempt_id, "attempt:" .. request_id)
            test.eq(admitted.thread_id, "thread:" .. request_id)
            local carrier_request = assert(bounds.object(admitted.request))
            test.eq(carrier_request.owner_id, REQUESTER)
            test.eq(carrier_request.workspace_id, workspace, "approval workspace was lost at launch admission")
            local resources = principals.objects(carrier_request.resources)
            test.eq(#resources, 1)
            test.eq(resources[1].root_ref, ROOT)
            local projections = principals.strings(carrier_request.projections)
            test.eq(#projections, 1)
            local listed = value(call("bee.credentials.binding:list", {workspace_id = workspace}))
            local found = false
            for _, projection in ipairs(principals.objects(listed.projections)) do
                if projection.projection_id == projections[1] then
                    found = true
                    test.eq(projection.subject, REQUESTER)
                    test.eq(projection.attempt_id, "attempt:" .. request_id)
                end
            end
            test.is_true(found)
            local replay = value(call("bee.harness.binding:admit", {request_id = request_id, definition_ref = DEFINITION, workspace_id = workspace, brief = "ping"}))
            test.eq((principals.strings((assert(bounds.object(replay.request))).projections))[1], projections[1])
            test.eq(code(call("bee.harness.binding:admit", {request_id = fresh("request"), definition_ref = DEFINITION, workspace_id = workspace, brief = "ping", thread_id = "t"})), "FORBIDDEN")
            -- Bound to the same workspace, so the refusal is the launch policy's.
            local outsider = funcs.new():with_actor(principals.actor("bee.test.other", workspace)):with_scope(scope())
            local denied, err = outsider:call("bee.harness.binding:admit", {request_id = fresh("request"), definition_ref = DEFINITION, workspace_id = workspace, brief = "ping"})
            if err then error(tostring(err)) end
            test.eq(code(principals.reply(denied)), "FORBIDDEN")
        end)
        test.it("admits workdir, thread and placement overrides only where the definition and its policy both allow them", function()
            value(call("bee.resources.binding:associate", {workspace_id = workspace, name = "alternate", root_ref = ROOT, subpath = "", allowed_access = "write"}))
            local refused_request = fresh("override-refused")
            test.eq(code(call("bee.harness.binding:admit", {request_id = refused_request, definition_ref = DEFINITION, workspace_id = workspace,
                brief = "ping", workdir = "alternate"})), "FORBIDDEN")
            test.eq(code(call("bee.harness.binding:admit", {request_id = refused_request, definition_ref = DEFINITION, workspace_id = workspace,
                brief = "ping", thread_title = "Chosen title"})), "FORBIDDEN")
            test.eq(code(call("bee.threads.binding:get", {thread_id = "thread:" .. refused_request})), "NOT_FOUND")
            -- The definition alone allowing an override is not enough: the
            -- host policy must admit it as well.
            with_overrides({"brief", "workdir", "thread", "placement"}, {}, function()
                local plan = value(call("bee.harness.binding:resolve", {definition_ref = DEFINITION}))
                test.eq(#(principals.strings(plan.overrides)), 1)
                test.eq((principals.strings(plan.overrides))[1], "brief")
                test.eq(plan.placement_kind, "native")
                test.eq(code(call("bee.harness.binding:admit", {request_id = refused_request, definition_ref = DEFINITION, workspace_id = workspace,
                    brief = "ping", workdir = "alternate"})), "FORBIDDEN")
                test.eq(code(call("bee.harness.binding:admit", {request_id = refused_request, definition_ref = DEFINITION, workspace_id = workspace,
                    brief = "ping", thread_title = "Chosen title"})), "FORBIDDEN")
            end)
            with_overrides({"brief"}, {"workdir", "thread", "placement"}, function()
                test.eq(code(call("bee.harness.binding:admit", {request_id = refused_request, definition_ref = DEFINITION, workspace_id = workspace,
                    brief = "ping", workdir = "alternate"})), "FORBIDDEN")
            end)
            test.eq(code(call("bee.threads.binding:get", {thread_id = "thread:" .. refused_request})), "NOT_FOUND")
            with_overrides({"brief", "workdir", "thread"}, {"workdir", "thread"}, function()
                local plan = value(call("bee.harness.binding:resolve", {definition_ref = DEFINITION}))
                test.eq(#(principals.strings(plan.overrides)), 3)
                local request_id = fresh("override-workdir")
                local admitted = value(call("bee.harness.binding:admit", {request_id = request_id, definition_ref = DEFINITION, workspace_id = workspace,
                    brief = "ping", workdir = "alternate", thread_title = "Chosen title"}))
                local carrier_request = assert(bounds.object(admitted.request))
                test.eq(carrier_request.working_directory, "alternate")
                local resources = principals.objects(carrier_request.resources)
                test.eq(#resources, 1)
                test.eq(resources[1].name, "alternate")
                test.eq(admitted.thread_id, "thread:" .. request_id)
                local created = value(call("bee.threads.binding:get", {thread_id = admitted.thread_id}))
                test.eq((assert(bounds.object(created.summary))).title, "Chosen title")
                -- An existing thread the requester belongs to replaces the new one.
                local chosen = fresh("override-thread")
                value(call("bee.threads.binding:create", {thread_id = chosen, idempotency_key = fresh("create"), title = "Existing"}))
                local joined = value(call("bee.harness.binding:admit", {request_id = fresh("override-existing"), definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "ping", thread_id = chosen}))
                test.eq(joined.thread_id, chosen)
                local foreign_owner = fresh("foreign-owner")
                local foreign_thread = fresh("foreign-thread")
                value(call_as(foreign_owner, "bee.threads.binding:create", {thread_id = foreign_thread,
                    idempotency_key = fresh("foreign-create"), title = "Foreign"}))
                test.eq(code(call("bee.harness.binding:admit", {request_id = fresh("override-foreign"), definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "ping", thread_id = foreign_thread})), "DENIED")
                test.eq(code(call("bee.harness.binding:admit", {request_id = fresh("override-both"), definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "ping", thread_id = chosen, thread_title = "Both"})), "INVALID")
            end)
        end)
        test.it("admits the exact named thread while retaining thread override and membership checks", function()
            local selected = fresh("definition-thread")
            value(call("bee.threads.binding:create", {thread_id = selected, idempotency_key = fresh("create"), title = "Named"}))
            with_entry(DEFINITION, function(changed)
                changed.thread_policy = {kind = "named", thread_ref = selected}
            end, function()
                local admitted = value(call("bee.harness.binding:admit", {request_id = fresh("named-thread"), definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "ping", thread_id = selected}))
                test.eq(admitted.thread_id, selected)
                test.eq(code(call("bee.harness.binding:admit", {request_id = fresh("different-thread"), definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "ping", thread_id = fresh("other")})), "FORBIDDEN")
                test.eq(code(call("bee.harness.binding:admit", {request_id = fresh("named-title"), definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "ping", thread_title = "New thread"})), "FORBIDDEN")
                test.eq(code(call_as(fresh("nonmember"), "bee.harness.binding:admit", {request_id = fresh("named-nonmember"), definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "ping", thread_id = selected})), "DENIED")
            end)
        end)
        test.it("refuses a placement other than the host's before any thread or grant exists", function()
            local native = value(call("bee.harness.binding:admit", {request_id = fresh("placement-native"), definition_ref = DEFINITION,
                workspace_id = workspace, brief = "ping", placement = "native"}))
            test.eq((assert(bounds.object(native.plan))).placement_kind, "native")
            local request_id = fresh("placement-docker")
            test.eq(code(call("bee.harness.binding:admit", {request_id = request_id, definition_ref = DEFINITION,
                workspace_id = workspace, brief = "ping", placement = "docker"})), "FORBIDDEN")
            with_overrides({"brief", "placement"}, {"placement"}, function()
                local refused = call("bee.harness.binding:admit", {request_id = request_id, definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "ping", placement = "docker"})
                test.eq(code(refused), "PLACEMENT_UNAVAILABLE")
            end)
            test.eq(code(call("bee.threads.binding:get", {thread_id = "thread:" .. request_id})), "NOT_FOUND")
            -- "vm" names no installed placement package, but decoding no
            -- longer refuses it by shape: the definition's own override
            -- allow-list is what refuses it here, same as "docker" above.
            test.eq(code(call("bee.harness.binding:admit", {request_id = request_id, definition_ref = DEFINITION,
                workspace_id = workspace, brief = "ping", placement = "vm"})), "FORBIDDEN")
            test.eq(code(call("bee.harness.binding:admit", {request_id = fresh("placement-malformed"), definition_ref = DEFINITION,
                workspace_id = workspace, brief = "ping", placement = "bad\0placement"})), "INVALID")
        end)
        test.it("selects an installed placement package once the host's policy names its binding", function()
            local FIXTURE_PLACEMENT = "bee.harness.catalog:fixture_placement_binding"
            with_overrides({"brief", "placement"}, {"placement"}, function()
                local unselected = call("bee.harness.binding:admit", {request_id = fresh("placement-fixture-unselected"), definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "ping", placement = "fixture"})
                test.eq(code(unselected), "PLACEMENT_UNAVAILABLE")
                test.is_true(refusal_message(unselected):find("it places it native", 1, true) ~= nil)
                with_entry(POLICY, function(changed) changed.placement_binding = FIXTURE_PLACEMENT end, function()
                    local plan = value(call("bee.harness.binding:resolve", {definition_ref = DEFINITION}))
                    test.eq(plan.placement_kind, "fixture")
                    local admitted = value(call("bee.harness.binding:admit", {request_id = fresh("placement-fixture-selected"), definition_ref = DEFINITION,
                        workspace_id = workspace, brief = "ping", placement = "fixture"}))
                    test.eq((assert(bounds.object(admitted.plan))).placement_kind, "fixture")
                end)
            end)
        end)
        test.it("sets up a folder under an admitted root as the working directory only under a workdir override", function()
            local plan = value(call("bee.harness.binding:resolve", {definition_ref = DEFINITION}))
            local refused = call_setup({workspace_id = workspace, definition_ref = DEFINITION,
                expected_plan_digest = plan.plan_digest, workdir = {root_ref = ROOT, path = "chosen"}})
            test.eq(refused.ok, false)
            test.eq(refused.error, "the launch does not allow a workdir override")
            with_overrides({"brief", "workdir"}, {"workdir"}, function()
                local allowed = value(call("bee.harness.binding:resolve", {definition_ref = DEFINITION}))
                local reply = call_setup({workspace_id = workspace, definition_ref = DEFINITION,
                    expected_plan_digest = allowed.plan_digest, workdir = {root_ref = ROOT, path = "chosen/deeper"}})
                if reply.ok ~= true then error(tostring(reply.error)) end
                local name = tostring((assert(bounds.object(reply))).workdir)
                test.is_true(name:match("^folder%-[0-9a-f]+$") ~= nil)
                local found: {[string]: unknown}? = nil
                for _, association in ipairs(associations(workspace)) do
                    if association.name == name then found = association end
                end
                if not found then error("folder association is missing") end
                test.eq(found.root_ref, ROOT)
                test.eq(found.subpath, "chosen/deeper")
                local again = call_setup({workspace_id = workspace, definition_ref = DEFINITION,
                    expected_plan_digest = allowed.plan_digest, workdir = {root_ref = ROOT, path = "chosen/deeper"}})
                test.eq((assert(bounds.object(again))).workdir, name)
                local admitted = value(call("bee.harness.binding:admit", {request_id = fresh("folder-workdir"), definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "ping", workdir = name, expected_plan_digest = allowed.plan_digest}))
                test.eq((assert(bounds.object(admitted.request))).working_directory, name)
                for _, bad in ipairs({{root_ref = ROOT, path = "../escape"}, {root_ref = ROOT, path = "/abs"}, {root_ref = "bee.harness.catalog:not_a_root", path = "x"},
                    {root_ref = ROOT, path = "x", extra = true}}) do
                    local denied = call_setup({workspace_id = workspace, definition_ref = DEFINITION,
                        expected_plan_digest = allowed.plan_digest, workdir = bad})
                    test.eq(denied.ok, false)
                end
            end)
        end)
        test.it("reconciles a prepared and claimed attempt after its carrier disappears", function()
            local admitted = value(call("bee.harness.binding:admit", {request_id = fresh("orphan-prestart"),
                definition_ref = DEFINITION, workspace_id = workspace, brief = "fail during placement preparation"}))
            with_entry(POLICY, function(changed)
                changed.placement_binding = "bee.placement.native.binding:binding"
                changed.placement_options = {}
            end, function()
                local io = carrier_io(workspace)
                local planned, plan_error = machine.plan(io, carrier_fixtures.request(admitted.request))
                if not planned then error(tostring(plan_error)) end
                local prepared, preparation_error, failed = machine.prepare_attempt(io, planned)
                test.is_nil(prepared)
                test.is_true(tostring(preparation_error):find("native placement does not support placement_options", 1, true) ~= nil)
                test.not_nil(failed)
                test.not_nil(failed and failed.epoch)
                local db = assert(placement_store.open())
                local row = placement_store.row(db, assert(bounds.id(admitted.attempt_id)))
                db:release()
                test.is_nil(row)

                local reply, call_error = funcs.new():with_actor(principals.actor(REQUESTER, workspace))
                    :with_scope(scope()):call("bee.harness.catalog:managed_run_probe", {operation = "wait",
                        thread_id = admitted.thread_id, attempt_id = admitted.attempt_id, wait_ms = 0})
                if call_error then error("reconcile wait: " .. tostring(call_error)) end
                local settled = value(principals.reply(reply))
                test.eq(settled.state, "ended")
                test.eq(settled.outcome, "failed")
                local failure = bounds.object(settled.error)
                test.not_nil(failure)
                test.is_true(tostring(failure and failure.message):find("carrier exited during launch preparation", 1, true) ~= nil)
            end)
        end)
        test.it("keeps a lost running attempt live until placement finishes draining, then settles it", function()
            local request_id = fresh("orphan-running")
            with_entry(POLICY, function(changed)
                local environment = assert(bounds.object(changed.environment))
                environment.BEE_FIXTURE_LINGER = "12"
                changed.environment = environment
            end, function()
                local admitted = value(call("bee.harness.binding:admit", {request_id = request_id,
                    definition_ref = DEFINITION, workspace_id = workspace, brief = "prove lost carrier recovery"}))
                local carrier_request = assert(bounds.object(admitted.request))
                local spawner = process.with_context({}):with_actor(principals.actor(REQUESTER, workspace)):with_scope(scope())
                local lost_pid, spawn_error = spawner:spawn_monitored("bee.harness.catalog:carrier_faulted", "bee:workers",
                    carrier_request, "open", process.pid(), "attempt_started")
                if not lost_pid then error("spawn faulted carrier: " .. tostring(spawn_error)) end
                local events = assert(process.events())
                local crash_deadline = time.after("30s")
                local crashed = false
                while not crashed do
                    local selected = channel.select({events:case_receive(), crash_deadline:case_receive()})
                    if not selected.ok or selected.channel == crash_deadline then error("running carrier did not exit") end
                    local event = selected.value
                    if event.kind == process.event.EXIT and tostring(event.from) == tostring(lost_pid) then
                        local result = event.result or {}
                        test.is_true(tostring(result.error):find("crash after attempt_started", 1, true) ~= nil)
                        crashed = true
                    end
                end

                local thread_id, attempt_id = tostring(admitted.thread_id), tostring(admitted.attempt_id)
                local current = value(call("bee.harness.catalog:managed_run_probe", {operation = "status",
                    thread_id = thread_id, attempt_id = attempt_id}))
                test.eq(current.state, "running", "placement still owns a live runner and recovery remains possible")
                test.eq(count(kinds(thread_id), "receipt"), 0, "a missing carrier alone is not terminal")

                local drain_deadline = math.floor(time.now():unix_nano() / 1000000) + 75000
                local drained = false
                while not drained do
                    local db = assert(placement_store.open())
                    local evidence = placement_store.evidence(db, attempt_id, 0, 64)
                    local row = placement_store.row(db, attempt_id)
                    db:release()
                    local finished = false
                    for _, item in ipairs((evidence and evidence.evidence) or {}) do
                        if item.kind == "runner.finished" then finished = true end
                    end
                    if row and row.execution_state == "exited" and finished then
                        test.is_nil(row.runner_pid, "runner.finished clears its process identity")
                        local stale_db = assert(placement_store.open())
                        local _, stale_error = stale_db:execute(
                            "UPDATE bee_placement_attempts SET runner_pid = ? WHERE attempt_id = ?",
                            {"999999999", attempt_id})
                        stale_db:release()
                        if stale_error then error("simulate legacy stale runner pid: " .. tostring(stale_error)) end
                        drained = true
                    else
                        local remaining = drain_deadline - math.floor(time.now():unix_nano() / 1000000)
                        if remaining <= 0 then error("placement runner did not finish draining") end
                        time.sleep("50ms")
                    end
                end

                current = value(call("bee.harness.catalog:managed_run_probe", {operation = "status",
                    thread_id = thread_id, attempt_id = attempt_id}))
                test.eq(current.outcome, "uncertain")
                local failure = bounds.object(current.error)
                test.eq(failure and failure.code, "carrier_lost")
                local records = kinds(thread_id)
                test.eq(count(records, "turn.end"), 1)
                test.eq(count(records, "receipt"), 1)
                local db = assert(placement_store.open())
                local row = placement_store.row(db, attempt_id)
                db:release()
                test.not_nil(row)
                test.eq(row and row.runner_pid, "999999999", "legacy runner identity remains available for inspection")
            end)
        end)
        test.it("refuses caller-selected session identities and resources before creating work", function()
            for _, field in ipairs({"session_ref", "session_resource"}) do
                local request_id = fresh("session-injection")
                local request: {[string]: unknown} = {request_id = request_id, definition_ref = RETAINED_DEFINITION,
                    workspace_id = workspace, brief = "ping"}
                request[field] = "caller-selected"
                test.eq(code(call("bee.harness.binding:admit", request)), "INVALID")
                test.eq(code(call("bee.threads.binding:get", {thread_id = "thread:" .. request_id})), "NOT_FOUND")
            end
        end)
        test.it("uses a host-selected retained session resource with a retry-stable identity", function()
            local request_id = fresh("retained")
            local admitted = value(call("bee.harness.binding:admit", {request_id = request_id, definition_ref = RETAINED_DEFINITION, workspace_id = workspace, brief = "ping"}))
            test.is_true(type(admitted.session_ref) == "string" and (admitted.session_ref):match("^session:[0-9a-f]+$") ~= nil)
            local carrier_request = assert(bounds.object(admitted.request))
            test.eq(carrier_request.session_ref, admitted.session_ref)
            local resources = principals.objects(carrier_request.resources)
            test.eq(#resources, 2)
            local session_grant = nil
            for _, resource in ipairs(resources) do
                if resource.purpose == "session" then session_grant = resource end
            end
            if not session_grant then error("retained session grant missing") end
            test.eq(session_grant.name, "session")
            test.eq(session_grant.access, "write")
            local replay = value(call("bee.harness.binding:admit", {request_id = request_id, definition_ref = RETAINED_DEFINITION, workspace_id = workspace, brief = "ping"}))
            test.eq(replay.session_ref, admitted.session_ref)
            local replay_resources = principals.objects((assert(bounds.object(replay.request))).resources)
            local replay_grant = nil
            for _, resource in ipairs(replay_resources) do
                if resource.purpose == "session" then replay_grant = resource end
            end
            test.eq(replay_grant and replay_grant.grant_ref, session_grant.grant_ref)
            local other = value(call("bee.harness.binding:admit", {request_id = fresh("retained"), definition_ref = RETAINED_DEFINITION, workspace_id = workspace, brief = "ping"}))
            test.neq(other.session_ref, admitted.session_ref)
        end)
        test.it("refuses a host definition whose retained resource is unavailable before creating a thread", function()
            local entry = assert(registry.get(RETAINED_DEFINITION))
            local original = entry.data
            local changed: {[string]: unknown} = {}
            for key, item in pairs(assert(bounds.object(original))) do changed[key] = item end
            changed.session_resource = "missing-session"
            local request_id = fresh("retained-denied")
            local ok, failure = pcall(function()
                entry.data = changed
                apply(entry)
                local refused = call("bee.harness.binding:admit", {request_id = request_id, definition_ref = RETAINED_DEFINITION, workspace_id = workspace, brief = "ping"})
                test.eq(code(refused), "NOT_FOUND")
                test.eq(code(call("bee.threads.binding:get", {thread_id = "thread:" .. request_id})), "NOT_FOUND")
            end)
            entry.data = original
            apply(entry)
            if not ok then error(tostring(failure)) end
        end)
        test.it("recovers a start that failed after placement intent and before the first checkpoint", function()
            local request_id = fresh("request")
            local admitted = value(call("bee.harness.binding:admit", {request_id = request_id, definition_ref = DEFINITION, workspace_id = workspace, brief = "ping"}))
            local carrier_request = assert(bounds.object(admitted.request))
            local spawner = process.with_context({}):with_actor(principals.actor(REQUESTER, workspace)):with_scope(scope())
            local crashed_pid, spawn_error = spawner:spawn_monitored("bee.harness.catalog:carrier_faulted", "bee:workers", carrier_request, "open", process.pid(), "placement_intent")
            if not crashed_pid then error("spawn faulted carrier: " .. tostring(spawn_error)) end
            local events = assert(process.events())
            local deadline = time.after("30s")
            local crashed = false
            while not crashed do
                local selected = channel.select({events:case_receive(), deadline:case_receive()})
                if not selected.ok or selected.channel == deadline then error("faulted carrier did not stop") end
                local event = selected.value
                if event.kind == process.event.EXIT and tostring(event.from) == tostring(crashed_pid) then
                    crashed = true
                    if not tostring(event.result and event.result.error):find("crash after placement_intent", 1, true) then error("unexpected end: " .. tostring(event.result and event.result.error)) end
                end
            end
            local before = kinds("thread:" .. request_id)
            test.eq(count(before, "action.admitted"), 1)
            test.eq(count(before, "attempt.prepared"), 1)
            test.eq(count(before, "turn.request"), 0)
            local retried = value(call("bee.harness.binding:start", {request_id = request_id, definition_ref = DEFINITION, workspace_id = workspace, brief = "ping"}))
            test.eq(retried.mode, "open")
            test.eq(await_settled("thread:" .. request_id, tostring(retried.attempt_id)).answer, "pong")
            local after = kinds("thread:" .. request_id)
            test.eq(count(after, "action.admitted"), 1)
            test.eq(count(after, "attempt.prepared"), 1)
            test.eq(count(after, "attempt.started"), 1)
            test.eq(count(after, "turn.request"), 1)
            test.eq(count(after, "receipt"), 1)
        end)
        test.it("starts the carrier to settlement and a retried start recovers the same attempt", function()
            local request_id = fresh("request")
            local started = value(call("bee.harness.binding:start", {request_id = request_id, definition_ref = DEFINITION, workspace_id = workspace, brief = "ping"}))
            test.eq(started.mode, "open")
            local thread_id = tostring(started.thread_id)
            test.eq(await_settled(thread_id, tostring(started.attempt_id)).answer, "pong")
            local list = kinds(thread_id)
            test.eq(count(list, "action.admitted"), 1)
            test.eq(count(list, "attempt.prepared"), 1)
            test.eq(count(list, "receipt"), 1)
            local settled_replay = value(call("bee.harness.binding:start", {request_id = request_id,
                definition_ref = DEFINITION, workspace_id = workspace, brief = "ping"}))
            test.eq(settled_replay.mode, "settled")
            test.eq(settled_replay.thread_id, started.thread_id)
            test.eq(settled_replay.action_id, started.action_id)
            test.eq(settled_replay.attempt_id, started.attempt_id)
            test.eq(count(kinds(thread_id), "receipt"), 1)
            local retried_id = fresh("request")
            local first = value(call("bee.harness.binding:start", {request_id = retried_id, definition_ref = DEFINITION, workspace_id = workspace, brief = "ping"}))
            test.eq(await_settled(tostring(first.thread_id), tostring(first.attempt_id)).answer, "pong")
            local retried_list = kinds(tostring(first.thread_id))
            test.eq(count(retried_list, "attempt.started"), 1)
            test.eq(count(retried_list, "turn.request"), 1)
        end)
        test.it("fans two managed research actions into one caller-owned durable thread", function()
            local entry = assert(registry.get(DEFINITION))
            local original = entry.data
            local changed: {[string]: unknown} = {}
            for key, item in pairs(assert(bounds.object(original))) do changed[key] = item end
            changed.allowed_overrides = {"thread"}
            changed.thread_policy = {kind = "caller"}
            local ok, failure = pcall(function()
                entry.data = changed
                apply(entry)
                local shared = fresh("autoresearch")
                value(call("bee.threads.binding:create", {thread_id = shared, idempotency_key = fresh("create"), title = "Autoresearch"}))
                local first_id, second_id = fresh("research-one"), fresh("research-two")
                local first = value(call("bee.harness.binding:start", {request_id = first_id, definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "investigate the first hypothesis", thread_id = shared}))
                local second = value(call("bee.harness.binding:start", {request_id = second_id, definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "investigate the second hypothesis", thread_id = shared}))
                test.eq(first.thread_id, shared)
                test.eq(second.thread_id, shared)
                test.neq(first.action_id, second.action_id)
                test.neq(first.attempt_id, second.attempt_id)
                test.eq(await_settled(shared, tostring(first.attempt_id)).answer, "pong")
                test.eq(await_settled(shared, tostring(second.attempt_id)).answer, "pong")
                local records = kinds(shared)
                test.eq(count(records, "action.admitted"), 2)
                test.eq(count(records, "attempt.prepared"), 2)
                test.eq(count(records, "attempt.started"), 2)
                test.eq(count(records, "turn.request"), 2)
                test.eq(count(records, "receipt"), 2)
                local subscribed = value(call("bee.threads.binding:subscribe", {thread_id = shared,
                    idempotency_key = fresh("subscribe"), consumer_id = "autoresearch-coordinator",
                    after_sequence = 0, filter = {kinds = {"receipt"}}, durability = "durable"}))
                local page = value(call("bee.threads.binding:page", {thread_id = shared,
                    subscription_id = subscribed.subscription_id}))
                test.eq(#(principals.items(page.records)), 2)
                value(call("bee.threads.binding:ack_page", {thread_id = shared,
                    idempotency_key = fresh("ack-page"), subscription_id = subscribed.subscription_id,
                    page_id = page.page_id, scanned_through = page.scanned_through}))
                local detached = value(call("bee.threads.binding:unsubscribe", {thread_id = shared,
                    idempotency_key = fresh("detach-consumer"), subscription_id = subscribed.subscription_id}))
                test.is_true(detached.closed)
                local resumed = value(call("bee.threads.binding:resume", {thread_id = shared,
                    idempotency_key = fresh("resume-consumer"), subscription_id = subscribed.subscription_id}))
                test.eq(resumed.lease_generation, 2)
                local caught_up = value(call("bee.threads.binding:page", {thread_id = shared,
                    subscription_id = subscribed.subscription_id}))
                test.eq(#(principals.items(caught_up.records)), 0)
                test.is_nil(caught_up.page_id)
                local settled_replay = value(call("bee.harness.binding:start", {request_id = first_id,
                    definition_ref = DEFINITION, workspace_id = workspace, brief = "investigate the first hypothesis", thread_id = shared}))
                test.eq(settled_replay.mode, "settled")
                test.eq(settled_replay.thread_id, first.thread_id)
                test.eq(settled_replay.action_id, first.action_id)
                test.eq(settled_replay.attempt_id, first.attempt_id)
                test.eq(count(kinds(shared), "receipt"), 2)
                test.eq(count(kinds(shared), "receipt"), 2)
            end)
            entry.data = original
            apply(entry)
            if not ok then error(tostring(failure)) end
        end)
        test.it("readmits a recorded window with fresh grants and its original action and session", function()
            -- Construct committed predecessor state through the actual owners.
            -- No native process is started: placement completion is an explicit
            -- store fixture, not evidence of native process cleanup.
            local entry = registry.get(RETAINED_DEFINITION)
            if not entry then error("retained definition") end
            local original = entry.data
            local changed: {[string]: unknown} = {}
            for key, item in pairs(assert(bounds.object(original))) do changed[key] = item end
            changed.profile_id, changed.default_mode = "window", "window"
            entry.data = changed
            apply(entry)
            local policy_entry = registry.get(POLICY)
            if not policy_entry then error("fixture policy") end
            local original_policy = policy_entry.data
            local window_policy: {[string]: unknown} = {}
            for key, item in pairs(assert(bounds.object(original_policy))) do window_policy[key] = item end
            window_policy.prepare_options = {permission_mode = "default"}
            window_policy.allow_host_home = true
            policy_entry.data = window_policy
            apply(policy_entry)
            local origin = fresh("window-origin")
            local first = value(call("bee.harness.binding:admit", {request_id = origin, definition_ref = RETAINED_DEFINITION,
                workspace_id = workspace, brief = ""}))
            local transport = carrier_io(workspace)
            local planned, plan_error = machine.plan(transport, carrier_fixtures.request(first.request))
            if not planned then error(tostring(plan_error)) end
            local prepared, prepare_error = machine.prepare_attempt(transport, planned)
            if not prepared then error(tostring(prepare_error)) end
            local first_plan = assert(bounds.object(first.plan))
            assert(type(first_plan.binding_ref) == "string" and type(first_plan.binding_digest) == "string" and type(first_plan.profile_id) == "string" and type(first_plan.profile_digest) == "string" and type(first_plan.plan_digest) == "string")
            assert(type(first.attempt_id) == "string" and type(first.thread_id) == "string")
            local point = checkpoint.new({binding_ref = first_plan.binding_ref, binding_digest = first_plan.binding_digest,
                profile_id = first_plan.profile_id, profile_digest = first_plan.profile_digest, gateway_binding = "recorded-binding"}, prepared.epoch)
            point.retained_session_ref = first.session_ref
            local records, records_error = hook_records.batch("recorded-binding", nil, {{event_id = "session-start", event = "SessionStart",
                occurrence = "session:provider-session", ambiguous = false, provenance = "fixture", sequence = 1,
                fields = {event = "SessionStart", session_id = "provider-session", source = "startup"}}})
            if not records then error(tostring(records_error)) end
            value(call("bee.threads.binding:commit", {thread_id = first.thread_id, attempt_id = first.attempt_id,
                idempotency_key = fresh("commit"), carrier_epoch = prepared.epoch, expected_revision = 0, checkpoint = point, records = records.records}))
            local request: admission.Request = {request_id = fresh("resume"), definition_ref = RETAINED_DEFINITION, workspace_id = workspace,
                brief = "", expected_plan_digest = first_plan.plan_digest,
                continuation = {origin_request_id = origin, previous_attempt_id = first.attempt_id, thread_id = first.thread_id}}
            local refused_resume = call("bee.harness.binding:admit", request)
            test.eq(code(refused_resume), "CONFLICT", tostring(refused_resume.error and refused_resume.error.message))
            value(call("bee.threads.binding:receipt", {thread_id = first.thread_id, action_id = first.action_id, attempt_id = first.attempt_id,
                idempotency_key = fresh("receipt"), carrier_epoch = prepared.epoch, receipt = {scope = "attempt", outcome = "cancelled", evidence_refs = {},
                    error = {code = "fixture_closed", message = "predecessor fixture closed", retryable = false}}}))
            local refused_resume = call("bee.harness.binding:admit", request)
            test.eq(code(refused_resume), "CONFLICT", tostring(refused_resume.error and refused_resume.error.message))
            local db, db_error = placement_store.open()
            if not db then error(tostring(db_error)) end
            test.is_true(placement_store.transition(db, first.attempt_id, {execution = "starting", evidence = {kind = "fixture", detail = "no process started"}}).ok)
            test.is_true(placement_store.transition(db, first.attempt_id, {execution = "exited", evidence = {kind = "fixture", detail = "no process exists"}}).ok)
            local refused_resume = call("bee.harness.binding:admit", request)
            test.eq(code(refused_resume), "CONFLICT", tostring(refused_resume.error and refused_resume.error.message))
            test.is_true(placement_store.transition(db, first.attempt_id, {cleanup = "complete", evidence = {kind = "fixture", detail = "no home materialized"}}).ok)
            db:release()
            local resumed = value(call("bee.harness.binding:admit", request))
            test.eq(resumed.action_id, first.action_id)
            test.eq(resumed.thread_id, first.thread_id)
            test.eq(resumed.session_ref, first.session_ref)
            test.eq(resumed.attempt_id, "attempt:" .. request.request_id)
            test.eq(resumed.request.previous_attempt_id, first.attempt_id)
            test.eq(resumed.request.brief, "")
            test.eq(resumed.request.resources[1].name, first.request.resources[1].name)
            test.is_true(resumed.request.resources[1].grant_ref ~= first.request.resources[1].grant_ref)
            local replay = value(call("bee.harness.binding:admit", request))
            test.eq(replay.request.resources[1].grant_ref, resumed.request.resources[1].grant_ref)
            test.eq(code(call("bee.threads.binding:get", {thread_id = "thread:" .. request.request_id})), "NOT_FOUND")
            local resume_plan, resume_error = machine.plan(transport, carrier_fixtures.request(resumed.request))
            if not resume_plan then error(tostring(resume_error)) end
            test.eq(resume_plan.resume_ref, "provider-session")
            test.is_nil(resume_plan.launch.stdin)
            test.eq(resume_plan.launch.argv[#resume_plan.launch.argv], "provider-session")
            local prior_retention = window_policy.retain_ms
            window_policy.retain_ms = 54321
            policy_entry.data = window_policy
            apply(policy_entry)
            request.request_id = fresh("reviewed-resume")
            request.continuation.reauthorize = true
            local refused_resume = call("bee.harness.binding:admit", request)
            test.eq(code(refused_resume), "CONFLICT", tostring(refused_resume.error and refused_resume.error.message))
            local current, current_error = admission.resolve(RETAINED_DEFINITION, "window")
            if not current then error(tostring(current_error)) end
            request.expected_plan_digest = current.plan_digest
            local reviewed = value(call("bee.harness.binding:admit", request))
            test.eq(reviewed.plan.plan_digest, current.plan_digest)
            test.eq(reviewed.session_ref, first.session_ref)
            test.eq(reviewed.action_id, first.action_id)
            test.is_true(reviewed.request.reauthorize)
            local reviewed_plan, reviewed_error = machine.plan(transport, carrier_fixtures.request(reviewed.request))
            if not reviewed_plan then error(tostring(reviewed_error)) end
            test.eq(reviewed_plan.resume_ref, "provider-session")
            window_policy.retain_ms = prior_retention
            policy_entry.data = window_policy
            apply(policy_entry)
            request.expected_plan_digest = first.plan.plan_digest
            request.continuation.reauthorize = false
            -- Mutated saved references and changed host plans cannot select
            -- another session or silently replay under new configuration.
            request.workspace_id = fresh("foreign-workspace")
            local refused_resume = call("bee.harness.binding:admit", request)
            test.eq(code(refused_resume), "CONFLICT", tostring(refused_resume.error and refused_resume.error.message))
            request.workspace_id = workspace
            request.expected_plan_digest = string.rep("0", 64)
            local refused_resume = call("bee.harness.binding:admit", request)
            test.eq(code(refused_resume), "CONFLICT", tostring(refused_resume.error and refused_resume.error.message))
            request.continuation.reauthorize = true
            test.eq(code(call("bee.harness.binding:admit", request)), "CONFLICT", "review never bypasses the current plan fence")
            request.continuation.reauthorize = false
            request.expected_plan_digest = first.plan.plan_digest
            request.brief = "repeat original prompt"
            test.eq(code(call("bee.harness.binding:admit", request)), "INVALID")
            request.brief = ""
            local foreign, foreign_error = funcs.new():with_actor(security.new_actor("bee.test.foreign")):with_scope(scope()):call("bee.harness.binding:admit", request)
            if foreign_error then error(tostring(foreign_error)) end
            test.is_false((principals.reply(foreign)).ok)
            -- Current resource authority must approve again; the old grant
            -- and committed hook do not authorize a new attempt.
            value(call("bee.resources.binding:associate", {workspace_id = workspace, name = "session", root_ref = ROOT, subpath = "", allowed_access = "read"}))
            request.request_id = fresh("revoked-resume")
            test.is_false(call("bee.harness.binding:admit", request).ok)
            value(call("bee.resources.binding:associate", {workspace_id = workspace, name = "session", root_ref = ROOT, subpath = "", allowed_access = "write"}))
            entry.data = original
            apply(entry)
            policy_entry.data = original_policy
            apply(policy_entry)
        end)
        test.it("resolves an agent route to a hashed closure and admits its exact tools, prompt and mapped model", function()
            local first = assert(bounds.object(value(call("bee.harness.binding:resolve", {definition_ref = AGENT_DEFINITION}))))
            test.eq(first.agent_ref, AGENT_REVIEWER)
            local digest = first.agent_digest
            test.eq(type(digest), "string")
            test.eq(#(digest), 64)
            test.eq(first.agent_model, "claude-mapped")
            local declined = principals.items(first.declined_tuning)
            test.eq(#declined, 1)
            test.eq(declined[1], "temperature")
            local agent_tools = principals.items(first.agent_tools)
            test.eq(#agent_tools, 2)
            test.eq(agent_tools[1], "FileReport")
            test.eq(agent_tools[2], "FileRead")
            local second = assert(bounds.object(value(call("bee.harness.binding:resolve", {definition_ref = AGENT_DEFINITION}))))
            test.eq(second.agent_digest, digest)
            test.eq(second.plan_digest, first.plan_digest)
            local admitted = value(call("bee.harness.binding:admit", {request_id = fresh("agent-admit"),
                definition_ref = AGENT_DEFINITION, workspace_id = workspace, brief = "review fixture"}))
            test.eq(admitted.plan.agent_digest, digest)
            local carrier_request = assert(bounds.object(admitted.request))
            local preferences = assert(bounds.object(carrier_request.preferences))
            local tools = principals.items(preferences.mcp_tools)
            test.eq(#tools, 2)
            test.eq(tools[1], "FileReport")
            test.eq(tools[2], "FileRead")
            test.eq((assert(bounds.object(preferences.options))).model, "claude-mapped")
            local instructions = tostring(preferences.instructions)
            test.is_true(instructions:find("Review the supplied change.", 1, true) ~= nil)
            test.is_true(instructions:find("Use the approved repository tools.", 1, true) ~= nil)
            test.is_true(instructions:find("repo: workspace", 1, true) ~= nil)
        end)
        test.it("refuses a changed agent reference before admission", function()
            local selected = assert(bounds.object(value(call("bee.harness.binding:resolve", {definition_ref = AGENT_DEFINITION}))))
            with_entry(AGENT_REVIEWER, function(data) data.prompt = "Changed review prompt." end, function()
                local changed = assert(bounds.object(value(call("bee.harness.binding:resolve", {definition_ref = AGENT_DEFINITION}))))
                test.neq(changed.plan_digest, selected.plan_digest)
                test.neq(changed.agent_digest, selected.agent_digest)
                local refused = call("bee.harness.binding:admit", {request_id = fresh("agent-changed"), definition_ref = AGENT_DEFINITION,
                    workspace_id = workspace, brief = "review fixture", expected_plan_digest = selected.plan_digest})
                test.eq(code(refused), "CONFLICT")
            end)
        end)
        test.it("never reduces a trait to its prompt", function()
            with_entry(AGENT_TRAIT, function(data) data.wrappers = {"bee.harness.catalog:agent_wrapper"} end, function()
                local refused = call("bee.harness.binding:resolve", {definition_ref = AGENT_DEFINITION})
                test.eq(code(refused), "UNSUPPORTED_CAPABILITY")
                local message = refusal_message(refused)
                test.is_true(message:find("agent_repository_trait", 1, true) ~= nil)
                test.is_true(message:find("wrappers", 1, true) ~= nil)
            end)
        end)
        test.it("refuses unknown agent fields", function()
            with_entry(AGENT_REVIEWER, function(data) data.bogus_field = true end, function()
                test.eq(code(call("bee.harness.binding:resolve", {definition_ref = AGENT_DEFINITION})), "INVALID")
            end)
        end)
        test.it("refuses a model the host never mapped and a driver that takes no model", function()
            with_entry(AGENT_REVIEWER, function(data) data.model = "unmapped-model" end, function()
                local refused = call("bee.harness.binding:resolve", {definition_ref = AGENT_DEFINITION})
                test.eq(code(refused), "UNSUPPORTED_CAPABILITY")
                test.is_true(refusal_message(refused):find("unmapped-model", 1, true) ~= nil)
            end)
            with_entry(AGENT_DEFINITION, function(data)
                data.binding_ref = "bee.driver.codex.binding:binding"
                data.profile_id = "batch"
            end, function()
                local refused = call("bee.harness.binding:resolve", {definition_ref = AGENT_DEFINITION})
                test.eq(code(refused), "UNSUPPORTED_CAPABILITY")
                test.is_true(refusal_message(refused):find("codex", 1, true) ~= nil)
            end)
        end)
        test.it("declines only owner-permitted tuning hints", function()
            with_entry(AGENT_REVIEWER, function(data) data.tuning = {temperature = 0.2, top_k = 1} end, function()
                local refused = call("bee.harness.binding:resolve", {definition_ref = AGENT_DEFINITION})
                test.eq(code(refused), "UNSUPPORTED_CAPABILITY")
                test.is_true(refusal_message(refused):find("top_k", 1, true) ~= nil)
            end)
        end)
        test.it("refuses delegates outside host admission", function()
            with_entry(AGENT_POLICY, function(data) data.agent_delegates = {} end, function()
                local refused = call("bee.harness.binding:resolve", {definition_ref = AGENT_DEFINITION})
                test.eq(code(refused), "FORBIDDEN")
                test.is_true(refusal_message(refused):find("agent_helper", 1, true) ~= nil)
            end)
        end)
        test.it("refuses saved profile tools outside the agent and options claiming its model", function()
            local workspace_id, saved_id = workspace, fresh("agent-profile")
            value(call("bee.harness.binding:call", {operation = "put", workspace_id = workspace_id, profile_id = saved_id,
                expected_revision = 0, idempotency_key = fresh("save"),
                profile = {schema_revision = "bee.agent-profile@2", name = "Outside tools", definition_ref = AGENT_DEFINITION, driver_binding_ref = "bee.driver.claude.binding:binding", provider = {}, bee = {mcp = {{tool = "thread_read", scope = {}}}}}}))
            local outside = call("bee.harness.binding:resolve", {definition_ref = AGENT_DEFINITION, workspace_id = workspace_id,
                saved_profile_id = saved_id, saved_profile_revision = 1})
            test.eq(code(outside), "FORBIDDEN")
            value(call("bee.harness.binding:call", {operation = "put", workspace_id = workspace_id, profile_id = saved_id,
                expected_revision = 1, idempotency_key = fresh("save"),
                profile = {schema_revision = "bee.agent-profile@2", name = "Claimed model", definition_ref = AGENT_DEFINITION, driver_binding_ref = "bee.driver.claude.binding:binding", provider = {model = "sneaky"}, bee = {mcp = {}}}}))
            local claimed = call("bee.harness.binding:resolve", {definition_ref = AGENT_DEFINITION, workspace_id = workspace_id,
                saved_profile_id = saved_id, saved_profile_revision = 2})
            test.eq(code(claimed), "FORBIDDEN")
        end)
        restore_host()
    end)
end
return test.run_cases(define_tests)
