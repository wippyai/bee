-- MIT. The stream-json transport adapter: bytes to frames to envelopes. A
-- frame that is not a JSON object is reported, never skipped silently.
local json = require("json")
local framing = require("framing")
local M = {}
type Decoder = {framer: framing.Framer, index: integer}
type Envelope = {index: integer, value: {[string]: unknown}}
type Problem = {index: integer, message: string, sample: string}
-- limit bounds one frame; a caller that checkpoints the carry passes what
-- it can store.
function M.new(limit: integer?): Decoder
    return {framer = framing.new(limit), index = 0}
end
-- Feeds a chunk; returns the envelopes it completed and the frames it
-- could not decode. Indexes count every frame, decodable or not.
function M.feed(decoder: Decoder, chunk: string): ({Envelope}, {Problem}, string?)
    local envelopes: {Envelope} = {}
    local problems: {Problem} = {}
    local lines, framing_error = framing.feed(decoder.framer, chunk)
    if not lines then return envelopes, problems, framing_error end
    for _, line in ipairs(lines) do
        decoder.index = decoder.index + 1
        local value: unknown, decode_error = json.decode(line)
        if decode_error or type(value) ~= "table" then
            problems[#problems + 1] = {index = decoder.index, message = "frame is not a JSON object", sample = line:sub(1, 120)}
        else
            local object = value :: {[string]: unknown}
            envelopes[#envelopes + 1] = {index = decoder.index, value = object}
        end
    end
    return envelopes, problems, nil
end
-- Closes the stream; a trailing partial frame is a problem, not an envelope.
function M.finish(decoder: Decoder): Problem?
    local partial, framing_error = framing.finish(decoder.framer)
    if framing_error then return {index = decoder.index + 1, message = framing_error, sample = ""} end
    if partial then return {index = decoder.index + 1, message = "stream ended inside a frame", sample = partial:sub(1, 120)} end
    return nil
end
return M
