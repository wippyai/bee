-- MIT. Cross-node inbox forwarding at the destination admission, against
-- the real thread owner: a sender-side send to a remote node persists to
-- the durable outbox and never touches a same-named local thread; a
-- forwarded directory lookup returns the node-qualified address, workspace
-- and epoch; a forwarded send re-authorizes workspace, send grant, target
-- action and epoch for the mapped principal and commits under the
-- authenticated caller node; a resent send replays instead of
-- duplicating, on both the outbox row and the destination item; and a
-- forwarded commit settles destination notices and watches.
local test = require("test")
local funcs = require("funcs")
local registry = require("registry")
local time = require("time")
local uuid = require("uuid")
local system = require("system")
local types = require("types")
local principals = require("principals")
local thread_admission = require("thread_admission")
local harness = require("harness")
local sends = require("sends")
local REMOTE = "node-a"
local FORMAT = "2006-01-02T15:04:05.000Z07:00"
local WORKSPACE = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
type Object = {[string]: unknown}
local function local_node(): string
    local native, err = system.node.id()
    if err or not native or native == "" then error("native node identity is unavailable") end
    return native
end
local function key(): string
    local id, err = uuid.v4()
    if err or not id then error("uuid: " .. tostring(err)) end
    return id
end
local function subject(number: string): string
    return "{" .. REMOTE .. "@bee:workers|0x" .. number .. "}"
end
local ALPHA, BETA = subject("a1"), subject("a2")
local MEMBER_POLICIES = {"bee.security.threads:thread_observe_policy", "bee.security.threads:thread_lifecycle_policy",
    "bee.security.hive:hive_thread_invoke_policy", "bee.threads:inbox_send_test_policy",
    "bee.security.gateway:gateway_session_discover_policy"}
local function install(mappings: {Object})
    local entry = registry.get(principals.ENTRY)
    if not entry then error("mappings entry") end
    (entry.data :: Object).mappings = mappings
    local changes = registry.snapshot():changes()
    changes:update(entry)
    local applied, err = changes:apply()
    if not applied then error("install mappings: " .. tostring(err)) end
end
local ALPHA_ACTOR = principals.actor_of(REMOTE, ALPHA)
local BETA_ACTOR = principals.actor_of(REMOTE, BETA)
local function both()
    install({{issuer = REMOTE, subject_id = ALPHA, policies = MEMBER_POLICIES}, {issuer = REMOTE, subject_id = BETA, policies = MEMBER_POLICIES}})
end
local function current_mappings(): principals.Mappings
    local mappings, err = thread_admission.mappings(registry.get(principals.ENTRY))
    if not mappings then error(tostring(err)) end
    return mappings
end
local function forwarded(operation: string, input: Object, subject_id: string, extra: Object?, service: string?): types.Request
    local now = time.now()
    local digest = assert(types.digest(input))
    local value: Object = {protocol_revision = types.REVISION, request_id = "req-" .. key():sub(1, 8), idempotency_key = key(), caller_node_id = REMOTE, caller_incarnation = "1",
        owner_ref = {node_id = local_node(), service_id = service or "bee.threads", resource_ref = input.thread_id}, operation_ref = operation, operation_revision = "1", input = input, input_digest = digest,
        principal_ref = {issuer = REMOTE, subject_id = subject_id},
        principal_assertion = {method = types.ASSERTION_METHOD, audience = local_node(), issued_at = now:utc():format(FORMAT), expires_at = now:add("20s"):utc():format(FORMAT)},
        delegation_refs = {}, deadline = now:add("20s"):utc():format(FORMAT)}
    for name, item in pairs(extra or {}) do value[name] = item end
    local request, err = types.decode_request(value)
    if not request then error("forwarded request: " .. tostring(err)) end
    return request
end
local function admitted(request: types.Request): types.Reply
    local admission, fault = thread_admission.admit(local_node(), request, current_mappings(), time.now())
    if not admission then return types.reply_error(request.request_id, fault or types.fault("DENIED", "not admitted")) end
    return thread_admission.execute(request.request_id, admission)
end
local function code(reply: types.Reply): string
    if reply.ok then error("expected a failure, got success") end
    return reply.error and reply.error.code or ""
