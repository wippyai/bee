-- MIT. Captured Claude streams replayed through the public driver contract,
-- including the persisted codec state between every envelope.
local test = require("test")
local fs = require("fs")
local funcs = require("funcs")
local bounds = require("bounds")
local stream_json = require("stream_json")
local observation = require("observation")
local driver_types = require("driver_types")
type Object = {[string]: unknown}
type Run = {observations: {Object}, terminal: driver_types.Terminal}
local function step(state: unknown, index: integer, envelope: Object?, eof: boolean?): Object
    local raw, err = funcs.call("bee.drivers.universal:normalize", {
        descriptor_ref = "bee.drivers.claude.descriptor:cli", state = state,
        index = index, envelope = envelope, eof = eof,
    })
    if err then error(tostring(err)) end
    local reply = assert(bounds.object(raw))
    if reply.ok ~= true then error(tostring(reply.error)) end
    return reply
end
local function replay(name: string, chunk_size: integer, drop_result: boolean?): Run
    local volume = assert(fs.get("bee.drivers.tests:fixtures"))
    local content = assert(volume:readfile("/claude/stream-json-2/" .. name .. ".jsonl"))
    local decoder = stream_json.new()
    local state: unknown = nil
    local observations: {Object} = {}
    local terminal: driver_types.Terminal? = nil
    for offset = 1, #content, chunk_size do
        local envelopes, problems = stream_json.feed(decoder, content:sub(offset, offset + chunk_size - 1))
        test.eq(#problems, 0)
        for _, envelope in ipairs(envelopes) do
            local value = assert(bounds.object(envelope.value))
            if not (drop_result == true and value.type == "result") then
                local reply = step(state, envelope.index, value)
                state = reply.state
                for _, item in ipairs(reply.observations) do
                    local decoded, err = observation.decode(item)
                    if not decoded then error(tostring(err)) end
                    observations[#observations + 1] = item
                end
                if reply.terminal then terminal = assert(driver_types.decode_terminal(reply.terminal)) end
            end
        end
    end
    test.is_nil(stream_json.finish(decoder))
    local final = step(state, decoder.index + 1, nil, true)
    if final.terminal then terminal = assert(driver_types.decode_terminal(final.terminal)) end
    return {observations = observations, terminal = assert(terminal)}
end
local function define_tests()
    test.describe("Claude captured stream regressions", function()
        test.it("completes the streamed answer under the same segment id", function()
            for _, size in ipairs({7, 64, 4096}) do
                local run = replay("plain", size)
                local segments: {[string]: string} = {}
                local completed = 0
                local streamed_id: string? = nil
                for _, item in ipairs(run.observations) do
                    local data = item.data
                    if item.type == "text" and data.channel == "answer" then
                        if data.operation == "append" then
                            streamed_id = data.segment_id
                            segments[data.segment_id] = (segments[data.segment_id] or "") .. data.text
                        else
                            segments[data.segment_id] = data.text
                            if data.operation == "complete" then
                                completed = completed + 1
                                test.eq(data.segment_id, streamed_id)
                            end
                        end
                    end
                end
                local count = 0
                for _, text in pairs(segments) do count = count + 1; test.eq(text, "pong") end
                test.eq(count, 1)
                test.eq(completed, 1)
                test.eq(run.terminal.answer, "pong")
            end
        end)
        test.it("leaves a non-streamed answer on its assistant segment", function()
            local run = replay("probe", 31)
            local count = 0
            for _, item in ipairs(run.observations) do
                if item.type == "text" then
                    count = count + 1
                    test.eq(item.data.segment_id, "assistant:2:1")
                    test.eq(item.data.operation, "complete")
                    test.eq(item.data.text, "pong")
                end
            end
            test.eq(count, 1)
            test.eq(run.terminal.answer, "pong")
        end)
        test.it("tracks zero-based block indices and resets them at message_start", function()
            local reply = step(nil, 1, {type = "stream_event", event = {type = "message_start"}})
            reply = step(reply.state, 2, {type = "stream_event", event = {
                type = "content_block_delta", index = 1, delta = {type = "text_delta", text = "streamed"},
            }})
            -- User text must never consume an assistant's streamed segment.
            local user = step(reply.state, 3, {type = "user", message = {content = {{type = "text", text = "user"}}}})
            test.eq(user.observations[1].data.segment_id, "assistant:3:1")
            reply = step(user.state, 4, {type = "assistant", message = {content = {
                {type = "thinking", thinking = "summary"}, {type = "text", text = "streamed"},
                {type = "text", text = "unstreamed"},
            }}})
            test.eq(reply.observations[2].data.segment_id, "9:message:1:1")
            test.eq(reply.observations[2].data.operation, "complete")
            test.eq(reply.observations[3].data.segment_id, "9:message:1:2")
            reply = step(reply.state, 5, {type = "stream_event", event = {type = "message_start"}})
            reply = step(reply.state, 6, {type = "assistant", message = {content = {
                {type = "thinking", thinking = "summary"}, {type = "text", text = "next"},
            }}})
            test.eq(reply.observations[2].data.segment_id, "9:message:5:1")
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
