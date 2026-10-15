-- MIT. Launch fixture authority, host setup and carrier observation.
local shared_fixtures = require("shared_fixtures")
local test = require("test")
local completion = require("completion")
local principals = require("principals")
local funcs = require("funcs")
local security = require("security")
local process = require("process")
local registry = require("registry")
local env = require("env")
local exec = require("exec")
local time = require("time")
local hash = require("hash")
local admission = require("admission")
local machine = require("machine")
local checkpoint = require("checkpoint")
local bounds = require("bounds")
local system = require("system")
local node_client = require("node_client")
local M = {}
local REQUESTER = "bee.test.launcher"
local DEFINITION = "bee.tests.harness:fixture_definition"
local SHIPPED_SHAPE_DEFINITION = "bee.tests.harness:shipped_shape_definition"
local SHIPPED_BATCH_POLICY = "bee.driver.claude.security:launch_policy_claude_batch"
local AGENT_DEFINITION = "bee.tests.harness:agent_fixture_definition"
local AGENT_POLICY = "bee.tests.harness:agent_fixture_policy"
local AGENT_REVIEWER = "bee.tests.harness:agent_reviewer"
local AGENT_TRAIT = "bee.tests.harness:agent_repository_trait"
local RETAINED_DEFINITION = "bee.tests.harness:retained_fixture_definition"
local EMPTY_DEFINITION = "bee.tests.harness:setup_empty_definition"
local POLICY = "bee.tests.harness:fixture_policy"
local ROOT = "bee.tests.harness:project_fixture"
local SECOND_ROOT = "bee.tests.harness:git_project_fixture"
local SOURCE = "bee.tests.harness:launch_sentinel_key"
local ALTERNATE_SOURCE = "bee.tests.harness:alternate_setup_key"
local counter = 0
local function fresh(prefix: string): string
    counter = counter + 1
    return prefix .. "-" .. tostring(math.floor(time.now():unix_nano() / 1000)) .. "-" .. tostring(counter)
end
local function workspace_id(prefix: string): string
    return assert(hash.sha256(fresh(prefix))):sub(1, 32)
end
local scope_names = {"bee.tests.harness:saved_profile_test_policy", "bee.tests.harness:launch_client_policy", "bee.tests.harness:launch_recovery_client_policy", "bee.tests.harness:launch_recovery_runtime_policy", "bee.tests.harness:carrier_client_policy", "bee.threads.security:create", "bee.threads.security:observe",
    "bee.threads.security:lifecycle", "bee.threads.security:carrier", "bee.harness.security:carrier_policy", "bee.tests.harness:carrier_spawn_policy", "bee.resources.security:resource_manage_policy",
    "bee.resources.security:resource_grant_policy", "bee.credentials.security:credential_manage_policy", "bee.credentials.security:credential_issue_policy", "bee.harness.security:launch_spawn_policy", "bee.harness.security:interactive_session_policy", "bee.tests.harness:setup_client_policy"}
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
local function call(target: string, request: unknown): admission.Reply
    local result, err = funcs.new():with_actor(principals.actor(REQUESTER, principals.workspace(request))):with_scope(scope()):call(target, request)
    if err then error(target .. ": " .. tostring(err)) end
    return principals.reply(result)
end
local function profile_call(request: unknown): {[string]: unknown}
    local result, err = funcs.new():with_actor(principals.actor(REQUESTER, principals.workspace(request))):with_scope(scope()):call("bee.harness.binding:call", request)
    assert(not err, tostring(err))
    return assert(bounds.object(result))
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
    for index, name in ipairs({"bee.tests.harness:gateway_client_policy", "bee.tests.support:gateway_manage_policy"}) do
        local policy, err = security.policy(name)
        if err or not policy then error("policy " .. name .. ": " .. tostring(err)) end
        policies[index] = policy
    end
    local reply, err = funcs.new():with_actor(security.new_actor(REQUESTER)):with_scope(security.new_scope(policies)):call("bee.gateway.binding:open",
        {address = tostring((assert(bounds.object(endpoint.data))).address)})
    if err then error("bee.gateway.binding:open: " .. tostring(err)) end
    value(principals.reply(reply))
end
local function code(reply: admission.Reply): string
    if reply.ok then error("expected a failure, got success") end
    return reply.error and reply.error.code or ""
end
local function apply(entry: {id: string, kind: string, meta?: {[string]: unknown}, data?: unknown})
    local changes = registry.snapshot():changes()
    changes:update(entry)
    local applied, err = changes:apply()
    if not applied then error("apply: " .. tostring(err)) end
end
type EntryField = "data" | "meta"
-- Restores the selected entry field after the body.
local function with_entry(ref: string, mutate: (changed: {[string]: unknown}) -> (), body: () -> (), field: EntryField?)
    local entry = assert(registry.get(ref))
    local original: {[string]: unknown}
    if field == "meta" then original = assert(bounds.object(entry.meta))
    else original = assert(bounds.object(entry.data)) end
    local changed: {[string]: unknown} = {}
    for key, item in pairs(original) do changed[key] = item end
    mutate(changed)
    if field == "meta" then entry.meta = changed else entry.data = changed end
    apply(entry)
    local ok, failure = pcall(body)
    if field == "meta" then entry.meta = original else entry.data = original end
    apply(entry)
    if not ok then error(tostring(failure)) end
