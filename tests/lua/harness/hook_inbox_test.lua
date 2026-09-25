-- MIT. Hook-boundary inbox context per driver: at a supported
-- UserPromptSubmit or Stop hook boundary the hook response carries the
-- bound action's outstanding inbox items, bounded and identified, without
-- polling and without anything typed into a PTY. Claude answers
-- additionalContext; Codex answers hook output text, and keeps its proven
-- shape on Stop. Anything else, and anything without the session_inbox
-- grant, answers exactly as before.
local test = require("test")
local principals = require("principals")
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local env = require("env")
local json = require("json")
local system = require("system")
local exec = require("exec")
local base64 = require("base64")
local sends = require("sends")
local hook_inbox = require("hook_inbox")
local ACTOR = "bee.test.hook_inbox"
local ROOT = "bee.harness.catalog:project_fixture"
type Object = {[string]: unknown}
local counter = 0
local function fresh(prefix: string): string
    counter = counter + 1
    return prefix .. "-" .. tostring(counter)
end
local scope_names = {"bee.security.threads:thread_create_policy", "bee.security.threads:thread_observe_policy", "bee.security.threads:thread_lifecycle_policy",
    "bee.security.gateway:gateway_manage_policy", "bee.security.gateway:gateway_admit_policy", "bee.security.gateway:gateway_materialize_policy",
    "bee.harness.catalog:workspace_catalog_call_policy", "bee.security.storage:workspace_catalog_manage_policy",
    "bee.security.gateway:gateway_session_send_workspace_policy"}
local function scope(): security.Scope
    local policies: {security.Policy} = {}
    for index, name in ipairs(scope_names) do
        local policy, err = security.policy(name)
        if err or not policy then error("policy " .. name .. ": " .. tostring(err)) end
        policies[index] = policy
    end
    return security.new_scope(policies)
end
local function call_as(actor_id: string, target: string, request: unknown, workspace_id: string?): Object
    local reply, err = funcs.new():with_actor(principals.actor(actor_id, workspace_id or principals.workspace(request))):with_scope(scope()):call(target, request)
    if err then error(target .. ": " .. tostring(err)) end
    local value = reply :: Object
    if value.ok ~= true then
        local fault = value.error :: Object
        error(target .. ": " .. tostring(fault.code) .. ": " .. tostring(fault.message))
    end
    return value.value :: Object
end
local function call(target: string, request: unknown): Object return call_as(ACTOR, target, request) end
local function apply(entry: {[string]: unknown})
    local changes = registry.snapshot():changes()
    changes:update(entry)
    local applied, err = changes:apply()
    if not applied then error("apply: " .. tostring(err)) end
