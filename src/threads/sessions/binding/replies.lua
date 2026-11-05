-- MIT. The reply and identity helpers every session operation shares.
local bounds = require("bounds")
local journal = require("journal")
local security = require("security")
local snapshot = require("snapshot").decode

local M = {}
type Object = {[string]: unknown}
type Reply = {ok: boolean, value?: unknown, error?: Object}

local function object(value: unknown): Object?
    return bounds.object(value)
end

local function fail(code: string, message: string, operation_key: string?): Reply
    local error: Object = {code = code, message = message, retry = "never"}
    if operation_key then error.operation_key = operation_key end
    return {ok = false, error = error}
end

local function unavailable(message: string, operation_key: string?): Reply
    local reply = fail("UNAVAILABLE", message, operation_key)
    local failure = reply.error
    if failure then failure.retry = "refresh" end
    return reply
end

local function succeed(value: unknown): Reply
    return {ok = true, value = value}
end

local function request_input(request: unknown): (Object?, Reply?)
    local input = object(request)
    if not input then return nil, fail("INVALID", "request must be an object", nil) end
    return input, nil
end

local function identity(): (string?, string?)
    local caller = security.actor()
    if not caller then return nil, nil end
    local id = bounds.id(caller:id())
    local meta = object(caller:meta())
    local workspace = meta and bounds.id(meta.workspace_id)
    if not id or not workspace then return nil, nil end
    return id, workspace
end

local function key(value: unknown): string?
    if type(value) ~= "string" or #value < 1 or #value > 128 or value:find("%c") then return nil end
    return value
end

local function ref(value: unknown): string?
    if type(value) ~= "string" or #value < 1 or #value > 256 or value:find("%c") then return nil end
    return value
end

local function describe(session: string): (Object?, string?)
    local value, err = journal.invoke("session_describe", {session = session})
    if err or not value then return nil, err or "Threads returned no session" end
    return snapshot(value)
end

M.object = object
M.fail = fail
M.unavailable = unavailable
M.succeed = succeed
M.request_input = request_input
M.identity = identity
M.key = key
M.ref = ref
M.describe = describe
return M
