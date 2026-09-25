-- MIT. Thread-operation admission at the destination, against the real
-- thread owner: a verified request runs as the actor the host maps its
-- principal to, under the mapping's scope, with the authenticated caller
-- node; an unknown issuer or subject is denied; two subjects of one node
-- keep separate identities and commits; the identity is stable across the
-- caller's incarnations; a removed mapping or a removed membership refuses
-- the next request; the payload selects neither actor nor caller node;
-- and the supervisor's worker entry answers with the hive reply.
local test = require("test")
local funcs = require("funcs")
local registry = require("registry")
local time = require("time")
local uuid = require("uuid")
local types = require("types")
local principals = require("principals")
local thread_admission = require("thread_admission")
local harness = require("harness")
local sends = require("sends")
local LOCAL, REMOTE = "node-b", "node-a"
local FORMAT = "2006-01-02T15:04:05.000Z07:00"
type Object = {[string]: unknown}
local function key(): string
    local id, err = uuid.v4()
    if err or not id then error("uuid: " .. tostring(err)) end
    return id
end
local function subject(number: string): string
    return "{" .. REMOTE .. "@bee:workers|0x" .. number .. "}"
end
local ALPHA, BETA = subject("a1"), subject("a2")
local MEMBER_POLICIES = {"bee.security.threads:thread_observe_policy", "bee.security.threads:thread_lifecycle_policy", "bee.security.hive:hive_thread_invoke_policy"}
local UNINVOKING = {"bee.security.threads:thread_observe_policy", "bee.security.threads:thread_lifecycle_policy"}
local function install(mappings: {Object})
    local entry = registry.get(principals.ENTRY)
    if not entry then error("mappings entry") end
    (entry.data :: Object).mappings = mappings
    local changes = registry.snapshot():changes()
    changes:update(entry)
    local applied, err = changes:apply()
    if not applied then error("install mappings: " .. tostring(err)) end
end
local ALPHA_ACTOR, BETA_ACTOR = principals.actor_of(REMOTE, ALPHA), principals.actor_of(REMOTE, BETA)
local function both()
    install({{issuer = REMOTE, subject_id = ALPHA, policies = MEMBER_POLICIES}, {issuer = REMOTE, subject_id = BETA, policies = MEMBER_POLICIES}})
end
local function current_mappings(): principals.Mappings
    local mappings, err = thread_admission.mappings(registry.get(principals.ENTRY))
    if not mappings then error(tostring(err)) end
    return mappings
end
-- A request exactly as ingress admits it: authenticated caller node and
-- incarnation, a principal in that node's namespace, a bounded assertion.
local function forwarded(operation: string, input: Object, subject_id: string, extra: Object?): types.Request
    local now = time.now()
    local digest = assert(types.digest(input))
    local value: Object = {protocol_revision = types.REVISION, request_id = "req-" .. key():sub(1, 8), idempotency_key = key(), caller_node_id = REMOTE, caller_incarnation = "1",
        owner_ref = {node_id = LOCAL, service_id = "bee.threads", resource_ref = input.thread_id}, operation_ref = operation, operation_revision = "1", input = input, input_digest = digest,
        principal_ref = {issuer = REMOTE, subject_id = subject_id},
        principal_assertion = {method = types.ASSERTION_METHOD, audience = LOCAL, issued_at = now:utc():format(FORMAT), expires_at = now:add("20s"):utc():format(FORMAT)},
        delegation_refs = {}, deadline = now:add("20s"):utc():format(FORMAT)}
    for name, item in pairs(extra or {}) do value[name] = item end
    local request, err = types.decode_request(value)
    if not request then error("forwarded request: " .. tostring(err)) end
    return request
end
local function admitted(request: types.Request): types.Reply
    local admission, fault = thread_admission.admit(LOCAL, request, current_mappings(), time.now())
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
local function send_input(thread_id: string, idempotency: string, text: string): Object
    local message = harness.message("m-" .. key():sub(1, 8), text)
    return {thread_id = thread_id, idempotency_key = idempotency, payload_digest = assert(sends.payload_digest(message)), message = message}
