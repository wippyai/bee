-- MIT. Accept the one observed Codex startup line before its JSONL protocol.
local stream_json = require("stream_json")
type State = {
    provider: string,
    decoder: stream_json.Decoder,
    protocol_started: boolean,
    preamble_seen: boolean,
}
local M = {}

function M.new(provider: string): State
    return {provider = provider, decoder = stream_json.new(), protocol_started = false, preamble_seen = false}
end

function M.feed(state: State, chunk: string): ({{index: integer, value: {[string]: unknown}}}, string?)
    local envelopes, problems, feed_error = stream_json.feed(state.decoder, chunk)
    if feed_error then return {}, feed_error end

    local first_envelope = envelopes[1] and envelopes[1].index or nil
    for _, problem in ipairs(problems) do
        local is_codex_preamble = state.provider == "codex" and not state.protocol_started and not state.preamble_seen
            and (first_envelope == nil or problem.index < first_envelope)
        if is_codex_preamble then
            state.preamble_seen = true
        else
            return {}, problem.message
        end
    end
    if #envelopes > 0 then state.protocol_started = true end
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
