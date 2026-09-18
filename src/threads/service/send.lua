-- MIT. Owner-qualified send: a message that arrived through a forwarding
-- seam is committed by the destination thread owner under a request
-- identity that survives forwarding and retries, the caller's node and
-- idempotency key, with the payload digest the sender computed. The
-- caller is the local actor destination admission established for the
-- forwarded principal; local membership decides what it may commit.
-- An ambiguous timeout is answered by status against that identity,
-- never by a fresh send.
local sql = require("sql")
local hash = require("hash")
local json = require("json")
local bounds = require("bounds")
local canonical = require("canonical")
local reader = require("reader")
local transaction = require("transaction")
local authority = require("authority")
local M = {}
type Result = transaction.Result
local function failure(code: string, message: string): Result
    return transaction.failure(code, message)
end
local function storage(err: string): Result
    return transaction.failure("INTERNAL", err)
end
-- The request identity is the thread, the authenticated principal (the
-- command's actor), the sending node and the sender's idempotency key:
-- two subjects on one node never collide or read each other's results.
-- The request digest covers every caller-controlled field, context
-- included, so a retry replays only an identical request.
local function identity(object: {[string]: unknown}): (string?, string?, Result?)
    local caller_node = bounds.id(object.caller_node_id)
    if not caller_node then return nil, nil, failure("INVALID_ARGUMENT", "caller_node_id is not an identifier") end
    local key = bounds.id(object.idempotency_key)
    if not key then return nil, nil, failure("INVALID_ARGUMENT", "idempotency_key is not an identifier") end
    return caller_node, "send/" .. caller_node .. "/" .. key, nil
end
function M.payload_digest(message: unknown): (string?, string?)
    local encoded, encode_error = canonical.encode(message)
    if not encoded then return nil, encode_error end
    local digest, hash_error = hash.sha256(encoded)
    if hash_error or not digest then return nil, "digest failed" end
    return digest, nil
end
function M.send(db: sql.DB, actor: string, request: unknown): Result
    local object = bounds.object(request)
    if not object then return failure("INVALID_ARGUMENT", "request must be an object") end
    local unknown_field = bounds.fields(object, {"thread_id", "idempotency_key", "caller_node_id", "payload_digest", "message", "context"})
    if unknown_field then return failure("INVALID_ARGUMENT", unknown_field) end
    local caller_node, command_key, invalid = identity(object)
    if not caller_node or not command_key then return invalid or failure("INVALID_ARGUMENT", "invalid identity") end
    local declared = bounds.id(object.payload_digest)
    if not declared or #declared ~= 64 then return failure("INVALID_ARGUMENT", "payload_digest must be a sha256 hex digest") end
    local computed, digest_error = M.payload_digest(object.message)
    if not computed then return failure("INVALID_ARGUMENT", "message is not measurable: " .. tostring(digest_error)) end
    if computed ~= declared then return failure("INVALID_ARGUMENT", "payload_digest does not match the message") end
    local mutation, mutation_invalid = authority.mutation({thread_id = object.thread_id, idempotency_key = command_key, caller_node_id = caller_node, payload_digest = declared, message = object.message, context = object.context})
    if not mutation then return mutation_invalid or failure("INVALID_ARGUMENT", "invalid request") end
    return transaction.write(db, function(tx: sql.Transaction): Result
        local head, caller, denied = authority.membership(tx, mutation.thread_id, actor)
        if not head or not caller then return denied or failure("DENIED", "caller is not a member of the thread") end
        local replayed, replay_err = authority.replay(tx, actor, "send", mutation)
        if replay_err then return storage(replay_err) end
        if replayed then return replayed end
        if head.state ~= "open" then return failure("INVALID_STATE", "thread is closed") end
        local context, context_error = authority.context(tx, mutation.thread_id, object.context)
        if not context then return context_error or failure("INVALID_ARGUMENT", "invalid context") end
        local result = authority.submit_message(tx, head, caller, object.message, context)
        if not result.ok then return result end
        local committed = result.value :: {record_id: string, sequence: integer}
        return authority.remember(tx, actor, "send", mutation, {record_id = committed.record_id, sequence = committed.sequence, caller_node_id = caller_node, payload_digest = declared})
    end)
end
-- send_status: what the owner committed under a request identity, or that
-- nothing was. A sender that lost the reply asks here before anything else.
function M.send_status(db: sql.DB, actor: string, request: unknown): Result
    local object = bounds.object(request)
    if not object then return failure("INVALID_ARGUMENT", "request must be an object") end
    local unknown_field = bounds.fields(object, {"thread_id", "idempotency_key", "caller_node_id"})
    if unknown_field then return failure("INVALID_ARGUMENT", unknown_field) end
    local thread_id = bounds.id(object.thread_id)
    if not thread_id then return failure("INVALID_ARGUMENT", "thread_id is not an identifier") end
    local caller_node, command_key, invalid = identity(object)
    if not caller_node or not command_key then return invalid or failure("INVALID_ARGUMENT", "invalid identity") end
    return transaction.read(db, function(tx: sql.Transaction): Result
        local head, caller, denied = authority.membership(tx, thread_id, actor)
        if not head or not caller then return denied or failure("DENIED", "caller is not a member of the thread") end
        local command, err = reader.command(tx, thread_id, actor, command_key)
        if err then return storage(err) end
        if not command or command.operation ~= "send" then
            return transaction.success({committed = false, caller_node_id = caller_node, observation = "no matching commit at this read; an earlier request may still be in flight, and an identical replay stays safe"}, false)
        end
        local value: unknown = json.decode(command.reply_json)
        local reply = bounds.object(value) or {}
        return transaction.success({committed = true, caller_node_id = caller_node, record_id = reply.record_id, sequence = reply.sequence, payload_digest = reply.payload_digest}, false)
    end)
end
return M
