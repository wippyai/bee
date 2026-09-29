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
type Protocol = {
    PROTOCOL_REVISION: string,
    MAX_ANSWER_BYTES: integer,
    new: (boolean) -> unknown,
    decode_state: (unknown) -> (unknown?, string?),
    normalize: (unknown, integer, {[string]: unknown}, integer?) -> (Step?, string?),
    finish: (unknown, integer) -> (Step?, string?),
}

local implementations: {[string]: Protocol} = {
    ["claude-stream-json"] = claude :: Protocol,
    ["codex-jsonl"] = codex :: Protocol,
    ["opencode-json-events"] = opencode :: Protocol,
    ["agy-stream-json"] = agy :: Protocol,
    ["grok-streaming-json"] = grok :: Protocol,
    ["muse-record-jsonl"] = muse :: Protocol,
}

function M.resolve(codec_id: string): Protocol?
    return implementations[codec_id]
end

return M
