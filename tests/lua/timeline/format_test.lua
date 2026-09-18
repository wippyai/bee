-- MIT. Every record family becomes one bounded line whose glyph follows
-- the recorded outcome: an exit is not success, uncertainty shows as such,
-- an approval names where it is decided, and hostile text never passes.
local test = require("test")
local format = require("format")
local record = require("record")
type Object = {[string]: unknown}
local LIFECYCLE = {["turn.end"] = true, ["turn.request"] = true, ["receipt"] = true, ["attempt.started"] = true, ["attempt.prepared"] = true, ["action.admitted"] = true}
local function entry(kind: string, body: Object, extra: Object?): Object
    local value: Object = {schema_revision = "bee.thread-record@1", record_id = "r-" .. kind, thread_id = "t-1", sequence = 7, recorded_at = "2026-09-09T00:00:00.000Z",
        kind = kind, producer_id = "bee.test.producer", source = "bee", body = body}
    if LIFECYCLE[kind] then value.action_id = "act-1"; value.attempt_id = "attempt-1" end
    if kind == "turn.end" or kind == "turn.request" then value.turn_id = "turn-1" end
    for key, item in pairs(extra or {}) do value[key] = item end
    return value
end
local function row(kind: string, body: Object, extra: Object?): format.Row
    local decoded, err = record.decode(entry(kind, body, extra))
    if not decoded then error(kind .. ": " .. tostring(err)) end
    return format.row(decoded)
end
local function define_tests()
    test.describe("Timeline format", function()
        test.it("follows the recorded outcome and never infers success from an exit", function()
            local ended = row("turn.end", {outcome = "succeeded", answer_message_ids = {}, evidence_refs = {}})
            test.eq(ended.glyph, format.GLYPHS.succeeded)
            test.eq(ended.outcome, "succeeded")
            local failed = row("receipt", {scope = "attempt", outcome = "failed", evidence_refs = {}, error = {code = "EXIT", message = "code 2", retryable = false}})
            test.eq(failed.glyph, format.GLYPHS.failed)
            test.is_true(failed.summary:find("EXIT: code 2", 1, true) ~= nil)
            local uncertain = row("receipt", {scope = "action", outcome = "uncertain", evidence_refs = {}, error = {code = "LOST", message = "reply lost after dispatch", retryable = false}})
            test.eq(uncertain.glyph, format.GLYPHS.uncertain)
            local exit = row("observation", {type = "execution.exit", event_key = "exit-1", data = {type = "execution.exit", exit_code = 0}}, {source = "stream"})
            test.eq(exit.glyph, format.GLYPHS.record)
            test.eq(exit.outcome, "")
            test.is_true(exit.summary:find("execution exit code 0", 1, true) ~= nil)
            local mark = row("delivery.mark", {delivery_id = "d-1", message_id = "m-1", recipient_id = "bee.test.bob", state = "uncertain", owner_epoch = 2, channel = "wait"})
            test.eq(mark.glyph, format.GLYPHS.uncertain)
            test.eq(mark.outcome, "uncertain")
        end)
        test.it("summarizes messages, tools, turns and approvals from their own bodies", function()
            local message = row("message", {message_id = "m-1", message_kind = "request", sender_id = "bee.test.alice", recipient_ids = {"bee.test.bob"}, content = {text = "hello \27[31mred\27[0m"}})
            test.is_true(message.summary:find("request from bee.test.alice to bee.test.bob: hello", 1, true) ~= nil)
            test.is_nil(message.summary:find("\27", 1, true))
            local call = row("observation", {type = "tool.call", event_key = "k-1", data = {type = "tool.call", call_id = "c-1", tool_name = "Bash", input = {text = "ls"}}}, {source = "stream"})
            test.eq(call.glyph, format.GLYPHS.busy)
            test.is_true(call.summary:find("tool Bash ls", 1, true) ~= nil)
            local result = row("observation", {type = "tool.result", event_key = "k-2", data = {type = "tool.result", call_id = "c-1", outcome = "cancelled", output = {text = "stopped"}}}, {source = "stream"})
            test.eq(result.glyph, format.GLYPHS.cancelled)
            local signal = row("observation", {type = "turn.signal", event_key = "k-3", data = {type = "turn.signal", phase = "ended"}}, {source = "hook"})
            test.eq(signal.glyph, format.GLYPHS.uncertain)
            local request = row("approval.request", {approval_id = "a-1", request_kind = "permission", requester_id = "bee.test.claude", operation_ref = "Bash",
                prompt = {text = "touch x"}, response_schema = {}, expires_at = "2026-09-09T01:00:00.000Z", state = "pending"})
            test.eq(request.glyph, format.GLYPHS.waiting_viewer)
            test.eq(request.approval_id, "a-1")
            test.is_true(request.summary:find("decide in Approvals", 1, true) ~= nil)
            local started = row("attempt.started", {execution_kind = "process", execution_ref = "attempt-1", owner_epoch = 3}, {correlation_id = "corr-1"})
            test.eq(started.glyph, format.GLYPHS.busy)
            test.is_true(started.details[2]:find("action act-1  attempt attempt-1  correlation corr-1", 1, true) ~= nil)
            test.is_true(started.details[1]:find("producer bee.test.producer  source bee", 1, true) ~= nil)
            local long = row("message", {message_id = "m-2", message_kind = "notification", sender_id = "bee.test.alice", recipient_ids = {}, content = {text = string.rep("x", 1000)}})
            test.is_true(#long.summary <= format.LINE_LIMIT + 3)
        end)
    end)
end
return require("test").run_cases(define_tests)
