-- MIT. Frame the driver's declared JSON-lines output protocol.
local stream_json = require("stream_json")
type State = {
    decoder: stream_json.Decoder,
}
local M = {}

function M.new(): State
    return {decoder = stream_json.new()}
end

function M.feed(state: State, chunk: string): ({{index: integer, value: {[string]: unknown}}}, string?)
    local envelopes, problems, feed_error = stream_json.feed(state.decoder, chunk)
    if feed_error then return {}, feed_error end

    for _, problem in ipairs(problems) do
        return {}, problem.message
    end
    return envelopes, nil
end

function M.next_index(state: State): integer
    return state.decoder.index + 1
end

function M.finish(state: State): string?
    local problem = stream_json.finish(state.decoder)
    return problem and problem.message or nil
end

return M
