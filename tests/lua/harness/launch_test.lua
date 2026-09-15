-- MIT. Launch admission against the Claude protocol fixture: a definition
-- resolves to one measured plan with no effects, admission obtains the
-- attempt-bound grant and projection in the requester's own authority,
-- start runs the carrier to settlement, and a retried start recovers the
-- same attempt without a second action, attempt, turn or receipt.
local test = require("test")
local funcs = require("funcs")
local security = require("security")
local process = require("process")
local channel = require("channel")
local registry = require("registry")
local env = require("env")
local time = require("time")
local admission = require("admission")
local definitions = require("definitions")
local launch_policy = require("launch_policy")
local machine = require("machine")
local checkpoint = require("checkpoint")
local hook_records = require("hook_records")
local placement_store = require("placement_store")
local REQUESTER = "bee.test.launcher"
local DEFINITION = "bee.harness.catalog:fixture_definition"
local RETAINED_DEFINITION = "bee.harness.catalog:retained_fixture_definition"
local EMPTY_DEFINITION = "bee.harness.catalog:setup_empty_definition"
local POLICY = "bee.harness.catalog:fixture_policy"
local ROOT = "bee.harness.catalog:project_fixture"
local SOURCE = "bee.harness.catalog:launch_sentinel_key"
local ALTERNATE_SOURCE = "bee.harness.catalog:alternate_setup_key"
local counter = 0
local function fresh(prefix: string): string
    counter = counter + 1
    return prefix .. "-" .. tostring(math.floor(time.now():unix_nano() / 1000)) .. "-" .. tostring(counter)
end
local scope_names = {"bee.harness.catalog:saved_profile_test_policy", "bee.harness.catalog:launch_client_policy", "bee.harness.catalog:carrier_client_policy", "bee:thread_create_policy", "bee:thread_observe_policy",
    "bee:thread_lifecycle_policy", "bee:thread_carrier_policy", "bee:carrier_policy", "bee.harness.catalog:carrier_spawn_policy", "bee:resource_manage_policy",
    "bee:resource_grant_policy", "bee:credential_manage_policy", "bee:credential_issue_policy", "bee:launch_spawn_policy", "bee.harness.catalog:setup_client_policy"}
local function scope(): security.Scope
    local policies: {security.Policy} = {}
    for index, name in ipairs(scope_names) do
        local policy, err = security.policy(name)
        if err or not policy then error("policy " .. name .. ": " .. tostring(err)) end
        policies[index] = policy
    end
    return security.new_scope(policies)
end
local actor = security.new_actor(REQUESTER)
local function call(target: string, request: unknown): admission.Reply
    local result, err = funcs.new():with_actor(actor):with_scope(scope()):call(target, request)
    if err then error(target .. ": " .. tostring(err)) end
    return result :: admission.Reply
end
local function call_as(actor_id: string, target: string, request: unknown): admission.Reply
    local result, err = funcs.new():with_actor(security.new_actor(actor_id)):with_scope(scope()):call(target, request)
    if err then error(target .. ": " .. tostring(err)) end
    return result :: admission.Reply
