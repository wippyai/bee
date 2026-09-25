-- MIT. Hive envelopes: exact shapes, bounded sizes, one revision, and the
-- digest that binds a request to its input.
local test = require("test")
local types = require("types")
local bounds = require("bounds")
local function owner(): {[string]: unknown}
    return {node_id = "forge", service_id = "bee.hive.telemetry"}
end
local function call(extra: {[string]: unknown}?): {[string]: unknown}
    local value: {[string]: unknown} = {protocol_revision = types.REVISION, request_id = "r1", idempotency_key = "k1",
        owner_ref = owner(), target = {operation_ref = "bee.hive.telemetry:stats"}, input = {}}
    if extra then for key, item in pairs(extra) do value[key] = item end end
    return value
end
local function define_tests()
    test.describe("Hive envelopes", function()
        test.it("decodes a call and rejects a target naming both or neither", function()
            local decoded = types.decode_call(call())
            if not decoded then error("decode failed") end
            test.eq(decoded.target.operation_ref, "bee.hive.telemetry:stats")
            test.is_nil(decoded.target.interface_ref)
            local _, both = types.decode_call(call({target = {operation_ref = "a:b", interface_ref = "a:c"}}))
            test.eq(both, "target names exactly one of operation_ref or interface_ref")
            local _, neither = types.decode_call(call({target = {}}))
            test.eq(neither, "target names exactly one of operation_ref or interface_ref")
            local _, revision = types.decode_call(call({protocol_revision = "bee.hive@2"}))
            test.eq(revision, "protocol_revision is not bee.hive@1")
            local _, unknown = types.decode_call(call({principal_ref = {issuer = "x", subject_id = "y"}}))
            test.eq(unknown, "unknown field principal_ref")
            local _, stamp = types.decode_call(call({deadline = "soon"}))
            test.eq(stamp, "deadline is not a canonical UTC timestamp")
        end)
        test.it("binds a forwarded request to its input digest", function()
            local input = {b = 2, a = {"x", "y"}}
            local digest = types.digest(input)
            if not digest then error("digest failed") end
            local request: {[string]: unknown} = {protocol_revision = types.REVISION, request_id = "r1", idempotency_key = "k1",
                caller_node_id = "laptop", caller_incarnation = "inc-1", owner_ref = owner(), operation_ref = "bee.hive.telemetry:stats",
                operation_revision = "1", input = input, input_digest = digest,
                principal_ref = {issuer = "node:laptop", subject_id = "laptop"},
                principal_assertion = {method = "node_supervisor", audience = "forge", issued_at = "2026-09-08T10:00:00.000Z", expires_at = "2026-09-08T10:05:00.000Z"},
                delegation_refs = {}, deadline = "2026-09-08T10:05:00.000Z"}
            local decoded, decode_error = types.decode_request(request)
            if not decoded then error(tostring(decode_error)) end
            test.eq(decoded.input_digest, digest)
            test.eq(decoded.principal_ref.subject_id, "laptop")
            request.input = {b = 3, a = {"x", "y"}}
            local _, mismatch = types.decode_request(request)
            test.eq(mismatch, "input_digest does not match the input")
            request.input = input
            request.principal_assertion = {method = "node_supervisor", audience = "forge", issued_at = "2026-09-08T10:05:00.000Z", expires_at = "2026-09-08T10:00:00.000Z"}
            local _, expired = types.decode_request(request)
            test.eq(expired, "assertion expires before it is issued")
            request.principal_assertion = {method = "token", audience = "forge", issued_at = "2026-09-08T10:00:00.000Z", expires_at = "2026-09-08T10:05:00.000Z"}
            local _, method = types.decode_request(request)
            test.eq(method, "assertion method must be node_supervisor")
            request.principal_assertion = {method = "node_supervisor", audience = "laptop", issued_at = "2026-09-08T10:00:00.000Z", expires_at = "2026-09-08T10:05:00.000Z"}
            local _, audience = types.decode_request(request)
            test.eq(audience, "assertion audience must be the owner node")
            request.principal_assertion = {method = "node_supervisor", audience = "forge", issued_at = "2026-09-08T10:00:00.000Z", expires_at = "2026-09-08T10:05:00.000Z"}
            request.deadline = nil
            local _, no_deadline = types.decode_request(request)
            test.eq(no_deadline, "a forwarded request needs a canonical UTC deadline")
            request.deadline = "2026-09-08T10:04:00.000Z"
            local _, outlives = types.decode_request(request)
            test.eq(outlives, "assertion validity cannot outlive the deadline")
            request.deadline = "2026-09-08T10:05:00.000Z"
            request.delegation_refs = {"grant-1"}
            local _, delegated = types.decode_request(request)
            test.eq(delegated, "delegation_refs must be empty until delegation exists")
            test.eq(types.digest({a = {"x", "y"}, b = 2}), digest)
        end)
        test.it("keeps replies to exactly one of value or error", function()
            local ok = types.decode_reply(types.reply_ok("r1", {samples = 3}))
            if not ok then error("reply_ok is not a reply") end
            test.is_true(ok.ok)
            test.eq(#ok.grants, 0)
            local failed = types.decode_reply(types.reply_error("r1", types.fault("DENIED", "no")))
            if not failed or not failed.error then error("reply_error is not a reply") end
            test.eq(failed.error.code, "DENIED")
            test.is_false(failed.error.retryable)
            test.is_true(types.fault("BUSY", "later").retryable)
            local controlled = types.decode_reply(types.reply_error("r1", types.fault("DESKTOP_CONTROLLED", "already controlled")))
            if not controlled or not controlled.error then error("controller refusal did not decode") end
            test.eq(controlled.error.code, "DESKTOP_CONTROLLED")
            test.is_false(controlled.error.retryable)
            local _, both = types.decode_reply({protocol_revision = types.REVISION, request_id = "r1", ok = true, value = 1, error = types.fault("DENIED", "no")})
            test.eq(both, "a reply carries exactly one of value or error")
            local _, code = types.decode_reply({protocol_revision = types.REVISION, request_id = "r1", ok = false, error = {code = "NOPE", message = "x", retryable = false}})
            test.eq(code, "fault code is not a Hive error code")
            local _, big = types.decode_reply(types.reply_ok("r1", {text = string.rep("x", types.MAX_OUTPUT_BYTES)}))
            test.eq(big, "value exceeds " .. tostring(types.MAX_OUTPUT_BYTES) .. " bytes")
            -- An uncertain outcome carries the identity to ask about or replay; no other code may.
            local uncertain = types.decode_reply(types.reply_error("r1", types.uncertain("outcome unknown", {operation_ref = "bee.threads.service:send", idempotency_key = "k-1"})))
            if not uncertain or not uncertain.error then error("uncertain reply is not a reply") end
            test.eq(uncertain.error.code, "UNCERTAIN")
            test.is_false(uncertain.error.retryable)
            test.eq(uncertain.error.identity and uncertain.error.identity.idempotency_key, "k-1")
            test.eq(uncertain.error.identity and uncertain.error.identity.operation_ref, "bee.threads.service:send")
            local _, misplaced = types.decode_reply({protocol_revision = types.REVISION, request_id = "r1", ok = false, error = {code = "DENIED", message = "x", retryable = false, identity = {operation_ref = "a:b", idempotency_key = "k"}}})
            test.eq(misplaced, "only an UNCERTAIN fault carries an identity")
        end)
        test.it("bounds inputs, lists and identifiers", function()
            local _, big = types.decode_call(call({input = {text = string.rep("x", types.MAX_INPUT_BYTES)}}))
            test.eq(big, "input exceeds " .. tostring(types.MAX_INPUT_BYTES) .. " bytes")
            local many: {string} = {}
            for index = 1, bounds.MAX_LIST_ITEMS + 1 do many[index] = "g" .. tostring(index) end
            local _, list_error = bounds.ids(many)
            test.eq(list_error, "list exceeds " .. tostring(bounds.MAX_LIST_ITEMS) .. " items")
            test.is_nil(bounds.id(string.rep("x", bounds.MAX_ID_BYTES + 1)))
            test.is_nil(bounds.id("a\nb"))
            test.is_nil(bounds.line("two\nlines", 160))
            test.eq(bounds.line("one line", 160), "one line")
        end)
        test.it("decodes frames and hellos and parses PIDs", function()
            local frame = types.decode_frame({communication_session_id = "s1", sequence = 7, payload = {x = 1}})
            if not frame then error("frame") end
            test.eq(frame.sequence, 7)
            local _, sequence = types.decode_frame({communication_session_id = "s1", sequence = 0, payload = 1})
            test.eq(sequence, "sequence must be a positive integer")
            local hello = types.decode_hello({protocol_revision = types.REVISION, supervisor_incarnation = "inc-1", challenge = "c1"})
            if not hello then error("hello") end
            test.is_nil(hello.response)
            local node, host = types.pid_parts("{forge@bee.hive_host:supervisor_host|abc123}")
            test.eq(node, "forge")
            test.eq(host, "bee.hive_host:supervisor_host")
            local local_node, local_host = types.pid_parts("{bee:workers|abc123}")
            test.eq(local_node, "")
            test.eq(local_host, "bee:workers")
            test.is_nil(types.pid_parts("garbage"))
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
