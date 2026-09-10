-- MIT. Where a normalized event came from, as one versioned string that
-- rides in the observation's raw_ref, and the event key derived from it.
-- The driver supplies content; this supplies identity.
local bounds = require("bounds")
local M = {}
M.REVISION = "bee.carrier.provenance@1"
type Provenance = {stream_id: string, source_first_sequence: integer, source_last_sequence: integer, envelope_index: integer, event_index: integer}
local function count(value: unknown): integer?
    local number = bounds.integer(value)
    if not number or number < 0 then return nil end
    return number
end
function M.check(value: Provenance): string?
    if not bounds.id(value.stream_id) or value.stream_id:find("[:%s]") then return "stream_id is not a plain identifier" end
    if not count(value.source_first_sequence) or not count(value.source_last_sequence) then return "chunk sequences must be nonnegative integers" end
    if value.source_first_sequence > value.source_last_sequence then return "chunk range is reversed" end
    if not count(value.envelope_index) or not count(value.event_index) then return "envelope and event indexes must be nonnegative integers" end
    return nil
end
function M.encode(value: Provenance): (string?, string?)
    local problem = M.check(value)
    if problem then return nil, problem end
    return table.concat({M.REVISION, value.stream_id, tostring(value.source_first_sequence) .. "-" .. tostring(value.source_last_sequence),
        tostring(value.envelope_index), tostring(value.event_index)}, ":"), nil
end
function M.decode(text: unknown): (Provenance?, string?)
    if type(text) ~= "string" then return nil, "provenance must be a string" end
    local revision, stream, first, last, envelope, event = (text :: string):match("^([^:]+):([^:]+):(%d+)%-(%d+):(%d+):(%d+)$")
    if revision ~= M.REVISION then return nil, "provenance revision is not " .. M.REVISION end
    if type(stream) ~= "string" then return nil, "provenance is malformed" end
    local value: Provenance = {stream_id = stream :: string, source_first_sequence = tonumber(first) :: integer, source_last_sequence = tonumber(last) :: integer,
        envelope_index = tonumber(envelope) :: integer, event_index = tonumber(event) :: integer}
    local problem = M.check(value)
    if problem then return nil, problem end
    return value, nil
end
-- The event key: stable for one attempt, stream, envelope and event; the
-- chunk range is provenance only and never enters the key, so the same
-- event arriving through a different chunking replays instead of duplicating.
function M.event_key(attempt_id: string, value: Provenance): string
    return table.concat({"carrier", attempt_id, value.stream_id, tostring(value.envelope_index), tostring(value.event_index)}, ":")
end
return M