end
local function with_provider_source(provider: string, body: () -> ())
    local formats = assert(registry.find({["meta.type"] = "bee.credential_format", ["meta.provider"] = provider}))
    test.eq(#formats, 1)
    local file = assert(bounds.object(assert(bounds.object(formats[1].data)).file))
    with_entry("bee.credentials.env:credential_sources", function(data)
        local rows: {unknown} = {}
        local found = false
        for _, row in ipairs(assert(bounds.array(data.sources, 64))) do
            rows[#rows + 1] = row
            local source = assert(bounds.object(row))
            if source.ref == "bee.env:machine_login_source" and source.provider == provider then found = true end
        end
        if not found then
            rows[#rows + 1] = {ref = "bee.env:machine_login_source", workspace_id = "*", audience = "*", provider = provider,
                projection_kinds = {"file"}, path = file.path}
        end
        data.sources = rows
    end, function()
        with_entry("bee.credentials.security:credential_file_policy", function(data)
            local original = assert(bounds.object(data.policy))
            local changed: {[string]: unknown} = {}
            for key, value in pairs(original) do changed[key] = value end
            local resources: {string} = {}
            for _, ref in ipairs(assert(bounds.ids(original.resources, true))) do resources[#resources + 1] = ref end
            resources[#resources + 1] = "bee.env:machine_login_source"
            changed.resources = resources
            data.policy = changed
        end, body)
    end)
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
    local bin, bin_error = env.get("bee.tests.harness:fixture_bin")
    local streams, streams_error = env.get("bee.tests.harness:fixture_streams")
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
    sources[#sources + 1] = {ref = "bee.tests.credentials:claude_login_fixture", workspace_id = "*", audience = REQUESTER, provider = "claude", projection_kinds = {"file"}}
    sources[#sources + 1] = {ref = ALTERNATE_SOURCE, workspace_id = "*", audience = REQUESTER, provider = "claude", projection_kinds = {"environment"}}
    apply(sources_entry)
    value(call("bee.resources.binding:associate", {workspace_id = workspace, name = "project", root_ref = ROOT, subpath = "", allowed_access = "write"}))
    value(call("bee.resources.binding:associate", {workspace_id = workspace, name = "session", root_ref = ROOT, subpath = "", allowed_access = "write"}))
    value(call("bee.credentials.binding:define", {workspace_id = workspace, name = "anthropic", provider = "claude", source = {kind = "env_variable", ref = SOURCE}}))
end
local function setup(workspace: string, definition_ref: string): {[string]: unknown}
    local plan = value(call("bee.tests.harness.launch:resolve", {definition_ref = definition_ref}))
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
local count = shared_fixtures.count

function M.prepare(): string
        local before: {[string]: boolean} = {}
        for _, actor in ipairs(assert(system.hosts.processes("bee:workers"))) do before[actor.pid] = true end
        test.after_all(function()
            local actors = assert(system.hosts.processes("bee:workers"))
            for _, actor in ipairs(actors) do
                if not before[actor.pid] and actor.source == "bee.harness.service:presentation_owner" then
                    completion.cancel(actor.pid)
                end
            end
            for _, actor in ipairs(actors) do
                if not before[actor.pid] and actor.source == "bee.harness.service:presentation_executor" then completion.join(actor.pid) end
            end
        end)
        local roots_entry = assert(registry.get("bee.resources.env:resource_roots"))
        local roots_present = false
        for _, root in ipairs(principals.objects(roots_entry.data.roots)) do if root.root_ref == ROOT then roots_present = true end end
        if not roots_present then
            roots_entry.data.roots[#roots_entry.data.roots + 1] = {root_ref = ROOT, access = "write"}
            apply(roots_entry)
        end
        local home = assert(env.get("bee.env:machine_home"))
        local added, add_error = node_client.call(assert(system.node.id()), "workspace_add", {path = home .. "/" .. fresh("launch-home"), label = fresh("launch")})
        if not added then error(tostring(add_error)) end
        local workspace = tostring(added.workspace)
        prepare_host(workspace)
        return workspace
end
M.AGENT_DEFINITION = AGENT_DEFINITION
M.AGENT_POLICY = AGENT_POLICY
M.AGENT_REVIEWER = AGENT_REVIEWER
M.AGENT_TRAIT = AGENT_TRAIT
M.ALTERNATE_SOURCE = ALTERNATE_SOURCE
M.DEFINITION = DEFINITION
M.EMPTY_DEFINITION = EMPTY_DEFINITION
M.POLICY = POLICY
M.REQUESTER = REQUESTER
M.RETAINED_DEFINITION = RETAINED_DEFINITION
M.ROOT = ROOT
M.SECOND_ROOT = SECOND_ROOT
M.SHIPPED_BATCH_POLICY = SHIPPED_BATCH_POLICY
M.SHIPPED_SHAPE_DEFINITION = SHIPPED_SHAPE_DEFINITION
M.SOURCE = SOURCE
M.apply = apply
M.associations = associations
M.await_settled = await_settled
M.call = call
M.call_as = call_as
M.call_as_bound = call_as_bound
M.call_as_with_policies = call_as_with_policies
M.call_setup = call_setup
M.carrier_io = carrier_io
M.code = code
M.count = count
M.fixture_paths = fixture_paths
M.fresh = fresh
M.kinds = kinds
M.open_gateway = open_gateway
M.profile_call = profile_call
M.refusal_message = refusal_message
M.restore_host = restore_host
M.scope = scope
M.setup = setup
M.shell = shell
M.value = value
M.with_entry = with_entry
M.with_host_project_root = with_host_project_root
M.with_overrides = with_overrides
M.with_provider_source = with_provider_source
M.workspace_id = workspace_id
return M
