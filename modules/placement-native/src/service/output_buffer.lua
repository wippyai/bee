-- MIT. Coalesce short pipe reads into protocol-sized output frames.
local protocol = require("protocol")
local M = {}
M.MAX_BYTES = protocol.MAX_CHUNK_BYTES
type Stream = "stdout" | "stderr"
type Buffers = {stdout: string, stderr: string}
type Chunk = {stream: Stream, data: string}
function M.new(): Buffers
    return {stdout = "", stderr = ""}
end
function M.append(buffers: Buffers, stream: Stream, data: string): {Chunk}
    local chunks: {Chunk} = {}
    local pending = buffers[stream]
    local offset = 1
    while offset <= #data do
        local room = M.MAX_BYTES - #pending
        local ending = math.min(#data, offset + room - 1)
        pending = pending .. data:sub(offset, ending)
        offset = ending + 1
        if #pending == M.MAX_BYTES then
            chunks[#chunks + 1] = {stream = stream, data = pending}
            pending = ""
        end
    end
    buffers[stream] = pending
    return chunks
end
function M.flush(buffers: Buffers, stream: Stream): Chunk?
    local pending = buffers[stream]
    if pending == "" then return nil end
    buffers[stream] = ""
    return {stream = stream, data = pending}
end
function M.size(buffers: Buffers): integer
    return #buffers.stdout + #buffers.stderr
end
return M
