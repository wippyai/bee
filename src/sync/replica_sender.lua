-- MIT. Bounded sender for immutable content over the existing Hive client.
-- Stable call keys plus destination status make uncertain mutation replies
-- reconcilable without inventing another transport or remote callback.
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
local OPERATION = "bee.sync:replica_receive"
local SERVICE = "bee.sync"
local MAX_CONTENT_BYTES = 16777216
local CHUNK_BYTES = 32768

local function failure(code: string, message: string): transaction.Result
    return transaction.failure(code, message)
end

local function key(descriptor_digest: string, action: string, offset: integer?): (string?, string?)
    return hash.sha256(descriptor_digest .. ":" .. action .. ":" .. tostring(offset or 0))
end

local function state(value: unknown): (State?, string?)
    if type(value) ~= "table" then return nil, "replica state is not an object" end
    local raw = value :: Object
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
    return {state = raw.state :: string, received_bytes = math.floor(received),
        total_bytes = math.floor(total)}, nil
end

local function result(reply: unknown): transaction.Result
    if type(reply) ~= "table" then return failure("UNAVAILABLE", "Hive replica reply is malformed") end
    local envelope = reply :: Object
    if envelope.ok ~= true then
        local fault = type(envelope.error) == "table" and (envelope.error :: Object) or nil
        local code = fault and fault.code
        local message = fault and fault.message
        return failure(type(code) == "string" and code or "UNAVAILABLE",
            type(message) == "string" and message or "Hive replica call failed")
    end
    if type(envelope.value) ~= "table" then return failure("UNAVAILABLE", "replica owner reply is malformed") end
    local domain = envelope.value :: Object
    if type(domain.ok) ~= "boolean" or type(domain.replayed) ~= "boolean" then
        return failure("UNAVAILABLE", "replica owner reply is malformed")
    end
    if domain.ok ~= true then
        return failure(type(domain.code) == "string" and domain.code or "INTERNAL",
            type(domain.message) == "string" and domain.message or "replica owner refused the call")
    end
    return transaction.success(domain.value, domain.replayed)
end

local function call(client: unknown, node: string, input: Object, idempotency_key: string, timeout: string?): transaction.Result
    if type(client) ~= "table" then return failure("UNAVAILABLE", "Hive client is unavailable") end
    local selected = client :: any
    local reply = selected:call({node_id = node, service_id = SERVICE}, {operation_ref = OPERATION}, input,
        {idempotency_key = idempotency_key, timeout = timeout})
    return result(reply)
end

local function status(client: unknown, node: string, descriptor: version.Descriptor, timeout: string?): (State?, transaction.Result?)
    local stable, stable_error = key(descriptor.digest, "status", 0)
    if not stable then return nil, failure("INTERNAL", tostring(stable_error)) end
    local outcome = call(client, node, {action = "status", source_owner = descriptor.owner_id,
        feed = descriptor.feed, version_key = descriptor.key, descriptor_digest = descriptor.digest}, stable, timeout)
    if not outcome.ok then return nil, outcome end
    local decoded, decode_error = state(outcome.value)
    if not decoded then return nil, failure("UNAVAILABLE", decode_error or "replica status is malformed") end
    return decoded, nil
end

local function mutation(client: unknown, node: string, descriptor: version.Descriptor, action: string,
    input: Object, offset: integer?, expected: integer, timeout: string?): transaction.Result
    local stable, stable_error = key(descriptor.digest, action, offset)
    if not stable then return failure("INTERNAL", tostring(stable_error)) end
    local outcome = call(client, node, input, stable, timeout)
    if outcome.ok then return outcome end
    if outcome.code ~= "UNCERTAIN" and outcome.code ~= "DEADLINE_EXCEEDED"
        and outcome.code ~= "UNAVAILABLE" then return outcome end
    local observed, status_error = status(client, node, descriptor, timeout)
    if status_error then
        if action == "begin" and status_error.code == "NOT_FOUND" then
            return call(client, node, input, stable, timeout)
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
        return call(client, node, input, stable, timeout)
    end
    return failure("CONFLICT", "destination replica advanced unexpectedly")
end

function M.send(destination_node: string, raw_descriptor: unknown, content: string, options: Options): transaction.Result
    local descriptor, descriptor_error = version.decode(raw_descriptor)
    if not descriptor then return failure("INVALID", descriptor_error or "invalid version descriptor") end
    if not bounds.id(destination_node) then return failure("INVALID", "destination node is invalid") end
    local source_cursor = bounds.count(options.source_cursor, 9007199254740991)
    if source_cursor == nil then return failure("INVALID", "source cursor is invalid") end
    if #content ~= descriptor.total_bytes or #content > MAX_CONTENT_BYTES then return failure("INVALID", "content length does not match descriptor") end
    local measured, measure_error = hash.sha256(content)
    if not measured or measure_error or measured ~= descriptor.content_digest then return failure("INVALID", "content digest does not match descriptor") end
    local client, open_error = hive.open()
    if not client then return failure("UNAVAILABLE", open_error or "Hive client unavailable") end
    local timeout = options.timeout
    local begun = mutation(client, destination_node, descriptor, "begin",
        {action = "begin", descriptor = descriptor, source_cursor = source_cursor}, nil, 0, timeout)
    if not begun.ok then client:close(); return begun end
    local observed, status_error = status(client, destination_node, descriptor, timeout)
    if status_error then client:close(); return status_error end
    local offset = observed and observed.received_bytes or 0
    while offset < #content do
        local ending = offset + CHUNK_BYTES
        if ending > #content then ending = #content end
        local bytes = content:sub(offset + 1, ending)
        local encoded, encode_error = base64.encode(bytes)
        if not encoded then client:close(); return failure("INTERNAL", tostring(encode_error)) end
        local next_offset = offset + #bytes
        local written = mutation(client, destination_node, descriptor, "put", {action = "put",
            source_owner = descriptor.owner_id, feed = descriptor.feed, version_key = descriptor.key,
            descriptor_digest = descriptor.digest, offset = offset, content_base64 = encoded}, offset, next_offset, timeout)
        if not written.ok then client:close(); return written end
        offset = next_offset
    end
    local finished = mutation(client, destination_node, descriptor, "finish", {action = "finish",
        source_owner = descriptor.owner_id, feed = descriptor.feed, version_key = descriptor.key,
        descriptor_digest = descriptor.digest}, nil, descriptor.total_bytes, timeout)
    client:close()
    return finished
end

return M
