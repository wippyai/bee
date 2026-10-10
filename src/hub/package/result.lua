-- MIT. Typed replies and bounded diagnostics at the Hub boundary.
local bounds = require("bounds")
local M = {}
type Result = {ok: boolean, code: string?, message: string?, full_message: string?, value: unknown, replayed: boolean}
function M.failure(code: string, message: string, value: unknown?): Result
    return {ok = false, code = code, message = message, value = value, replayed = false}
end
function M.success(value: unknown, replayed: boolean): Result
    return {ok = true, value = value, replayed = replayed}
end
M.MAX_MESSAGE_BYTES = 4096
function M.message(raw: unknown): string?
    if type(raw) ~= "string" then return nil end
    if #raw <= M.MAX_MESSAGE_BYTES then return raw end
    local suffix = " [truncated]"
    local stop = M.MAX_MESSAGE_BYTES - #suffix
    while stop > 0 do
        local next_byte = string.byte(raw, stop + 1)
        if not next_byte or next_byte < 128 or next_byte >= 192 then break end
        stop = stop - 1
    end
    return raw:sub(1, stop) .. suffix
end
function M.decode(raw: unknown): Result
    local reply = bounds.object(raw)
    if not reply or type(reply.ok) ~= "boolean" or type(reply.replayed) ~= "boolean" then
        return M.failure("UNCERTAIN", "invalid Hub backend reply")
    end
    local code: string? = nil
    local message: string? = nil
    if reply.code ~= nil then
        code = bounds.line(reply.code, 160)
        if not code then code = reply.ok and "INTERNAL" or "FAILED" end
    end
    if reply.message ~= nil then
        message = M.message(reply.message)
        if not message then message = "invalid Hub result message" end
    end
    return {ok = reply.ok, replayed = reply.replayed, code = code, message = message, full_message = type(reply.full_message) == "string" and reply.full_message
        or (type(reply.message) == "string" and reply.message or nil), value = reply.value}
end
return M