end
local function define_tests()
    test.describe("Thread-operation admission", function()
        local owner = harness.principal("owner-node-b", harness.ALL)
        local function thread_with_members(): string
            local thread_id = harness.thread(owner, "Forwarded")
            harness.value(owner:call("join", {thread_id = thread_id, idempotency_key = harness.key(), member_id = ALPHA_ACTOR, role = "participant", expected_revision = 1}))
            harness.value(owner:call("join", {thread_id = thread_id, idempotency_key = harness.key(), member_id = BETA_ACTOR, role = "participant", expected_revision = 2}))
            return thread_id
        end
        test.it("runs a verified send as the mapped actor with the authenticated caller node and denies unknown issuers and subjects", function()
            both()
            local thread_id = thread_with_members()
            local first = value(admitted(forwarded("bee.threads.service:send", send_input(thread_id, "k-1", "from alpha"), ALPHA)))
            test.eq(first.caller_node_id, REMOTE)
            test.eq(first.sequence, 1)
            local status = value(admitted(forwarded("bee.threads.service:send_status", {thread_id = thread_id, idempotency_key = "k-1"}, ALPHA)))
            test.eq(status.committed, true)
            test.eq(status.record_id, first.record_id)
            test.eq(code(admitted(forwarded("bee.threads.service:send", send_input(thread_id, "k-2", "unknown subject"), subject("a9")))), "DENIED")
            local foreign = forwarded("bee.threads.service:send", send_input(thread_id, "k-3", "foreign issuer"), ALPHA)
            foreign.principal_ref = {issuer = "node-z", subject_id = ALPHA}
            test.eq(code(admitted(foreign)), "DENIED")
            test.eq(code(admitted(forwarded("bee.hive.telemetry:presence", {}, ALPHA))), "UNSUPPORTED_CAPABILITY")
            local page = harness.value(owner:call("read_after", {thread_id = thread_id, cursor = 0, filter = {kinds = {"message"}}}))
            test.eq(#page.records, 1)
        end)
        test.it("keeps two subjects of one node apart and their identities stable across the caller's incarnations", function()
            both()
            local thread_id = thread_with_members()
            local alpha_input = send_input(thread_id, "k-1", "same key")
            local alpha = value(admitted(forwarded("bee.threads.service:send", alpha_input, ALPHA)))
            local beta = value(admitted(forwarded("bee.threads.service:send", send_input(thread_id, "k-1", "same key"), BETA)))
            test.neq(alpha.record_id, beta.record_id)
            test.eq(beta.sequence, 2)
            -- The same command from the same subject after the caller's
            -- supervisor restarted replays the same commit.
            local later = forwarded("bee.threads.service:send", alpha_input, ALPHA, {caller_incarnation = "2"})
            local replay = admitted(later)
            test.eq(value(replay).record_id, alpha.record_id)
            local beta_status = value(admitted(forwarded("bee.threads.service:send_status", {thread_id = thread_id, idempotency_key = "k-1"}, BETA)))
            test.eq(beta_status.record_id, beta.record_id)
            local page = harness.value(owner:call("read_after", {thread_id = thread_id, cursor = 0, filter = {kinds = {"message"}}}))
            test.eq(#page.records, 2)
        end)
        test.it("refuses after the mapping or the membership is removed and lets the payload select nothing", function()
            both()
            local thread_id = thread_with_members()
            value(admitted(forwarded("bee.threads.service:send", send_input(thread_id, "k-1", "before removal"), ALPHA)))
            install({{issuer = REMOTE, subject_id = BETA, policies = MEMBER_POLICIES}})
            test.eq(code(admitted(forwarded("bee.threads.service:send", send_input(thread_id, "k-2", "after mapping removal"), ALPHA))), "DENIED")
            both()
            harness.value(owner:call("leave", {thread_id = thread_id, idempotency_key = harness.key(), member_id = ALPHA_ACTOR, expected_revision = 3}))
            test.eq(code(admitted(forwarded("bee.threads.service:send", send_input(thread_id, "k-3", "after membership removal"), ALPHA))), "DENIED")
            test.eq(code(admitted(forwarded("bee.threads.service:send_status", {thread_id = thread_id, idempotency_key = "k-1"}, ALPHA))), "DENIED")
            local mismatched = send_input(thread_id, "k-4", "payload names another node")
            mismatched.caller_node_id = "node-c"
            test.eq(code(admitted(forwarded("bee.threads.service:send", mismatched, BETA))), "INVALID_ARGUMENT")
            local selecting = send_input(thread_id, "k-5", "payload names an actor")
            selecting.actor_id = "owner-node-b"
            test.eq(code(admitted(forwarded("bee.threads.service:send", selecting, BETA))), "INVALID_ARGUMENT")
            -- The common ceilings hold on this path too: revision, owner service, deadline, stray fields.
            test.eq(code(admitted(forwarded("bee.threads.service:send", send_input(thread_id, "k-6", "old revision"), BETA, {operation_revision = "0"}))), "CONFLICT")
            test.eq(code(admitted(forwarded("bee.threads.service:send", send_input(thread_id, "k-7", "other owner service"), BETA, {owner_ref = {node_id = LOCAL, service_id = "bee.hive"}}))), "INVALID_ARGUMENT")
            local stray = send_input(thread_id, "k-8", "stray field")
            stray.extra = true
            test.eq(code(admitted(forwarded("bee.threads.service:send", stray, BETA))), "INVALID_ARGUMENT")
            local past = forwarded("bee.threads.service:send", send_input(thread_id, "k-9", "late"), BETA)
            local expired = thread_admission.admit(LOCAL, past, current_mappings(), time.now():add("60s"))
            test.is_nil(expired)
            -- The owner reference must bind the thread the payload addresses.
            local unbound = forwarded("bee.threads.service:send", send_input(thread_id, "k-10", "no resource"), BETA, {owner_ref = {node_id = LOCAL, service_id = "bee.threads"}})
            test.eq(code(admitted(unbound)), "INVALID_ARGUMENT")
            local elsewhere = forwarded("bee.threads.service:send", send_input(thread_id, "k-11", "other resource"), BETA, {owner_ref = {node_id = LOCAL, service_id = "bee.threads", resource_ref = "thread-other"}})
            test.eq(code(admitted(elsewhere)), "INVALID_ARGUMENT")
            local page = harness.value(owner:call("read_after", {thread_id = thread_id, cursor = 0, filter = {kinds = {"message"}}}))
            test.eq(#page.records, 1)
        end)
        test.it("requires the principal's own invocation authority, bounds inputs and replies, and keeps every subject to its own status", function()
            local thread_id = thread_with_members()
            -- A mapped principal whose scope lacks hive.invoke is refused, whatever the worker holds.
            install({{issuer = REMOTE, subject_id = ALPHA, policies = UNINVOKING}, {issuer = REMOTE, subject_id = BETA, policies = MEMBER_POLICIES}})
            local refused = admitted(forwarded("bee.threads.service:send", send_input(thread_id, "k-1", "no invoke"), ALPHA))
            test.eq(code(refused), "DENIED")
            test.is_true(tostring(refused.error and refused.error.message):find("may not invoke", 1, true) ~= nil)
            both()
            -- Oversized input never reaches the owner: the envelope refuses it.
            local huge = send_input(thread_id, "k-2", string.rep("x", types.MAX_INPUT_BYTES + 1))
            local now = time.now()
            local decoded = types.decode_request({protocol_revision = types.REVISION, request_id = "req-huge", idempotency_key = key(), caller_node_id = REMOTE, caller_incarnation = "1",
                owner_ref = {node_id = LOCAL, service_id = "bee.threads", resource_ref = thread_id}, operation_ref = "bee.threads.service:send", operation_revision = "1", input = huge, input_digest = string.rep("0", 64),
                principal_ref = {issuer = REMOTE, subject_id = BETA}, principal_assertion = {method = types.ASSERTION_METHOD, audience = LOCAL, issued_at = now:utc():format(FORMAT), expires_at = now:add("20s"):utc():format(FORMAT)},
                delegation_refs = {}, deadline = now:add("20s"):utc():format(FORMAT)})
            test.is_nil(decoded)
            -- A message the envelope admits but the owner's record bound refuses commits nothing.
            local large = admitted(forwarded("bee.threads.service:send", send_input(thread_id, "k-3", string.rep("y", 20000)), BETA))
            test.is_false(large.ok)
            local page = harness.value(owner:call("read_after", {thread_id = thread_id, cursor = 0, filter = {kinds = {"message"}}}))
            test.eq(#page.records, 0)
            -- Each subject reads only its own commit under a shared key; an unmapped subject reads nothing.
            local alpha_input = send_input(thread_id, "k-4", "alpha's")
            local alpha = value(admitted(forwarded("bee.threads.service:send", alpha_input, ALPHA)))
            local beta = value(admitted(forwarded("bee.threads.service:send", send_input(thread_id, "k-4", "beta's"), BETA)))
            test.eq(value(admitted(forwarded("bee.threads.service:send_status", {thread_id = thread_id, idempotency_key = "k-4"}, BETA))).record_id, beta.record_id)
            test.eq(value(admitted(forwarded("bee.threads.service:send_status", {thread_id = thread_id, idempotency_key = "k-4"}, ALPHA))).record_id, alpha.record_id)
            test.eq(code(admitted(forwarded("bee.threads.service:send_status", {thread_id = thread_id, idempotency_key = "k-4"}, subject("a9")))), "DENIED")
            -- A duplicate of an admitted request creates no record and passes the same admission.
            local duplicate = forwarded("bee.threads.service:send", alpha_input, ALPHA)
            test.eq(value(admitted(duplicate)).record_id, alpha.record_id)
            test.eq(value(admitted(duplicate)).record_id, alpha.record_id)
            local after = harness.value(owner:call("read_after", {thread_id = thread_id, cursor = 0, filter = {kinds = {"message"}}}))
            test.eq(#after.records, 2)
        end)
        test.it("answers through the supervisor's worker entry with the hive reply", function()
            both()
            local thread_id = thread_with_members()
            local request = forwarded("bee.threads.service:send", send_input(thread_id, "k-1", "through the worker"), BETA)
            local raw, err = funcs.call("bee.hive_host.supervisor:admit_thread", request)
            if err then error("admit_thread: " .. tostring(err)) end
            local reply = raw :: types.Reply
            test.eq(reply.request_id, request.request_id)
            test.eq(value(reply).sequence, 1)
            local denied = forwarded("bee.threads.service:send", send_input(thread_id, "k-2", "unmapped"), subject("a9"))
            local raw_denied = funcs.call("bee.hive_host.supervisor:admit_thread", denied)
            test.eq(code(raw_denied :: types.Reply), "DENIED")
        end)
    end)
end
return test.run_cases(define_tests)
