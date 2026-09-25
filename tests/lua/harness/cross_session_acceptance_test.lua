-- MIT. Cross-session coordination through two scripted managed agents of
-- different drivers. One case covers shared-owner thread tools and notices;
-- another gives each agent its own actor and thread and exchanges accepted
-- inbox messages and a correlated reply through their separate MCP bindings.
local test = require("test")
local principals = require("principals")
local funcs = require("funcs")
local security = require("security")
local process = require("process")
local registry = require("registry")
local env = require("env")
local time = require("time")
local channel = require("channel")
local json = require("json")
local system = require("system")
local placement_fixture = require("placement_fixture")
local catalog = require("catalog")
local policy = require("policy")
local sends = require("sends")
local ACTOR = "bee.test.cross_session"
local WAITER_POLICY = "bee.harness.catalog:cross_session_claude_policy"
local PUSH_POLICY = "bee.harness.catalog:cross_session_claude_push_policy"
local SENDER_POLICY = "bee.harness.catalog:cross_session_codex_policy"
local CODEX_BINDING = "bee.driver.codex:binding"
local SENTINEL_SOURCE = "bee.harness.catalog:codex_sentinel_key"
local ROOT = "bee.harness.catalog:project_fixture"
local CARRIER = "bee.harness.catalog:carrier_faulted"
type Object = {[string]: unknown}
local counter = 0
local function fresh(prefix: string): string
    counter = counter + 1
    return prefix .. "-" .. tostring(math.floor(time.now():unix_nano() / 1000)) .. "-" .. tostring(counter)
