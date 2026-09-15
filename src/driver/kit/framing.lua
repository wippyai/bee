-- MIT. Line framing for JSONL streams: chunks arrive fragmented, lines are
-- reassembled, and a line that outgrows the bound is an error, not a
-- silently truncated frame.
local M = {}
type Framer = {carry: string, frames: integer, overflow: boolean, limit: integer}
M.MAX_FRAME_BYTES = 1048576
-- A framer bounds its frames; a caller that must checkpoint the carry
-- passes the bound it can store.
function M.new(limit: integer?): Framer
    local bound = M.MAX_FRAME_BYTES
    if limit and limit > 0 and limit < bound then bound = limit end
    return {carry = "", frames = 0, overflow = false, limit = bound}
end
-- Feeds one chunk; returns the complete lines it closed. A frame that
-- exceeds the bound poisons the framer until reset.
function M.feed(framer: Framer, chunk: string): ({string}?, string?)
    if framer.overflow then return nil, "frame exceeds " .. tostring(framer.limit) .. " bytes" end
    local lines: {string} = {}
    local data = framer.carry .. chunk
    local start = 1
    while true do
        local newline = data:find("\n", start, true)
        if not newline then break end
        local line = data:sub(start, newline - 1)
        if line:sub(-1) == "\r" then line = line:sub(1, -2) end
        if #line > framer.limit then
            framer.overflow = true
            framer.carry = ""
            return nil, "frame exceeds " .. tostring(framer.limit) .. " bytes"
        end
        if #line > 0 then
            lines[#lines + 1] = line
            framer.frames = framer.frames + 1
        end
        start = newline + 1
    end
    framer.carry = data:sub(start)
    if #framer.carry > framer.limit then
        framer.overflow = true
        framer.carry = ""
        return nil, "frame exceeds " .. tostring(framer.limit) .. " bytes"
    end
    return lines, nil
end
-- Closes the stream: a trailing partial line is reported, not dropped.
function M.finish(framer: Framer): (string?, string?)
    if framer.overflow then return nil, "frame exceeds " .. tostring(framer.limit) .. " bytes" end
    if #framer.carry == 0 then return nil, nil end
    local partial = framer.carry
    framer.carry = ""
    return partial, nil
end
return M
