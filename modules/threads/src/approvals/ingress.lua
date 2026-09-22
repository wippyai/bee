-- MIT. The approval ingress: the approval authority appends its typed
-- projection records to a thread under its own owner scope and event id,
-- authenticated by its action on the thread rather than by membership. It
-- commits no decision, settles nothing and writes no other family. It also
-- addresses one notice to the requester, because only a message commit owes
-- a recipient anything and a decision nobody is told of reaches no agent.
local sql = require("sql")
local bounds = require("bounds")
local record_types = require("types")
local record = require("record")
local reader = require("reader")
local transaction = require("transaction")
local authority = require("authority")
local access = require("access")
local M = {}
type Result = transaction.Result
M.KINDS = {"approval.request", "approval.transition", "message"}
local function failure(code: string, message: string): Result
    return transaction.failure(code, message)
end
local function storage(err: string): Result
    return transaction.failure("INTERNAL", err)
end
-- A message from this ingress is the authority's own notice about a request
-- it owns: it is sent under the calling actor, it may only notify, and it
-- names someone. An ingress with no membership must never place a request
-- here, because nobody could ever be held to answer it.
local function notice(actor: string, value: unknown): ({[string]: unknown}?, string?)
    local object = bounds.object(value)
    if not object then return nil, "message must be an object" end
    local submission: {[string]: unknown} = {}
    for field, item in pairs(object) do submission[field] = item end
    if submission.sender_id ~= nil and submission.sender_id ~= actor then return nil, "sender_id must be the calling authority" end
    submission.sender_id = actor
    if submission.message_kind ~= "notification" then return nil, "message_kind must be notification" end
    if submission.in_reply_to ~= nil then return nil, "a projected notification answers nothing" end
    local recipients = submission.recipient_ids
    if type(recipients) ~= "table" or #(recipients :: {unknown}) == 0 then return nil, "recipient_ids names at least one recipient" end
    return submission, nil
end
-- append: one approval record keyed by the calling authority's own scope
-- and event id; no payload field selects another authority's namespace.
function M.append(db: sql.DB, actor: string, request: unknown): Result
    local mutation, invalid = authority.mutation(request)
    if not mutation then return invalid or failure("INVALID_ARGUMENT", "invalid request") end
    local object = bounds.object(request) or {}
    local unknown_field = bounds.fields(object, {"thread_id", "idempotency_key", "owner_event_id", "kind", "body", "context"})
    if unknown_field then return failure("INVALID_ARGUMENT", unknown_field) end
    local owner_event_id = bounds.id(object.owner_event_id)
    if not owner_event_id then return failure("INVALID_ARGUMENT", "owner_event_id is not an identifier") end
    local kind = bounds.member(object.kind, M.KINDS)
    if not kind then return failure("INVALID_ARGUMENT", "kind must be approval.request, approval.transition or message") end
    local payload: unknown = object.body
    if kind == "message" then
        local submission, invalid = notice(actor, object.body)
        if not submission then return failure("INVALID_ARGUMENT", "message: " .. tostring(invalid)) end
        payload = submission
    end
    local body, body_error = record.decode_body(kind :: record_types.Kind, payload)
    if not body then return failure("INVALID_ARGUMENT", kind .. ": " .. tostring(body_error)) end
    return transaction.write(db, function(tx: sql.Transaction): Result
        if not access.may_project_approvals(mutation.thread_id) then return failure("DENIED", "caller holds no approval ingress authority for the thread") end
        local head, head_err = reader.head(tx, mutation.thread_id)
        if head_err then return storage(head_err) end
        if not head then return failure("NOT_FOUND", "thread does not exist") end
        local replayed, replay_err = authority.replay(tx, actor, "approval_append", mutation)
        if replay_err then return storage(replay_err) end
        if replayed then return replayed end
        if head.state ~= "open" then return failure("INVALID_STATE", "thread is closed") end
        local context, context_error = authority.context(tx, mutation.thread_id, object.context)
        if not context then return context_error or failure("INVALID_ARGUMENT", "invalid context") end
        local scope = "approval/" .. actor
        local result: Result
        if kind == "message" then
            result = authority.project_message(tx, head, actor, body :: record_types.Message, context, scope, owner_event_id)
        else
            result = authority.commit_keyed(tx, head, kind :: record_types.Kind, actor, "bee", body, context, scope, owner_event_id)
        end
        if not result.ok then return result end
        if result.replayed then return result end
        return authority.remember(tx, actor, "approval_append", mutation, result.value)
    end)
end
return M
