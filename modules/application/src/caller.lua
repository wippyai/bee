-- MIT. An application's caller toward an owner service: a typed reply or,
-- when the transport gives no usable answer, nothing at all, which the
-- caller's model treats as an unknown outcome to recover by reading. The
-- caller runs under the process's own actor; it selects no identity and
-- holds no authority of its own.
local M = {}
type Fault = {code: string, message: string, retryable: boolean?}
type Reply = {ok: true, error: nil, value: unknown, replayed: boolean?}
    | {ok: false, error: Fault, value: nil, replayed: boolean?}
type Envelope = {ok: true, error: nil, value: unknown, replayed: boolean?}
    | {ok: false, error: Fault, value: unknown?, replayed: boolean?}
type Call = (string, unknown) -> (unknown, string?)
type Client = {invoke: (Client, string, unknown) -> Reply?}
local reply = require("reply")

-- The common owner envelope permits a failure value only for callers that
-- decode an operation-specific error projection themselves.
function M.envelope(raw: unknown): Envelope?
    local decoded = reply.decode(raw)
    if not decoded then return nil end
    if decoded.ok and decoded.value == nil then return nil end
    return decoded
end

function M.decode(raw: unknown): Reply?
    local envelope = M.envelope(raw)
    if not envelope then return nil end
    if envelope.ok then
        local decoded: Reply = {ok = true, error = nil, value = envelope.value, replayed = envelope.replayed}
        return decoded
    end
    if envelope.value ~= nil then return nil end
    local fault = envelope.error
    if not fault then return nil end
    local decoded: Reply = {ok = false, error = fault, value = nil, replayed = envelope.replayed}
    return decoded
end

function M.new(call: Call): Client
    local function invoke(_: Client, target: string, request: unknown): Reply?
        local raw, err = call(target, request)
        if err then return nil end
        return M.decode(raw)
    end
    return {invoke = invoke}
end
-- An answer the transport never delivered: unknown, never a refusal of
-- the owner's own.
function M.unknown(): Reply
    local unknown: Reply = {ok = false, error = {code = "UNAVAILABLE", message = "no answer from the owner"}, value = nil, replayed = false}
    return unknown
end
return M
