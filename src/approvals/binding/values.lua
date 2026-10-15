-- MIT. Values for the approvals authority.
local hash = require("hash")
local system = require("system")
local bounds = require("bounds")
local canonical = require("canonical")
local transaction = require("transaction")
local clock = require("clock")
local part_model = require("part_model")
local M = {}
type Result = part_model.Result
type Object = part_model.Object
type RequestKind = part_model.RequestKind
type ApprovalState = part_model.ApprovalState
local function failure(code: string, message: string, value: unknown?): Result
    return transaction.failure(code, message, value)
end
local function refusal(code: string, message: string, value: unknown): Result
    return transaction.refusal(code, message, value)
end
local function storage(what: string): Result
    return failure("STORAGE", what)
end
local function success(value: unknown, replayed: boolean): Result
    return transaction.success(value, replayed)
end
local now_ms = clock.milliseconds
local stamp = clock.stamp
local function node(): (string?, string?)
    local id, err = system.node.id()
    local valid = bounds.id(id)
    if err or not valid then return nil, tostring(err or "native node identity is unavailable") end
    return valid, nil
end
local function text(value: unknown): string?
    if type(value) ~= "string" then return nil end
    return value
end
local function integer(value: unknown): integer?
    return bounds.integer(value)
end
local function request_kind(value: unknown): RequestKind?
    if value == "permission" then return "permission" end
    if value == "question" then return "question" end
    return nil
end
local function approval_state(value: unknown): ApprovalState?
    if value == "pending" then return "pending" end
    if value == "decided" then return "decided" end
    if value == "expired" then return "expired" end
    if value == "withdrawn" then return "withdrawn" end
    if value == "superseded" then return "superseded" end
    if value == "invalidated" then return "invalidated" end
    return nil
end
local function advance_incarnation(value: unknown): (integer?, string?)
    if type(value) ~= "number" then return nil, "authority incarnation is corrupt" end
    local current: integer? = bounds.count(value)
    if current == nil then return nil, "authority incarnation is corrupt" end
    if current == 0 then return nil, "authority incarnation is corrupt" end
    local advanced = bounds.count(value + 1)
    if advanced == nil then return nil, "authority incarnation is corrupt" end
    return advanced, nil
end
local function digest_of(value: unknown, maximum_bytes: integer?): (string?, string?, string?)
    local encoded, encode_error = canonical.encode(value, maximum_bytes)
    if not encoded then return nil, nil, encode_error end
    local sum, hash_error = hash.sha256(encoded)
    if hash_error or not sum then return nil, nil, "digest failed" end
    return sum, encoded, nil
end
local function response_schema_bytes(schema: Object): (string?, string?)
    if next(schema) == nil then return "{}", nil end
    return canonical.encode(schema, part_model.MAX_SCHEMA_BYTES)
end
M.advance_incarnation = advance_incarnation
M.approval_state = approval_state
M.digest_of = digest_of
M.failure = failure
M.integer = integer
M.node = node
M.now_ms = now_ms
M.refusal = refusal
M.request_kind = request_kind
M.response_schema_bytes = response_schema_bytes
M.stamp = stamp
M.storage = storage
M.success = success
M.text = text
return M
