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
local bounds = require("bounds")
local record_bounds = require("record_bounds")

local function decode_fault(raw: unknown): Fault?
    local declared = bounds.object(raw)
    if not declared or bounds.fields(declared, {"code", "message", "retryable"}) then return nil end
    local code = bounds.id(declared.code)
    local message = bounds.text(declared.message, record_bounds.MAX_FAULT_MESSAGE_BYTES)
    if not code or not message or (declared.retryable ~= nil and type(declared.retryable) ~= "boolean") then return nil end
    local retryable: boolean? = nil
    if declared.retryable ~= nil then retryable = declared.retryable end
    return {code = code, message = message, retryable = retryable}
end

-- The common owner envelope permits a failure value only for callers that
-- decode an operation-specific error projection themselves.
function M.envelope(raw: unknown): Envelope?
    local reply = bounds.object(raw)
    if not reply or bounds.fields(reply, {"ok", "error", "value", "replayed"}) then return nil end
    if type(reply.ok) ~= "boolean" then return nil end
    local replayed: boolean? = nil
    if reply.replayed ~= nil then
        if type(reply.replayed) ~= "boolean" then return nil end
        replayed = reply.replayed
    end
    if reply.ok then
        if reply.error ~= nil or reply.value == nil then return nil end
        local decoded: Envelope = {ok = true, error = nil, value = reply.value, replayed = replayed}
        return decoded
    end
    local fault = decode_fault(reply.error)
    if not fault then return nil end
    local decoded: Envelope = {ok = false, error = fault, value = reply.value, replayed = replayed}
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
