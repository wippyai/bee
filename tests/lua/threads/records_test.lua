-- MIT. Record decoders reject what the contract excludes and encode
-- canonically so identical records compare byte for byte.
local test = require("test")
local record = require("record")
local observation = require("observation")
local message = require("message")
local lifecycle = require("lifecycle")
local delivery = require("delivery")
local bounds = require("bounds")
local types = require("types")
local function base(kind: string, body: {[string]: unknown}, extra: {[string]: unknown}?): {[string]: unknown}
    local value: {[string]: unknown} = {schema_revision = "bee.thread-record@1", record_id = "r1", thread_id = "t1",
        sequence = 1, recorded_at = "2026-09-08T10:00:00.000Z", kind = kind, producer_id = "p1", source = "bee", body = body}
    if extra then for key, item in pairs(extra) do value[key] = item end end
    return value
end
local function text_message(): {[string]: unknown}
    return {message_id = "m1", message_kind = "request", sender_id = "alice", recipient_ids = {"bob"}, content = {text = "hello"}}
end
local function define_tests()
    test.describe("Thread records", function()
        test.it("preserves preparation binding digests without inventing them for historical records", function()
            local body: {[string]: unknown} = {binding_ref = "driver:binding", binding_digest = "driver",
                profile_id = "window", profile_digest = "profile", placement_binding = "placement:binding",
                placement_attempt_id = "attempt", plan_digest = "plan"}
            local historical, historical_error = record.decode(base("attempt.prepared", body, {action_id = "action", attempt_id = "attempt"}))
            if not historical then error(tostring(historical_error)) end
            local old_bytes = record.encode(historical)
            if not old_bytes then error("encode historical preparation") end
            test.is_nil(old_bytes:find("placement_binding_digest", 1, true))
            body.placement_binding_digest = string.rep("a", 64)
            local measured, measured_error = record.decode(base("attempt.prepared", body, {action_id = "action", attempt_id = "attempt"}))
            if not measured then error(tostring(measured_error)) end
            local encoded = record.encode(measured)
            if not encoded then error("encode measured preparation") end
            local decoded, decode_error = record.decode_json(encoded)
            if not decoded then error(tostring(decode_error)) end
            test.eq((decoded.body :: types.Prepared).placement_binding_digest, string.rep("a", 64))
            test.eq(record.encode(decoded), encoded)
            for _, invalid in ipairs({"", "digest", string.rep("A", 64), string.rep("a", 65)}) do
                body.placement_binding_digest = invalid
                test.is_nil(record.decode(base("attempt.prepared", body, {action_id = "action", attempt_id = "attempt"})))
            end
        end)
        test.it("encodes with sorted keys and no whitespace regardless of field order", function()
            local first = record.decode(base("message", text_message(), {correlation_id = "c1"}))
            if not first then error("decode failed") end
            local encoded = record.encode(first)
            if not encoded then error("encode failed") end
            test.eq(encoded, '{"body":{"content":{"text":"hello"},"message_id":"m1","message_kind":"request","recipient_ids":["bob"],"sender_id":"alice"},'
                .. '"correlation_id":"c1","kind":"message","producer_id":"p1","record_id":"r1","recorded_at":"2026-09-08T10:00:00.000Z",'
                .. '"schema_revision":"bee.thread-record@1","sequence":1,"source":"bee","thread_id":"t1"}')
            local again = record.decode_json(encoded)
            if not again then error("round trip failed") end
            local second = record.encode(again)
            test.eq(second, encoded)
        end)
        test.it("escapes strings so control characters and quotes survive a round trip", function()
            local body = text_message()
            body.content = {text = 'say "hi"\n\ttab \\ slash \1'}
            local decoded = record.decode(base("message", body))
            if not decoded then error("decode failed") end
            local encoded = record.encode(decoded)
            if not encoded then error("encode failed") end
            test.is_true(encoded:find('\\"hi\\"\\u000a\\u0009tab \\\\ slash \\u0001', 1, true) ~= nil)
            local again = record.decode_json(encoded)
            if not again then error("round trip failed") end
            local content = (again.body :: types.Message).content
            test.eq(content.text, 'say "hi"\n\ttab \\ slash \1')
        end)
        test.it("rejects unknown fields, foreign revisions and unsupported families", function()
            local unknown = base("message", text_message(), {extra = true})
            local _, unknown_error = record.decode(unknown)
            test.eq(unknown_error, "unknown field extra")
            local revision = base("message", text_message())
            revision.schema_revision = "bee.thread-record@2"
            local _, revision_error = record.decode(revision)
            test.eq(revision_error, "schema_revision is not bee.thread-record@1")
            local _, kind_error = record.decode(base("ballot.cast", {}))
            test.eq(kind_error, "kind is not a supported record family")
            local body = text_message()
            body.recipient_ids = {"bob", "bob"}
            local _, repeat_error = message.decode(body)
            test.eq(repeat_error, "recipient_ids: list item 2 repeats")
        end)
        test.it("requires exactly one content carrier and canonical timestamps", function()
            local both = text_message()
            both.content = {text = "a", artifact_ref = "b"}
            local _, both_error = message.decode(both)
            test.eq(both_error, "content needs exactly one of text or artifact_ref")
            local none = text_message()
            none.content = {}
            local _, none_error = message.decode(none)
            test.eq(none_error, "content needs exactly one of text or artifact_ref")
            local stamped = base("message", text_message())
            stamped.recorded_at = "2026-09-08T10:00:00Z"
            local _, stamp_error = record.decode(stamped)
            test.eq(stamp_error, "recorded_at is not a canonical UTC timestamp")
            test.is_nil(bounds.timestamp("2026-13-08T10:00:00.000Z"))
        end)
        test.it("bounds arrays, identifiers and the encoded record", function()
            local many: {string} = {}
            for index = 1, 65 do many[index] = "r" .. tostring(index) end
            local body = text_message()
            body.recipient_ids = many
            local _, many_error = message.decode(body)
            test.eq(many_error, "recipient_ids: list exceeds 64 items")
            local long = text_message()
            long.message_id = string.rep("x", 161)
            local _, long_error = message.decode(long)
            test.eq(long_error, "message_id is not an identifier")
            local control = text_message()
            control.sender_id = "a\nb"
            local _, control_error = message.decode(control)
            test.eq(control_error, "sender_id is not an identifier")
            local big = text_message()
            big.content = {text = string.rep("y", 16384)}
            local decoded = record.decode(base("message", big))
            if not decoded then error("decode failed") end
            local _, size_error = record.encode(decoded)
            test.eq(size_error, "record exceeds 16384 bytes")
        end)
        test.it("accepts each observation tag and checks extension payload depth", function()
            local cases: {{[string]: unknown}} = {
                {type = "session.state", state = "resumed", resume_ref = "s1"},
                {type = "turn.signal", phase = "ended", reported_outcome = "succeeded", usage = {input_tokens = 10, cost_decimal = "0.25", currency = "USD"}},
                {type = "text", segment_id = "seg", operation = "append", text = "partial", channel = "answer"},
                {type = "tool.call", call_id = "c1", tool_name = "read", input = {text = "{}"}},
                {type = "tool.result", call_id = "c1", outcome = "failed", output = {artifact_ref = "a1"}, error = {code = "ENOENT", message = "missing", retryable = false}},
                {type = "notice", level = "warning", code = "slow", content = {text = "slow tool"}},
                {type = "execution.exit", exit_code = 137, signal = "SIGKILL"},
                {type = "extension", event_name = "claude.hook", event_revision = "1", payload_json = '{"a":[1,{"b":null}]}'},
            }
            for _, data in ipairs(cases) do
                local decoded, decode_error = observation.decode({type = data.type, event_key = "k-" .. tostring(data.type), data = data})
                if not decoded then error(tostring(data.type) .. ": " .. tostring(decode_error)) end
                test.eq(decoded.data.type, data.type)
                local envelope = record.decode(base("observation", {type = data.type, event_key = "k", data = data}, {source = "hook"}))
                if not envelope then error("envelope failed") end
                local encoded = record.encode(envelope)
                if not encoded then error("encode failed") end
                local again = record.decode_json(encoded)
                if not again then error("round trip failed") end
                local second = record.encode(again)
                test.eq(second, encoded)
            end
            local _, mismatch = observation.decode({type = "text", event_key = "k", data = {type = "notice", level = "info", code = "c", content = {text = "t"}}})
            test.eq(mismatch, "observation type does not match its data")
            local deep = "[" .. string.rep("[", 16) .. string.rep("]", 16) .. "]"
            local _, depth_error = observation.decode({type = "extension", event_key = "k", data = {type = "extension", event_name = "x.y", event_revision = "1", payload_json = deep}})
            test.eq(depth_error, "payload_json nests deeper than 16")
            local _, json_error = observation.decode({type = "extension", event_key = "k", data = {type = "extension", event_name = "x.y", event_revision = "1", payload_json = "{"}})
            test.eq(json_error, "payload_json is not valid JSON")
            local _, unknown_tag = observation.decode({type = "permission.request", event_key = "k", data = {type = "permission.request"}})
            test.eq(unknown_tag, "observation type is not supported")
        end)
        test.it("checks lifecycle bodies and their context identifiers", function()
            local admitted = {request_id = "q", principal_id = "alice", binding_ref = "b", binding_digest = "d", grant_refs = {}, budget_ref = "budget", input = {text = "go"}}
            local _, missing_action = record.decode(base("action.admitted", admitted))
            test.eq(missing_action, "action.admitted names its action_id")
            local with_turn = record.decode(base("action.admitted", admitted, {action_id = "a", turn_id = "t"}))
            test.is_nil(with_turn)
            test.not_nil(record.decode(base("action.admitted", admitted, {action_id = "a"})))
            local _, epoch_error = lifecycle.started({execution_kind = "process", execution_ref = "pid", owner_epoch = 0})
            test.eq(epoch_error, "owner_epoch must be a positive integer")
            local _, delivery_error = lifecycle.turn_request({input_message_ids = {"m1"}, input = {text = "x"}, delivery_ids = {"d1"}})
            test.eq(delivery_error, "delivery_ids must be empty until delivery exists")
            local _, silent_failure = lifecycle.turn_end({outcome = "failed", answer_message_ids = {}, evidence_refs = {}})
            test.eq(silent_failure, "a turn that did not succeed names its error")
            local _, noisy_success = lifecycle.receipt({scope = "action", outcome = "succeeded", evidence_refs = {}, error = {code = "x", message = "y", retryable = true}})
            test.eq(noisy_success, "a succeeded receipt carries no error")
            test.not_nil(record.decode(base("turn.end", {outcome = "uncertain", answer_message_ids = {}, evidence_refs = {"e"}, error = {code = "lost", message = "connection", retryable = true}},
                {action_id = "a", attempt_id = "b", turn_id = "c"})))
            local _, reply_error = message.decode({message_id = "m", message_kind = "reply", sender_id = "s", recipient_ids = {}, content = {text = "x"}})
            test.eq(reply_error, "reply needs in_reply_to")
            local _, silent_reply = message.decode({message_id = "m", message_kind = "reply", sender_id = "s", recipient_ids = {}, content = {text = "x"}, in_reply_to = {thread_id = "t", record_id = "r"}})
            test.eq(silent_reply, "reply needs an outcome")
            local _, settled_request = message.decode({message_id = "m", message_kind = "request", sender_id = "s", recipient_ids = {}, content = {text = "x"}, outcome = "succeeded"})
            test.eq(settled_request, "request carries no outcome")
            test.not_nil(message.decode({message_id = "m", message_kind = "notification", sender_id = "s", recipient_ids = {}, content = {text = "x"}, outcome = "failed"}))
        end)
        test.it("decodes delivery marks and answered requests", function()
            local mark = base("delivery.mark", {delivery_id = "d1", message_id = "m1", recipient_id = "bob", state = "claimed", owner_epoch = 1, channel = "wait"})
            local decoded = record.decode(mark)
            if not decoded then error("mark") end
            local encoded = record.encode(decoded)
            if not encoded then error("encode mark") end
            test.is_true(encoded:find('"kind":"delivery.mark"', 1, true) ~= nil)
            local again = record.decode_json(encoded)
            if not again then error("round trip") end
            test.eq(record.encode(again), encoded)
            local _, state_error = delivery.mark({delivery_id = "d1", message_id = "m1", recipient_id = "bob", state = "pending", owner_epoch = 1, channel = "wait"})
            test.eq(state_error, "delivery state is not claimed, delivered, released or uncertain")
            local _, epoch_error = delivery.mark({delivery_id = "d1", message_id = "m1", recipient_id = "bob", state = "claimed", owner_epoch = 0, channel = "wait"})
            test.eq(epoch_error, "owner_epoch must be a positive integer")
            local answered = record.decode(base("request.answered", {request_message_id = "m1", recipient_id = "bob", reply_message_id = "m2", outcome = "succeeded"}))
            if not answered then error("answered") end
            test.eq((answered.body :: types.Answered).reply_message_id, "m2")
            local _, outcome_error = delivery.answered({request_message_id = "m1", recipient_id = "bob", reply_message_id = "m2", outcome = "done"})
            test.eq(outcome_error, "answered outcome is not an outcome")
            test.is_nil(record.decode(base("recap.checkpoint", {through_sequence = 1})))
        end)
        test.it("addresses a message to sessions by action and names the sending action", function()
            local body = text_message()
            body.recipient_action_ids = {"action-b"}
            body.sender_action_id = "action-a"
            local decoded, decode_error = record.decode(base("message", body))
            if not decoded then error(tostring(decode_error)) end
            local encoded = record.encode(decoded)
            if not encoded then error("encode addressed message") end
            test.is_true(encoded:find('"recipient_action_ids":["action-b"]', 1, true) ~= nil)
            test.is_true(encoded:find('"sender_action_id":"action-a"', 1, true) ~= nil)
            local again = record.decode_json(encoded)
            if not again then error("round trip") end
            test.eq(record.encode(again), encoded)
            local addressed = again.body :: types.Message
            test.eq((addressed.recipient_action_ids :: {string})[1], "action-b")
            test.eq(addressed.sender_action_id, "action-a")
            local plain = record.decode(base("message", text_message()))
            if not plain then error("plain message") end
            test.is_nil((record.encode(plain) or ""):find("action_id", 1, true))
            local _, empty_error = message.decode({message_id = "m1", message_kind = "request", sender_id = "alice", recipient_ids = {}, recipient_action_ids = {}, content = {text = "x"}})
            test.eq(empty_error, "recipient_action_ids names at least one action")
            local _, repeat_error = message.decode({message_id = "m1", message_kind = "request", sender_id = "alice", recipient_ids = {}, recipient_action_ids = {"a", "a"}, content = {text = "x"}})
            test.eq(repeat_error, "recipient_action_ids: list item 2 repeats")
            local _, sender_error = message.decode({message_id = "m1", message_kind = "request", sender_id = "alice", recipient_ids = {}, sender_action_id = "", content = {text = "x"}})
            test.eq(sender_error, "sender_action_id is not an identifier")
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
