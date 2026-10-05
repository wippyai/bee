-- MIT. Bounded sender for immutable content over Hive calls to a receiver
-- route. Destination status makes uncertain mutation replies reconcilable:
-- begin, chunks and finish all have natural immutable replay identities.
local hive = require("hive")
local hash = require("hash")
local base64 = require("base64")
local version = require("version")
local transaction = require("transaction")
local bounds = require("bounds")
local M = {}

type Object = {[string]: unknown}
type State = {state: string, received_bytes: integer, total_bytes: integer}
type Options = {timeout: string?, source_cursor: integer}
-- A destination is a receiver route on a node.
type Destination = {node: string, route: string}
local OPERATION = "receive"
local TIMEOUT = "60s"
local MAX_CONTENT_BYTES = 16777216
local CHUNK_BYTES = 32768

local function failure(code: string, message: string): transaction.Result
    return transaction.failure(code, message)
end

local function state(value: unknown): (State?, string?)
    if type(value) ~= "table" then return nil, "replica state is not an object" end
    local raw = value
    for name in pairs(raw) do
        if name ~= "source_owner" and name ~= "feed" and name ~= "key" and name ~= "state"
            and name ~= "received_bytes" and name ~= "total_bytes" then
            return nil, "replica state has an unknown field"
        end
    end
    local received, total = raw.received_bytes, raw.total_bytes
    if (raw.state ~= "receiving" and raw.state ~= "available") or type(received) ~= "number"
        or received ~= math.floor(received) or received < 0 or type(total) ~= "number"
        or total ~= math.floor(total) or total < 0 or total > MAX_CONTENT_BYTES or received > total then
        return nil, "replica state is malformed"
    end
    return {state = raw.state, received_bytes = math.floor(received),
        total_bytes = math.floor(total)}, nil
end

-- result reads a receiver's reply: the Hive reply carries the replica
-- owner's own result.
local function result(reply: hive.Reply?, call_error: string?): transaction.Result
    if not reply then return failure("UNAVAILABLE", call_error or "Hive replica call failed") end
    if reply.ok ~= true then return failure("UNAVAILABLE", reply.error or "Hive replica call failed") end
    local domain = reply.value
    if type(domain) ~= "table" or type(domain.ok) ~= "boolean" or type(domain.replayed) ~= "boolean" then
        return failure("UNAVAILABLE", "replica owner reply is malformed")
    end
    if domain.ok ~= true then
        return failure(type(domain.code) == "string" and domain.code or "INTERNAL",
            type(domain.message) == "string" and domain.message or "replica owner refused the call")
    end
    return transaction.success(domain.value, domain.replayed)
end

local function call(destination: Destination, input: Object, timeout: string?): transaction.Result
    return result(hive.call(destination.node, destination.route .. "." .. OPERATION, input, timeout or TIMEOUT))
end

local function status(destination: Destination, descriptor: version.Descriptor, timeout: string?): (State?, transaction.Result?)
    local outcome = call(destination, {action = "status", source_owner = descriptor.owner_id,
        feed = descriptor.feed, version_key = descriptor.key, descriptor_digest = descriptor.digest}, timeout)
    if not outcome.ok then return nil, outcome end
    local decoded, decode_error = state(outcome.value)
    if not decoded then return nil, failure("UNAVAILABLE", decode_error or "replica status is malformed") end
    return decoded, nil
end

local function mutation(destination: Destination, descriptor: version.Descriptor, action: string,
    input: Object, offset: integer?, expected: integer, timeout: string?): transaction.Result
    local outcome = call(destination, input, timeout)
    if outcome.ok then return outcome end
    if outcome.code ~= "UNCERTAIN" and outcome.code ~= "DEADLINE_EXCEEDED"
        and outcome.code ~= "UNAVAILABLE" then return outcome end
    local observed, status_error = status(destination, descriptor, timeout)
    if status_error then
        if action == "begin" and status_error.code == "NOT_FOUND" then
            return call(destination, input, timeout)
        end
        return failure("UNCERTAIN", "replica outcome and destination status are unknown")
    end
    if observed and ((action == "begin")
        or (action == "put" and observed.received_bytes >= expected)
        or (action == "finish" and observed.state == "available")) then
        return transaction.success(observed, true)
    end
    -- Status proved the mutation did not advance. One identical replay is safe:
    -- begin, chunks and finish all have natural immutable replay identities.
    if observed and (action == "begin" or observed.received_bytes == (offset or 0)) then
        return call(destination, input, timeout)
    end
    return failure("CONFLICT", "destination replica advanced unexpectedly")
end

function M.send(destination: Destination, raw_descriptor: version.Descriptor, content: string, options: Options): transaction.Result
    local descriptor, descriptor_error = version.decode(raw_descriptor)
    if not descriptor then return failure("INVALID", descriptor_error or "invalid version descriptor") end
    if not bounds.id(destination.node) or not bounds.id(destination.route) then return failure("INVALID", "destination is invalid") end
    local source_cursor = bounds.count(options.source_cursor)
    if source_cursor == nil then return failure("INVALID", "source cursor is invalid") end
    if #content ~= descriptor.total_bytes or #content > MAX_CONTENT_BYTES then return failure("INVALID", "content length does not match descriptor") end
    local measured, measure_error = hash.sha256(content)
    if not measured or measure_error or measured ~= descriptor.content_digest then return failure("INVALID", "content digest does not match descriptor") end
    local timeout = options.timeout
    local begun = mutation(destination, descriptor, "begin",
        {action = "begin", descriptor = descriptor, source_cursor = source_cursor}, nil, 0, timeout)
    if not begun.ok then return begun end
    local observed, status_error = status(destination, descriptor, timeout)
    if status_error then return status_error end
    local offset = observed and observed.received_bytes or 0
    while offset < #content do
        local ending = offset + CHUNK_BYTES
        if ending > #content then ending = #content end
        local bytes = content:sub(offset + 1, ending)
        local encoded, encode_error = base64.encode(bytes)
        if not encoded then return failure("INTERNAL", tostring(encode_error)) end
        local next_offset = offset + #bytes
        local written = mutation(destination, descriptor, "put", {action = "put",
            source_owner = descriptor.owner_id, feed = descriptor.feed, version_key = descriptor.key,
            descriptor_digest = descriptor.digest, offset = offset, content_base64 = encoded}, offset, next_offset, timeout)
        if not written.ok then return written end
        offset = next_offset
    end
    local finished = mutation(destination, descriptor, "finish", {action = "finish",
        source_owner = descriptor.owner_id, feed = descriptor.feed, version_key = descriptor.key,
        descriptor_digest = descriptor.digest}, nil, descriptor.total_bytes, timeout)
    return finished
end

return M
