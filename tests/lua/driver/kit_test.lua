-- MIT. Pure kit: framing survives fragments and rejects oversized frames,
-- quoting is exact, builders emit observations the records decoder accepts.
local test = require("test")
local framing = require("framing")
local quote = require("quote")
local events = require("events")
local observation = require("observation")
local stream_json = require("stream_json")
local function define_tests()
    test.describe("Driver kit", function()
        test.it("reassembles fragmented lines and reports a trailing partial", function()
            local framer = framing.new()
            local first = framing.feed(framer, '{"a":1}\n{"b":')
            test.eq(#first, 1)
            test.eq(first[1], '{"a":1}')
            local second = framing.feed(framer, '2}\r\n\n{"c":3}')
            test.eq(#second, 1)
            test.eq(second[1], '{"b":2}')
            local partial = framing.finish(framer)
            test.eq(partial, '{"c":3}')
            test.is_nil(framing.finish(framer))
            test.eq(framer.frames, 2)
        end)
        test.it("refuses a frame beyond the byte bound and stays poisoned", function()
            local framer = framing.new()
            local _, err = framing.feed(framer, string.rep("x", framing.MAX_FRAME_BYTES + 1))
            test.eq(err, "frame exceeds " .. tostring(framing.MAX_FRAME_BYTES) .. " bytes")
            local _, again = framing.feed(framer, "\n")
            test.not_nil(again)
        end)
        test.it("quotes argv for display without changing plain arguments", function()
            test.eq(quote.posix("claude"), "claude")
            test.eq(quote.posix("say it's"), "'say it'\\''s'")
            test.eq(quote.posix(""), "''")
            test.eq(quote.line({"codex", "exec", "--sandbox", "read-only", "hello world"}), "codex exec --sandbox read-only 'hello world'")
        end)
        test.it("builds observations the records decoder accepts and splits long text", function()
            local samples = {
                events.session("k1", "started", "sess"),
                events.turn("k2", "ended", "succeeded", events.usage(10, 5, nil)),
                events.tool_call("k3", "call-1", "Bash", '{"command":"ls"}'),
                events.tool_result("k4", "call-1", "failed", "", events.fault("exit_1", "no such file", false)),
                events.notice("k5", "warning", "permission_denied", "Bash denied"),
                events.extension("k6", "claude.rate_limit", "stream-json-2", '{"x":1}'),
            }
            for _, sample in ipairs(samples) do
                local decoded, err = observation.decode(sample)
                if not decoded then error(tostring(sample.type) .. ": " .. tostring(err)) end
            end
            local pieces = events.text("k7", "seg", "replace", string.rep("y", events.MAX_TEXT_BYTES * 2 + 5), "answer")
            test.eq(#pieces, 3)
            test.eq(pieces[1].data.operation, "replace")
            test.eq(pieces[2].data.operation, "append")
            test.eq(pieces[2].event_key, "k7#1")
            test.eq(#pieces[3].data.text, 5)
            for _, piece in ipairs(pieces) do test.not_nil(observation.decode(piece)) end
            test.is_nil(events.usage(nil, "many", nil))
            test.eq(events.usage(nil, nil, 3).cached_tokens, 3)
        end)
        test.it("decodes stream-json envelopes and reports undecodable frames", function()
            local decoder = stream_json.new()
            local envelopes, problems = stream_json.feed(decoder, '{"type":"a"}\nnot json\n{"type":"b"}\n{"tail":')
            test.eq(#envelopes, 2)
            test.eq(envelopes[1].index, 1)
            test.eq(envelopes[2].index, 3)
            test.eq(envelopes[2].value.type, "b")
            test.eq(#problems, 1)
            test.eq(problems[1].index, 2)
            local tail = stream_json.finish(decoder)
            if not tail then error("trailing frame not reported") end
            test.eq(tail.message, "stream ended inside a frame")
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
