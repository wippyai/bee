-- MIT. Launch admission against the Claude protocol fixture: a definition
-- resolves to one measured plan with no effects, admission obtains the
-- attempt-bound grant and projection in the requester's own authority,
-- start runs the carrier to settlement, and a retried start recovers the
-- same attempt without a second action, attempt, turn or receipt.
local test = require("test")
local principals = require("principals")
local funcs = require("funcs")
local security = require("security")
local process = require("process")
local channel = require("channel")
local registry = require("registry")
local env = require("env")
local exec = require("exec")
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
local AGENT_DEFINITION = "bee.harness.catalog:agent_fixture_definition"
local AGENT_POLICY = "bee.harness.catalog:agent_fixture_policy"
local AGENT_REVIEWER = "bee.harness.catalog:agent_reviewer"
local AGENT_TRAIT = "bee.harness.catalog:agent_repository_trait"
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
local scope_names = {"bee.harness.catalog:saved_profile_test_policy", "bee.harness.catalog:launch_client_policy", "bee.harness.catalog:carrier_client_policy", "bee.security.threads:thread_create_policy", "bee.security.threads:thread_observe_policy",
    "bee.security.threads:thread_lifecycle_policy", "bee.security.threads:thread_carrier_policy", "bee.security.harness:carrier_policy", "bee.harness.catalog:carrier_spawn_policy", "bee.security.resources:resource_manage_policy",
    "bee.security.resources:resource_grant_policy", "bee.security.credentials:credential_manage_policy", "bee.security.credentials:credential_issue_policy", "bee.security.harness:launch_spawn_policy", "bee.harness.catalog:setup_client_policy"}
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
    local result, err = funcs.new():with_actor(principals.actor(REQUESTER, principals.workspace(request))):with_scope(scope()):call(target, request)
    if err then error(target .. ": " .. tostring(err)) end
    return result :: admission.Reply
end
local function call_as(actor_id: string, target: string, request: unknown): admission.Reply
    local result, err = funcs.new():with_actor(principals.actor(actor_id, principals.workspace(request))):with_scope(scope()):call(target, request)
    if err then error(target .. ": " .. tostring(err)) end
    return result :: admission.Reply
end
local function value(reply: admission.Reply): {[string]: unknown}
    if not reply.ok then error(tostring(reply.error and reply.error.code) .. ": " .. tostring(reply.error and reply.error.message)) end
    return reply.value :: {[string]: unknown}
end
-- The host opens the gateway listener; a case whose attempt reaches gateway
-- admission opens it here as the host would, under the manage authority
-- only this call holds.
local function open_gateway()
    local endpoint = registry.get("bee:gateway_endpoint")
    if not endpoint then error("gateway endpoint entry") end
    local policies: {security.Policy} = {}
    for index, name in ipairs({"bee.harness.catalog:gateway_client_policy", "bee.security.gateway:gateway_manage_policy"}) do
        local policy, err = security.policy(name)
        if err or not policy then error("policy " .. name .. ": " .. tostring(err)) end
        policies[index] = policy
    end
    local reply, err = funcs.new():with_actor(actor):with_scope(security.new_scope(policies)):call("bee.gateway.binding:open",
        {address = tostring((endpoint.data :: {[string]: unknown}).address)})
    if err then error("bee.gateway.binding:open: " .. tostring(err)) end
    value(reply :: admission.Reply)
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
    for key, item in pairs(original :: {[string]: unknown}) do changed[key] = item end
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
local function carrier_io(): machine.IO
    return {
        call = function(target: string, input: unknown): (unknown, string?) return call(target, input), nil end,
        send = function(target: string, topic: string, input: unknown) end,
        self_pid = function(): string return process.pid() end,
        now_ms = function(): integer return math.floor(time.now():unix_nano() / 1000000) end,
        key = function(): string return fresh("key") end,
    }
end
local function shell(command: string): string
    local executor = assert(exec.get("bee:placement_executor"))
    local proc, exec_error = executor:exec("sh -c '" .. command .. "'")
    if not proc then error("exec " .. command .. ": " .. tostring(exec_error)) end
    local stdout = proc:stdout_stream()
    local started, start_error = proc:start()
    if not started then error("start " .. command .. ": " .. tostring(start_error)) end
    local output = ""
    while true do
        local chunk: unknown = stdout:read(65536)
        if type(chunk) ~= "string" or chunk == "" then break end
        output = output .. (chunk :: string)
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
    local native_roots = registry.get("bee:placement_admitted_roots")
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
    local mode_entry = registry.get("bee:placement_resource_mode")
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
    value(call("bee.resources.binding:associate", {workspace_id = workspace, name = "project", root_ref = ROOT, subpath = "", allowed_access = "write"}))
    value(call("bee.resources.binding:associate", {workspace_id = workspace, name = "session", root_ref = ROOT, subpath = "", allowed_access = "write"}))
    value(call("bee.credentials.binding:define", {workspace_id = workspace, name = "anthropic", provider = "claude", source = {kind = "env_variable", ref = SOURCE}}))
end
local function setup(workspace: string, definition_ref: string): {[string]: unknown}
    local plan = value(call("bee.harness.launch:resolve", {definition_ref = definition_ref}))
    local reply = call("bee.harness.launch:setup", {workspace_id = workspace, definition_ref = definition_ref, expected_plan_digest = plan.plan_digest})
    return reply :: unknown as {[string]: unknown}
end
local function associations(workspace: string): {{[string]: unknown}}
    local listed = value(call("bee.resources.binding:list", {workspace_id = workspace}))
    return listed.associations :: {{[string]: unknown}}
end
-- Temporarily sets the fixture definition's and its policy's allowed
-- overrides, restoring both whatever the body does.
local function with_overrides(definition_overrides: {string}, policy_overrides: {string}, body: () -> ())
    local definition_entry = assert(registry.get(DEFINITION))
    local policy_entry = assert(registry.get(POLICY))
    local definition_data, policy_data = definition_entry.data :: {[string]: unknown}, policy_entry.data :: {[string]: unknown}
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
    local mode_entry = registry.get("bee:placement_resource_mode")
    if not mode_entry then error("resource mode") end
    local mode_data = mode_entry.data :: {[string]: unknown}
    mode_data.mode = "host_configured"
    apply(mode_entry)
