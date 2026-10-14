-- MIT. Bounded executable byte streaming and hashing.
local hash = require("hash")
local M = {}
M.CHUNK_BYTES = 262144

type StreamDigest = {digest: string, size: integer, head: string}
type StreamingHasher = hash.Hasher
type Read = (integer) -> (unknown, unknown)
type Close = () -> (boolean?, unknown?)

local function close_after_failure(close: Close, message: string): (StreamDigest?, string?)
    local _, close_error = close()
    if close_error then message = message .. "; close failed: " .. tostring(close_error) end
    return nil, message
end

function M.digest(read: Read, close: Close, expected_size: integer): (StreamDigest?, string?)
    if expected_size < 0 then return close_after_failure(close, "executable has an invalid reported size") end
    local hasher: StreamingHasher, hasher_error = hash.new("sha256")
    if hasher_error then return close_after_failure(close, "hasher unavailable: " .. tostring(hasher_error)) end
    local total = 0
    local head = ""
    while true do
        local raw_chunk, read_error = read(M.CHUNK_BYTES)
        local eof = read_error ~= nil and tostring(read_error) == "EOF"
        if read_error ~= nil and not eof then
            return close_after_failure(close, "executable could not be read: " .. tostring(read_error))
        end
        if raw_chunk ~= nil and type(raw_chunk) ~= "string" then
            return close_after_failure(close, "executable read returned an invalid chunk")
        end
        local chunk = raw_chunk
        if chunk == "" and not eof then
            return close_after_failure(close, "executable read returned an empty chunk before EOF")
        end
        if chunk ~= nil and #chunk > 0 then
            total = total + #chunk
            if total > expected_size then
                return close_after_failure(close, "executable changed size while being measured")
            end
            if head == "" then head = chunk:sub(1, 256) end
            hasher:update(chunk)
        end
        if eof then break end
        if chunk == nil then return close_after_failure(close, "executable read ended without an EOF result") end
    end
    local closed, close_error = close()
    if close_error or closed == false then
        return nil, "executable could not be closed after measurement: " .. tostring(close_error or "close refused")
    end
    if total ~= expected_size then
        return nil, "executable read was incomplete: measured " .. tostring(total) .. " of " .. tostring(expected_size) .. " bytes"
    end
    local digest = hasher:sum()
    if not digest or #digest ~= 64 or not digest:match("^[0-9a-f]+$") then return nil, "executable digest is invalid" end
    return {digest = digest, size = total, head = head}, nil
end

return M
