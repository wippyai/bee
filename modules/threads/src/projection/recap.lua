-- MIT. The recap: a folded conversational summary. Its fold and empty
-- checkpoint live here; reading, bounded folding and the revision fence are
-- the shared projection engine. Derived, rebuildable, and never a source of
-- delivery or lifecycle state.
local sql = require("sql")
local record_types = require("record_types")
local transaction = require("transaction")
local engine = require("engine")
local bounds = require("bounds")
local M = {}
type Result = transaction.Result
type Checkpoint = {[string]: unknown}
type Folded = {schema: string, messages: integer, answered: integer, open_requests: {[string]: integer},
    deliveries: {[string]: integer}, actions: {[string]: string}, summary_lines: {string},
    last_turn: {turn_id: string, outcome: record_types.Outcome}?}

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
local function decoded(raw: Checkpoint): Folded?
    local messages = bounds.count(raw.messages)
    local raw_actions = bounds.object(raw.actions)
    if not messages or not raw_actions then return nil end
    local actions: {[string]: string} = {}
    for key, value in pairs(raw_actions) do
        if type(value) ~= "string" then return nil end
        actions[key] = value
    end
    local answered = bounds.count(raw.answered)
    local raw_deliveries = bounds.object(raw.deliveries)
    local raw_requests = bounds.object(raw.open_requests)
    local raw_lines = bounds.array(raw.summary_lines)
    if not answered or not raw_deliveries or not raw_requests or not raw_lines then return nil end
    local deliveries: {[string]: integer} = {}
    for key, value in pairs(raw_deliveries) do
        local count = bounds.count(value)
        if not count then return nil end
        deliveries[key] = count
    end
    local open_requests: {[string]: integer} = {}
    for key, value in pairs(raw_requests) do
        local count = bounds.count(value)
        if not count then return nil end
        open_requests[key] = count
    end
    local summary_lines: {string} = {}
    for index, value in ipairs(raw_lines) do
        if type(value) ~= "string" then return nil end
        summary_lines[index] = value
    end
    local last_turn: {turn_id: string, outcome: record_types.Outcome}? = nil
    if raw.last_turn ~= nil then
        local turn = bounds.object(raw.last_turn)
        if not turn or type(turn.turn_id) ~= "string" then return nil end
        local outcome = turn.outcome
        if outcome ~= "succeeded" and outcome ~= "failed" and outcome ~= "cancelled" and outcome ~= "uncertain" then return nil end
        last_turn = {turn_id = turn.turn_id, outcome = outcome}
    end
    return {schema = M.SCHEMA, messages = messages, answered = answered, actions = actions,
        deliveries = deliveries, open_requests = open_requests, summary_lines = summary_lines, last_turn = last_turn}
end
-- Folds one record into the checkpoint. Pure: no reads, no time.
function M.fold(raw: Checkpoint, entry: record_types.Record): Checkpoint
    local checkpoint = assert(decoded(raw), "stored checkpoint is corrupt")
    local open_requests = checkpoint.open_requests
    local deliveries = checkpoint.deliveries
    local actions = checkpoint.actions
    if entry.kind == "message" then
        local body = entry.body
        checkpoint.messages = (checkpoint.messages) + 1
        if body.message_kind == "request" and #body.recipient_ids > 0 then open_requests[body.message_id] = #body.recipient_ids end
        local text = body.content.text or ("artifact " .. tostring(body.content.artifact_ref))
        local lines = checkpoint.summary_lines
        lines[#lines + 1] = line(body.sender_id .. ": " .. text)
        while #lines > M.MAX_SUMMARY_LINES do table.remove(lines, 1) end
    elseif entry.kind == "request.answered" then
        local body = entry.body
        checkpoint.answered = (checkpoint.answered) + 1
        local remaining = open_requests[body.request_message_id]
        if remaining then
            if remaining <= 1 then open_requests[body.request_message_id] = nil else open_requests[body.request_message_id] = remaining - 1 end
        end
    elseif entry.kind == "delivery.mark" then
        local body = entry.body
        deliveries[body.state] = (deliveries[body.state] or 0) + 1
    elseif entry.kind == "action.admitted" and entry.action_id then
        actions[entry.action_id] = "admitted"
    elseif entry.kind == "attempt.started" and entry.action_id then
        actions[entry.action_id] = "running"
    elseif entry.kind == "turn.end" and entry.turn_id then
        local body = entry.body
        checkpoint.last_turn = {turn_id = entry.turn_id, outcome = body.outcome}
    elseif entry.kind == "receipt" and entry.action_id then
        local body = entry.body
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
