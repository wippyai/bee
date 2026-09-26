-- MIT. OpenCode run-json normalization against captured opencode 1.18.32
-- fixtures: every observation decodes, the answer accumulates from text
-- frames, tool frames become tool call/result pairs, an error frame fails
-- the turn, and only the stream end reports terminally.
local test = require("test")
local fs = require("fs")
local stream_json = require("stream_json")
local protocol = require("protocol")
local normalize = require("normalize")
local observation = require("observation")
local function fixture(path: string): string
    local volume, err = fs.get("bee.driver:fixtures")
    if not volume then error("fixtures: " .. tostring(err)) end
    local content, read_error = volume:readfile(path)
    if not content then error(path .. ": " .. tostring(read_error)) end
    return content
end
local function run(path: string, chunk_size: integer): {observations: {{[string]: unknown}}, state: protocol.State}
    local content = fixture(path)
    local decoder = stream_json.new()
    local state = protocol.new(false)
    local observations: {{[string]: unknown}} = {}
    local offset = 1
    while offset <= #content do
        local envelopes = stream_json.feed(decoder, content:sub(offset, offset + chunk_size - 1))
        for _, envelope in ipairs(envelopes) do
            local step = protocol.normalize(state, envelope.index, envelope.value)
            for _, item in ipairs(step.observations) do
                local decoded, err = observation.decode(item)
                if not decoded then error(path .. " " .. tostring(item.type) .. ": " .. tostring(err)) end
                observations[#observations + 1] = item
            end
        end
        offset = offset + chunk_size
    end
    return {observations = observations, state = state}
end
local function kinds(observations: {{[string]: unknown}}): {string}
    local names: {string} = {}
    for _, item in ipairs(observations) do names[#names + 1] = tostring(item.type) end
    return names
end
local function has(observations: {{[string]: unknown}}, kind: string): boolean
    for _, item in ipairs(observations) do
        if tostring(item.type) == kind then return true end
    end
    return false
end
local function define_tests()
    test.describe("OpenCode protocol", function()
        test.it("settles a plain text turn with the accumulated answer", function()
            local result = run("opencode/run-json-1/plain.jsonl", 7)
            test.is_true(has(result.observations, "session.state"))
            test.is_true(has(result.observations, "text"))
            test.is_nil(result.state.terminal)
            local reply = normalize.handle({state = result.state, index = 100, eof = true})
            if not reply.ok then error(tostring(reply.error)) end
            local terminal = reply.terminal :: {[string]: unknown}
            test.eq(terminal.outcome, "succeeded")
            test.eq(terminal.answer, "pineapple")
            test.eq(terminal.resume_ref, result.state.session_id)
            test.not_nil(terminal.usage)
            local usage = terminal.usage :: {[string]: unknown}
            test.is_true((usage.input_tokens :: integer) > 0)
        end)
        test.it("reports tool frames as call/result pairs across steps", function()
            local result = run("opencode/run-json-1/tool.jsonl", 11)
            local names = kinds(result.observations)
            local calls, results = 0, 0
            local succeeded = false
            for _, item in ipairs(result.observations) do
                if item.type == "tool.call" then
                    calls = calls + 1
                    test.eq((item.data :: {[string]: unknown}).tool_name, "read")
                elseif item.type == "tool.result" then
                    results = results + 1
                    local data = item.data :: {[string]: unknown}
                    if data.outcome == "succeeded" then succeeded = true end
                end
            end
            test.eq(calls, 1)
            test.eq(results, 1)
            test.is_true(succeeded)
            test.is_true(#names > 4)
            local reply = normalize.handle({state = result.state, index = 200, eof = true})
            if not reply.ok then error(tostring(reply.error)) end
            local terminal = reply.terminal :: {[string]: unknown}
            test.eq(terminal.outcome, "succeeded")
            test.is_true(tostring(terminal.answer):find("name", 1, true) ~= nil)
        end)
        test.it("fails the turn on an error frame", function()
            local content = fixture("opencode/run-json-1/error.jsonl")
            local decoder = stream_json.new()
            local state = protocol.new(false)
            local envelopes = stream_json.feed(decoder, content)
            test.eq(#envelopes, 1)
            local step = protocol.normalize(state, 0, envelopes[1].value)
            test.is_true(has(step.observations, "notice"))
            test.not_nil(state.error)
            local reply = normalize.handle({state = state, index = 1, eof = true})
            if not reply.ok then error(tostring(reply.error)) end
            local terminal = reply.terminal :: {[string]: unknown}
            test.eq(terminal.outcome, "failed")
            test.is_nil(terminal.answer)
            test.not_nil(terminal.error)
        end)
        test.it("leaves an empty stream uncertain and guards envelopes after the terminal", function()
            local state = protocol.new(false)
            local reply = normalize.handle({state = state, index = 0, eof = true})
            if not reply.ok then error(tostring(reply.error)) end
            test.eq((reply.terminal :: {[string]: unknown}).outcome, "uncertain")
            local done = protocol.new(false)
            local first = protocol.normalize(done, 0, {type = "step_start", sessionID = "ses_after"})
            test.is_true(#first.observations > 0)
            local last = protocol.finish(done, 1)
            test.not_nil(last.terminal)
            local after = protocol.normalize(done, 2, {type = "text", sessionID = "ses_after", part = {type = "text", text = "late"}})
            test.eq(#after.observations, 1)
            test.eq(after.observations[1].type, "notice")
            local quiet = protocol.finish(done, 3)
            test.eq(#quiet.observations, 0)
        end)
        test.it("keeps unknown envelope types as extension evidence", function()
            local state = protocol.new(false)
            local step = protocol.normalize(state, 0, {type = "session_updated", sessionID = "ses_ext", part = {}})
            test.eq(#step.observations, 3)
            test.eq(step.observations[3].type, "extension")
            local data = step.observations[3].data :: {[string]: unknown}
            test.eq(data.event_name, "opencode.session_updated")
            test.eq(data.event_revision, "opencode-run-json-1")
            test.is_nil(state.terminal)
        end)
        test.it("decodes persisted states and refuses malformed ones", function()
            local state = protocol.new(true)
            protocol.normalize(state, 0, {type = "step_start", sessionID = "ses_persist"})
            local reply = normalize.handle({state = state, index = 5, envelope = {type = "text", sessionID = "ses_persist", part = {type = "text", text = "hi"}}})
            if not reply.ok then error(tostring(reply.error)) end
            test.eq((reply.state :: protocol.State).session_id, "ses_persist")
            local bad = normalize.handle({state = {started = "yes"}, index = 0, eof = true})
            test.is_false(bad.ok)
            test.not_nil(bad.error)
            local fresh = normalize.handle({index = 0, eof = true})
            test.is_true(fresh.ok)
            test.eq((fresh.terminal :: {[string]: unknown}).outcome, "uncertain")
            local missing = normalize.handle({index = -1, eof = true})
            test.is_false(missing.ok)
            test.eq(missing.error, "index must be a nonnegative integer")
        end)
    end)
end
return test.run_cases(define_tests)