end
local function value(reply: admission.Reply): {[string]: unknown}
    if not reply.ok then error(tostring(reply.error and reply.error.code) .. ": " .. tostring(reply.error and reply.error.message)) end
    return reply.value :: {[string]: unknown}
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
local function carrier_io(): machine.IO
    return {
        call = function(target: string, input: unknown): (unknown, string?) return call(target, input), nil end,
        send = function(target: string, topic: string, input: unknown) end,
        self_pid = function(): string return process.pid() end,
        now_ms = function(): integer return math.floor(time.now():unix_nano() / 1000000) end,
        key = function(): string return fresh("key") end,
    }
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
    local policy_data = policy_entry.data :: {[string]: unknown}
    policy_data.executables = {claude = bin .. "/claude"}
    policy_data.environment = {BEE_FIXTURE_STREAM = streams .. "/claude/stream-json-2/plain.jsonl"}
    apply(policy_entry)
    local roots_entry = registry.get("bee:resource_roots")
    if not roots_entry then error("resource roots") end
    local roots_data = roots_entry.data :: {[string]: unknown}
    local roots = roots_data.roots :: {{[string]: unknown}}
    local present = false
    for _, root in ipairs(roots) do
        if root.root_ref == ROOT then present = true end
    end
    if not present then
        roots[#roots + 1] = {root_ref = ROOT, access = "write"}
        apply(roots_entry)
    end
    local native_roots = registry.get("bee.placement.native:admitted_roots")
    if not native_roots then error("native admitted roots") end
    local native_data = native_roots.data :: {[string]: unknown}
    local admitted = native_data.roots :: {{[string]: unknown}}
    local native_present = false
    for _, root in ipairs(admitted) do if root.root_ref == ROOT then native_present = true end end
    if not native_present then
        admitted[#admitted + 1] = {root_ref = ROOT, access = "write"}
        apply(native_roots)
    end
    local setup_entry = registry.get("bee:harness_setup")
    if not setup_entry then error("harness setup") end
    local setup_data = setup_entry.data :: {[string]: unknown}
    setup_data.roots = {project = ROOT, session = ROOT}
    setup_data.credentials = {anthropic = {provider = "claude", source = {kind = "env_variable", ref = SOURCE}}}
    apply(setup_entry)
    local mode_entry = registry.get("bee.placement.native:resource_mode")
    if not mode_entry then error("resource mode") end
    local mode_data = mode_entry.data :: {[string]: unknown}
    mode_data.mode = "granted"
    apply(mode_entry)
    local sources_entry = registry.get("bee:credential_sources")
    if not sources_entry then error("credential sources") end
    local sources_data = sources_entry.data :: {[string]: unknown}
    local sources = sources_data.sources :: {{[string]: unknown}}
    sources[#sources + 1] = {ref = SOURCE, workspace_id = "*", audience = REQUESTER, provider = "claude", projection_kinds = {"environment"}}
    sources[#sources + 1] = {ref = "bee.credentials:claude_login_fixture", workspace_id = "*", audience = REQUESTER, provider = "claude", projection_kinds = {"file"}}
    sources[#sources + 1] = {ref = ALTERNATE_SOURCE, workspace_id = "*", audience = REQUESTER, provider = "claude", projection_kinds = {"environment"}}
    apply(sources_entry)
    value(call("bee.resources:associate", {workspace_id = workspace, name = "project", root_ref = ROOT, subpath = "", allowed_access = "write"}))
    value(call("bee.resources:associate", {workspace_id = workspace, name = "session", root_ref = ROOT, subpath = "", allowed_access = "write"}))
    value(call("bee.credentials:define", {workspace_id = workspace, name = "anthropic", provider = "claude", source = {kind = "env_variable", ref = SOURCE}}))
end
local function setup(workspace: string, definition_ref: string): {[string]: unknown}
    local plan = value(call("bee.harness.launch:resolve", {definition_ref = definition_ref}))
    local reply = call("bee.harness.launch:setup", {workspace_id = workspace, definition_ref = definition_ref, expected_plan_digest = plan.plan_digest})
    return reply :: unknown as {[string]: unknown}
end
local function associations(workspace: string): {{[string]: unknown}}
    local listed = value(call("bee.resources:list", {workspace_id = workspace}))
    return listed.associations :: {{[string]: unknown}}
end
local function restore_host()
    local mode_entry = registry.get("bee.placement.native:resource_mode")
    if not mode_entry then error("resource mode") end
    local mode_data = mode_entry.data :: {[string]: unknown}
    mode_data.mode = "host_configured"
    apply(mode_entry)
end
local function await_exit(pid: string): {[string]: unknown}
    assert(process.monitor(pid))
    local events = assert(process.events())
    local deadline = time.after("30s")
    local outcome: {[string]: unknown}? = nil
    while not outcome do
        local selected = channel.select({events:case_receive(), deadline:case_receive()})
        if not selected.ok or selected.channel == deadline then error("carrier did not finish") end
        local event = selected.value
        if event.kind == process.event.EXIT and tostring(event.from) == pid then
            local result = event.result or {}
            if result.error then error("carrier failed: " .. tostring(result.error)) end
            outcome = result.value :: {[string]: unknown}
        end
    end
    return outcome :: {[string]: unknown}
end
local function kinds(thread_id: string): {string}
    local page = value(call("bee.threads.service:read_after", {thread_id = thread_id, cursor = 0, limit = 64}))
    local list: {string} = {}
    for index, item in ipairs(page.records :: {{[string]: unknown}}) do list[index] = tostring(item.kind) end
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
        local workspace = fresh("ws")
        prepare_host(workspace)
        test.it("fences a saved profile revision before admission and rejects preferences outside host policy", function()
            local workspace_id, saved_id = workspace, fresh("profile")
            local function save(revision: integer, title: string, options: {[string]: unknown})
                value(call("bee.harness.profiles:call", {operation = "put", workspace_id = workspace_id, profile_id = saved_id,
                    expected_revision = revision, idempotency_key = fresh("save"), profile = {title = title, definition_ref = DEFINITION, options = options}}))
            end
            save(0, "First profile", {})
            local original = value(call("bee.harness.launch:resolve", {definition_ref = DEFINITION, workspace_id = workspace_id,
                saved_profile_id = saved_id, saved_profile_revision = 1}))
            test.eq(original.saved_profile_id, saved_id)
            test.eq(original.saved_profile_revision, 1)
            test.is_nil(original.preferences)
            local admitted = value(call("bee.harness.launch:admit", {request_id = fresh("saved-profile-admit"), definition_ref = DEFINITION,
                workspace_id = workspace_id, brief = "profile fixture", saved_profile_id = saved_id, saved_profile_revision = 1,
                expected_plan_digest = original.plan_digest}))
            local carrier_request = admitted.request :: {[string]: unknown}
            local preferences = carrier_request.preferences :: {[string]: unknown}
            test.eq(preferences.instructions, "")
            test.eq(#(preferences.mcp_tools :: {unknown}), 0)
            save(1, "Revised profile", {})
            local refused = call("bee.harness.launch:admit", {request_id = fresh("stale-profile"), definition_ref = DEFINITION,
                workspace_id = workspace_id, brief = "never launch", saved_profile_id = saved_id, saved_profile_revision = 1,
                expected_plan_digest = original.plan_digest})
            test.eq(code(refused), "CONFLICT")
            local updated = value(call("bee.harness.launch:resolve", {definition_ref = DEFINITION, workspace_id = workspace_id,
                saved_profile_id = saved_id, saved_profile_revision = 2}))
            test.neq(original.plan_digest, updated.plan_digest)
            save(2, "Forbidden option", {permission_mode = "dontAsk"})
            local unsafe = call("bee.harness.launch:resolve", {definition_ref = DEFINITION, workspace_id = workspace_id,
                saved_profile_id = saved_id, saved_profile_revision = 3})
            test.is_false(unsafe.ok)
        end)
        test.it("sets selected resources once, then admission grants the exact associations", function()
            local first_workspace = fresh("setup")
            local first = setup(first_workspace, RETAINED_DEFINITION)
            test.is_true(first.ok == true)
            test.eq(#(first.resources :: {unknown}), 2)
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
            local defined = value(call("bee.credentials:list", {workspace_id = first_workspace}))
            local definitions = defined.definitions :: {{[string]: unknown}}
            test.eq(#definitions, 1)
            test.eq(definitions[1].name, "anthropic")
            test.eq(definitions[1].revision, 1)
            test.eq(#(first.credentials :: {unknown}), 1)
            local admitted = value(call("bee.harness.launch:admit", {request_id = fresh("setup-admit"), definition_ref = RETAINED_DEFINITION,
                workspace_id = first_workspace, brief = "ping"}))
            local request = admitted.request :: {[string]: unknown}
            local resources = request.resources :: {{[string]: unknown}}
            test.eq(#resources, 2)
            test.eq(resources[1].root_ref, ROOT)
            test.eq(resources[2].root_ref, ROOT)
        end)
        test.it("preserves optional login policy on setup retry and refuses a required definition", function()
            local entry = registry.get("bee:harness_setup")
            if not entry then error("host setup") end
            local original = entry.data
            local changed: {[string]: unknown} = {}
            for key, item in pairs(original :: {[string]: unknown}) do changed[key] = item end
            local source = {kind = "fs_directory", ref = "bee.credentials:claude_login_fixture"}
            changed.credentials = {anthropic = {provider = "claude", source = source, optional = true}}
            local ok, failure = pcall(function()
                entry.data = changed
                apply(entry)
                local target = fresh("setup-optional-login")
                test.is_true(setup(target, RETAINED_DEFINITION).ok == true)
                test.is_true(setup(target, RETAINED_DEFINITION).ok == true)
                local listed = value(call("bee.credentials:list", {workspace_id = target}))
                local definitions = listed.definitions :: {{[string]: unknown}}
                test.eq(#definitions, 1)
                test.eq(definitions[1].optional, true)
                test.eq(definitions[1].revision, 1)
                local conflict = fresh("setup-required-login")
                value(call("bee.credentials:define", {workspace_id = conflict, name = "anthropic", provider = "claude", source = source}))
                local reply = setup(conflict, RETAINED_DEFINITION)
                test.is_false(reply.ok == true)
                test.eq(reply.error, "existing credential anthropic differs from host setup")
                local retained = value(call("bee.credentials:list", {workspace_id = conflict}))
                local unchanged = retained.definitions :: {{[string]: unknown}}
                test.eq(unchanged[1].optional, false)
                test.eq(unchanged[1].revision, 1)
            end)
            entry.data = original
            apply(entry)
            if not ok then error(tostring(failure)) end
        end)
        test.it("never replaces a different existing credential during first-use setup", function()
            local target = fresh("setup-existing-credential")
            local existing = value(call("bee.credentials:define", {workspace_id = target, name = "anthropic", provider = "claude",
                source = {kind = "env_variable", ref = ALTERNATE_SOURCE}, expected_revision = 0}))
            local reply = setup(target, RETAINED_DEFINITION)
            test.is_false(reply.ok == true)
            test.eq(reply.error, "existing credential anthropic differs from host setup")
            local listed = value(call("bee.credentials:list", {workspace_id = target}))
            local definitions = listed.definitions :: {{[string]: unknown}}
            test.eq(#definitions, 1)
            test.eq(definitions[1].definition_id, existing.definition_id)
            test.eq(definitions[1].revision, 1)
            test.eq(definitions[1].source_ref, ALTERNATE_SOURCE)
        end)
        test.it("refuses missing host credential setup before creating resources", function()
            local entry = registry.get("bee:harness_setup")
            if not entry then error("host setup") end
            local original = entry.data
            local changed: {[string]: unknown} = {}
            for key, item in pairs(original :: {[string]: unknown}) do changed[key] = item end
            changed.credentials = {}
            local target = fresh("setup-no-credential")
            local ok, failure = pcall(function()
                entry.data = changed
                apply(entry)
                local reply = setup(target, RETAINED_DEFINITION)
                test.is_false(reply.ok == true)
                test.eq(#associations(target), 0)
                local listed = value(call("bee.credentials:list", {workspace_id = target}))
                test.eq(#(listed.definitions :: {unknown}), 0)
            end)
            entry.data = original
            apply(entry)
            if not ok then error(tostring(failure)) end
        end)
        test.it("refuses changed or conflicting selected setup without replacing an association", function()
            local conflicting_workspace = fresh("setup-conflict")
            value(call("bee.resources:associate", {workspace_id = conflicting_workspace, name = "project", root_ref = ROOT, subpath = "", allowed_access = "read", expected_revision = 0}))
            local conflict = setup(conflicting_workspace, DEFINITION)
            test.is_false(conflict.ok == true)
            test.eq(#associations(conflicting_workspace), 1)
            local plan = value(call("bee.harness.launch:resolve", {definition_ref = DEFINITION}))
            local changed_workspace = fresh("setup-changed")
            local entry = assert(registry.get(DEFINITION))
            local original = entry.data
            local changed: {[string]: unknown} = {}
            for key, item in pairs(original :: {[string]: unknown}) do changed[key] = item end
            changed.title = "Changed before setup"
            local ok, failure = pcall(function()
                entry.data = changed
                apply(entry)
                local reply = call("bee.harness.launch:setup", {workspace_id = changed_workspace, definition_ref = DEFINITION, expected_plan_digest = plan.plan_digest})
                test.is_false((reply :: unknown as {[string]: unknown}).ok == true)
                test.eq(#associations(changed_workspace), 0)
            end)
            entry.data = original
            apply(entry)
            if not ok then error(tostring(failure)) end
        end)
        test.it("rejects an unauthorized caller, private backend calls and unknown definitions", function()
            local plan = value(call("bee.harness.launch:resolve", {definition_ref = DEFINITION}))
            local no_setup, no_setup_error = funcs.new():with_actor(security.new_actor("bee.test.setup.denied")):with_scope(security.new_scope({})):call("bee.harness.launch:setup",
                {workspace_id = fresh("setup-denied"), definition_ref = DEFINITION, expected_plan_digest = plan.plan_digest})
            test.is_true(no_setup_error ~= nil or (type(no_setup) == "table" and no_setup.ok == false))
            local call_only = assert(security.policy("bee.harness.catalog:setup_call_only_policy"))
            local denied_workspace = fresh("setup-operation-denied")
            local denied, denied_error = funcs.new():with_actor(actor):with_scope(security.new_scope({call_only})):call("bee.harness.launch:setup",
                {workspace_id = denied_workspace, definition_ref = DEFINITION, expected_plan_digest = plan.plan_digest})
            test.is_nil(denied_error)
            test.is_true(type(denied) == "table")
            if type(denied) ~= "table" then error("missing denied setup reply") end
            test.eq(denied.ok, false)
            test.eq(denied.error, "setup is not authorized")
            test.eq(#associations(denied_workspace), 0)
            local policy, policy_error = security.policy("bee.harness.catalog:setup_client_policy")
            if policy_error or not policy then error(tostring(policy_error)) end
            local private_reply, private_error = funcs.new():with_actor(actor):with_scope(security.new_scope({policy})):call("bee.harness.launch:setup_backend",
                {workspace_id = fresh("setup-private"), definition_ref = DEFINITION, expected_plan_digest = plan.plan_digest})
            test.is_true(private_error ~= nil or (type(private_reply) == "table" and private_reply.ok == false))
            local unknown = call("bee.harness.launch:setup", {workspace_id = fresh("setup-unknown"), definition_ref = "bee.harness.catalog:missing",
                expected_plan_digest = plan.plan_digest})
            test.is_false((unknown :: unknown as {[string]: unknown}).ok == true)
            local empty = setup(fresh("setup-empty"), EMPTY_DEFINITION)
            test.is_true(empty.ok == true)
            test.eq(#(empty.resources :: {unknown}), 0)
        end)
        test.it("decodes an empty window prompt but refuses it for a resolved structured launch", function()
            local request = {request_id = fresh("request"), definition_ref = DEFINITION, workspace_id = fresh("workspace"), brief = ""}
            local decoded, decode_error = admission.decode_request(request)
            if not decoded then error(tostring(decode_error)) end
            test.eq(decoded.brief, "")
            local reply = call("bee.harness.launch:admit", request)
            test.eq(code(reply), "INVALID")
            test.eq(reply.error and reply.error.message, "a structured launch needs a nonempty brief")
        end)
        test.it("ships hidden Codex, Claude, and Agy research routes with bounded batch policies", function()
            local cases = {
                {definition = "bee.driver.codex:research_batch", policy = "bee:launch_policy_codex_batch",
                    binding = "bee.driver.codex:binding", credential = "codex_login", executable = "bee.driver.codex:executable",
                    config = "bee.driver.codex:config_home", option = "sandbox", expected = "read-only"},
                {definition = "bee.driver.claude:research_batch", policy = "bee:launch_policy_claude_batch",
                    binding = "bee.driver.claude:binding", credential = "claude_api_key", executable = "bee.driver.claude:executable",
                    config = "bee.driver.claude:config_home", option = "max_turns", expected = 1},
                {definition = "bee.driver.agy:research_batch", policy = "bee:launch_policy_agy_batch",
                    binding = "bee.driver.agy:binding", executable = "bee.driver.agy:executable",
                    option = "model", expected = "gemini-3.8-flash", additional_options = {effort = "high"}},
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
                test.eq(#decoded.allowed_overrides, 1)
                if selected.credential then test.eq(decoded.credentials[1], selected.credential)
                else test.eq(#decoded.credentials, 0) end
                test.is_false(decoded.presentation.start_menu)
                local policy_entry = assert(registry.get(selected.policy))
                local policy, policy_error = launch_policy.decode(selected.policy, policy_entry,
                    function(ref: string): (string?, string?)
                        if ref == selected.executable then return "/usr/bin/research-agent", nil end
                        if selected.config and ref == selected.config then return "", nil end
                        return nil, "unadmitted environment reference"
                    end)
                if not policy then error(tostring(policy_error)) end
                test.eq(policy.prepare_options[selected.option], selected.expected)
                for option, expected in pairs(selected.additional_options or {}) do
                    test.eq(policy.prepare_options[option], expected)
                end
                if selected.binding == "bee.driver.agy:binding" then
                    test.eq(#policy.gateway_hooks, 0)
                    test.is_true(policy.allow_host_home)
                    local has_thread_message = false
                    for _, tool in ipairs(policy.gateway_tools) do if tool == "thread_message" then has_thread_message = true end end
                    test.is_true(has_thread_message)
                end
                local has_workspace = false
                for _, tool in ipairs(policy.gateway_tools) do if tool == "workspace" then has_workspace = true end end
                test.is_true(has_workspace)
            end
        end)
        test.it("admits a shared caller thread only after checking membership and before acquiring launch resources", function()
            local entry = assert(registry.get(DEFINITION))
            local original = entry.data
            local changed: {[string]: unknown} = {}
            for key, item in pairs(original :: {[string]: unknown}) do changed[key] = item end
            changed.allowed_overrides = {"thread"}
            changed.thread_policy = {kind = "caller"}
            local ok, failure = pcall(function()
                entry.data = changed
                apply(entry)
                local shared = fresh("research-thread")
                value(call("bee.threads.service:create", {thread_id = shared, idempotency_key = fresh("create"), title = "Research"}))
                local admitted = value(call("bee.harness.launch:admit", {request_id = fresh("shared-agent"), definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "independent finding", thread_id = shared}))
                test.eq(admitted.thread_id, shared)
                test.eq((admitted.request :: {[string]: unknown}).thread_id, shared)

                local foreign_owner = fresh("foreign-owner")
                local foreign_thread = fresh("foreign-thread")
                value(call_as(foreign_owner, "bee.threads.service:create", {thread_id = foreign_thread,
                    idempotency_key = fresh("foreign-create"), title = "Foreign"}))
                local before = value(call_as(foreign_owner, "bee.threads.service:read_after", {thread_id = foreign_thread, cursor = 0}))
                local resources_before = value(call("bee.resources:list", {workspace_id = workspace}))
                local credentials_before = value(call("bee.credentials:list", {workspace_id = workspace}))
                local refused = call("bee.harness.launch:admit", {request_id = fresh("foreign-agent"), definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "must not start", thread_id = foreign_thread})
                test.eq(code(refused), "DENIED")
                local after = value(call_as(foreign_owner, "bee.threads.service:read_after", {thread_id = foreign_thread, cursor = 0}))
                test.eq(#(after.records :: {unknown}), #(before.records :: {unknown}))
                local resources_after = value(call("bee.resources:list", {workspace_id = workspace}))
                local credentials_after = value(call("bee.credentials:list", {workspace_id = workspace}))
                test.eq(#(resources_after.grants :: {unknown}), #(resources_before.grants :: {unknown}))
                test.eq(#(credentials_after.projections :: {unknown}), #(credentials_before.projections :: {unknown}))
            end)
            entry.data = original
            apply(entry)
            if not ok then error(tostring(failure)) end
        end)
        test.it("refuses caller environment before admitting a thread", function()
            for _, environment in ipairs({{}, {BEE_PROFILE_VALUE = "caller-value"}}) do
                local request_id = fresh("environment")
                local reply = call("bee.harness.launch:admit", {request_id = request_id, definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "ping", environment = environment})
                test.eq(code(reply), "INVALID")
                test.is_true(reply.error ~= nil and tostring(reply.error.message):find("environment", 1, true) ~= nil)
                local absent = call("bee.threads.service:get", {thread_id = "thread:" .. request_id})
                test.eq(code(absent), "NOT_FOUND")
            end
        end)
        test.it("refuses an unlinked carrier host before admitting a thread", function()
            local entry = registry.get("bee.harness:carrier_host_ref")
            if not entry then error("carrier host reference") end
            local original = entry.data
            entry.data = {}
            apply(entry)
            local request_id = fresh("unlinked")
            local reply = call("bee.harness.launch:start", {request_id = request_id, definition_ref = DEFINITION, workspace_id = workspace, brief = "ping"})
            entry.data = original
            apply(entry)
            test.eq(code(reply), "UNAVAILABLE")
            test.eq(reply.error and reply.error.message, "carrier process host is not linked")
            local absent = call("bee.threads.service:get", {thread_id = "thread:" .. request_id})
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
            for key, item in pairs(original_definition :: {[string]: unknown}) do changed_definition[key] = item end
            for key, item in pairs(original_policy :: {[string]: unknown}) do changed_policy[key] = item end
            changed_definition.title = "Changed launch title"
            changed_policy.start_ms = 23456
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
            local plan = value(call("bee.harness.launch:resolve", {definition_ref = DEFINITION}))
            test.eq(plan.launch_id, "claude-fixture")
            test.eq(plan.mode, "batch")
            test.eq(#(plan.plan_digest :: string), 64)
            local again = value(call("bee.harness.launch:resolve", {definition_ref = DEFINITION}))
            test.eq(again.plan_digest, plan.plan_digest)
            test.eq(code(call("bee.harness.launch:resolve", {definition_ref = DEFINITION, mode = "window"})), "FORBIDDEN")
            test.eq(code(call("bee.harness.launch:resolve", {definition_ref = "bee.harness.catalog:nothing"})), "NOT_FOUND")
            local entry = registry.get(DEFINITION)
            if not entry then error("definition") end
            local data = entry.data :: {[string]: unknown}
            local original = data.title
            data.title = "Retitled fixture"
            apply(entry)
            local moved = value(call("bee.harness.launch:resolve", {definition_ref = DEFINITION}))
            test.neq(moved.plan_digest, plan.plan_digest)
            data.title = original
            apply(entry)
        end)
        test.it("fences admission to the selected plan before creating a thread", function()
            local selected = value(call("bee.harness.launch:resolve", {definition_ref = DEFINITION}))
            local policy_entry = registry.get(POLICY)
            if not policy_entry then error("launch policy") end
            local original_policy = policy_entry.data
            local changed_policy: {[string]: unknown} = {}
            for key, item in pairs(original_policy :: {[string]: unknown}) do changed_policy[key] = item end
            changed_policy.start_ms = 23456

            local mismatch_request = fresh("plan-fenced")
            local ok, failure = pcall(function()
                policy_entry.data = changed_policy
                apply(policy_entry)
                local changed = value(call("bee.harness.launch:resolve", {definition_ref = DEFINITION}))
                test.neq(changed.plan_digest, selected.plan_digest)

                local refused = call("bee.harness.launch:admit", {request_id = mismatch_request, definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "ping", expected_plan_digest = selected.plan_digest})
                test.eq(code(refused), "CONFLICT")
                test.eq(code(call("bee.threads.service:get", {thread_id = "thread:" .. mismatch_request})), "NOT_FOUND")
            end)

            policy_entry.data = original_policy
            local restoration = registry.snapshot():changes()
            restoration:update(policy_entry)
            local restored, restore_error = restoration:apply()
            if not restored then error("restore launch policy: " .. tostring(restore_error)) end
            if not ok then error(tostring(failure)) end

            local restored_plan = value(call("bee.harness.launch:resolve", {definition_ref = DEFINITION}))
            test.eq(restored_plan.plan_digest, selected.plan_digest)
            local matching_request = fresh("plan-matched")
            local matching = value(call("bee.harness.launch:admit", {request_id = matching_request, definition_ref = DEFINITION,
                workspace_id = workspace, brief = "ping", expected_plan_digest = selected.plan_digest}))
            local matching_plan = matching.plan :: {[string]: unknown}
            test.eq(matching_plan.plan_digest, selected.plan_digest)
            test.eq(matching.thread_id, "thread:" .. matching_request)
        end)
        test.it("rejects a malformed expected plan digest", function()
            local request_id = fresh("plan-malformed")
            local refused = call("bee.harness.launch:admit", {request_id = request_id, definition_ref = DEFINITION,
                workspace_id = workspace, brief = "ping", expected_plan_digest = string.rep("A", 64)})
            test.eq(code(refused), "INVALID")
            test.eq(code(call("bee.threads.service:get", {thread_id = "thread:" .. request_id})), "NOT_FOUND")
        end)
        test.it("defers driver configuration until placement supplies the actual HOME", function()
            local binding = assert(registry.get("bee.driver.claude:binding"))
            local original = binding.data
            binding.data = {contracts = {{contract = "bee.driver:driver", methods = {
                prepare = "bee.driver.claude:prepare", dispatch = "bee.driver.claude:dispatch",
                normalize = "bee.driver.claude:normalize", configure = "bee.harness.catalog:configuration_probe",
            }}}}
            local ok, failure = pcall(function()
                apply(binding)
                local selected = value(call("bee.harness.launch:resolve", {definition_ref = DEFINITION}))
                local request_id = fresh("complete-config-inputs")
                local admitted = value(call("bee.harness.launch:admit", {request_id = request_id, definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "ping", expected_plan_digest = selected.plan_digest})) :: admission.Admitted
                local io = carrier_io()
                local planned, plan_error = machine.plan(io, admitted.request)
                if not planned then error(tostring(plan_error)) end
                local prepared, prepare_error = machine.prepare_attempt(io, planned)
                if not prepared then error(tostring(prepare_error)) end
                local db = assert(placement_store.open())
                local row = assert(placement_store.row(db, admitted.attempt_id))
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
        test.it("admits inherited Codex configuration and refuses a conflicting private provider", function()
            local definition_entry = assert(registry.get(DEFINITION))
            local policy_entry = assert(registry.get(POLICY))
            local original_definition, original_policy = definition_entry.data, policy_entry.data
            local changed_definition: {[string]: unknown} = {}
            local changed_policy: {[string]: unknown} = {}
            for name, value in pairs(original_definition :: {[string]: unknown}) do changed_definition[name] = value end
            for name, value in pairs(original_policy :: {[string]: unknown}) do changed_policy[name] = value end
            changed_definition.binding_ref = "bee.driver.codex:binding"
            changed_definition.profile_id = "window"
            changed_definition.default_mode = "window"
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
                local unapproved = value(call("bee.harness.launch:admit", {request_id = fresh("unapproved-host-home"), definition_ref = DEFINITION,
                    workspace_id = workspace, brief = ""})) :: admission.Admitted
                local refused_plan, refusal = machine.plan(carrier_io(), unapproved.request)
                test.is_nil(refused_plan)
                test.eq(refusal, "launch policy does not authorize host HOME")
                local refused_db = assert(placement_store.open())
                test.is_nil(placement_store.row(refused_db, unapproved.attempt_id))
                refused_db:release()
                changed_policy.allow_host_home = true
                policy_entry.data = changed_policy
                apply(policy_entry)
                local admitted = value(call("bee.harness.launch:admit", {request_id = request_id, definition_ref = DEFINITION,
                    workspace_id = workspace, brief = ""})) :: admission.Admitted
                local io = carrier_io()
                local planned, plan_error = machine.plan(io, admitted.request)
                if not planned then error(tostring(plan_error)) end
                local prepared, prepare_error = machine.prepare_attempt(io, planned)
                if not prepared then error(tostring(prepare_error)) end
                local db = assert(placement_store.open())
                local row, row_error = placement_store.row(db, admitted.attempt_id)
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
                local conflicted = value(call("bee.harness.launch:admit", {request_id = fresh("provider-home-conflict"), definition_ref = DEFINITION,
                    workspace_id = workspace, brief = ""})) :: admission.Admitted
                local refused, refusal = machine.plan(io, conflicted.request)
                test.is_nil(refused)
                test.eq(refusal, "selected provider configuration requires a private-home profile")
                local check_db = assert(placement_store.open())
                local unintended = placement_store.row(check_db, conflicted.attempt_id)
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
        test.it("fences a selected plan when its host provider changes", function()
            local definition_entry = assert(registry.get(DEFINITION))
            local codex_policy = assert(registry.get("bee.harness.catalog:codex_fixture_policy"))
            local provider = assert(registry.get("bee.harness.catalog:codex_fixture_provider"))
            local original_definition, original_policy, original_provider = definition_entry.data, codex_policy.data, provider.data
            local changed_definition: {[string]: unknown} = {}
            local changed_policy: {[string]: unknown} = {}
            local changed_provider: {[string]: unknown} = {}
            for name, value in pairs(original_definition :: {[string]: unknown}) do changed_definition[name] = value end
            for name, value in pairs(original_policy :: {[string]: unknown}) do changed_policy[name] = value end
            for name, value in pairs(original_provider :: {[string]: unknown}) do changed_provider[name] = value end
            changed_definition.binding_ref = "bee.driver.codex:binding"
            changed_definition.profile_id = "window"
            changed_definition.default_mode = "window"
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
                local selected = value(call("bee.harness.launch:resolve", {definition_ref = DEFINITION}))
                changed_provider.model = "gpt-5.1"
                provider.data = changed_provider
                local update = registry.snapshot():changes()
                update:update(provider)
                local updated, update_error = update:apply()
                if not updated then error("change provider: " .. tostring(update_error)) end
                local refused = call("bee.harness.launch:admit", {request_id = request_id, definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "", expected_plan_digest = selected.plan_digest})
                test.eq(code(refused), "CONFLICT")
                test.eq(code(call("bee.threads.service:get", {thread_id = "thread:" .. request_id})), "NOT_FOUND")
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
            local admitted = value(call("bee.harness.launch:admit", {request_id = request_id, definition_ref = DEFINITION, workspace_id = workspace, brief = "ping"}))
            test.eq(admitted.requester, REQUESTER)
            test.eq(admitted.attempt_id, "attempt:" .. request_id)
            test.eq(admitted.thread_id, "thread:" .. request_id)
            local carrier_request = admitted.request :: {[string]: unknown}
            test.eq(carrier_request.owner_id, REQUESTER)
            test.eq(carrier_request.workspace_id, workspace, "approval workspace was lost at launch admission")
            local resources = carrier_request.resources :: {{[string]: unknown}}
            test.eq(#resources, 1)
            test.eq(resources[1].root_ref, ROOT)
            local projections = carrier_request.projections :: {string}
            test.eq(#projections, 1)
            local listed = value(call("bee.credentials:list", {workspace_id = workspace}))
            local found = false
            for _, projection in ipairs(listed.projections :: {{[string]: unknown}}) do
                if projection.projection_id == projections[1] then
                    found = true
                    test.eq(projection.subject, REQUESTER)
                    test.eq(projection.attempt_id, "attempt:" .. request_id)
                end
            end
            test.is_true(found)
            local replay = value(call("bee.harness.launch:admit", {request_id = request_id, definition_ref = DEFINITION, workspace_id = workspace, brief = "ping"}))
            test.eq(((replay.request :: {[string]: unknown}).projections :: {string})[1], projections[1])
            test.eq(code(call("bee.harness.launch:admit", {request_id = fresh("request"), definition_ref = DEFINITION, workspace_id = workspace, brief = "ping", thread_id = "t"})), "FORBIDDEN")
            local outsider = funcs.new():with_actor(security.new_actor("bee.test.other")):with_scope(scope())
            local denied, err = outsider:call("bee.harness.launch:admit", {request_id = fresh("request"), definition_ref = DEFINITION, workspace_id = workspace, brief = "ping"})
            if err then error(tostring(err)) end
            test.eq(code(denied :: admission.Reply), "FORBIDDEN")
        end)
        test.it("refuses caller-selected session identities and resources before creating work", function()
            for _, field in ipairs({"session_ref", "session_resource"}) do
                local request_id = fresh("session-injection")
                local request: {[string]: unknown} = {request_id = request_id, definition_ref = RETAINED_DEFINITION,
                    workspace_id = workspace, brief = "ping"}
                request[field] = "caller-selected"
                test.eq(code(call("bee.harness.launch:admit", request)), "INVALID")
                test.eq(code(call("bee.threads.service:get", {thread_id = "thread:" .. request_id})), "NOT_FOUND")
            end
        end)
        test.it("uses a host-selected retained session resource with a retry-stable identity", function()
            local request_id = fresh("retained")
            local admitted = value(call("bee.harness.launch:admit", {request_id = request_id, definition_ref = RETAINED_DEFINITION, workspace_id = workspace, brief = "ping"}))
            test.is_true(type(admitted.session_ref) == "string" and (admitted.session_ref :: string):match("^session:[0-9a-f]+$") ~= nil)
            local carrier_request = admitted.request :: {[string]: unknown}
            test.eq(carrier_request.session_ref, admitted.session_ref)
            local resources = carrier_request.resources :: {{[string]: unknown}}
            test.eq(#resources, 2)
            local session_grant = nil
            for _, resource in ipairs(resources) do
                if resource.purpose == "session" then session_grant = resource end
            end
            if not session_grant then error("retained session grant missing") end
            test.eq(session_grant.name, "session")
            test.eq(session_grant.access, "write")
            local replay = value(call("bee.harness.launch:admit", {request_id = request_id, definition_ref = RETAINED_DEFINITION, workspace_id = workspace, brief = "ping"}))
            test.eq(replay.session_ref, admitted.session_ref)
            local replay_resources = (replay.request :: {[string]: unknown}).resources :: {{[string]: unknown}}
            local replay_grant = nil
            for _, resource in ipairs(replay_resources) do
                if resource.purpose == "session" then replay_grant = resource end
            end
            test.eq(replay_grant and replay_grant.grant_ref, session_grant.grant_ref)
            local other = value(call("bee.harness.launch:admit", {request_id = fresh("retained"), definition_ref = RETAINED_DEFINITION, workspace_id = workspace, brief = "ping"}))
            test.neq(other.session_ref, admitted.session_ref)
        end)
        test.it("refuses a host definition whose retained resource is unavailable before creating a thread", function()
            local entry = assert(registry.get(RETAINED_DEFINITION))
            local original = entry.data
            local changed: {[string]: unknown} = {}
            for key, item in pairs(original :: {[string]: unknown}) do changed[key] = item end
            changed.session_resource = "missing-session"
            local request_id = fresh("retained-denied")
            local ok, failure = pcall(function()
                entry.data = changed
                apply(entry)
                local refused = call("bee.harness.launch:admit", {request_id = request_id, definition_ref = RETAINED_DEFINITION, workspace_id = workspace, brief = "ping"})
                test.eq(code(refused), "NOT_FOUND")
                test.eq(code(call("bee.threads.service:get", {thread_id = "thread:" .. request_id})), "NOT_FOUND")
            end)
            entry.data = original
            apply(entry)
            if not ok then error(tostring(failure)) end
        end)
        test.it("recovers a start that failed after placement intent and before the first checkpoint", function()
            local request_id = fresh("request")
            local admitted = value(call("bee.harness.launch:admit", {request_id = request_id, definition_ref = DEFINITION, workspace_id = workspace, brief = "ping"}))
            local carrier_request = admitted.request :: {[string]: unknown}
            local spawner = process.with_context({}):with_actor(actor):with_scope(scope())
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
            local retried = value(call("bee.harness.launch:start", {request_id = request_id, definition_ref = DEFINITION, workspace_id = workspace, brief = "ping"}))
            test.eq(retried.mode, "open")
            local outcome = await_exit(tostring(retried.carrier))
            test.eq((outcome.settlement :: {[string]: unknown}).answer, "pong")
            local after = kinds("thread:" .. request_id)
            test.eq(count(after, "action.admitted"), 1)
            test.eq(count(after, "attempt.prepared"), 1)
            test.eq(count(after, "attempt.started"), 1)
            test.eq(count(after, "turn.request"), 1)
            test.eq(count(after, "receipt"), 1)
        end)
        test.it("starts the carrier to settlement and a retried start recovers the same attempt", function()
            local request_id = fresh("request")
            local started = value(call("bee.harness.launch:start", {request_id = request_id, definition_ref = DEFINITION, workspace_id = workspace, brief = "ping"}))
            test.eq(started.mode, "open")
            local outcome = await_exit(tostring(started.carrier))
            test.eq((outcome.settlement :: {[string]: unknown}).answer, "pong")
            local thread_id = tostring(started.thread_id)
            local list = kinds(thread_id)
            test.eq(count(list, "action.admitted"), 1)
            test.eq(count(list, "attempt.prepared"), 1)
            test.eq(count(list, "receipt"), 1)
            test.eq(code(call("bee.harness.launch:start", {request_id = request_id, definition_ref = DEFINITION, workspace_id = workspace, brief = "ping"})), "CONFLICT")
            local retried_id = fresh("request")
            local first = value(call("bee.harness.launch:start", {request_id = retried_id, definition_ref = DEFINITION, workspace_id = workspace, brief = "ping"}))
            local first_outcome = await_exit(tostring(first.carrier))
            test.eq((first_outcome.settlement :: {[string]: unknown}).answer, "pong")
            local retried_list = kinds(tostring(first.thread_id))
            test.eq(count(retried_list, "attempt.started"), 1)
            test.eq(count(retried_list, "turn.request"), 1)
        end)
        test.it("fans two managed research actions into one caller-owned durable thread", function()
            local entry = assert(registry.get(DEFINITION))
            local original = entry.data
            local changed: {[string]: unknown} = {}
            for key, item in pairs(original :: {[string]: unknown}) do changed[key] = item end
            changed.allowed_overrides = {"thread"}
            changed.thread_policy = {kind = "caller"}
            local ok, failure = pcall(function()
                entry.data = changed
                apply(entry)
                local shared = fresh("autoresearch")
                value(call("bee.threads.service:create", {thread_id = shared, idempotency_key = fresh("create"), title = "Autoresearch"}))
                local first_id, second_id = fresh("research-one"), fresh("research-two")
                local first = value(call("bee.harness.launch:start", {request_id = first_id, definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "investigate the first hypothesis", thread_id = shared}))
                local second = value(call("bee.harness.launch:start", {request_id = second_id, definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "investigate the second hypothesis", thread_id = shared}))
                test.eq(first.thread_id, shared)
                test.eq(second.thread_id, shared)
                test.neq(first.action_id, second.action_id)
                test.neq(first.attempt_id, second.attempt_id)
                test.eq(((await_exit(tostring(first.carrier))).settlement :: {[string]: unknown}).answer, "pong")
                test.eq(((await_exit(tostring(second.carrier))).settlement :: {[string]: unknown}).answer, "pong")
                local records = kinds(shared)
                test.eq(count(records, "action.admitted"), 2)
                test.eq(count(records, "attempt.prepared"), 2)
                test.eq(count(records, "attempt.started"), 2)
                test.eq(count(records, "turn.request"), 2)
                test.eq(count(records, "receipt"), 2)
                local subscribed = value(call("bee.threads.delivery:subscribe", {thread_id = shared,
                    idempotency_key = fresh("subscribe"), consumer_id = "autoresearch-coordinator",
                    after_sequence = 0, filter = {kinds = {"receipt"}}, durability = "durable"}))
                local page = value(call("bee.threads.delivery:page", {thread_id = shared,
                    subscription_id = subscribed.subscription_id}))
                test.eq(#(page.records :: {unknown}), 2)
                value(call("bee.threads.delivery:ack_page", {thread_id = shared,
                    idempotency_key = fresh("ack-page"), subscription_id = subscribed.subscription_id,
                    page_id = page.page_id, scanned_through = page.scanned_through}))
                local detached = value(call("bee.threads.delivery:unsubscribe", {thread_id = shared,
                    idempotency_key = fresh("detach-consumer"), subscription_id = subscribed.subscription_id}))
                test.is_true(detached.closed)
                local resumed = value(call("bee.threads.delivery:resume", {thread_id = shared,
                    idempotency_key = fresh("resume-consumer"), subscription_id = subscribed.subscription_id}))
                test.eq(resumed.lease_generation, 2)
                local caught_up = value(call("bee.threads.delivery:page", {thread_id = shared,
                    subscription_id = subscribed.subscription_id}))
                test.eq(#(caught_up.records :: {unknown}), 0)
                test.is_nil(caught_up.page_id)
                test.eq(code(call("bee.harness.launch:start", {request_id = first_id, definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "investigate the first hypothesis", thread_id = shared})), "CONFLICT")
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
            for key, item in pairs(original :: {[string]: unknown}) do changed[key] = item end
            changed.profile_id, changed.default_mode = "window", "window"
            entry.data = changed
            apply(entry)
            local policy_entry = registry.get(POLICY)
            if not policy_entry then error("fixture policy") end
            local original_policy = policy_entry.data
            local window_policy: {[string]: unknown} = {}
            for key, item in pairs(original_policy :: {[string]: unknown}) do window_policy[key] = item end
            window_policy.prepare_options = {permission_mode = "default"}
            window_policy.allow_host_home = true
            policy_entry.data = window_policy
            apply(policy_entry)
            local origin = fresh("window-origin")
            local first = value(call("bee.harness.launch:admit", {request_id = origin, definition_ref = RETAINED_DEFINITION,
                workspace_id = workspace, brief = ""})) :: admission.Admitted
            local transport: machine.IO = {
                call = function(target: string, input: unknown): (unknown, string?) return call(target, input), nil end,
                send = function(target: string, topic: string, input: unknown) end,
                self_pid = function(): string return process.pid() end,
                now_ms = function(): integer return math.floor(time.now():unix_nano() / 1000000) end,
                key = function(): string return fresh("key") end,
            }
            local planned, plan_error = machine.plan(transport, first.request)
            if not planned then error(tostring(plan_error)) end
            local prepared, prepare_error = machine.prepare_attempt(transport, planned)
            if not prepared then error(tostring(prepare_error)) end
            local point = checkpoint.new({binding_ref = first.plan.binding_ref, binding_digest = first.plan.binding_digest,
                profile_id = first.plan.profile_id, profile_digest = first.plan.profile_digest, gateway_binding = "recorded-binding"}, prepared.epoch)
            point.retained_session_ref = first.session_ref
            local records, records_error = hook_records.batch("recorded-binding", nil, {{event_id = "session-start", event = "SessionStart",
                occurrence = "session:provider-session", ambiguous = false, provenance = "fixture", sequence = 1,
                fields = {event = "SessionStart", session_id = "provider-session", source = "startup"}}})
            if not records then error(tostring(records_error)) end
            value(call("bee.threads.carrier:commit", {thread_id = first.thread_id, attempt_id = first.attempt_id,
                idempotency_key = fresh("commit"), carrier_epoch = prepared.epoch, expected_revision = 0, checkpoint = point, records = records.records}))
            local request: admission.Request = {request_id = fresh("resume"), definition_ref = RETAINED_DEFINITION, workspace_id = workspace,
                brief = "", expected_plan_digest = first.plan.plan_digest,
                continuation = {origin_request_id = origin, previous_attempt_id = first.attempt_id, thread_id = first.thread_id}}
            test.eq(code(call("bee.harness.launch:admit", request)), "CONFLICT")
            value(call("bee.threads.service:receipt", {thread_id = first.thread_id, action_id = first.action_id, attempt_id = first.attempt_id,
                idempotency_key = fresh("receipt"), carrier_epoch = prepared.epoch, receipt = {scope = "attempt", outcome = "cancelled", evidence_refs = {},
                    error = {code = "fixture_closed", message = "predecessor fixture closed", retryable = false}}}))
            test.eq(code(call("bee.harness.launch:admit", request)), "CONFLICT")
            local db, db_error = placement_store.open()
            if not db then error(tostring(db_error)) end
            test.is_true(placement_store.transition(db, first.attempt_id, {execution = "starting", evidence = {kind = "fixture", detail = "no process started"}}).ok)
            test.is_true(placement_store.transition(db, first.attempt_id, {execution = "exited", evidence = {kind = "fixture", detail = "no process exists"}}).ok)
            test.eq(code(call("bee.harness.launch:admit", request)), "CONFLICT")
            test.is_true(placement_store.transition(db, first.attempt_id, {cleanup = "complete", evidence = {kind = "fixture", detail = "no home materialized"}}).ok)
            db:release()
            local resumed = value(call("bee.harness.launch:admit", request)) :: admission.Admitted
            test.eq(resumed.action_id, first.action_id)
            test.eq(resumed.thread_id, first.thread_id)
            test.eq(resumed.session_ref, first.session_ref)
            test.eq(resumed.attempt_id, "attempt:" .. request.request_id)
            test.eq(resumed.request.previous_attempt_id, first.attempt_id)
            test.eq(resumed.request.brief, "")
            test.eq(resumed.request.resources[1].name, first.request.resources[1].name)
            test.is_true(resumed.request.resources[1].grant_ref ~= first.request.resources[1].grant_ref)
            local replay = value(call("bee.harness.launch:admit", request)) :: admission.Admitted
            test.eq(replay.request.resources[1].grant_ref, resumed.request.resources[1].grant_ref)
            test.eq(code(call("bee.threads.service:get", {thread_id = "thread:" .. request.request_id})), "NOT_FOUND")
            local resume_plan, resume_error = machine.plan(transport, resumed.request)
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
            test.eq(code(call("bee.harness.launch:admit", request)), "CONFLICT")
            local current, current_error = admission.resolve(RETAINED_DEFINITION, "window")
            if not current then error(tostring(current_error)) end
            request.expected_plan_digest = current.plan_digest
            local reviewed = value(call("bee.harness.launch:admit", request)) :: admission.Admitted
            test.eq(reviewed.plan.plan_digest, current.plan_digest)
            test.eq(reviewed.session_ref, first.session_ref)
            test.eq(reviewed.action_id, first.action_id)
            test.is_true(reviewed.request.reauthorize)
            local reviewed_plan, reviewed_error = machine.plan(transport, reviewed.request)
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
            test.eq(code(call("bee.harness.launch:admit", request)), "CONFLICT")
            request.workspace_id = workspace
            request.expected_plan_digest = string.rep("0", 64)
            test.eq(code(call("bee.harness.launch:admit", request)), "CONFLICT")
            request.continuation.reauthorize = true
            test.eq(code(call("bee.harness.launch:admit", request)), "CONFLICT", "review never bypasses the current plan fence")
            request.continuation.reauthorize = false
            request.expected_plan_digest = first.plan.plan_digest
            request.brief = "repeat original prompt"
            test.eq(code(call("bee.harness.launch:admit", request)), "INVALID")
            request.brief = ""
            local foreign, foreign_error = funcs.new():with_actor(security.new_actor("bee.test.foreign")):with_scope(scope()):call("bee.harness.launch:admit", request)
            if foreign_error then error(tostring(foreign_error)) end
            test.is_false((foreign :: admission.Reply).ok)
            -- Current resource authority must approve again; the old grant
            -- and committed hook do not authorize a new attempt.
            value(call("bee.resources:associate", {workspace_id = workspace, name = "session", root_ref = ROOT, subpath = "", allowed_access = "read"}))
            request.request_id = fresh("revoked-resume")
            test.is_false(call("bee.harness.launch:admit", request).ok)
            value(call("bee.resources:associate", {workspace_id = workspace, name = "session", root_ref = ROOT, subpath = "", allowed_access = "write"}))
            entry.data = original
            apply(entry)
            policy_entry.data = original_policy
            apply(policy_entry)
        end)
        restore_host()
    end)
end
return test.run_cases(define_tests)
