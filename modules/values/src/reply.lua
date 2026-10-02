-- Shared decoder for Bee service reply envelopes.
local bounds = require("bounds")
local M = {}

type Fault = {code: string, message: string, retryable: boolean?}
type Success = {ok: true, value: unknown, replayed: boolean?}
type Failure = {ok: false, error: Fault, value: unknown?, replayed: boolean?}
type Reply = Success | Failure

local function replayed(object: {[string]: unknown}): (boolean?, string?)
    if object.replayed == nil then return nil, nil end
    if type(object.replayed) ~= "boolean" then return nil, "replayed flag must be a boolean" end
    return object.replayed, nil
end

function M.decode(value: unknown): (Reply?, string?)
    local object = bounds.object(value)
    if not object then return nil, "reply must be an object" end
    local unknown_field = bounds.fields(object, {"ok", "error", "value", "replayed"})
    if unknown_field then return nil, "reply: " .. unknown_field end
    local replay, replay_error = replayed(object)
    if replay_error then return nil, replay_error end
    if object.ok == true then
        if object.error ~= nil then return nil, "successful reply carries an error" end
        return {ok = true, value = object.value, replayed = replay}, nil
    end
    if object.ok ~= false then return nil, "reply status must be a boolean" end
    local fault = bounds.object(object.error)
    if not fault then return nil, "failed reply has no error object" end
    local unknown_fault_field = bounds.fields(fault, {"code", "message", "retryable"})
    if unknown_fault_field then return nil, "reply error: " .. unknown_fault_field end
    local code, message = bounds.id(fault.code), bounds.text(fault.message, 4096)
    local retryable: boolean? = nil
    if fault.retryable ~= nil then
        if type(fault.retryable) ~= "boolean" then return nil, "reply retryable flag must be a boolean" end
        retryable = fault.retryable
    end
    if not code or not message then return nil, "reply error fields are malformed" end
    return {ok = false, error = {code = code, message = message, retryable = retryable}, value = object.value, replayed = replay}, nil
end

return M
