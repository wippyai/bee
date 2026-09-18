-- MIT. The recap: a folded conversational summary. Its fold and empty
-- checkpoint live here; reading, bounded folding and the revision fence are
-- the shared projection engine. Derived, rebuildable, and never a source of
-- delivery or lifecycle state.
local sql = require("sql")
local record_types = require("record_types")
local transaction = require("transaction")
local engine = require("engine")
local M = {}
type Result = transaction.Result
type Checkpoint = {[string]: unknown}
M.SCHEMA = "bee.recap@1"
M.KIND = "recap"
M.MAX_SUMMARY_LINES = 8
M.MAX_LINE_BYTES = 120
function M.empty(): Checkpoint
    return {schema = M.SCHEMA, messages = 0, open_requests = {}, answered = 0,
        deliveries = {claimed = 0, delivered = 0, released = 0, uncertain = 0}, actions = {}, summary_lines = {}}
end
local function line(text: string): string
    local single = text:gsub("%s+", " ")
    if #single > M.MAX_LINE_BYTES then single = single:sub(1, M.MAX_LINE_BYTES - 1) .. "…" end
    return single
end
-- Folds one record into the checkpoint. Pure: no reads, no time.
function M.fold(raw: Checkpoint, entry: record_types.Record): Checkpoint
    local checkpoint = raw
    local open_requests = checkpoint.open_requests :: {[string]: integer}
    local deliveries = checkpoint.deliveries :: {[string]: integer}
    local actions = checkpoint.actions :: {[string]: string}
    if entry.kind == "message" then
        local body = entry.body :: record_types.Message
        checkpoint.messages = (checkpoint.messages :: integer) + 1
        if body.message_kind == "request" and #body.recipient_ids > 0 then open_requests[body.message_id] = #body.recipient_ids end
        local text = body.content.text or ("artifact " .. tostring(body.content.artifact_ref))
        local lines = checkpoint.summary_lines :: {string}
        lines[#lines + 1] = line(body.sender_id .. ": " .. text)
        while #lines > M.MAX_SUMMARY_LINES do table.remove(lines, 1) end
    elseif entry.kind == "request.answered" then
        local body = entry.body :: record_types.Answered
        checkpoint.answered = (checkpoint.answered :: integer) + 1
        local remaining = open_requests[body.request_message_id]
        if remaining then
            if remaining <= 1 then open_requests[body.request_message_id] = nil else open_requests[body.request_message_id] = remaining - 1 end
        end
    elseif entry.kind == "delivery.mark" then
        local body = entry.body :: record_types.DeliveryMark
        deliveries[body.state] = (deliveries[body.state] or 0) + 1
    elseif entry.kind == "action.admitted" and entry.action_id then
        actions[entry.action_id] = "admitted"
    elseif entry.kind == "attempt.started" and entry.action_id then
        actions[entry.action_id] = "running"
    elseif entry.kind == "turn.end" and entry.turn_id then
        local body = entry.body :: record_types.TurnEnd
        checkpoint.last_turn = {turn_id = entry.turn_id, outcome = body.outcome}
    elseif entry.kind == "receipt" and entry.action_id then
        local body = entry.body :: record_types.Receipt
        if body.scope == "action" then actions[entry.action_id] = "ended" else actions[entry.action_id] = "admitted" end
    end
    return checkpoint
end
local SPEC: engine.Spec = {schema = M.SCHEMA, kind = M.KIND, empty = M.empty, fold = M.fold}
function M.digest(checkpoint: Checkpoint, through: integer): (string?, string?)
    return engine.digest(SPEC, checkpoint, through)
end
function M.read(db: sql.DB, actor: string, request: unknown): Result
    return engine.read(SPEC, db, actor, request)
end
function M.update(db: sql.DB, actor: string, request: unknown): Result
    return engine.update(SPEC, db, actor, request)
end
function M.rebuild(db: sql.DB, actor: string, request: unknown): Result
    return engine.rebuild(SPEC, db, actor, request)
end
return M
