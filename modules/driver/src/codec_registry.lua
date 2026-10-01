-- MIT. Shared protocol implementations selected by descriptor codec id.
local claude = require("claude_stream_json")
local codex = require("codex_jsonl")
local opencode = require("opencode_json_events")
local agy = require("agy_stream_json")
local grok = require("grok_streaming_json")
local muse = require("muse_record_jsonl")

local bounds = require("bounds")
local normalizer = require("normalizer")
local M = {}

type Observation = {[string]: unknown}
type Step = {observations: {Observation}, terminal: unknown?}
type Object = {[string]: unknown}
type Protocol = {
    PROTOCOL_REVISION: string,
    MAX_ANSWER_BYTES: integer,
    new: (boolean) -> unknown,
    decode_state: (unknown) -> (unknown?, string?),
    normalize: (unknown, integer, {[string]: unknown}, integer?, Object?) -> (Step?, string?),
    finish: (unknown, integer) -> (Step?, string?),
}
type Codec<State> = {
    PROTOCOL_REVISION: string, MAX_ANSWER_BYTES: integer,
    new: (boolean) -> State, decode_state: (unknown) -> (State?, string?),
    normalize: (State, integer, Object, integer?, Object?) -> (Step?, string?),
    finish: (State, integer) -> (Step?, string?),
}
local function synchronize(raw: unknown, decoded: unknown)
    local target, source = bounds.object(raw), bounds.object(decoded)
    assert(target and source, "codec state must be an object")
    local keys: {string} = {}
    for key in pairs(assert(target)) do keys[#keys + 1] = key end
    for _, key in ipairs(keys) do target[key] = nil end
    for key, value in pairs(assert(source)) do target[key] = value end
end
local function adapted<State>(codec: Codec<State>): Protocol
    return {
        PROTOCOL_REVISION = codec.PROTOCOL_REVISION, MAX_ANSWER_BYTES = codec.MAX_ANSWER_BYTES,
        new = function(resumed: boolean): unknown return codec.new(resumed) end,
        decode_state = function(raw: unknown): (unknown?, string?) return codec.decode_state(raw) end,
        normalize = function(raw: unknown, index: integer, envelope: Object, budget: integer?, paths: Object?): (Step?, string?)
            local state, state_error = codec.decode_state(raw)
            if not state then return nil, state_error end
            local step, step_error = codec.normalize(state, index, envelope, budget, paths)
            synchronize(raw, state)
            return step, step_error
        end,
        finish = function(raw: unknown, index: integer): (Step?, string?)
            local state, state_error = codec.decode_state(raw)
            if not state then return nil, state_error end
            local step, step_error = codec.finish(state, index)
            synchronize(raw, state)
            return step, step_error
        end,
    }
end
local implementations: {[string]: Protocol} = {
    ["claude-stream-json"] = adapted(claude), ["codex-jsonl"] = adapted(codex),
    ["opencode-json-events"] = adapted(opencode), ["agy-stream-json"] = adapted(agy),
    ["grok-streaming-json"] = adapted(grok), ["muse-record-jsonl"] = adapted(muse),
}
function M.bind(codec_id: string, paths: Object): ((unknown) -> unknown)?
    if codec_id == "claude-stream-json" then
        return normalizer.bind(claude.new, claude.decode_state,
            function(state: claude.State, index: integer, envelope: Object, budget: integer?): (Step?, string?)
                return claude.normalize(state, index, envelope, budget, paths)
            end, function(state: claude.State, index: integer): (Step?, string?)
                return claude.finish(state, index), nil
            end)
    end
    if codec_id == "codex-jsonl" then
        return normalizer.bind(codex.new, codex.decode_state,
            function(state: codex.State, index: integer, envelope: Object, budget: integer?): (Step?, string?)
                return codex.normalize(state, index, envelope, budget, paths)
            end, function(state: codex.State, index: integer): (Step?, string?)
                return codex.finish(state, index), nil
            end)
    end
    if codec_id == "opencode-json-events" then
        return normalizer.bind(opencode.new, opencode.decode_state,
            function(state: opencode.State, index: integer, envelope: Object, budget: integer?): (Step?, string?)
                return opencode.normalize(state, index, envelope, budget, paths)
            end, function(state: opencode.State, index: integer): (Step?, string?)
                return opencode.finish(state, index), nil
            end)
    end
    if codec_id == "agy-stream-json" then
        return normalizer.bind(agy.new, agy.decode_state,
            function(state: agy.State, index: integer, envelope: Object, budget: integer?): (Step?, string?)
                return agy.normalize(state, index, envelope, budget, paths)
            end, function(state: agy.State, index: integer): (Step?, string?)
                return agy.finish(state, index), nil
            end)
    end
    if codec_id == "grok-streaming-json" then
        return normalizer.bind(grok.new, grok.decode_state,
            function(state: grok.State, index: integer, envelope: Object, budget: integer?): (Step?, string?)
                return grok.normalize(state, index, envelope, budget, paths)
            end, function(state: grok.State, index: integer): (Step?, string?)
                return grok.finish(state, index), nil
            end)
    end
    if codec_id == "muse-record-jsonl" then
        return normalizer.bind(muse.new, muse.decode_state,
            function(state: muse.State, index: integer, envelope: Object, budget: integer?): (Step?, string?)
                return muse.normalize(state, index, envelope, budget, paths)
            end, function(state: muse.State, index: integer): (Step?, string?)
                return muse.finish(state, index), nil
            end)
    end
    return nil
end

function M.resolve(codec_id: string, json_paths: Object): Protocol?
    local implementation = implementations[codec_id]
    if not implementation then return nil end
    return {
        PROTOCOL_REVISION = implementation.PROTOCOL_REVISION,
        MAX_ANSWER_BYTES = implementation.MAX_ANSWER_BYTES,
        new = function(resumed: boolean): unknown return implementation.new(resumed) end,
        decode_state = function(value: unknown): (unknown?, string?) return implementation.decode_state(value) end,
        normalize = function(state: unknown, index: integer, envelope: Object, budget: integer?): (Step?, string?)
            return implementation.normalize(state, index, envelope, budget, json_paths)
        end,
        finish = function(state: unknown, index: integer): (Step?, string?) return implementation.finish(state, index) end,
    }
end

return M
