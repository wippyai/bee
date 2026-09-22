-- MIT. The status projection: neutral, recorded work facts folded from
-- committed records for a thread's presentation surface (bar button, title,
-- collapsed recap). It is independent of the recap: its own schema, cursor
-- and revision, folded through the shared engine. It records state, never
-- liveness: "running" means a started attempt with no recorded end, not a
-- live process. Waiting facts are stored neutrally with their target
-- identities; the caller's relationship to them is derived per read and
-- never persisted as thread-wide status. Pending approvals are counted
-- neutrally; nothing here establishes who may decide one.
local sql = require("sql")
local record_types = require("record_types")
local transaction = require("transaction")
local bounds = require("bounds")
local engine = require("engine")
local M = {}
type Result = transaction.Result
type Checkpoint = {[string]: unknown}
type Object = {[string]: unknown}
M.SCHEMA = "bee.status@1"
M.KIND = "status"
function M.empty(): Checkpoint
    return {schema = M.SCHEMA, messages = 0, actions = {}, open_requests = {}, pending_approvals = {},
        last_outcome = nil, last_activity_sequence = 0}
end
-- Folds one record into the checkpoint. Pure: no reads, no time. It keeps
-- only what a status surface needs, as the record committed it.
function M.fold(raw: Checkpoint, entry: record_types.Record): Checkpoint
    local checkpoint = raw
    local actions = checkpoint.actions :: {[string]: string}
    local open_requests = checkpoint.open_requests :: {[string]: Object}
    local pending_approvals = checkpoint.pending_approvals :: {[string]: Object}
    checkpoint.last_activity_sequence = entry.sequence
    if entry.kind == "message" then
        local body = entry.body :: record_types.Message
        checkpoint.messages = (checkpoint.messages :: integer) + 1
        if body.message_kind == "request" and #body.recipient_ids > 0 then
            local targets: {[string]: boolean} = {}
            for _, recipient in ipairs(body.recipient_ids) do targets[recipient] = true end
            open_requests[body.message_id] = {sender_id = body.sender_id, targets = targets, remaining = #body.recipient_ids}
        end
    elseif entry.kind == "request.answered" then
        local body = entry.body :: record_types.Answered
        local open = open_requests[body.request_message_id]
        if open then
            local remaining = (open.remaining :: integer) - 1
            local targets = open.targets :: {[string]: boolean}
            targets[body.recipient_id] = nil
            if remaining <= 0 then open_requests[body.request_message_id] = nil else open.remaining = remaining end
        end
    elseif entry.kind == "action.admitted" and entry.action_id then
        actions[entry.action_id] = "admitted"
    elseif entry.kind == "attempt.started" and entry.action_id then
        -- A new attempt of this action is relevant lifecycle evidence: it
        -- supersedes an earlier uncertain outcome of the same action only.
        actions[entry.action_id] = "running"
    elseif entry.kind == "turn.end" and entry.turn_id then
        local body = entry.body :: record_types.TurnEnd
        checkpoint.last_outcome = {kind = "turn", outcome = body.outcome, at_sequence = entry.sequence}
        -- Uncertainty is per action: this turn's outcome touches only its own
        -- action, never another's. A different action succeeding cannot clear it.
        if entry.action_id then
            if body.outcome == "uncertain" then actions[entry.action_id] = "uncertain"
            elseif actions[entry.action_id] == "uncertain" then actions[entry.action_id] = "running" end
        end
    elseif entry.kind == "receipt" and entry.action_id then
        local body = entry.body :: record_types.Receipt
        checkpoint.last_outcome = {kind = "receipt", outcome = body.outcome, at_sequence = entry.sequence}
        if body.outcome == "uncertain" then actions[entry.action_id] = "uncertain"
        elseif body.scope == "action" then actions[entry.action_id] = nil
        elseif actions[entry.action_id] == "uncertain" then actions[entry.action_id] = "running" end
    elseif entry.kind == "approval.request" then
        local body = entry.body :: record_types.ApprovalRequest
        pending_approvals[body.approval_id] = {requester_id = body.requester_id, request_kind = body.request_kind}
    elseif entry.kind == "approval.transition" then
        local body = entry.body :: record_types.ApprovalTransition
        pending_approvals[body.approval_id] = nil
    end
    return checkpoint
end
local SPEC: engine.Spec = {schema = M.SCHEMA, kind = M.KIND, empty = M.empty, fold = M.fold}
-- Derives the presentation facts a reader needs from the folded checkpoint
-- and the caller's own identity. Pure. "running" is a recorded start with no
-- recorded end, not a live process; a projection behind the head is stale,
-- reported as such rather than as certainty.
function M.derive(checkpoint: Checkpoint, actor: string, through: integer, head: integer): Object
    local actions = checkpoint.actions :: {[string]: string}
    local open_requests = checkpoint.open_requests :: {[string]: Object}
    local pending_approvals = checkpoint.pending_approvals :: {[string]: Object}
    local running, open_actions, uncertain_actions = 0, 0, 0
    for _, state in pairs(actions) do
        open_actions = open_actions + 1
        if state == "running" then running = running + 1
        elseif state == "uncertain" then uncertain_actions = uncertain_actions + 1 end
    end
    local request_count = 0
    local waiting_message_ids: {string} = {}
    local waiting_on_you = false
    for message_id, open in pairs(open_requests) do
        request_count = request_count + 1
        local targets = open.targets :: {[string]: boolean}
        if targets[actor] then
            waiting_on_you = true
            waiting_message_ids[#waiting_message_ids + 1] = message_id
        end
    end
    local approval_count = 0
    for _ in pairs(pending_approvals) do approval_count = approval_count + 1 end
    local last_outcome = checkpoint.last_outcome
    local activity = "idle"
    -- An unresolved uncertain action is surfaced over other work so it is
    -- never hidden; it clears only when that action's own lifecycle resolves.
    if uncertain_actions > 0 then activity = "uncertain"
    elseif running > 0 then activity = "running"
    elseif request_count > 0 or approval_count > 0 then activity = "waiting" end
    return {
        activity = activity,
        stale = through < head,
        open_actions = open_actions,
        running_actions = running,
        uncertain_actions = uncertain_actions,
        open_requests = request_count,
        pending_approvals = approval_count,
        waiting_on_you = waiting_on_you,
        waiting_message_ids = waiting_message_ids,
        last_outcome = last_outcome,
    }
end
function M.read(db: sql.DB, actor: string, request: unknown): Result
    local result = engine.read(SPEC, db, actor, request)
    if not result.ok then return result end
    local value = result.value :: Object
    local checkpoint = value.checkpoint :: Checkpoint
    value.status = M.derive(checkpoint, actor, value.through_sequence :: integer, value.head_sequence :: integer)
    return result
end
function M.update(db: sql.DB, actor: string, request: unknown): Result
    return engine.update(SPEC, db, actor, request)
end
function M.rebuild(db: sql.DB, actor: string, request: unknown): Result
    return engine.rebuild(SPEC, db, actor, request)
end
return M