end
-- The durable thread is the settlement oracle. launch:start returns the pid
-- of a carrier it spawned unmonitored, which may have settled and exited
-- before the caller could monitor it; the receipt and the ended checkpoint
-- outlive the process.
local function await_settled(thread_id: string, attempt_id: string): {[string]: unknown}
    local deadline_ms = math.floor(time.now():unix_nano() / 1000000) + 30000
    local cursor = 0
    local settled = false
    while not settled do
        local page = value(call("bee.threads.service:read_after", {thread_id = thread_id, cursor = cursor, limit = 64, filter = {kinds = {"receipt"}}}))
        for _, item in ipairs(page.records :: {{[string]: unknown}}) do
            if item.attempt_id == attempt_id then settled = true end
        end
        cursor = math.floor(tonumber(page.scanned_through) or cursor)
        if not settled and page.has_more ~= true then
            local remaining = deadline_ms - math.floor(time.now():unix_nano() / 1000000)
            if remaining <= 0 then error("attempt " .. attempt_id .. " did not settle") end
            value(call("bee.threads.delivery:watch", {thread_id = thread_id, after_sequence = cursor, wait_ms = remaining}))
        end
    end
    local stored = value(call("bee.threads.carrier:checkpoint", {thread_id = thread_id, attempt_id = attempt_id}))
    test.eq(stored.attempt_state, "ended")
    return (stored.checkpoint :: {[string]: unknown}).terminal :: {[string]: unknown}
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
            local defined = value(call("bee.credentials.binding:list", {workspace_id = first_workspace}))
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
        test.it("refreshes a setup association after its admitted root definition changes", function()
            local target = fresh("setup-root-refresh")
            test.is_true(setup(target, RETAINED_DEFINITION).ok == true)
            local before = associations(target)
            local prior_revision = before[1].revision
            if type(prior_revision) ~= "number" then error("setup association revision is invalid") end
            local root = assert(registry.get(ROOT))
            local original = root.data
            local changed: {[string]: unknown} = {}
            for key, item in pairs(original :: {[string]: unknown}) do changed[key] = item end
            changed.meta = "setup-refresh"
            local ok, failure = pcall(function()
                root.data = changed
                apply(root)
                test.is_true(setup(target, RETAINED_DEFINITION).ok == true)
                local after = associations(target)
                test.eq(after[1].revision, prior_revision + 1)
                test.neq(after[1].association_id, before[1].association_id)
                local admitted = value(call("bee.harness.launch:admit", {request_id = fresh("setup-root-refresh-admit"),
                    definition_ref = RETAINED_DEFINITION, workspace_id = target, brief = "ping"}))
                test.eq(#((admitted.request :: {[string]: unknown}).resources :: {unknown}), 2)
            end)
            root.data = original
            apply(root)
            if not ok then error(tostring(failure)) end
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
                local listed = value(call("bee.credentials.binding:list", {workspace_id = target}))
                local definitions = listed.definitions :: {{[string]: unknown}}
                test.eq(#definitions, 1)
                test.eq(definitions[1].optional, true)
                test.eq(definitions[1].revision, 1)
                local conflict = fresh("setup-required-login")
                value(call("bee.credentials.binding:define", {workspace_id = conflict, name = "anthropic", provider = "claude", source = source}))
                local reply = setup(conflict, RETAINED_DEFINITION)
                test.is_false(reply.ok == true)
                test.eq(reply.error, "existing credential anthropic differs from host setup")
                local retained = value(call("bee.credentials.binding:list", {workspace_id = conflict}))
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
            local existing = value(call("bee.credentials.binding:define", {workspace_id = target, name = "anthropic", provider = "claude",
                source = {kind = "env_variable", ref = ALTERNATE_SOURCE}, expected_revision = 0}))
            local reply = setup(target, RETAINED_DEFINITION)
            test.is_false(reply.ok == true)
            test.eq(reply.error, "existing credential anthropic differs from host setup")
            local listed = value(call("bee.credentials.binding:list", {workspace_id = target}))
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
                local listed = value(call("bee.credentials.binding:list", {workspace_id = target}))
                test.eq(#(listed.definitions :: {unknown}), 0)
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
            local denied, denied_error = funcs.new():with_actor(principals.actor(REQUESTER, denied_workspace)):with_scope(security.new_scope({call_only})):call("bee.harness.launch:setup",
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
            local private_reply, private_error = funcs.new():with_actor(principals.actor(REQUESTER, private_workspace)):with_scope(security.new_scope({policy})):call("bee.harness.launch:setup_backend",
                {workspace_id = private_workspace, definition_ref = DEFINITION, expected_plan_digest = plan.plan_digest})
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
        test.it("ships hidden research routes for every batch driver with bounded policies", function()
            local cases = {
                {definition = "bee.driver.codex:research_batch", policy = "bee:launch_policy_codex_batch",
                    binding = "bee.driver.codex:binding", credential = "codex_login", executable = "bee.driver.codex:executable",
                    config = "bee.driver.codex:config_home", option = "sandbox", expected = "workspace-write"},
                {definition = "bee.driver.claude:research_batch", policy = "bee:launch_policy_claude_batch",
                    binding = "bee.driver.claude:binding", credential = "claude_api_key", executable = "bee.driver.claude:executable",
                    config = "bee.driver.claude:config_home", option = "max_turns", expected = 1},
                {definition = "bee.driver.agy:research_batch", policy = "bee:launch_policy_agy_batch",
                    binding = "bee.driver.agy:binding", executable = "bee.driver.agy:executable",
                    option = "model", expected = "gemini-3.8-flash", additional_options = {effort = "high"}},
                {definition = "bee.driver.muse:research_batch", policy = "bee:launch_policy_muse_batch",
                    binding = "bee.driver.muse:binding", credential = "muse_login", executable = "bee.driver.muse:executable",
                    option = "approval_mode", expected = "on-request", additional_options = {max_steps = 1}},
                {definition = "bee.driver.opencode:research_batch", policy = "bee:launch_policy_opencode_batch",
                    binding = "bee.driver.opencode:binding", executable = "bee.driver.opencode:executable", unconfined = true},
                {definition = "bee.driver.grok:research_batch", policy = "bee:launch_policy_grok_batch",
                    binding = "bee.driver.grok:binding", executable = "bee.driver.grok:executable",
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
                if selected.binding == "bee.driver.agy:binding" then
                    test.eq(#policy.gateway_hooks, 0)
                    test.eq(policy.prepare_options.sandbox, true)
                    local has_thread_message = false
                    for _, tool in ipairs(policy.gateway_tools) do if tool == "thread_message" then has_thread_message = true end end
                    test.is_true(has_thread_message)
                end
                local has_workspace = false
                for _, tool in ipairs(policy.gateway_tools) do if tool == "overlay" then has_workspace = true end end
                test.is_true(has_workspace)
            end
        end)
        test.it("flags exactly the unconfined orchestrator worker on the shipped orchestrator policy", function()
            local entry = assert(registry.get("bee:launch_policy_claude_window"))
            local orchestrator, orchestrator_error = launch_policy.decode("bee:launch_policy_claude_window", entry,
                function(ref: string): (string?, string?)
                    if ref == "bee.driver.claude:executable" then return "/usr/bin/orchestrator-agent", nil end
                    if ref == "bee.driver.claude:config_home" then return "", nil end
                    return nil, "unadmitted environment reference"
                end)
            if not orchestrator then error(tostring(orchestrator_error)) end
            test.eq(#orchestrator.agent_launch_unconfined, 1)
            test.eq(orchestrator.agent_launch_unconfined[1], "bee.driver.grok:research_batch")
            -- The named Codex route is the person's explicit host-home
            -- choice, so it keeps the inherited home while gaining the
            -- workspace-write CLI sandbox.
            local named_entry = assert(registry.get("bee:launch_policy_codex_named_batch"))
            local named, named_error = launch_policy.decode("bee:launch_policy_codex_named_batch", named_entry,
                function(ref: string): (string?, string?)
                    if ref == "bee.driver.codex:executable" then return "/usr/bin/named-agent", nil end
                    if ref == "bee.driver.codex:config_home" then return "/home/person/.codex", nil end
                    return nil, "unadmitted environment reference"
                end)
            if not named then error(tostring(named_error)) end
            test.is_true(named.allow_host_home)
            test.eq(named.prepare_options.sandbox, "workspace-write")
        end)
        test.it("ships every driver route with thread and workdir overrides its host policy admits, and no placement override", function()
            local shipped = {
                {"bee.driver.claude:default_window", "bee:launch_policy_claude_window"}, {"bee.driver.claude:research_batch", "bee:launch_policy_claude_batch"},
                {"bee.driver.codex:default_window", "bee:launch_policy_codex_window"}, {"bee.driver.codex:research_batch", "bee:launch_policy_codex_batch"},
                {"bee.driver.codex:named_batch", "bee:launch_policy_codex_named_batch"},
                {"bee.driver.muse:default_window", "bee:launch_policy_muse_window"}, {"bee.driver.muse:research_batch", "bee:launch_policy_muse_batch"},
                {"bee.driver.agy:default_window", "bee:launch_policy_agy_window"}, {"bee.driver.agy:research_batch", "bee:launch_policy_agy_batch"},
                {"bee.driver.grok:default_window", "bee:launch_policy_grok_window"}, {"bee.driver.grok:research_batch", "bee:launch_policy_grok_batch"},
                {"bee.driver.opencode:default_window", "bee:launch_policy_opencode_window"}, {"bee.driver.opencode:research_batch", "bee:launch_policy_opencode_batch"},
            }
            for _, pair in ipairs(shipped) do
                local decoded, definition_error = definitions.decode(pair[1], assert(registry.get(pair[1])))
                if not decoded then error(tostring(definition_error)) end
                test.is_true(definitions.allows(decoded, "workdir"), pair[1] .. " allows no workdir override")
                test.is_true(definitions.allows(decoded, "thread"), pair[1] .. " allows no thread override")
                test.is_false(definitions.allows(decoded, "placement"), pair[1] .. " allows a placement override")
                local data = assert(registry.get(pair[2])).data :: {[string]: unknown}
                test.eq(table.concat(data.allowed_overrides :: {string}, ","), "thread,workdir", pair[2] .. " admits other overrides")
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
                local resources_before = value(call("bee.resources.binding:list", {workspace_id = workspace}))
                local credentials_before = value(call("bee.credentials.binding:list", {workspace_id = workspace}))
                local refused = call("bee.harness.launch:admit", {request_id = fresh("foreign-agent"), definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "must not start", thread_id = foreign_thread})
                test.eq(code(refused), "DENIED")
                local after = value(call_as(foreign_owner, "bee.threads.service:read_after", {thread_id = foreign_thread, cursor = 0}))
                test.eq(#(after.records :: {unknown}), #(before.records :: {unknown}))
                local resources_after = value(call("bee.resources.binding:list", {workspace_id = workspace}))
                local credentials_after = value(call("bee.credentials.binding:list", {workspace_id = workspace}))
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
                prepare = "bee.driver.claude.binding:prepare", dispatch = "bee.driver.claude.binding:dispatch",
                normalize = "bee.driver.claude.binding:normalize", configure = "bee.harness.catalog:configuration_probe",
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
        test.it("launches a saved profile that names a Codex config profile and still delivers Bee MCP and hooks", function()
            local definition_entry = assert(registry.get(DEFINITION))
            local codex_policy = assert(registry.get("bee.harness.catalog:codex_fixture_policy"))
            local original_definition, original_policy = definition_entry.data, codex_policy.data
            local changed_definition: {[string]: unknown} = {}
            local changed_policy: {[string]: unknown} = {}
            for name, value in pairs(original_definition :: {[string]: unknown}) do changed_definition[name] = value end
            for name, value in pairs(original_policy :: {[string]: unknown}) do changed_policy[name] = value end
            changed_definition.binding_ref = "bee.driver.codex:binding"
            changed_definition.profile_id = "window"
            changed_definition.default_mode = "window"
            changed_definition.policy_ref = "bee.harness.catalog:codex_fixture_policy"
            changed_definition.credentials = {}
            changed_policy.executables = {codex = "/bin/true"}
            changed_policy.provider_ref = nil
            changed_policy.allow_host_home = true
            changed_policy.profile_options = {config_profile = {kind = "text", max_bytes = 64}}
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
                value(call("bee.harness.profiles:call", {operation = "put", workspace_id = workspace_id, profile_id = saved_id,
                    expected_revision = 0, idempotency_key = fresh("save"),
                    profile = {title = "DeepSeek Flash", definition_ref = DEFINITION, options = {config_profile = "ds-flash"}, mcp_tools = {"thread_read"}}}))
                local selected = value(call("bee.harness.launch:resolve", {definition_ref = DEFINITION, workspace_id = workspace_id,
                    saved_profile_id = saved_id, saved_profile_revision = 1}))
                local admitted = value(call("bee.harness.launch:admit", {request_id = fresh("named-profile-admit"), definition_ref = DEFINITION,
                    workspace_id = workspace_id, brief = "", saved_profile_id = saved_id, saved_profile_revision = 1,
                    expected_plan_digest = selected.plan_digest})) :: admission.Admitted
                local carrier_request = admitted.request :: {[string]: unknown}
                local preferences = carrier_request.preferences :: {[string]: unknown}
                test.eq((preferences.options :: {[string]: unknown}).config_profile, "ds-flash")
                open_gateway()
                local io = carrier_io()
                local planned, plan_error = machine.plan(io, admitted.request)
                if not planned then error(tostring(plan_error)) end
                -- Codex layers the named profile on its base user config.
                test.eq(planned.launch.argv[1], "--profile")
                test.eq(planned.launch.argv[2], "ds-flash")
                local prepared, prepare_error = machine.prepare_attempt(io, planned)
                if not prepared then error(tostring(prepare_error)) end
                local db = assert(placement_store.open())
                local row = assert(placement_store.row(db, admitted.attempt_id))
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
            local listed = value(call("bee.credentials.binding:list", {workspace_id = workspace}))
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
            -- Bound to the same workspace, so the refusal is the launch policy's.
            local outsider = funcs.new():with_actor(principals.actor("bee.test.other", workspace)):with_scope(scope())
            local denied, err = outsider:call("bee.harness.launch:admit", {request_id = fresh("request"), definition_ref = DEFINITION, workspace_id = workspace, brief = "ping"})
            if err then error(tostring(err)) end
            test.eq(code(denied :: admission.Reply), "FORBIDDEN")
        end)
        test.it("admits workdir, thread and placement overrides only where the definition and its policy both allow them", function()
            value(call("bee.resources.binding:associate", {workspace_id = workspace, name = "alternate", root_ref = ROOT, subpath = "", allowed_access = "write"}))
            local refused_request = fresh("override-refused")
            test.eq(code(call("bee.harness.launch:admit", {request_id = refused_request, definition_ref = DEFINITION, workspace_id = workspace,
                brief = "ping", workdir = "alternate"})), "FORBIDDEN")
            test.eq(code(call("bee.harness.launch:admit", {request_id = refused_request, definition_ref = DEFINITION, workspace_id = workspace,
                brief = "ping", thread_title = "Chosen title"})), "FORBIDDEN")
            test.eq(code(call("bee.threads.service:get", {thread_id = "thread:" .. refused_request})), "NOT_FOUND")
            -- The definition alone allowing an override is not enough: the
            -- host policy must admit it as well.
            with_overrides({"brief", "workdir", "thread", "placement"}, {}, function()
                local plan = value(call("bee.harness.launch:resolve", {definition_ref = DEFINITION}))
                test.eq(#(plan.overrides :: {string}), 1)
                test.eq((plan.overrides :: {string})[1], "brief")
                test.eq(plan.placement_kind, "native")
                test.eq(code(call("bee.harness.launch:admit", {request_id = refused_request, definition_ref = DEFINITION, workspace_id = workspace,
                    brief = "ping", workdir = "alternate"})), "FORBIDDEN")
                test.eq(code(call("bee.harness.launch:admit", {request_id = refused_request, definition_ref = DEFINITION, workspace_id = workspace,
                    brief = "ping", thread_title = "Chosen title"})), "FORBIDDEN")
            end)
            with_overrides({"brief"}, {"workdir", "thread", "placement"}, function()
                test.eq(code(call("bee.harness.launch:admit", {request_id = refused_request, definition_ref = DEFINITION, workspace_id = workspace,
                    brief = "ping", workdir = "alternate"})), "FORBIDDEN")
            end)
            test.eq(code(call("bee.threads.service:get", {thread_id = "thread:" .. refused_request})), "NOT_FOUND")
            with_overrides({"brief", "workdir", "thread"}, {"workdir", "thread"}, function()
                local plan = value(call("bee.harness.launch:resolve", {definition_ref = DEFINITION}))
                test.eq(#(plan.overrides :: {string}), 3)
                local request_id = fresh("override-workdir")
                local admitted = value(call("bee.harness.launch:admit", {request_id = request_id, definition_ref = DEFINITION, workspace_id = workspace,
                    brief = "ping", workdir = "alternate", thread_title = "Chosen title"}))
                local carrier_request = admitted.request :: {[string]: unknown}
                test.eq(carrier_request.working_directory, "alternate")
                local resources = carrier_request.resources :: {{[string]: unknown}}
                test.eq(#resources, 1)
                test.eq(resources[1].name, "alternate")
                test.eq(admitted.thread_id, "thread:" .. request_id)
                local created = value(call("bee.threads.service:get", {thread_id = admitted.thread_id}))
                test.eq((created.summary :: {[string]: unknown}).title, "Chosen title")
                -- An existing thread the requester belongs to replaces the new one.
                local chosen = fresh("override-thread")
                value(call("bee.threads.service:create", {thread_id = chosen, idempotency_key = fresh("create"), title = "Existing"}))
                local joined = value(call("bee.harness.launch:admit", {request_id = fresh("override-existing"), definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "ping", thread_id = chosen}))
                test.eq(joined.thread_id, chosen)
                local foreign_owner = fresh("foreign-owner")
                local foreign_thread = fresh("foreign-thread")
                value(call_as(foreign_owner, "bee.threads.service:create", {thread_id = foreign_thread,
                    idempotency_key = fresh("foreign-create"), title = "Foreign"}))
                test.eq(code(call("bee.harness.launch:admit", {request_id = fresh("override-foreign"), definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "ping", thread_id = foreign_thread})), "DENIED")
                test.eq(code(call("bee.harness.launch:admit", {request_id = fresh("override-both"), definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "ping", thread_id = chosen, thread_title = "Both"})), "INVALID")
            end)
        end)
        test.it("refuses a placement other than the host's before any thread or grant exists", function()
            local native = value(call("bee.harness.launch:admit", {request_id = fresh("placement-native"), definition_ref = DEFINITION,
                workspace_id = workspace, brief = "ping", placement = "native"}))
            test.eq((native.plan :: {[string]: unknown}).placement_kind, "native")
            local request_id = fresh("placement-docker")
            test.eq(code(call("bee.harness.launch:admit", {request_id = request_id, definition_ref = DEFINITION,
                workspace_id = workspace, brief = "ping", placement = "docker"})), "FORBIDDEN")
            with_overrides({"brief", "placement"}, {"placement"}, function()
                local refused = call("bee.harness.launch:admit", {request_id = request_id, definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "ping", placement = "docker"})
                test.eq(code(refused), "PLACEMENT_UNAVAILABLE")
            end)
            test.eq(code(call("bee.threads.service:get", {thread_id = "thread:" .. request_id})), "NOT_FOUND")
            test.eq(code(call("bee.harness.launch:admit", {request_id = request_id, definition_ref = DEFINITION,
                workspace_id = workspace, brief = "ping", placement = "vm"})), "INVALID")
        end)
        test.it("sets up a folder under an admitted root as the working directory only under a workdir override", function()
            local plan = value(call("bee.harness.launch:resolve", {definition_ref = DEFINITION}))
            local refused = call("bee.harness.launch:setup", {workspace_id = workspace, definition_ref = DEFINITION,
                expected_plan_digest = plan.plan_digest, workdir = {root_ref = ROOT, path = "chosen"}}) :: unknown as {[string]: unknown}
            test.eq(refused.ok, false)
            test.eq(refused.error, "the launch does not allow a workdir override")
            with_overrides({"brief", "workdir"}, {"workdir"}, function()
                local allowed = value(call("bee.harness.launch:resolve", {definition_ref = DEFINITION}))
                local reply = call("bee.harness.launch:setup", {workspace_id = workspace, definition_ref = DEFINITION,
                    expected_plan_digest = allowed.plan_digest, workdir = {root_ref = ROOT, path = "chosen/deeper"}}) :: unknown as {[string]: unknown}
                if reply.ok ~= true then error(tostring(reply.error)) end
                local name = tostring(reply.workdir)
                test.is_true(name:match("^folder%-[0-9a-f]+$") ~= nil)
                local found: {[string]: unknown}? = nil
                for _, association in ipairs(associations(workspace)) do
                    if association.name == name then found = association end
                end
                if not found then error("folder association is missing") end
                test.eq(found.root_ref, ROOT)
                test.eq(found.subpath, "chosen/deeper")
                local again = call("bee.harness.launch:setup", {workspace_id = workspace, definition_ref = DEFINITION,
                    expected_plan_digest = allowed.plan_digest, workdir = {root_ref = ROOT, path = "chosen/deeper"}}) :: unknown as {[string]: unknown}
                test.eq(again.workdir, name)
                local admitted = value(call("bee.harness.launch:admit", {request_id = fresh("folder-workdir"), definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "ping", workdir = name, expected_plan_digest = allowed.plan_digest}))
                test.eq((admitted.request :: {[string]: unknown}).working_directory, name)
                for _, bad in ipairs({{root_ref = ROOT, path = "../escape"}, {root_ref = ROOT, path = "/abs"}, {root_ref = "bee.harness.catalog:not_a_root", path = "x"},
                    {root_ref = ROOT, path = "x", extra = true}}) do
                    local denied = call("bee.harness.launch:setup", {workspace_id = workspace, definition_ref = DEFINITION,
                        expected_plan_digest = allowed.plan_digest, workdir = bad}) :: unknown as {[string]: unknown}
                    test.eq(denied.ok, false)
                end
            end)
        end)
        test.it("launches, waits on and cancels a managed agent as an application under its host grant", function()
            local application = "bee.application:" .. workspace .. ":launcher"
            local sources_entry = assert(registry.get("bee:credential_sources"))
            local sources = (sources_entry.data :: {[string]: unknown}).sources :: {{[string]: unknown}}
            sources[#sources + 1] = {ref = SOURCE, workspace_id = "*", audience = application, provider = "claude", projection_kinds = {"environment"}}
            apply(sources_entry)
            local function app_call(actor_id: string, names: {string}, request: {[string]: unknown}): admission.Reply
                local policies: {security.Policy} = {}
                for index, name in ipairs(names) do policies[index] = assert(security.policy(name)) end
                local reply, err = funcs.new():with_actor(principals.actor(actor_id, workspace)):with_scope(security.new_scope(policies))
                    :call("bee.harness.launch:agent_call", request)
                if err then error("agent_call: " .. tostring(err)) end
                return reply :: admission.Reply
            end
            local granted = {"bee.security.harness:agent_call_policy", "bee.harness.catalog:app_launch_grant_policy"}
            local ungranted = {"bee.security.harness:agent_call_policy"}
            local key = fresh("app-run")
            test.eq(code(app_call(application, ungranted, {operation = "launch", definition_ref = DEFINITION, brief = "ping", idempotency_key = key})), "LAUNCH_NOT_PERMITTED")
            local function settle(run: {[string]: unknown}): {[string]: unknown}
                local deadline_ms = math.floor(time.now():unix_nano() / 1000000) + 30000
                local state = ""
                while math.floor(time.now():unix_nano() / 1000000) < deadline_ms do
                    local current = value(app_call(application, granted, {operation = "wait", thread_id = run.thread_id, attempt_id = run.attempt_id, wait_ms = 5000}))
                    if current.state == "ended" then return current end
                    state = tostring(current.state)
                end
                error("the application's run did not settle; it is " .. state)
            end
            local run = value(app_call(application, granted, {operation = "launch", definition_ref = DEFINITION, brief = "ping", idempotency_key = key}))
            test.eq(run.definition_ref, DEFINITION)
            local early = value(app_call(application, granted, {operation = "status", thread_id = run.thread_id, attempt_id = run.attempt_id}))
            test.is_true(early.state == "starting" or early.state == "running" or early.state == "ended")
            local replay = value(app_call(application, granted, {operation = "launch", definition_ref = DEFINITION, brief = "ping", idempotency_key = key}))
            test.eq(replay.attempt_id, run.attempt_id)
            local settled = settle(run)
            test.eq(settled.outcome, "succeeded")
            test.not_nil(settled.answer)
            local status = value(app_call(application, granted, {operation = "status", thread_id = run.thread_id, attempt_id = run.attempt_id}))
            test.eq(status.state, "ended")
            -- Another application does not belong to the run's thread.
            test.eq(code(app_call("bee.application:" .. workspace .. ":other", granted, {operation = "status", thread_id = run.thread_id, attempt_id = run.attempt_id})), "DENIED")
            test.eq(code(app_call(application, granted, {operation = "wait", thread_id = run.thread_id, attempt_id = run.attempt_id, wait_ms = 60001})), "INVALID")
            -- The application agents library drives the same facade.
            local probe_policies = {"bee.security.harness:agent_call_policy", "bee.harness.catalog:app_launch_grant_policy", "bee.harness.catalog:agents_probe_policy"}
            local function probe(request: {[string]: unknown}): {[string]: unknown}
                local policies: {security.Policy} = {}
                for index, name in ipairs(probe_policies) do policies[index] = assert(security.policy(name)) end
                local reply, err = funcs.new():with_actor(principals.actor(application, workspace)):with_scope(security.new_scope(policies))
                    :call("bee.harness.catalog:agents_probe", request)
                if err then error("agents probe: " .. tostring(err)) end
                return reply :: {[string]: unknown}
            end
            local shared = fresh("app-shared")
            value(call_as(application, "bee.threads.service:create", {thread_id = shared, idempotency_key = fresh("create"), title = "Application thread"}))
            local through_library: {[string]: unknown} = {}
            with_overrides({"brief", "thread"}, {"thread"}, function()
                through_library = probe({launch = {definition_ref = DEFINITION, brief = "ping", idempotency_key = fresh("library"),
                    thread = {thread_id = shared}}})
            end)
            if through_library.ok ~= true then error(tostring(((through_library.error or {}) :: {[string]: unknown}).message)) end
            test.eq(((through_library.run :: {[string]: unknown}).thread_id), shared)
            test.eq(((through_library.status :: {[string]: unknown}).outcome), "succeeded")
            local unpermitted = probe({launch = {definition_ref = RETAINED_DEFINITION, brief = "ping", idempotency_key = fresh("library")}})
            test.eq(((unpermitted.error :: {[string]: unknown}).code), "LAUNCH_NOT_PERMITTED")
            -- A child that keeps reading its input runs until its owner cancels it.
            local policy_entry = assert(registry.get(POLICY))
            local policy_data = policy_entry.data :: {[string]: unknown}
            local environment = policy_data.environment :: {[string]: unknown}
            environment.BEE_FIXTURE_READ = "1"
            apply(policy_entry)
            local ok, failure = pcall(function()
                local held = value(app_call(application, granted, {operation = "launch", definition_ref = DEFINITION, brief = "hold", idempotency_key = fresh("app-hold")}))
                local cancelled = false
                for _ = 1, 50 do
                    local reply = app_call(application, granted, {operation = "cancel", thread_id = held.thread_id, attempt_id = held.attempt_id})
                    if reply.ok then cancelled = true break end
                    test.eq(code(reply), "NOT_STARTED")
                    time.sleep("100ms")
                end
                test.is_true(cancelled)
                -- Only the attempt's owner stops it.
                test.eq(code(app_call("bee.application:" .. workspace .. ":other", granted, {operation = "cancel", thread_id = held.thread_id, attempt_id = held.attempt_id})), "DENIED")
                test.eq(settle(held).outcome, "cancelled")
                local library_cancel = probe({launch = {definition_ref = DEFINITION, brief = "hold", idempotency_key = fresh("library-hold")}, cancel = true})
                if library_cancel.ok ~= true then error(tostring(((library_cancel.error or {}) :: {[string]: unknown}).message)) end
                test.eq(((library_cancel.status :: {[string]: unknown}).outcome), "cancelled")
            end)
            environment.BEE_FIXTURE_READ = nil
            apply(policy_entry)
            if not ok then error(tostring(failure)) end
        end)
        test.it("runs an agent as a function with durable receipts, replay, cancel before start and wait for terminal carrier record", function()
            local run_workspace = fresh("func-run-ws")
            local application = "bee.application:" .. run_workspace .. ":launcher"
            local sources_entry = assert(registry.get("bee:credential_sources"))
            local sources = (sources_entry.data :: {[string]: unknown}).sources :: {{[string]: unknown}}
            sources[#sources + 1] = {ref = SOURCE, workspace_id = "*", audience = application, provider = "claude", projection_kinds = {"environment"}}
            apply(sources_entry)
            local function app_call(actor_id: string, names: {string}, request: {[string]: unknown}): admission.Reply
                local policies: {security.Policy} = {}
                for index, name in ipairs(names) do policies[index] = assert(security.policy(name)) end
                local reply, err = funcs.new():with_actor(principals.actor(actor_id, run_workspace)):with_scope(security.new_scope(policies))
                    :call("bee.harness.launch:agent_call", request)
                if err then error("agent_call: " .. tostring(err)) end
                return reply :: admission.Reply
            end
            local granted = {"bee.security.harness:agent_call_policy", "bee.harness.catalog:app_launch_grant_policy"}
            local run_key = fresh("func-run-key")

            -- 1. Run returns a durable receipt promptly
            local run_reply = app_call(application, granted, {operation = "run", definition_ref = DEFINITION, brief = "ping function", idempotency_key = run_key})
            test.eq(run_reply.ok, true)
            local run_val = value(run_reply)
            test.not_nil(run_val.thread_id)
            test.not_nil(run_val.action_id)
            test.not_nil(run_val.attempt_id)
            test.eq(run_val.definition_ref, DEFINITION)
            test.eq(run_val.brief, "ping function")
            test.eq(run_val.idempotency_key, run_key)
            test.is_true(run_val.state == "starting" or run_val.state == "running" or run_val.state == "ended")
            local receipt = type(run_val.receipt) == "table" and (run_val.receipt :: {[string]: unknown}) or nil
            test.not_nil(receipt)
            test.eq(receipt and receipt.scope, "attempt")
            test.eq(receipt and receipt.thread_id, run_val.thread_id)
            test.eq(receipt and receipt.action_id, run_val.action_id)
            test.eq(receipt and receipt.attempt_id, run_val.attempt_id)
            test.eq(receipt and receipt.idempotency_key, run_key)

            -- 2. Idempotent run replay returns identical attempt receipt
            local replay_reply = app_call(application, granted, {operation = "run", definition_ref = DEFINITION, brief = "ping function", idempotency_key = run_key})
            test.eq(replay_reply.ok, true)
            local replay_val = value(replay_reply)
            test.eq(replay_val.attempt_id, run_val.attempt_id)
            test.eq(replay_val.action_id, run_val.action_id)
            test.eq(replay_val.thread_id, run_val.thread_id)

            -- 3. Wait for function run completion
            local deadline_ms = math.floor(time.now():unix_nano() / 1000000) + 30000
            local settled: {[string]: unknown}? = nil
            while math.floor(time.now():unix_nano() / 1000000) < deadline_ms do
                local cur = value(app_call(application, granted, {operation = "wait", thread_id = tostring(run_val.thread_id), attempt_id = tostring(run_val.attempt_id), wait_ms = 5000}))
                if cur.state == "ended" then settled = cur break end
            end
            test.not_nil(settled)
            test.eq(settled and settled.outcome, "succeeded")

            -- 4. Cancel before start settles attempt as cancelled with terminal receipt
            local admit_reply = call_as(application, "bee.harness.launch:admit", {
                request_id = fresh("cancel-before-start-req"),
                definition_ref = DEFINITION,
                workspace_id = run_workspace,
                brief = "cancel before start"
            })
            local admitted = value(admit_reply)
            local adm_thread = admitted.thread_id :: string
            local adm_attempt = admitted.attempt_id :: string

            local cancel_pre = app_call(application, granted, {
                operation = "cancel",
                thread_id = adm_thread,
                attempt_id = adm_attempt,
                idempotency_key = fresh("cancel-pre-key")
            })
            test.eq(cancel_pre.ok, true)
            local cancel_pre_val = value(cancel_pre)
            test.eq(cancel_pre_val.state, "ended")
            test.eq(cancel_pre_val.outcome, "cancelled")

            local status_pre = value(app_call(application, granted, {
                operation = "status",
                thread_id = adm_thread,
                attempt_id = adm_attempt
            }))
            test.eq(status_pre.state, "ended")
            test.eq(status_pre.outcome, "cancelled")

            local replay_cancel = app_call(application, granted, {
                operation = "cancel",
                thread_id = adm_thread,
                attempt_id = adm_attempt
            })
            test.eq(replay_cancel.ok, true)
            test.eq(value(replay_cancel).state, "ended")
            test.eq(value(replay_cancel).outcome, "cancelled")

            -- 5. Cancel running attempt with wait for terminal carrier record
            local policy_entry = assert(registry.get(POLICY))
            local policy_data = policy_entry.data :: {[string]: unknown}
            local environment = policy_data.environment :: {[string]: unknown}
            environment.BEE_FIXTURE_READ = "1"
            apply(policy_entry)
            local ok, failure = pcall(function()
                local held_run = value(app_call(application, granted, {
                    operation = "run",
                    definition_ref = DEFINITION,
                    brief = "hold-run",
                    idempotency_key = fresh("func-hold-key")
                }))
                local cancel_running = app_call(application, granted, {
                    operation = "cancel",
                    thread_id = held_run.thread_id,
                    attempt_id = held_run.attempt_id,
                    wait_ms = 5000,
                    idempotency_key = fresh("cancel-run-key")
                })
                test.eq(cancel_running.ok, true)
                local cr_val = value(cancel_running)
                test.eq(cr_val.state, "ended")
                test.eq(cr_val.outcome, "cancelled")
            end)
            environment.BEE_FIXTURE_READ = nil
            apply(policy_entry)
            if not ok then error(tostring(failure)) end
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
            local retried = value(call("bee.harness.launch:start", {request_id = request_id, definition_ref = DEFINITION, workspace_id = workspace, brief = "ping"}))
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
            local started = value(call("bee.harness.launch:start", {request_id = request_id, definition_ref = DEFINITION, workspace_id = workspace, brief = "ping"}))
            test.eq(started.mode, "open")
            local thread_id = tostring(started.thread_id)
            test.eq(await_settled(thread_id, tostring(started.attempt_id)).answer, "pong")
            local list = kinds(thread_id)
            test.eq(count(list, "action.admitted"), 1)
            test.eq(count(list, "attempt.prepared"), 1)
            test.eq(count(list, "receipt"), 1)
            test.eq(code(call("bee.harness.launch:start", {request_id = request_id, definition_ref = DEFINITION, workspace_id = workspace, brief = "ping"})), "CONFLICT")
            local retried_id = fresh("request")
            local first = value(call("bee.harness.launch:start", {request_id = retried_id, definition_ref = DEFINITION, workspace_id = workspace, brief = "ping"}))
            test.eq(await_settled(tostring(first.thread_id), tostring(first.attempt_id)).answer, "pong")
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
                test.eq(await_settled(shared, tostring(first.attempt_id)).answer, "pong")
                test.eq(await_settled(shared, tostring(second.attempt_id)).answer, "pong")
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
            value(call("bee.resources.binding:associate", {workspace_id = workspace, name = "session", root_ref = ROOT, subpath = "", allowed_access = "read"}))
            request.request_id = fresh("revoked-resume")
            test.is_false(call("bee.harness.launch:admit", request).ok)
            value(call("bee.resources.binding:associate", {workspace_id = workspace, name = "session", root_ref = ROOT, subpath = "", allowed_access = "write"}))
            entry.data = original
            apply(entry)
            policy_entry.data = original_policy
            apply(policy_entry)
        end)
        test.it("resolves an agent route to a hashed closure and admits its exact tools, prompt and mapped model", function()
            local first = value(call("bee.harness.launch:resolve", {definition_ref = AGENT_DEFINITION})) :: {[string]: unknown}
            test.eq(first.agent_ref, AGENT_REVIEWER)
            local digest = first.agent_digest
            test.eq(type(digest), "string")
            test.eq(#(digest :: string), 64)
            test.eq(first.agent_model, "claude-mapped")
            local declined = first.declined_tuning :: {unknown}
            test.eq(#declined, 1)
            test.eq(declined[1], "temperature")
            local agent_tools = first.agent_tools :: {unknown}
            test.eq(#agent_tools, 2)
            test.eq(agent_tools[1], "FileReport")
            test.eq(agent_tools[2], "FileRead")
            local second = value(call("bee.harness.launch:resolve", {definition_ref = AGENT_DEFINITION})) :: {[string]: unknown}
            test.eq(second.agent_digest, digest)
            test.eq(second.plan_digest, first.plan_digest)
            local admitted = value(call("bee.harness.launch:admit", {request_id = fresh("agent-admit"),
                definition_ref = AGENT_DEFINITION, workspace_id = workspace, brief = "review fixture"})) :: admission.Admitted
            test.eq(admitted.plan.agent_digest, digest)
            local carrier_request = admitted.request :: {[string]: unknown}
            local preferences = carrier_request.preferences :: {[string]: unknown}
            local tools = preferences.mcp_tools :: {unknown}
            test.eq(#tools, 2)
            test.eq(tools[1], "FileReport")
            test.eq(tools[2], "FileRead")
            test.eq((preferences.options :: {[string]: unknown}).model, "claude-mapped")
            local instructions = tostring(preferences.instructions)
            test.is_true(instructions:find("Review the supplied change.", 1, true) ~= nil)
            test.is_true(instructions:find("Use the approved repository tools.", 1, true) ~= nil)
            test.is_true(instructions:find("repo: workspace", 1, true) ~= nil)
        end)
        test.it("refuses a changed agent reference before admission", function()
            local selected = value(call("bee.harness.launch:resolve", {definition_ref = AGENT_DEFINITION})) :: {[string]: unknown}
            with_entry(AGENT_REVIEWER, function(data) data.prompt = "Changed review prompt." end, function()
                local changed = value(call("bee.harness.launch:resolve", {definition_ref = AGENT_DEFINITION})) :: {[string]: unknown}
                test.neq(changed.plan_digest, selected.plan_digest)
                test.neq(changed.agent_digest, selected.agent_digest)
                local refused = call("bee.harness.launch:admit", {request_id = fresh("agent-changed"), definition_ref = AGENT_DEFINITION,
                    workspace_id = workspace, brief = "review fixture", expected_plan_digest = selected.plan_digest})
                test.eq(code(refused), "CONFLICT")
            end)
        end)
        test.it("never reduces a trait to its prompt", function()
            with_entry(AGENT_TRAIT, function(data) data.wrappers = {"bee.harness.catalog:agent_wrapper"} end, function()
                local refused = call("bee.harness.launch:resolve", {definition_ref = AGENT_DEFINITION})
                test.eq(code(refused), "UNSUPPORTED_CAPABILITY")
                local message = refusal_message(refused)
                test.is_true(message:find("agent_repository_trait", 1, true) ~= nil)
                test.is_true(message:find("wrappers", 1, true) ~= nil)
            end)
        end)
        test.it("refuses unknown agent fields", function()
            with_entry(AGENT_REVIEWER, function(data) data.bogus_field = true end, function()
                test.eq(code(call("bee.harness.launch:resolve", {definition_ref = AGENT_DEFINITION})), "INVALID")
            end)
        end)
        test.it("refuses a model the host never mapped and a driver that takes no model", function()
            with_entry(AGENT_REVIEWER, function(data) data.model = "unmapped-model" end, function()
                local refused = call("bee.harness.launch:resolve", {definition_ref = AGENT_DEFINITION})
                test.eq(code(refused), "UNSUPPORTED_CAPABILITY")
                test.is_true(refusal_message(refused):find("unmapped-model", 1, true) ~= nil)
            end)
            with_entry(AGENT_DEFINITION, function(data)
                data.binding_ref = "bee.driver.codex:binding"
                data.profile_id = "batch"
            end, function()
                local refused = call("bee.harness.launch:resolve", {definition_ref = AGENT_DEFINITION})
                test.eq(code(refused), "UNSUPPORTED_CAPABILITY")
                test.is_true(refusal_message(refused):find("codex", 1, true) ~= nil)
            end)
        end)
        test.it("declines only owner-permitted tuning hints", function()
            with_entry(AGENT_REVIEWER, function(data) data.tuning = {temperature = 0.2, top_k = 1} end, function()
                local refused = call("bee.harness.launch:resolve", {definition_ref = AGENT_DEFINITION})
                test.eq(code(refused), "UNSUPPORTED_CAPABILITY")
                test.is_true(refusal_message(refused):find("top_k", 1, true) ~= nil)
            end)
        end)
        test.it("refuses delegates outside host admission", function()
            with_entry(AGENT_POLICY, function(data) data.agent_delegates = {} end, function()
                local refused = call("bee.harness.launch:resolve", {definition_ref = AGENT_DEFINITION})
                test.eq(code(refused), "FORBIDDEN")
                test.is_true(refusal_message(refused):find("agent_helper", 1, true) ~= nil)
            end)
        end)
        test.it("refuses saved profile tools outside the agent and options claiming its model", function()
            local workspace_id, saved_id = workspace, fresh("agent-profile")
            value(call("bee.harness.profiles:call", {operation = "put", workspace_id = workspace_id, profile_id = saved_id,
                expected_revision = 0, idempotency_key = fresh("save"),
                profile = {title = "Outside tools", definition_ref = AGENT_DEFINITION, options = {}, mcp_tools = {"thread_read"}}}))
            local outside = call("bee.harness.launch:resolve", {definition_ref = AGENT_DEFINITION, workspace_id = workspace_id,
                saved_profile_id = saved_id, saved_profile_revision = 1})
            test.eq(code(outside), "FORBIDDEN")
            value(call("bee.harness.profiles:call", {operation = "put", workspace_id = workspace_id, profile_id = saved_id,
                expected_revision = 1, idempotency_key = fresh("save"),
                profile = {title = "Claimed model", definition_ref = AGENT_DEFINITION, options = {model = "sneaky"}, mcp_tools = {}}}))
            local claimed = call("bee.harness.launch:resolve", {definition_ref = AGENT_DEFINITION, workspace_id = workspace_id,
                saved_profile_id = saved_id, saved_profile_revision = 2})
            test.eq(code(claimed), "FORBIDDEN")
        end)
        restore_host()
    end)
end
return test.run_cases(define_tests)