end
local function value(reply: types.Reply): Object
    if not reply.ok then error(tostring(reply.error and reply.error.code) .. ": " .. tostring(reply.error and reply.error.message)) end
    return reply.value :: Object
end
local function admitted_for(principal_id: string): {[string]: unknown}
    local value = harness.admitted()
    value.principal_id = principal_id
    return value
end
local function send_payload(dest_thread: string, sender_thread: string, sender_action: string, workspace: string, epoch: integer, idem: string, message_id: string, content: Object): Object
    return {thread_id = dest_thread, target_action_id = "action-b", sender_thread_id = sender_thread, sender_action_id = sender_action,
        node_id = local_node(), workspace_id = workspace, grant_epoch = epoch, idempotency_key = idem, message_id = message_id, content = content,
        payload_digest = assert(sends.payload_digest({message_id = message_id, content = content}))}
end
local function define_tests()
    test.describe("Cross-node inbox forwarding", function()
        local GRANTS = {"bee.security.threads:thread_create_policy", "bee.security.threads:thread_lifecycle_policy", "bee.threads:inbox_send_test_policy"}
        local owner = harness.principal("owner-node-b", GRANTS, WORKSPACE)
        local sender = harness.principal("agent-a", GRANTS, WORKSPACE)
        local function threads(): (string, string)
            local sender_thread = harness.thread(sender, "Sender session")
            local dest_thread = harness.thread(owner, "Destination session")
            harness.value(sender:call("admit_action", {thread_id = sender_thread, idempotency_key = harness.key(), action_id = "action-a", admitted = admitted_for("agent-a")}))
            harness.value(owner:call("admit_action", {thread_id = dest_thread, idempotency_key = harness.key(), action_id = "action-b", admitted = admitted_for("owner-node-b")}))
            -- A same-named local action proves remote routing never commits locally.
            harness.value(sender:call("admit_action", {thread_id = sender_thread, idempotency_key = harness.key(), action_id = "action-b", admitted = admitted_for("agent-a")}))
            harness.value(owner:call("inbox_accept", {thread_id = dest_thread, action_id = "action-b", sender_id = ALPHA_ACTOR, allow = true,
                expected_epoch = 0, idempotency_key = harness.key()}))
            return sender_thread, dest_thread
        end
        test.it("routes a remote send to the durable outbox and replays its row as status", function()
            local sender_thread, dest_thread = threads()
            local content = {text = "hello remote"}
            local request = send_payload(dest_thread, sender_thread, "action-a", WORKSPACE, 1, harness.key(), "m-1", content)
            request.node_id = REMOTE
            local queued = harness.value(sender:call("inbox_send", request))
            test.eq(queued.queued, true)
            local row = queued.outbox :: Object
            test.eq(row.state, "queued")
            test.eq(row.dest_node_id, REMOTE)
            test.eq(row.dest_action_id, "action-b")
            local first_id = tostring(row.outbox_id)
            -- Nothing committed to the same-named local thread.
            local local_items = harness.value(sender:call("inbox_list", {thread_id = sender_thread, action_id = "action-b", after_sequence = 0}))
            test.eq(#local_items.items, 0)
            -- A resent send returns the row's current state, not a new row.
            local status = harness.value(sender:call("inbox_send", request))
            test.eq(status.queued, true)
            test.eq(tostring((status.outbox :: Object).outbox_id), first_id)
            test.eq(tostring((status.outbox :: Object).state), "queued")
            -- Anything else under the key conflicts.
            local changed: {[string]: unknown} = {}
            for name, item in pairs(request) do changed[name] = item end
            changed.message_id = "m-2"
            changed.payload_digest = assert(sends.payload_digest({message_id = "m-2", content = content}))
            test.eq(harness.code(sender:call("inbox_send", changed)), "CONFLICT")
            -- A cross-node reply must name an inbox request this node received
            -- and answered from its own action; a correlation that matches
            -- nothing is denied, never queued.
            local reply: {[string]: unknown} = {}
            for name, item in pairs(request) do reply[name] = item end
            reply.in_reply_to = {thread_id = sender_thread, record_id = "record-0"}
            reply.outcome = "succeeded"
            test.eq(harness.code(sender:call("inbox_reply", reply)), "DENIED")
            -- Settle the row so later cases start from an empty outbox.
            local cleanup = harness.value(sender:call("inbox_outbox_claim", {holder = "pump-1"}))
            test.eq(#cleanup.deliveries, 1)
            harness.value(sender:call("inbox_outbox_settle", {outbox_id = first_id, delivered = true}))
            test.eq(#harness.value(sender:call("inbox_outbox_claim", {holder = "pump-1"})).deliveries, 0)
        end)
        test.it("claims, delivers through admission, and settles only on the destination reply", function()
            local sender_thread, dest_thread = threads()
            both()
            local content = {text = "pump me"}
            local request = send_payload(dest_thread, sender_thread, "action-a", WORKSPACE, 1, harness.key(), "m-9", content)
            request.node_id = REMOTE
            local queued = harness.value(sender:call("inbox_send", request))
            local row = queued.outbox :: Object
            local claimed = harness.value(sender:call("inbox_outbox_claim", {holder = "pump-1"}))
            test.eq(#claimed.deliveries, 1)
            local delivery = claimed.deliveries[1] :: Object
            test.eq(delivery.node_id, REMOTE)
            test.eq(delivery.target_action_id, "action-b")
            test.eq(delivery.message_id, "m-9")
            -- The claimed delivery carries the sender's addressing on the wire.
            for name, item in pairs(delivery) do
                if name ~= "caller_node_id" and name ~= "content" then test.eq(tostring(item), tostring(request[name])) end
            end
            local input = send_payload(dest_thread, sender_thread, "action-a", WORKSPACE, 1, tostring(delivery.idempotency_key), "m-9", content)
            -- A lost reply repeats the delivery; the destination replays instead of duplicating.
            local first = value(admitted(forwarded("bee.threads.service:inbox_send", input, ALPHA)))
            test.eq(first.state, "committed")
            local record_id = tostring(first.record_id)
            local replay = value(admitted(forwarded("bee.threads.service:inbox_send", input, ALPHA)))
            test.eq(replay.record_id, record_id)
            local items = harness.value(owner:call("inbox_list", {thread_id = dest_thread, action_id = "action-b", after_sequence = 0}))
            test.eq(#items.items, 1)
            test.eq(items.items[1].record_id, record_id)
            test.eq(items.items[1].sender_node_id, REMOTE)
            -- Settle on the destination reply; a later resend reports delivered.
            harness.value(sender:call("inbox_outbox_settle", {outbox_id = tostring(row.outbox_id), delivered = true, receipt = {record_id = record_id}}))
            local again = harness.value(sender:call("inbox_outbox_claim", {holder = "pump-1"}))
            test.eq(#again.deliveries, 0)
            local status = harness.value(sender:call("inbox_send", request))
            test.eq(tostring((status.outbox :: Object).state), "delivered")
            test.eq(tostring(((status.outbox :: Object).receipt :: Object).record_id), record_id)
            -- Only the row's sender settles it.
            test.eq(harness.code(owner:call("inbox_outbox_settle", {outbox_id = tostring(row.outbox_id), delivered = true})), "NOT_FOUND")
        end)
        test.it("looks up a node-qualified action through admission and denies strangers", function()
            local _, dest_thread = threads()
            both()
            local lookup = value(admitted(forwarded("bee.threads.service:inbox_describe",
                {thread_id = dest_thread, action_id = "action-b", node_id = local_node()}, ALPHA)))
            test.eq(lookup.node_id, local_node())
            test.eq(lookup.action_id, "action-b")
            test.eq(lookup.workspace_id, WORKSPACE)
            test.eq(lookup.grant_epoch, 1)
            test.eq(lookup.sendable, true)
            test.eq(code(admitted(forwarded("bee.threads.service:inbox_describe",
                {thread_id = dest_thread, action_id = "action-b", node_id = local_node()}, subject("a9")))), "DENIED")
            test.eq(code(admitted(forwarded("bee.threads.service:inbox_describe",
                {thread_id = dest_thread, action_id = "missing", node_id = local_node()}, ALPHA))), "NOT_FOUND")
            local stray_input = {thread_id = dest_thread, action_id = "action-b", node_id = local_node(), actor = "owner-node-b"}
            test.eq(code(admitted(forwarded("bee.threads.service:inbox_describe", stray_input, ALPHA))), "INVALID_ARGUMENT")
        end)
        test.it("re-authorizes workspace, grant, action and epoch at the destination", function()
            local sender_thread, dest_thread = threads()
            both()
            local content = {text = "checked"}
            local input = send_payload(dest_thread, sender_thread, "remote-action", WORKSPACE, 1, harness.key(), "m-7", content)
            local committed = value(admitted(forwarded("bee.threads.service:inbox_send", input, ALPHA)))
            test.eq(committed.state, "committed")
            -- An unaccepted principal is denied.
            local beta_input = send_payload(dest_thread, sender_thread, "remote-action", WORKSPACE, 1, harness.key(), "m-beta", content)
            test.eq(code(admitted(forwarded("bee.threads.service:inbox_send", beta_input, BETA))), "DENIED")
            -- A stale epoch conflicts: accept a new sender to bump the epoch, then send at the old epoch.
            harness.value(owner:call("inbox_accept", {thread_id = dest_thread, action_id = "action-b", sender_id = BETA_ACTOR, allow = true,
                expected_epoch = 1, idempotency_key = harness.key()}))
            local stale: {[string]: unknown} = {}
            for name, item in pairs(input) do stale[name] = item end
            stale.idempotency_key = harness.key()
            stale.message_id = "m-stale"
            stale.payload_digest = assert(sends.payload_digest({message_id = "m-stale", content = content}))
            test.eq(code(admitted(forwarded("bee.threads.service:inbox_send", stale, ALPHA))), "CONFLICT")
            -- A different workspace is denied.
            local foreign: {[string]: unknown} = {}
            for name, item in pairs(input) do foreign[name] = item end
            foreign.workspace_id = "cccccccccccccccccccccccccccccccc"
            foreign.idempotency_key = harness.key()
            foreign.message_id = "m-foreign"
            foreign.payload_digest = assert(sends.payload_digest({message_id = "m-foreign", content = content}))
            test.eq(code(admitted(forwarded("bee.threads.service:inbox_send", foreign, ALPHA))), "DENIED")
            -- A local actor naming a foreign caller is denied.
            local local_spoof = send_payload(dest_thread, sender_thread, "action-a", WORKSPACE, 1, harness.key(), "m-spoof", content)
            local_spoof.caller_node_id = REMOTE
            test.eq(harness.code(sender:call("inbox_send", local_spoof)), "DENIED")
            -- An unknown action is not found, and a tampered digest is invalid.
            local missing = send_payload(dest_thread, sender_thread, "remote-action", WORKSPACE, 1, harness.key(), "m-missing", content)
            missing.target_action_id = "no-such-action"
            test.eq(code(admitted(forwarded("bee.threads.service:inbox_send", missing, ALPHA))), "NOT_FOUND")
            local tampered: {[string]: unknown} = {}
            for name, item in pairs(input) do tampered[name] = item end
            tampered.payload_digest = string.rep("0", 64)
            test.eq(code(admitted(forwarded("bee.threads.service:inbox_send", tampered, ALPHA))), "INVALID_ARGUMENT")
        end)
        test.it("forwards a reply, a notice and a bounded watch to the destination owner", function()
            local sender_thread, dest_thread = threads()
            local content = {text = "reply me"}
            local input = send_payload(dest_thread, sender_thread, "remote-action", WORKSPACE, 1, harness.key(), "m-r1", content)
            value(admitted(forwarded("bee.threads.service:inbox_send", input, ALPHA)))
            local page = harness.value(owner:call("inbox_list", {thread_id = dest_thread, action_id = "action-b", after_sequence = 0}))
            local record_id = tostring((page.items[1] :: Object).record_id)
            -- The destination re-checks the reply correlation and commits the
            -- reply under the authenticated caller node.
            local reply_payload: Object = {thread_id = dest_thread, target_action_id = "action-b", sender_thread_id = sender_thread,
                sender_action_id = "remote-action", node_id = local_node(), workspace_id = WORKSPACE, grant_epoch = 1, idempotency_key = harness.key(),
                message_id = "m-r2", content = {text = "answer"}, payload_digest = assert(sends.payload_digest({message_id = "m-r2", content = {text = "answer"}})),
                in_reply_to = {thread_id = dest_thread, record_id = record_id}, outcome = "succeeded"}
            local replied = value(admitted(forwarded("bee.threads.service:inbox_reply", reply_payload, ALPHA)))
            test.eq(replied.state, "committed")
            -- The destination still re-authorizes the mapped principal: a reply
            -- at a stale epoch or naming another workspace is denied, whatever
            -- correlation it carries. (Its correlation was validated on the
            -- sender node, which is where the request item lives.)
            local stale: Object = {}
            for name, item in pairs(reply_payload) do stale[name] = item end
            stale.idempotency_key = harness.key()
            stale.message_id = "m-r3"
            stale.payload_digest = assert(sends.payload_digest({message_id = "m-r3", content = {text = "answer"}}))
            stale.grant_epoch = 9
            test.eq(code(admitted(forwarded("bee.threads.service:inbox_reply", stale, ALPHA))), "CONFLICT")
            -- A forwarded notice registers the mapped principal's watch on a
            -- thread it is a member of; a principal the destination has not
            -- admitted as a member is denied, whatever the payload says.
            local member = harness.principal(ALPHA_ACTOR, GRANTS, WORKSPACE)
            local watcher = harness.thread(member, "Watcher")
            harness.value(member:call("admit_action", {thread_id = watcher, idempotency_key = harness.key(), action_id = "watch-action", admitted = admitted_for(ALPHA_ACTOR)}))
            local notify = {thread_id = watcher, idempotency_key = harness.key(), target_thread_id = dest_thread, target_action_id = "action-b", watcher_action_id = "watch-action"}
            test.eq(code(admitted(forwarded("bee.threads.service:notify", notify, ALPHA))), "DENIED")
            -- Once the owner admits the member on the destination thread, the
            -- same forwarded notice registers a pending watch.
            harness.value(owner:call("join", {thread_id = dest_thread, idempotency_key = harness.key(), member_id = ALPHA_ACTOR, role = "participant", expected_revision = 1}))
            local accepted = value(admitted(forwarded("bee.threads.service:notify", notify, ALPHA)))
            test.eq(accepted.state, "pending")
            -- A forwarded bounded watch reads one page of the destination thread.
            local watch = value(admitted(forwarded("bee.threads.delivery:watch",
                {thread_id = dest_thread, after_sequence = 0, wait_ms = 0, transport_budget_ms = 0}, ALPHA, nil, "bee.threads.delivery")))
            test.not_nil(watch.status)
        end)
        test.it("settles destination notices and watches on a forwarded commit", function()
            local sender_thread, dest_thread = threads()
            both()
            local watcher = harness.thread(owner, "Watcher session")
            harness.value(owner:call("admit_action", {thread_id = watcher, idempotency_key = harness.key(), action_id = "watcher-action", admitted = admitted_for("owner-node-b")}))
            local registered = harness.value(owner:call("notify", {thread_id = watcher, idempotency_key = harness.key(),
                target_thread_id = dest_thread, target_action_id = "action-b", watcher_action_id = "watcher-action"}))
            test.eq(registered.state, "pending")
            local content = {text = "watched"}
            local input = send_payload(dest_thread, sender_thread, "remote-action", WORKSPACE, 1, harness.key(), "m-5", content)
            value(admitted(forwarded("bee.threads.service:inbox_send", input, ALPHA)))
            local watched = harness.value(owner:call("watch", {thread_id = dest_thread, after_sequence = 0, wait_ms = 0}))
            test.eq(watched.status, "ready")
            harness.value(owner:call("receipt", {thread_id = dest_thread, action_id = "action-b", idempotency_key = harness.key(),
                receipt = {scope = "action", outcome = "succeeded", evidence_refs = {}}}))
            local page = harness.value(owner:call("read_after", {thread_id = watcher, cursor = 0, limit = 64}))
            local told = 0
            for _, item in ipairs(page.records) do
                local body = item.body :: Object
                if item.kind == "message" and tostring(body.message_id):sub(1, 7) == "notice:" then told = told + 1 end
            end
            test.eq(told, 1)
        end)
    end)
end
return test.run_cases(define_tests)
