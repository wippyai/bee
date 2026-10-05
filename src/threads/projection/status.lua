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
type OpenRequest = {sender_id: string, targets: {[string]: boolean}, remaining: integer}
type LastOutcome = {kind: string, outcome: record_types.Outcome, at_sequence: integer}
type Folded = {schema: string, messages: integer, actions: {[string]: string}, open_requests: {[string]: OpenRequest},
    pending_approvals: {[string]: {requester_id: string, request_kind: string?}}, last_outcome: LastOutcome?, last_activity_sequence: integer}

type Object = {[string]: unknown}
M.SCHEMA = "bee.status@1"
M.KIND = "status"
function M.empty(): Checkpoint
    return {schema = M.SCHEMA, messages = 0, actions = {}, open_requests = {}, pending_approvals = {},
        last_outcome = nil, last_activity_sequence = 0}
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
    local raw_requests = bounds.object(raw.open_requests)
    local raw_approvals = bounds.object(raw.pending_approvals)
    local last_activity_sequence = bounds.count(raw.last_activity_sequence)
    if not raw_requests or not raw_approvals or not last_activity_sequence then return nil end
    local open_requests: {[string]: OpenRequest} = {}
    for key, value in pairs(raw_requests) do
        local request = bounds.object(value)
        if not request or type(request.sender_id) ~= "string" then return nil end
        local remaining = bounds.count(request.remaining)
        local raw_targets = bounds.object(request.targets)
        if not remaining or not raw_targets then return nil end
        local targets: {[string]: boolean} = {}
        for target, present in pairs(raw_targets) do
            if type(present) ~= "boolean" then return nil end
            targets[target] = present
        end
        open_requests[key] = {sender_id = request.sender_id, remaining = remaining, targets = targets}
    end
    local pending_approvals: {[string]: {requester_id: string, request_kind: string?}} = {}
    for key, value in pairs(raw_approvals) do
        local approval = bounds.object(value)
        if not approval or type(approval.requester_id) ~= "string" then return nil end
        local request_kind: string? = nil
        if approval.request_kind ~= nil then
            if type(approval.request_kind) ~= "string" then return nil end
            request_kind = approval.request_kind
        end
        pending_approvals[key] = {requester_id = approval.requester_id, request_kind = request_kind}
    end
    local last_outcome: LastOutcome? = nil
    if raw.last_outcome ~= nil then
        local last = bounds.object(raw.last_outcome)
        if not last or type(last.kind) ~= "string" then return nil end
        local sequence = bounds.count(last.at_sequence)
        local outcome = last.outcome
        if not sequence or (outcome ~= "succeeded" and outcome ~= "failed" and outcome ~= "cancelled" and outcome ~= "uncertain") then return nil end
        last_outcome = {kind = last.kind, outcome = outcome, at_sequence = sequence}
    end
    return {schema = M.SCHEMA, messages = messages, actions = actions, open_requests = open_requests,
        pending_approvals = pending_approvals, last_outcome = last_outcome, last_activity_sequence = last_activity_sequence}
end
-- Folds one record into the checkpoint. Pure: no reads, no time. It keeps
-- only what a status surface needs, as the record committed it.
function M.fold(raw: Checkpoint, entry: record_types.Record): Checkpoint
    local checkpoint = assert(decoded(raw), "stored checkpoint is corrupt")
    local actions = checkpoint.actions
    local open_requests = checkpoint.open_requests
    local pending_approvals = checkpoint.pending_approvals
    checkpoint.last_activity_sequence = entry.sequence
    if entry.kind == "message" then
        local body = entry.body
        checkpoint.messages = (checkpoint.messages) + 1
        if body.message_kind == "request" and #body.recipient_ids > 0 then
            local targets: {[string]: boolean} = {}
            for _, recipient in ipairs(body.recipient_ids) do targets[recipient] = true end
            open_requests[body.message_id] = {sender_id = body.sender_id, targets = targets, remaining = #body.recipient_ids}
        end
    elseif entry.kind == "request.answered" then
        local body = entry.body
        local open = open_requests[body.request_message_id]
        if open then
            local remaining = (open.remaining) - 1
            local targets = open.targets
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
        local body = entry.body
        checkpoint.last_outcome = {kind = "turn", outcome = body.outcome, at_sequence = entry.sequence}
        -- Uncertainty is per action: this turn's outcome touches only its own
        -- action, never another's. A different action succeeding cannot clear it.
        if entry.action_id then
            if body.outcome == "uncertain" then actions[entry.action_id] = "uncertain"
            elseif actions[entry.action_id] == "uncertain" then actions[entry.action_id] = "running" end
        end
    elseif entry.kind == "receipt" and entry.action_id then
        local body = entry.body
        checkpoint.last_outcome = {kind = "receipt", outcome = body.outcome, at_sequence = entry.sequence}
        if body.outcome == "uncertain" then actions[entry.action_id] = "uncertain"
        elseif body.scope == "action" then actions[entry.action_id] = nil
        elseif actions[entry.action_id] == "uncertain" then actions[entry.action_id] = "running" end
    elseif entry.kind == "approval.request" then
        local body = entry.body
        pending_approvals[body.approval_id] = {requester_id = body.requester_id, request_kind = body.request_kind}
    elseif entry.kind == "approval.transition" then
        local body = entry.body
        pending_approvals[body.approval_id] = nil
    end
    return checkpoint
end
local SPEC: engine.Spec = {schema = M.SCHEMA, kind = M.KIND, empty = M.empty, fold = M.fold}
-- Derives the presentation facts a reader needs from the folded checkpoint
-- and the caller's own identity. Pure. "running" is a recorded start with no
-- recorded end, not a live process; a projection behind the head is stale,
-- reported as such rather than as certainty.
function M.derive(raw: Checkpoint, actor: string, through: integer, head: integer): Object
    local checkpoint = assert(decoded(raw), "stored checkpoint is corrupt")
    local actions = checkpoint.actions
    local open_requests = checkpoint.open_requests
    local pending_approvals = checkpoint.pending_approvals
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
        local targets = open.targets
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
    local value = bounds.object(result.value)
    if not value then return transaction.failure("INTERNAL", "projection result is corrupt") end
    local checkpoint = bounds.object(value.checkpoint)
    local through, head = bounds.count(value.through_sequence), bounds.count(value.head_sequence)
    if not checkpoint or not through or not head or not decoded(checkpoint) then return transaction.failure("INTERNAL", "stored checkpoint is corrupt") end
    value.status = M.derive(checkpoint, actor, through, head)
    return result
end
function M.update(db: sql.DB, actor: string, request: unknown): Result
    return engine.update(SPEC, db, actor, request)
end
function M.rebuild(db: sql.DB, actor: string, request: unknown): Result
    return engine.rebuild(SPEC, db, actor, request)
end
return M