end
local function admit_root()
    local catalog_roots = assert(registry.get("bee:resource_roots"))
    local available = (catalog_roots.data :: Object).roots :: {Object}
    local admitted = false
    for _, root in ipairs(available) do if root.root_ref == ROOT then admitted = true end end
    if not admitted then
        available[#available + 1] = {root_ref = ROOT, access = "write"}
        apply(catalog_roots)
    end
    local mode = assert(registry.get("bee:placement_resource_mode"))
    mode.data = {mode = "host_configured"}
    apply(mode)
    local entry = assert(registry.get("bee:placement_admitted_roots"))
    local roots = (entry.data :: Object).roots :: {Object}
    for _, root in ipairs(roots) do
        if root.root_ref == ROOT then return end
    end
    roots[#roots + 1] = {root_ref = ROOT, access = "write"}
    apply(entry)
end
local function shell(command: string): string
    local executor = assert(exec.get("bee:placement_executor"))
    local proc, exec_error = executor:exec("sh -c '" .. command .. "'")
    if not proc then error("exec: " .. tostring(exec_error)) end
    local stdout = proc:stdout_stream()
    assert(proc:start())
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
local function hookpost(url: string, credential: string, body: string): (integer, string)
    local bin = env.get("bee.harness.catalog:fixture_bin")
    if type(bin) ~= "string" or bin == "" then error("BEE_FIXTURE_BIN is not set for the test runtime") end
    local encoded = assert(base64.encode(body))
    local output = shell(bin .. "/gateway-client hookpost '" .. url .. "' '" .. credential .. "' '" .. encoded .. "'")
    local status, payload = 0, ""
    for line in output:gmatch("[^\n]+") do
        local code = line:match("^hookpost_status=(%d+)$")
        if code then status = tonumber(code) or 0 end
        local raw = line:match("^hookpost_body=(.*)$")
        if raw then payload = raw end
    end
    if status == 0 then error("hook post produced no status: " .. output) end
    return status, payload
end
local function endpoint_address(): string
    local entry = registry.get("bee:gateway_endpoint")
    if not entry then error("gateway endpoint entry") end
    return tostring((entry.data :: Object).address)
end
local function open_gateway()
    call("bee.gateway.binding:open", {address = endpoint_address()})
end
local function mint_binding(workspace_id: string, thread_id: string, action_id: string, tools: {string}): (string, string)
    local attempt_id = fresh("attempt")
    local admitted = call_as(ACTOR, "bee.gateway.binding:admit", {subject = ACTOR, action_id = action_id, attempt_id = attempt_id,
        thread_id = thread_id, owner_incarnation = 1, carrier_epoch = 1, tools = tools, hooks = {"UserPromptSubmit", "Stop", "PreToolUse"},
        workspace_id = workspace_id}, workspace_id)
    local binding_id = tostring((admitted.binding :: Object).binding_id)
    local authorized = call_as(ACTOR, "bee.gateway.binding:authorize_materialization",
        {attempt_id = attempt_id, carrier_epoch = 1, binding_id = binding_id}, workspace_id)
    local minted = call_as(ACTOR, "bee.gateway.binding:materialize",
        {attempt_id = attempt_id, carrier_epoch = 1, binding_id = binding_id, materialization_key = authorized.materialization_key}, workspace_id)
    return binding_id, tostring(minted.hook_token)
end
local function define_tests()
    test.describe("Hook-boundary inbox context", function()
        test.it("answers bounded identified inbox context through the driver hook contracts", function()
            admit_root()
            open_gateway()
            local label = fresh("hook-inbox-ws")
            local workspace = tostring(call("bee.workspace.catalog:create", {label = label, root_ref = ROOT,
                subpath = label, create_directory = true}).workspace_id)
            local target_thread = tostring(call_as(ACTOR, "bee.threads.service:create", {thread_id = fresh("hook-target-thread"),
                idempotency_key = fresh("key"), title = "Hook target"}, workspace).thread_id)
            local source_thread = tostring(call_as(ACTOR, "bee.threads.service:create", {thread_id = fresh("hook-source-thread"),
                idempotency_key = fresh("key"), title = "Hook source"}, workspace).thread_id)
            local target_action, source_action = fresh("target-action"), fresh("source-action")
            call_as(ACTOR, "bee.threads.service:admit_action", {thread_id = target_thread, action_id = target_action,
                idempotency_key = fresh("admit"), admitted = {request_id = fresh("request"), principal_id = ACTOR,
                    binding_ref = "bee.driver.claude:binding", binding_digest = "fixture-digest", grant_refs = {}, budget_ref = "bee.harness.catalog:project_fixture",
                    input = {text = "hook target"}}}, workspace)
            call_as(ACTOR, "bee.threads.service:admit_action", {thread_id = source_thread, action_id = source_action,
                idempotency_key = fresh("admit"), admitted = {request_id = fresh("request"), principal_id = ACTOR,
                    binding_ref = "bee.driver.claude:binding", binding_digest = "fixture-digest", grant_refs = {}, budget_ref = "bee.harness.catalog:project_fixture",
                    input = {text = "hook source"}}}, workspace)
            call_as(ACTOR, "bee.threads.service:inbox_accept", {thread_id = target_thread, action_id = target_action,
                sender_id = ACTOR, allow = true, expected_epoch = 0, idempotency_key = fresh("accept")}, workspace)
            local native = system.node.id()
            if not native or native == "" then error("native node identity is unavailable") end
            local message_id = fresh("message")
            local content = {text = "hook hello"}
            local sent = call_as(ACTOR, "bee.threads.service:inbox_send", {thread_id = target_thread, target_action_id = target_action,
                sender_thread_id = source_thread, sender_action_id = source_action, node_id = native, grant_epoch = 1,
                idempotency_key = fresh("send"), message_id = message_id, content = content,
                payload_digest = sends.payload_digest({message_id = message_id, content = content})}, workspace)
            local address = endpoint_address()
            local _, credential = mint_binding(workspace, target_thread, target_action, {"session_inbox", "thread_read"})
            local claude_url = "http://" .. address .. "/hook/" .. target_action
            local session = fresh("session")
            -- Claude answers additionalContext at both supported boundaries.
            local status, payload = hookpost(claude_url, credential,
                '{"hook_event_name":"UserPromptSubmit","session_id":"' .. session .. '","prompt":"go"}')
            if status ~= 202 then error("hook intake answered " .. tostring(status) .. ": " .. payload) end
            local answered = json.decode(payload) :: Object
            local context = tostring(answered.additionalContext)
            test.is_true(context:find(tostring(sent.record_id), 1, true) ~= nil, payload)
            test.is_true(context:find("hook hello", 1, true) ~= nil, payload)
            local stop_status, stop_payload = hookpost(claude_url, credential,
                '{"hook_event_name":"Stop","session_id":"' .. session .. '-stop","last_stop_reason":"done"}')
            test.eq(stop_status, 202)
            local stopped = json.decode(stop_payload) :: Object
            test.is_true(tostring(stopped.additionalContext):find(tostring(sent.record_id), 1, true) ~= nil, stop_payload)
            -- Other events answer exactly as before: no body.
            local other_status, other_payload = hookpost(claude_url, credential,
                '{"hook_event_name":"PreToolUse","session_id":"' .. session .. '-pre","tool_name":"read","tool_use_id":"t1","tool_input":{}}')
            test.eq(other_status, 202)
            test.eq(other_payload, "")
            -- Codex answers hook output text at UserPromptSubmit and keeps
            -- its proven shape on Stop.
            local codex_url = "http://" .. address .. "/hook/" .. target_action .. "/mcp"
            local envelope = '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"hook","arguments":{"event":"UserPromptSubmit","session_id":"' .. session .. '-codex","turn_id":"t1","prompt":"go"},"_meta":{"threadId":"t"}}}'
            local codex_status, codex_payload = hookpost(codex_url, credential, envelope)
            test.eq(codex_status, 200)
            local codex = json.decode(codex_payload) :: Object
            local result = (codex.result :: Object)
            local blocks = result.content :: {Object}
            test.is_true(tostring(blocks[1].text):find(tostring(sent.record_id), 1, true) ~= nil, codex_payload)
            test.is_true(tostring((result.structuredContent :: Object).event_id) ~= "", codex_payload)
            local stop_envelope = '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"hook","arguments":{"event":"Stop","session_id":"' .. session .. '-codex-stop","turn_id":"t1","last_assistant_message":"done"},"_meta":{"threadId":"t"}}}'
            local codex_stop_status, codex_stop_payload = hookpost(codex_url, credential, stop_envelope)
            test.eq(codex_stop_status, 200)
            local codex_stop = json.decode(codex_stop_payload) :: Object
            local stop_result = (codex_stop.result :: Object)
            test.eq(#(stop_result.content :: {Object}), 0)
            -- Without the session_inbox grant the hook is recorded but
            -- answers nothing new.
            local _, bare_credential = mint_binding(workspace, target_thread, target_action, {"thread_read"})
            local bare_status, bare_payload = hookpost(claude_url, bare_credential,
                '{"hook_event_name":"UserPromptSubmit","session_id":"' .. session .. '-bare","prompt":"go"}')
            test.eq(bare_status, 202)
            test.eq(bare_payload, "")
        end)
        test.it("reads outstanding inbox as the binding subject", function()
            admit_root()
            local label = fresh("hook-reader-ws")
            local workspace = tostring(call("bee.workspace.catalog:create", {label = label, root_ref = ROOT,
                subpath = label, create_directory = true}).workspace_id)
            local target_thread = tostring(call_as(ACTOR, "bee.threads.service:create", {thread_id = fresh("hook-reader-thread"),
                idempotency_key = fresh("key"), title = "Hook reader"}, workspace).thread_id)
            local source_thread = tostring(call_as(ACTOR, "bee.threads.service:create", {thread_id = fresh("hook-reader-source-thread"),
                idempotency_key = fresh("key"), title = "Hook reader source"}, workspace).thread_id)
            local target_action, source_action = fresh("target-action"), fresh("source-action")
            call_as(ACTOR, "bee.threads.service:admit_action", {thread_id = target_thread, action_id = target_action,
                idempotency_key = fresh("admit"), admitted = {request_id = fresh("request"), principal_id = ACTOR,
                    binding_ref = "bee.driver.claude:binding", binding_digest = "fixture-digest", grant_refs = {}, budget_ref = "bee.harness.catalog:project_fixture",
                    input = {text = "hook target"}}}, workspace)
            call_as(ACTOR, "bee.threads.service:admit_action", {thread_id = source_thread, action_id = source_action,
                idempotency_key = fresh("admit"), admitted = {request_id = fresh("request"), principal_id = ACTOR,
                    binding_ref = "bee.driver.claude:binding", binding_digest = "fixture-digest", grant_refs = {}, budget_ref = "bee.harness.catalog:project_fixture",
                    input = {text = "hook source"}}}, workspace)
            call_as(ACTOR, "bee.threads.service:inbox_accept", {thread_id = target_thread, action_id = target_action,
                sender_id = ACTOR, allow = true, expected_epoch = 0, idempotency_key = fresh("accept")}, workspace)
            local native = system.node.id()
            if not native or native == "" then error("native node identity is unavailable") end
            local message_id = fresh("message")
            local sent = call_as(ACTOR, "bee.threads.service:inbox_send", {thread_id = target_thread, target_action_id = target_action,
                sender_thread_id = source_thread, sender_action_id = source_action, node_id = native, grant_epoch = 1,
                idempotency_key = fresh("send"), message_id = message_id, content = {text = "reader hello"},
                payload_digest = sends.payload_digest({message_id = message_id, content = {text = "reader hello"}})}, workspace)
            local binding = {binding_id = fresh("binding"), subject = ACTOR, thread_id = target_thread, action_id = target_action, attempt_id = "attempt-1", workspace_id = workspace, tools = {"session_inbox"}}
            local context_text, context_error = hook_inbox.context(binding, "UserPromptSubmit")
            if not context_text then error("hook context: " .. tostring(context_error)) end
            test.is_true(context_text:find(tostring(sent.record_id), 1, true) ~= nil, context_text)
            local quiet, quiet_error = hook_inbox.context({binding_id = fresh("binding"), subject = ACTOR, thread_id = target_thread, action_id = target_action,
                attempt_id = "attempt-1", workspace_id = workspace, tools = {"thread_read"}}, "UserPromptSubmit")
            test.is_nil(quiet)
            test.is_true(tostring(quiet_error):find("session_inbox", 1, true) ~= nil, tostring(quiet_error))
            local idle, idle_error = hook_inbox.context(binding, "PreToolUse")
            test.is_nil(idle)
            test.is_nil(idle_error)
        end)
        test.it("answers nothing once the inbox is acknowledged", function()
            admit_root()
            open_gateway()
            local label = fresh("hook-empty-ws")
            local workspace = tostring(call("bee.workspace.catalog:create", {label = label, root_ref = ROOT,
                subpath = label, create_directory = true}).workspace_id)
            local target_thread = tostring(call_as(ACTOR, "bee.threads.service:create", {thread_id = fresh("hook-drained-thread"),
                idempotency_key = fresh("key"), title = "Hook drained"}, workspace).thread_id)
            local source_thread = tostring(call_as(ACTOR, "bee.threads.service:create", {thread_id = fresh("hook-drained-source-thread"),
                idempotency_key = fresh("key"), title = "Hook drained source"}, workspace).thread_id)
            local target_action, source_action = fresh("target-action"), fresh("source-action")
            call_as(ACTOR, "bee.threads.service:admit_action", {thread_id = target_thread, action_id = target_action,
                idempotency_key = fresh("admit"), admitted = {request_id = fresh("request"), principal_id = ACTOR,
                    binding_ref = "bee.driver.claude:binding", binding_digest = "fixture-digest", grant_refs = {}, budget_ref = "bee.harness.catalog:project_fixture",
                    input = {text = "hook target"}}}, workspace)
            call_as(ACTOR, "bee.threads.service:admit_action", {thread_id = source_thread, action_id = source_action,
                idempotency_key = fresh("admit"), admitted = {request_id = fresh("request"), principal_id = ACTOR,
                    binding_ref = "bee.driver.claude:binding", binding_digest = "fixture-digest", grant_refs = {}, budget_ref = "bee.harness.catalog:project_fixture",
                    input = {text = "hook source"}}}, workspace)
            call_as(ACTOR, "bee.threads.service:inbox_accept", {thread_id = target_thread, action_id = target_action,
                sender_id = ACTOR, allow = true, expected_epoch = 0, idempotency_key = fresh("accept")}, workspace)
            local native = system.node.id()
            if not native or native == "" then error("native node identity is unavailable") end
            local message_id = fresh("message")
            local content = {text = "drained hello"}
            local sent = call_as(ACTOR, "bee.threads.service:inbox_send", {thread_id = target_thread, target_action_id = target_action,
                sender_thread_id = source_thread, sender_action_id = source_action, node_id = native, grant_epoch = 1,
                idempotency_key = fresh("send"), message_id = message_id, content = content,
                payload_digest = sends.payload_digest({message_id = message_id, content = content})}, workspace)
            local ack = call_as(ACTOR, "bee.threads.service:inbox_ack", {thread_id = target_thread, action_id = target_action,
                inbox_sequence = sent.inbox_sequence, idempotency_key = fresh("ack")}, workspace)
            test.eq(ack.state, "acknowledged")
            local address = endpoint_address()
            local _, credential = mint_binding(workspace, target_thread, target_action, {"session_inbox"})
            local session = fresh("session")
            local status, payload = hookpost("http://" .. address .. "/hook/" .. target_action, credential,
                '{"hook_event_name":"UserPromptSubmit","session_id":"' .. session .. '","prompt":"go"}')
            test.eq(status, 202)
            test.eq(payload, "")
        end)
    end)
end

return test.run_cases(define_tests)
