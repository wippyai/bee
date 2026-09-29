-- MIT. Shared protocol implementations selected by descriptor codec id.
local claude = require("claude_stream_json")
local codex = require("codex_jsonl")
local opencode = require("opencode_json_events")
local agy = require("agy_stream_json")
local grok = require("grok_streaming_json")
local muse = require("muse_record_jsonl")

local M = {}

type Observation = {[string]: unknown}
type Step = {observations: {Observation}, terminal: unknown?}
type Object = {[string]: unknown}
type Protocol = {
    PROTOCOL_REVISION: string,
    MAX_ANSWER_BYTES: integer,
    new: (boolean) -> unknown,
    decode_state: (unknown) -> (unknown?, string?),
    normalize: (unknown, integer, {[string]: unknown}, integer?) -> (Step?, string?),
    finish: (unknown, integer) -> (Step?, string?),
}
type Codec = {
    PROTOCOL_REVISION: string,
    MAX_ANSWER_BYTES: integer,
    new: (boolean) -> unknown,
    decode_state: (unknown) -> (unknown?, string?),
    normalize: (unknown, integer, {[string]: unknown}, integer?, Object?) -> (Step?, string?),
    finish: (unknown, integer) -> (Step?, string?),
}

local implementations: {[string]: Codec} = {
    ["claude-stream-json"] = claude :: Codec,
    ["codex-jsonl"] = codex :: Codec,
    ["opencode-json-events"] = opencode :: Codec,
    ["agy-stream-json"] = agy :: Codec,
    ["grok-streaming-json"] = grok :: Codec,
    ["muse-record-jsonl"] = muse :: Codec,
}

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