end
local scope_names = {"bee.harness.catalog:carrier_client_policy", "bee.harness.catalog:gateway_client_policy", "bee.security.threads:thread_create_policy", "bee.security.threads:thread_observe_policy", "bee.security.threads:thread_lifecycle_policy",
    "bee.security.threads:thread_carrier_policy", "bee.security.harness:carrier_policy", "bee.harness.catalog:carrier_spawn_policy", "bee.security.gateway:gateway_manage_policy", "bee.security.gateway:gateway_admit_policy",
    "bee.harness.catalog:codex_credential_client_policy", "bee.security.credentials:credential_manage_policy", "bee.security.credentials:credential_issue_policy",
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
local function setting(id: string, what: string): string
    local value, err = env.get(id)
    if err or type(value) ~= "string" or value == "" then error(what .. " is not set for the test runtime") end
    return value
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
local function bind_policies()
    local bin = setting("bee.harness.catalog:fixture_bin", "BEE_FIXTURE_BIN")
    local waiter = assert(registry.get(WAITER_POLICY))
    local waiter_data = waiter.data :: Object
    waiter_data.executables = {claude = bin .. "/claude"}
    apply(waiter)
    local sender = assert(registry.get(SENDER_POLICY))
    -- The Codex fixture sits beside bin/, outside the composition's PATH.
    local harness_dir = bin:match("^(.*)/bin/?$")
    if not harness_dir then error("BEE_FIXTURE_BIN does not end in bin: " .. bin) end
    local sender_data = sender.data :: Object
    sender_data.executables = {codex = harness_dir .. "/codex/codex"}
    apply(sender)
    -- Codex runs with a projected provider key; the sentinel source never
    -- leaves this host, and the fixture never calls the provider.
    local sources = assert(registry.get("bee:credential_sources"))
    local list = (sources.data :: Object).sources :: {Object}
    for _, source in ipairs(list) do
        if source.ref == SENTINEL_SOURCE and source.audience == ACTOR then return end
    end
    list[#list + 1] = {ref = SENTINEL_SOURCE, workspace_id = "*", audience = ACTOR, provider = "codex", projection_kinds = {"environment"}}
    apply(sources)
end
-- A provider key projection for the Codex attempt, measured against the
-- binding, profile and launch policy exactly as admission measures them.
local function codex_projection(workspace: string, attempt_id: string): string
    call("bee.credentials.binding:define", {workspace_id = workspace, name = "openai", provider = "codex", source = {kind = "env_variable", ref = SENTINEL_SOURCE}})
    local snapshot = assert(catalog.snapshot())
    local usable = assert(catalog.usable(snapshot))
    for _, candidate in ipairs(usable) do
        if candidate.binding_id == CODEX_BINDING then
            local pinned, policy_error = policy.load(SENDER_POLICY)
            if not pinned then error(tostring(policy_error)) end
            local issued = call("bee.credentials.binding:issue_projection", {workspace_id = workspace, name = "openai", audience = ACTOR, attempt_id = attempt_id, profile_id = "batch",
                profile_digest = tostring(candidate.profile_digest.entry), binding_digest = tostring(candidate.binding_digest.entry), launch_policy_digest = tostring(pinned.digest),
                idempotency_key = fresh("key")})
            return tostring(issued.projection_id)
        end
    end
    error("the Codex binding is not usable on this host")
end
local function open_gateway()
    local entry = assert(registry.get("bee:gateway_endpoint"))
    call("bee.gateway.binding:open", {address = tostring((entry.data :: Object).address)})
end
local function session(binding_ref: string, policy_ref: string, thread_id: string, workspace_id: string, environment: {[string]: string}, owner_id: string?): Object
    local placement = placement_fixture.resolve()
    local attempt_id = fresh("attempt")
    return {thread_id = thread_id, action_id = "action-" .. attempt_id, attempt_id = attempt_id, owner_id = owner_id or ACTOR, owner_incarnation = 1, binding_ref = binding_ref,
        profile_id = "batch", brief = "coordinate", policy_ref = policy_ref, workspace_id = workspace_id,
        resources = {{name = "project", grant_ref = "host", root_ref = ROOT, subpath = "", access = "write", purpose = "project"}},
        environment = environment, working_directory = "project", placement_binding_ref = placement.binding_id, placement_binding_digest = placement.binding_digest}
end
local function spawn(request_value: Object, mode: string?, crash_after: string?): string
    local pid, err = process.with_context({}):with_actor(principals.actor(tostring(request_value.owner_id), request_value.workspace_id)):with_scope(scope()):spawn_monitored(CARRIER, "bee:workers", request_value, mode or "open", process.pid(), crash_after)
    if not pid then error("spawn carrier: " .. tostring(err)) end
    return tostring(pid)
end
local function await_crash(pid: string)
    local events = assert(process.events())
    local deadline = time.after("30s")
    while true do
        local selected = channel.select({events:case_receive(), deadline:case_receive()})
        if not selected.ok or selected.channel == deadline then error("faulted push carrier did not exit") end
        local event = selected.value
        if event.kind == process.event.EXIT and tostring(event.from) == pid then
            local result = event.result or {}
            if not result.error then error("faulted push carrier did not crash") end
            return
        end
    end
end
-- Waits for both carriers; each must settle.
local function await_all(pids: {[string]: string}): {[string]: Object}
    local events = assert(process.events())
    local deadline = time.after("150s")
    local outcomes: {[string]: Object} = {}
    local remaining = 0
    for _ in pairs(pids) do remaining = remaining + 1 end
    while remaining > 0 do
        local selected = channel.select({events:case_receive(), deadline:case_receive()})
        if not selected.ok or selected.channel == deadline then error("the carriers did not finish") end
        local event = selected.value
        if event.kind == process.event.EXIT then
            for label, pid in pairs(pids) do
                if tostring(event.from) == pid and not outcomes[label] then
                    local result = event.result or {}
                    if result.error then error(label .. " carrier failed: " .. tostring(result.error)) end
                    outcomes[label] = (result.value or {}) :: Object
                    remaining = remaining - 1
                end
            end
        end
    end
    return outcomes
end
local function records_of(thread_id: string, actor_id: string?): {Object}
    local all: {Object} = {}
    local cursor = 0
    for _ = 1, 32 do
        local page = call_as(actor_id or ACTOR, "bee.threads.service:read_after", {thread_id = thread_id, cursor = cursor, limit = 64})
        for _, item in ipairs(page.records :: {Object}) do all[#all + 1] = item end
        if page.has_more ~= true then break end
        cursor = math.floor(page.scanned_through :: number)
    end
    return all
end
local function report(thread_id: string, actor_id: string?): Object
    for _, item in ipairs(records_of(thread_id, actor_id)) do
        if item.kind == "observation" and item.source == "stream" then
            local data = (item.body :: Object).data :: Object
            if data.type == "notice" and data.code == "stderr" then
                local text = tostring((data.content :: Object).text)
                local start = text:find("gateway:", 1, true)
                if start then
                    local decoded, err = json.decode(text:sub(start + 8))
                    if err or type(decoded) ~= "table" then error("gateway report unreadable: " .. text) end
                    return decoded :: Object
                end
            end
        end
    end
    error("no gateway report on thread " .. thread_id)
end
local function prepared_binding(thread_id: string): string?
    for _, item in ipairs(records_of(thread_id)) do
        if item.kind == "attempt.prepared" then return tostring((item.body :: Object).binding_ref) end
    end
    return nil
end
local function wait_for_action(thread_id: string, action_id: string, actor_id: string)
    for _ = 1, 150 do
        for _, item in ipairs(records_of(thread_id, actor_id)) do
            if item.kind == "action.admitted" and item.action_id == action_id then return end
        end
        time.sleep("100ms")
    end
    error("action " .. action_id .. " was not admitted on " .. thread_id .. " for " .. actor_id)
end
local function define_tests()
    test.describe("Cross-session coordination", function()
        test.it("wakes a waiting session with a peer's message and tells it when the peer's turn ends", function()
            admit_root()
            bind_policies()
            open_gateway()
            local workspace = fresh("cross-session-ws")
            local waiting_thread = call("bee.threads.service:create", {thread_id = fresh("waiting-thread"), idempotency_key = fresh("key"), title = "Waiting session"}).thread_id :: string
            local sending_thread = call("bee.threads.service:create", {thread_id = fresh("sending-thread"), idempotency_key = fresh("key"), title = "Sending session"}).thread_id :: string
            local streams = setting("bee.harness.catalog:fixture_streams", "BEE_FIXTURE_STREAMS")
            local waiter = session("bee.driver.claude:binding", WAITER_POLICY, waiting_thread, workspace,
                {BEE_FIXTURE_GATEWAY = "1", BEE_FIXTURE_PEER_ROLE = "waiter", BEE_FIXTURE_STREAM = streams .. "/claude/stream-json-2/plain.jsonl"})
            local sender = session(CODEX_BINDING, SENDER_POLICY, sending_thread, workspace,
                {BEE_FIXTURE_GATEWAY = "1", BEE_FIXTURE_PEER_ROLE = "sender", BEE_FIXTURE_STREAM = streams .. "/codex/exec-json-1/plain.jsonl"})
            sender.projections = {codex_projection(workspace, tostring(sender.attempt_id))}
            local outcomes = await_all({waiter = spawn(waiter), sender = spawn(sender)})
            test.eq((outcomes.waiter.settlement :: Object).outcome, "succeeded")
            test.eq((outcomes.sender.settlement :: Object).outcome, "succeeded")
            test.eq(prepared_binding(waiting_thread), "bee.driver.claude:binding")
            test.eq(prepared_binding(sending_thread), CODEX_BINDING)
            local waiting = report(waiting_thread)
            local sending = report(sending_thread)
            -- Each found exactly the other among its workspace's sessions.
            test.eq(waiting.self, waiter.action_id)
            test.eq(waiting.peer, sender.action_id)
            test.eq(waiting.peer_thread, sending_thread)
            test.eq(waiting.peer_title, "Sending session")
            test.eq(waiting.sessions_seen, 2)
            test.eq(sending.self, sender.action_id)
            test.eq(sending.peer, waiter.action_id)
            -- The waiter registered its notice and signalled readiness; the
            -- sender saw it and answered.
            test.eq(waiting.notify_ok, true)
            test.eq(waiting.notify_state, "pending")
            test.eq(waiting.ready_sent, true)
            test.eq(sending.ready_seen, true)
            test.eq(sending.go_ahead_sent, true)
            -- The waiter's thread_wait woke and its next read held the message.
            test.eq(waiting.go_ahead, "go ahead")
            test.eq(waiting.go_ahead_sender, sender.action_id)
            test.eq(waiting.go_ahead_wait_status, "ready")
            -- The sender's turn ended after it answered; the owner told the
            -- waiter once, on its own thread, citing the ending record.
            test.is_true(tostring(waiting.notice_text):find("ended its turn", 1, true) ~= nil, "notice text: " .. tostring(waiting.notice_text))
            test.eq(waiting.notice_cause_thread, sending_thread)
            test.eq(waiting.notice_wait_status, "ready")
            local notices, go_aheads = 0, 0
            local cause: Object? = nil
            for _, item in ipairs(records_of(waiting_thread)) do
                if item.kind == "message" then
                    local body = item.body :: Object
                    if tostring(body.message_id):sub(1, 7) == "notice:" then
                        notices = notices + 1
                        cause = item.causation :: Object
                    elseif (body.content :: Object).text == "go ahead" then
                        go_aheads = go_aheads + 1
                        test.eq(body.sender_action_id, sender.action_id)
                        test.eq((body.recipient_action_ids :: {string})[1], waiter.action_id)
                        test.eq((body.recipient_ids :: {string})[1], ACTOR)
                        test.is_nil(item.action_id)
                    end
                end
            end
            test.eq(notices, 1)
            test.eq(go_aheads, 1)
            if not cause then error("the notice names no cause") end
            local ending: Object? = nil
            for _, item in ipairs(records_of(sending_thread)) do
                if item.record_id == cause.record_id then ending = item end
            end
            if not ending then error("the notice's cause is not on the sender's thread") end
            test.eq(ending.action_id, sender.action_id)
            test.eq(((ending.body :: Object).data :: Object).type, "turn.signal")
            test.eq(((ending.body :: Object).data :: Object).phase, "ended")
        end)
        test.it("delivers and replies between independent window actors without thread membership or polling", function()
            admit_root()
            bind_policies()
            open_gateway()
            local label = fresh("inbox-ws")
            local workspace = tostring(call("bee.workspace.catalog:create", {label = label, root_ref = ROOT,
                subpath = label, create_directory = true}).workspace_id)
            local waiter_actor = "bee.test.cross_session.waiter"
            local waiter_thread = tostring(call_as(waiter_actor, "bee.threads.service:create", {thread_id = fresh("inbox-waiter-thread"),
                idempotency_key = fresh("key"), title = "Independent B"}, workspace).thread_id)
            local sender_thread = tostring(call_as(ACTOR, "bee.threads.service:create", {thread_id = fresh("inbox-sender-thread"),
                idempotency_key = fresh("key"), title = "Independent A"}, workspace).thread_id)
            local streams = setting("bee.harness.catalog:fixture_streams", "BEE_FIXTURE_STREAMS")
            local waiter = session("bee.driver.claude:binding", WAITER_POLICY, waiter_thread, workspace,
                {BEE_FIXTURE_GATEWAY = "1", BEE_FIXTURE_PEER_ROLE = "inbox_waiter", BEE_FIXTURE_STREAM = streams .. "/claude/stream-json-2/plain.jsonl"}, waiter_actor)
            local sender = session(CODEX_BINDING, SENDER_POLICY, sender_thread, workspace,
                {BEE_FIXTURE_GATEWAY = "1", BEE_FIXTURE_PEER_ROLE = "inbox_sender", BEE_FIXTURE_STREAM = streams .. "/codex/exec-json-1/plain.jsonl"})
            sender.projections = {codex_projection(workspace, tostring(sender.attempt_id))}
            local pids = {waiter = spawn(waiter), sender = spawn(sender)}
            local admitted, admission_error = pcall(function()
                wait_for_action(waiter_thread, tostring(waiter.action_id), waiter_actor)
                wait_for_action(sender_thread, tostring(sender.action_id), ACTOR)
            end)
            if not admitted then await_all(pids); error(tostring(admission_error)) end
            local denied, denied_error = funcs.new():with_actor(principals.actor(ACTOR, workspace)):with_scope(scope()):call("bee.threads.service:get", {thread_id = waiter_thread})
            if denied_error then error(tostring(denied_error)) end
            test.eq(((denied :: Object).error :: Object).code, "DENIED")
            call_as(waiter_actor, "bee.threads.service:inbox_accept", {thread_id = waiter_thread, action_id = waiter.action_id,
                sender_id = ACTOR, allow = true, expected_epoch = 0, idempotency_key = fresh("accept")}, workspace)
            call_as(ACTOR, "bee.threads.service:inbox_accept", {thread_id = sender_thread, action_id = sender.action_id,
                sender_id = waiter_actor, allow = true, expected_epoch = 0, idempotency_key = fresh("accept")}, workspace)
            local native = system.node.id()
            if not native or native == "" then error("native node identity is unavailable") end
            local selected = assert(registry.get("bee.security.gateway:gateway_session_send_workspace_policy"))
            local policy = (selected.data :: Object).policy :: Object
            test.eq((policy.actions :: {string})[1], "bee.sessions.send")
            test.eq(policy.resources, "*")
            local outcomes = await_all(pids)
            test.eq((outcomes.waiter.settlement :: Object).outcome, "succeeded")
            test.eq((outcomes.sender.settlement :: Object).outcome, "succeeded")
            local waiting = report(waiter_thread, waiter_actor)
            local sending = report(sender_thread, ACTOR)
            if not waiting.self or not sending.self then
                error("inbox fixture directory: waiter=" .. tostring(json.encode(waiting)) .. " sender=" .. tostring(json.encode(sending)))
            end
            test.eq(waiting.self, waiter.action_id)
            test.eq(waiting.peer, sender.action_id)
            test.eq(waiting.sent_ok, true)
            test.eq(waiting.replayed, true)
            test.eq(waiting.replay_record_id, (waiting.sent :: Object).record_id)
            test.eq(sending.request_text, "hello")
            test.eq(sending.ack_ok, true)
            test.eq(sending.reply_ok, true)
            test.eq(waiting.reply_text, "world")
            test.eq(waiting.ack_ok, true)
            -- Both sides woke on the server wait instead of polling their
            -- inbox: a ready status names the wake, never a timeout.
            test.eq(waiting.reply_wait_status, "ready")
            test.eq(sending.request_wait_status, "ready")
            test.eq((waiting.reply_correlation :: Object).record_id, (waiting.sent :: Object).record_id)
            test.eq((waiting.reply_correlation :: Object).thread_id, sender_thread)
            local inbox_records = 0
            for _, item in ipairs(records_of(sender_thread, ACTOR)) do
                if item.kind == "message" and (item.body :: Object).message_id == "inbox-hello" then inbox_records = inbox_records + 1 end
            end
            test.eq(inbox_records, 1)
        end)
        test.it("answers a Codex-initiated inbox exchange without polling", function()
            admit_root()
            bind_policies()
            open_gateway()
            local label = fresh("inbox-reverse-ws")
            local workspace = tostring(call("bee.workspace.catalog:create", {label = label, root_ref = ROOT,
                subpath = label, create_directory = true}).workspace_id)
            local replier_actor = "bee.test.cross_session.replier"
            local replier_thread = tostring(call_as(replier_actor, "bee.threads.service:create", {thread_id = fresh("inbox-replier-thread"),
                idempotency_key = fresh("key"), title = "Independent C"}, workspace).thread_id)
            local initiator_thread = tostring(call_as(ACTOR, "bee.threads.service:create", {thread_id = fresh("inbox-initiator-thread"),
                idempotency_key = fresh("key"), title = "Independent D"}, workspace).thread_id)
            local streams = setting("bee.harness.catalog:fixture_streams", "BEE_FIXTURE_STREAMS")
            local replier = session("bee.driver.claude:binding", WAITER_POLICY, replier_thread, workspace,
                {BEE_FIXTURE_GATEWAY = "1", BEE_FIXTURE_PEER_ROLE = "inbox_sender", BEE_FIXTURE_STREAM = streams .. "/claude/stream-json-2/plain.jsonl"}, replier_actor)
            local initiator = session(CODEX_BINDING, SENDER_POLICY, initiator_thread, workspace,
                {BEE_FIXTURE_GATEWAY = "1", BEE_FIXTURE_PEER_ROLE = "inbox_waiter", BEE_FIXTURE_STREAM = streams .. "/codex/exec-json-1/plain.jsonl"})
            initiator.projections = {codex_projection(workspace, tostring(initiator.attempt_id))}
            local pids = {replier = spawn(replier), initiator = spawn(initiator)}
            local admitted, admission_error = pcall(function()
                wait_for_action(replier_thread, tostring(replier.action_id), replier_actor)
                wait_for_action(initiator_thread, tostring(initiator.action_id), ACTOR)
            end)
            if not admitted then await_all(pids); error(tostring(admission_error)) end
            local denied, denied_error = funcs.new():with_actor(principals.actor(ACTOR, workspace)):with_scope(scope()):call("bee.threads.service:get", {thread_id = replier_thread})
            if denied_error then error(tostring(denied_error)) end
            test.eq(((denied :: Object).error :: Object).code, "DENIED")
            call_as(replier_actor, "bee.threads.service:inbox_accept", {thread_id = replier_thread, action_id = replier.action_id,
                sender_id = ACTOR, allow = true, expected_epoch = 0, idempotency_key = fresh("accept")}, workspace)
            call_as(ACTOR, "bee.threads.service:inbox_accept", {thread_id = initiator_thread, action_id = initiator.action_id,
                sender_id = replier_actor, allow = true, expected_epoch = 0, idempotency_key = fresh("accept")}, workspace)
            local outcomes = await_all(pids)
            test.eq((outcomes.replier.settlement :: Object).outcome, "succeeded")
            test.eq((outcomes.initiator.settlement :: Object).outcome, "succeeded")
            local answering = report(replier_thread, replier_actor)
            local asking = report(initiator_thread, ACTOR)
            if not answering.self or not asking.self then
                error("reverse inbox fixture directory: replier=" .. tostring(json.encode(answering)) .. " initiator=" .. tostring(json.encode(asking)))
            end
            test.eq(asking.self, initiator.action_id)
            test.eq(asking.peer, replier.action_id)
            test.eq(asking.sent_ok, true)
            test.eq(asking.replayed, true)
            test.eq(asking.replay_record_id, (asking.sent :: Object).record_id)
            test.eq(answering.request_text, "hello")
            test.eq(answering.ack_ok, true)
            test.eq(answering.reply_ok, true)
            test.eq(asking.reply_text, "world")
            test.eq(asking.ack_ok, true)
            test.eq(asking.reply_wait_status, "ready")
            test.eq(answering.request_wait_status, "ready")
            test.eq((asking.reply_correlation :: Object).record_id, (asking.sent :: Object).record_id)
            test.eq((asking.reply_correlation :: Object).thread_id, replier_thread)
            local inbox_records = 0
            for _, item in ipairs(records_of(replier_thread, replier_actor)) do
                if item.kind == "message" and (item.body :: Object).message_id == "inbox-hello" then inbox_records = inbox_records + 1 end
            end
            test.eq(inbox_records, 1)
        end)
        test.it("queues a busy Claude inbox and pushes its identified record between turns", function()
            admit_root()
            bind_policies()
            open_gateway()
            local bin = setting("bee.harness.catalog:fixture_bin", "BEE_FIXTURE_BIN")
            local entry = assert(registry.get(PUSH_POLICY))
            local entry_data = entry.data :: Object
            entry_data.executables = {claude = bin .. "/claude"}
            apply(entry)
            local label = fresh("push-ws")
            local workspace = tostring(call("bee.workspace.catalog:create", {label = label, root_ref = ROOT,
                subpath = label, create_directory = true}).workspace_id)
            local target_actor = "bee.test.cross_session.push_target"
            local target_thread = tostring(call_as(target_actor, "bee.threads.service:create", {thread_id = fresh("push-target-thread"),
                idempotency_key = fresh("key"), title = "Push target"}, workspace).thread_id)
            local source_thread = tostring(call_as(ACTOR, "bee.threads.service:create", {thread_id = fresh("push-source-thread"),
                idempotency_key = fresh("key"), title = "Push source"}, workspace).thread_id)
            local streams = setting("bee.harness.catalog:fixture_streams", "BEE_FIXTURE_STREAMS")
            local target = session("bee.driver.claude:binding", PUSH_POLICY, target_thread, workspace,
                {BEE_FIXTURE_STREAM = streams .. "/claude/stream-json-2/plain.jsonl", BEE_FIXTURE_PUSH = "1",
                    BEE_FIXTURE_PUSH_EXIT = "1", BEE_FIXTURE_PACE = "0.2"}, target_actor)
            local source = session(CODEX_BINDING, SENDER_POLICY, source_thread, workspace,
                {BEE_FIXTURE_STREAM = streams .. "/codex/exec-json-1/plain.jsonl"})
            source.projections = {codex_projection(workspace, tostring(source.attempt_id))}
            local pids = {target = spawn(target), source = spawn(source)}
            wait_for_action(target_thread, tostring(target.action_id), target_actor)
            wait_for_action(source_thread, tostring(source.action_id), ACTOR)
            call_as(target_actor, "bee.threads.service:inbox_accept", {thread_id = target_thread, action_id = target.action_id,
                sender_id = ACTOR, allow = true, expected_epoch = 0, idempotency_key = fresh("accept")}, workspace)
            local native = assert(system.node.id())
            local content = {text = "push while busy"}
            local message_id = fresh("message")
            local sent = call_as(ACTOR, "bee.threads.service:inbox_send", {thread_id = target_thread, target_action_id = target.action_id,
                sender_thread_id = source_thread, sender_action_id = source.action_id, node_id = native, grant_epoch = 1,
                idempotency_key = fresh("send"), message_id = message_id, content = content,
                payload_digest = sends.payload_digest({message_id = message_id, content = content})}, workspace)
            test.not_nil(sent.record_id)
            local accepted: Object? = nil
            for _ = 1, 150 do
                local page = call_as(target_actor, "bee.threads.service:inbox_list", {thread_id = target_thread,
                    action_id = target.action_id, after_sequence = 0, limit = 4}, workspace)
                local item = (page.items :: {Object})[1]
                if item and item.state == "transport_accepted" then accepted = item; break end
                time.sleep("100ms")
            end
            if not accepted then error("Claude did not accept the pushed inbox transport") end
            test.eq(accepted.record_id, sent.record_id)
            test.eq(accepted.payload_digest, sent.payload_digest)
            local ack = call_as(target_actor, "bee.threads.service:inbox_ack", {thread_id = target_thread,
                action_id = target.action_id, inbox_sequence = sent.inbox_sequence, idempotency_key = fresh("ack")}, workspace)
            test.eq(ack.state, "acknowledged")
            local outcomes = await_all(pids)
            test.eq((outcomes.target.settlement :: Object).outcome, "succeeded")
            test.eq((outcomes.source.settlement :: Object).outcome, "succeeded")
            local first_end, pushed = 0, 0
            for _, item in ipairs(records_of(target_thread, target_actor)) do
                if item.kind == "observation" and item.source == "stream" then
                    local data = (item.body :: Object).data :: Object
                    if data.type == "turn.signal" and data.phase == "ended" and first_end == 0 then first_end = item.sequence :: integer end
                    local value = json.encode(item.body)
                    if value:find("push:", 1, true) and value:find(tostring(sent.record_id), 1, true) then pushed = item.sequence :: integer end
                end
            end
            test.is_true((sent.thread_sequence :: integer) < first_end, "the inbox item was not committed while Claude was busy")
            test.is_true(first_end > 0 and pushed > first_end, "push was not observed after the initial turn")
        end)
        test.it("recovers an ambiguous Claude inbox write under a new carrier epoch", function()
            admit_root()
            bind_policies()
            open_gateway()
            local bin = setting("bee.harness.catalog:fixture_bin", "BEE_FIXTURE_BIN")
            local entry = assert(registry.get(PUSH_POLICY))
            local data = entry.data :: Object
            data.executables = {claude = bin .. "/claude"}
            apply(entry)
            local label = fresh("push-recovery-ws")
            local workspace = tostring(call("bee.workspace.catalog:create", {label = label, root_ref = ROOT,
                subpath = label, create_directory = true}).workspace_id)
            local target_actor = "bee.test.cross_session.push_recovery"
            local thread_id = tostring(call_as(target_actor, "bee.threads.service:create", {thread_id = fresh("push-thread"),
                idempotency_key = fresh("key"), title = "Push recovery"}, workspace).thread_id)
            local source_thread = tostring(call_as(ACTOR, "bee.threads.service:create", {thread_id = fresh("source-thread"),
                idempotency_key = fresh("key"), title = "Push source"}, workspace).thread_id)
            local source_action = fresh("source-action")
            call_as(ACTOR, "bee.threads.service:admit_action", {thread_id = source_thread, action_id = source_action,
                idempotency_key = fresh("admit"), admitted = {request_id = fresh("source-request"), principal_id = ACTOR,
                    binding_ref = CODEX_BINDING, binding_digest = "fixture-digest", grant_refs = {}, budget_ref = SENDER_POLICY,
                    input = {text = "send an inbox item"}}}, workspace)
            local streams = setting("bee.harness.catalog:fixture_streams", "BEE_FIXTURE_STREAMS")
            local target = session("bee.driver.claude:binding", PUSH_POLICY, thread_id, workspace,
                {BEE_FIXTURE_STREAM = streams .. "/claude/stream-json-2/plain.jsonl", BEE_FIXTURE_PUSH = "1",
                    BEE_FIXTURE_PACE = "0.2"}, target_actor)
            local first = spawn(target, "open", "write_dispatched")
            wait_for_action(thread_id, tostring(target.action_id), target_actor)
            call_as(target_actor, "bee.threads.service:inbox_accept", {thread_id = thread_id, action_id = target.action_id,
                sender_id = ACTOR, allow = true, expected_epoch = 0, idempotency_key = fresh("accept")}, workspace)
            local idle = false
            for _ = 1, 100 do
                for _, item in ipairs(records_of(thread_id, target_actor)) do
                    if item.kind == "observation" and item.source == "stream" then
                        local data = (item.body :: Object).data :: Object
                        if data.type == "turn.signal" and data.phase == "ended" then idle = true end
                    end
                end
                if idle then break end
                time.sleep("100ms")
            end
            test.is_true(idle, "Claude did not reach an idle turn boundary before the inbox send")
            local message_id = fresh("message")
            local content = {text = "survive an ambiguous write"}
            local sent = call_as(ACTOR, "bee.threads.service:inbox_send", {thread_id = thread_id, target_action_id = target.action_id,
                sender_thread_id = source_thread, sender_action_id = source_action, node_id = assert(system.node.id()), grant_epoch = 1,
                idempotency_key = fresh("send"), message_id = message_id, content = content,
                payload_digest = sends.payload_digest({message_id = message_id, content = content})}, workspace)
            await_crash(first)
            local previous = call_as(target_actor, "bee.threads.carrier:checkpoint", {thread_id = thread_id,
                attempt_id = target.attempt_id}, workspace)
            local replacement = spawn(target, "resume")
            local accepted: Object? = nil
            for _ = 1, 150 do
                local page = call_as(target_actor, "bee.threads.service:inbox_list", {thread_id = thread_id,
                    action_id = target.action_id, after_sequence = 0, limit = 1}, workspace)
                local item = (page.items :: {Object})[1]
                if item and item.state == "transport_accepted" then accepted = item; break end
                time.sleep("100ms")
            end
            if not accepted then error("replacement did not recover the accepted inbox write") end
            test.eq(accepted.record_id, sent.record_id)
            local current = call_as(target_actor, "bee.threads.carrier:checkpoint", {thread_id = thread_id,
                attempt_id = target.attempt_id}, workspace)
            test.is_true((current.carrier_epoch :: integer) > (previous.carrier_epoch :: integer))
            call_as(target_actor, "bee.threads.service:inbox_ack", {thread_id = thread_id, action_id = target.action_id,
                inbox_sequence = sent.inbox_sequence, idempotency_key = fresh("ack")}, workspace)
            call_as(target_actor, "bee.placement.native:close_stdin", {attempt_id = target.attempt_id}, workspace)
            local result = await_all({target = replacement})
            test.eq((result.target.settlement :: Object).outcome, "succeeded")
        end)
        test.it("polls an inbox item committed while its controller was down", function()
            admit_root()
            bind_policies()
            open_gateway()
            local label = fresh("lost-push-hint-ws")
            local workspace = tostring(call("bee.workspace.catalog:create", {label = label, root_ref = ROOT,
                subpath = label, create_directory = true}).workspace_id)
            local target_actor = "bee.test.cross_session.lost_push_hint"
            local target_thread = tostring(call_as(target_actor, "bee.threads.service:create", {thread_id = fresh("target-thread"),
                idempotency_key = fresh("key"), title = "Lost hint target"}, workspace).thread_id)
            local source_thread = tostring(call_as(ACTOR, "bee.threads.service:create", {thread_id = fresh("source-thread"),
                idempotency_key = fresh("key"), title = "Lost hint source"}, workspace).thread_id)
            local source_action = fresh("source-action")
            call_as(ACTOR, "bee.threads.service:admit_action", {thread_id = source_thread, action_id = source_action,
                idempotency_key = fresh("admit"), admitted = {request_id = fresh("source-request"), principal_id = ACTOR,
                    binding_ref = CODEX_BINDING, binding_digest = "fixture-digest", grant_refs = {}, budget_ref = SENDER_POLICY,
                    input = {text = "send after controller crash"}}}, workspace)
            local streams = setting("bee.harness.catalog:fixture_streams", "BEE_FIXTURE_STREAMS")
            local target = session("bee.driver.claude:binding", PUSH_POLICY, target_thread, workspace,
                {BEE_FIXTURE_STREAM = streams .. "/claude/stream-json-2/plain.jsonl", BEE_FIXTURE_PUSH = "1"}, target_actor)
            local first = spawn(target, "open", "attempt_started")
            await_crash(first)
            call_as(target_actor, "bee.threads.service:inbox_accept", {thread_id = target_thread, action_id = target.action_id,
                sender_id = ACTOR, allow = true, expected_epoch = 0, idempotency_key = fresh("accept")}, workspace)
            local message_id = fresh("message")
            local content = {text = "arrived while the controller was down"}
            local sent = call_as(ACTOR, "bee.threads.service:inbox_send", {thread_id = target_thread, target_action_id = target.action_id,
                sender_thread_id = source_thread, sender_action_id = source_action, node_id = assert(system.node.id()), grant_epoch = 1,
                idempotency_key = fresh("send"), message_id = message_id, content = content,
                payload_digest = sends.payload_digest({message_id = message_id, content = content})}, workspace)
            local pending = call_as(target_actor, "bee.threads.service:inbox_list", {thread_id = target_thread,
                action_id = target.action_id, after_sequence = 0, limit = 1}, workspace)
            test.eq((pending.items :: {Object})[1].state, "committed")
            local replacement = spawn(target, "resume")
            local accepted: Object? = nil
            for _ = 1, 150 do
                local page = call_as(target_actor, "bee.threads.service:inbox_list", {thread_id = target_thread,
                    action_id = target.action_id, after_sequence = 0, limit = 1}, workspace)
                local item = (page.items :: {Object})[1]
                if item and item.state == "transport_accepted" then accepted = item; break end
                time.sleep("100ms")
            end
            if not accepted then error("replacement missed the item committed without a live hint subscriber") end
            test.eq(accepted.record_id, sent.record_id)
            call_as(target_actor, "bee.threads.service:inbox_ack", {thread_id = target_thread, action_id = target.action_id,
                inbox_sequence = sent.inbox_sequence, idempotency_key = fresh("ack")}, workspace)
            call_as(target_actor, "bee.placement.native:close_stdin", {attempt_id = target.attempt_id}, workspace)
            local result = await_all({target = replacement})
            test.eq((result.target.settlement :: Object).outcome, "succeeded")
        end)
    end)
end
return test.run_cases(define_tests)
