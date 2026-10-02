-- MIT. Status projection state machine for a client session.
local text = require("text")
local caller = require("caller")
local bounds = require("bounds")
local M = {}
M.UPDATE = "bee.threads.binding:status_update"
M.READ = "bee.threads.binding:status_read"
M.WATCH = "bee.threads.binding:watch"
M.WAIT_MS = 30000
type Reply = caller.Reply
type Object = {[string]: unknown}
type Intent = {generation: integer, target: string, request: Object}
type Availability = "unbound" | "loading" | "ready" | "stale" | "unavailable"
type Activity = "idle" | "running" | "waiting" | "uncertain"
type Outcome = "succeeded" | "failed" | "cancelled" | "uncertain"
type LastOutcome = {kind: "turn" | "receipt", outcome: Outcome, at_sequence: integer}
type Owner = {authority: string, incarnation: integer}
type Status = {
    activity: Activity, stale: boolean, waiting_on_you: boolean, waiting_message_ids: {string},
    open_requests: integer, pending_approvals: integer, running_actions: integer,
    uncertain_actions: integer, open_actions: integer, last_outcome: LastOutcome?,
}
type Projection = {revision: integer, through_sequence: integer, head_sequence: integer, owner: Owner?, status: Status?}
type Value = {
    thread_id: string?, generation: integer, owner_authority: string, owner_incarnation: integer,
    availability: Availability, detail: string,
    status: Status?, revision: integer, through_sequence: integer, head_sequence: integer, stale: boolean,
}
type Reader = {
    thread_id: string?, generation: integer, owner_authority: string, owner_incarnation: integer,
    revision: integer, through_sequence: integer, head_sequence: integer,
    status: Status?, availability: Availability, detail: string, needs_refresh: boolean,
}

function M.new(): Reader
    return {thread_id = nil, generation = 0, owner_authority = "", owner_incarnation = 0, revision = 0, through_sequence = 0, head_sequence = 0,
        status = nil, availability = "unbound", detail = "", needs_refresh = false}
end
function M.bind(reader: Reader, thread_id: string)
    reader.thread_id = thread_id
    reader.generation = reader.generation + 1
    reader.owner_authority = ""
    reader.owner_incarnation = 0
    reader.revision = 0
    reader.through_sequence = 0
    reader.head_sequence = 0
    reader.status = nil
    reader.availability = "loading"
    reader.detail = ""
    reader.needs_refresh = false
end
function M.unbind(reader: Reader)
    reader.thread_id = nil
    reader.generation = reader.generation + 1
    reader.status = nil
    reader.availability = "unbound"
    reader.detail = ""
    reader.needs_refresh = false
end
local function fault_text(reply: Reply): string
    local fault = reply.error
    if not fault then return "no answer" end
    return text.bound(fault.code .. ": " .. fault.message, 200)
end
local function current(reader: Reader, generation: integer): boolean
    return reader.thread_id ~= nil and generation == reader.generation
end
local function outcome(value: unknown): Outcome?
    if value == "succeeded" then return "succeeded" end
    if value == "failed" then return "failed" end
    if value == "cancelled" then return "cancelled" end
    if value == "uncertain" then return "uncertain" end
    return nil
end
local function activity(value: unknown): Activity?
    if value == "idle" then return "idle" end
    if value == "running" then return "running" end
    if value == "waiting" then return "waiting" end
    if value == "uncertain" then return "uncertain" end
    return nil
end
local function decode_last_outcome(value: unknown): LastOutcome?
    if value == nil then return nil end
    local object = bounds.object(value)
    if not object or bounds.fields(object, {"kind", "outcome", "at_sequence"}) then return nil end
    local kind = bounds.member(object.kind, {"turn", "receipt"})
    local selected_outcome = outcome(object.outcome)
    local sequence = record_bounds.sequence(object.at_sequence)
    if not kind or not selected_outcome or not sequence then return nil end
    local selected_kind: "turn" | "receipt"
    if kind == "turn" then selected_kind = "turn"
    elseif kind == "receipt" then selected_kind = "receipt"
    else return nil end
    return {kind = selected_kind, outcome = selected_outcome, at_sequence = sequence}
end
local function decode_status(value: unknown): Status?
    local object = bounds.object(value)
    if not object or bounds.fields(object, {"activity", "stale", "waiting_on_you", "waiting_message_ids",
        "open_requests", "pending_approvals", "running_actions", "uncertain_actions", "open_actions", "last_outcome"}) then return nil end
    local selected_activity = activity(object.activity)
    local waiting = bounds.ids(object.waiting_message_ids, true)
    local last = decode_last_outcome(object.last_outcome)
    if object.last_outcome ~= nil and not last then return nil end
    if not selected_activity or type(object.stale) ~= "boolean" or type(object.waiting_on_you) ~= "boolean" or not waiting then return nil end
    local open_requests = bounds.count(object.open_requests)
    local pending_approvals = bounds.count(object.pending_approvals)
    local running_actions = bounds.count(object.running_actions)
    local uncertain_actions = bounds.count(object.uncertain_actions)
    local open_actions = bounds.count(object.open_actions)
    if not open_requests or not pending_approvals or not running_actions or not uncertain_actions or not open_actions then return nil end
    return {activity = selected_activity, stale = object.stale, waiting_on_you = object.waiting_on_you,
        waiting_message_ids = waiting, open_requests = open_requests, pending_approvals = pending_approvals,
        running_actions = running_actions, uncertain_actions = uncertain_actions, open_actions = open_actions,
        last_outcome = last}
end
local function decode_projection(value: unknown, include_status: boolean): (Projection?, string?)
    local object = bounds.object(value)
    if not object then return nil, "projection value must be an object" end
    local allowed = {"revision", "through_sequence", "head_sequence", "checkpoint", "digest", "owner_authority", "owner_incarnation"}
    if include_status then allowed[#allowed + 1] = "status" end
    local unknown = bounds.fields(object, allowed)
    if unknown then return nil, "projection value: " .. unknown end
    local revision = bounds.count(object.revision)
    local through = record_bounds.cursor(object.through_sequence)
    local head = record_bounds.cursor(object.head_sequence)
    if not revision or not through or not head or through > head then return nil, "projection cursors are malformed" end
    if not bounds.object(object.checkpoint) then return nil, "projection checkpoint must be an object" end
    if object.digest ~= nil and not bounds.text(object.digest, 64) then return nil, "projection digest is malformed" end
    local owner: Owner? = nil
    if object.owner_authority ~= nil or object.owner_incarnation ~= nil then
        local authority = bounds.text(object.owner_authority, 160)
        local incarnation = bounds.count(object.owner_incarnation)
        if not authority or (authority ~= "" and not bounds.id(authority)) or not incarnation then
            return nil, "projection owner identity is malformed"
        end
        if (authority == "") ~= (incarnation == 0) then return nil, "projection owner identity is inconsistent" end
        owner = {authority = authority, incarnation = incarnation}
    elseif include_status then return nil, "status projection has no owner identity" end
    local status: Status? = nil
    if include_status then
        local status_error: string?
        status, status_error = decode_status(object.status)
        if not status then return nil, "projection status is malformed: " .. tostring(status_error or "invalid value") end
    end
    return {revision = revision, through_sequence = through, head_sequence = head, owner = owner, status = status}, nil
end
local function accept_owner(reader: Reader, owner: Owner?): boolean
    if not owner or owner.authority == "" then return true end
    if reader.owner_authority == "" then
        reader.owner_authority = owner.authority
        reader.owner_incarnation = owner.incarnation
        return true
    end
    if owner.authority ~= reader.owner_authority then
        reader.generation = reader.generation + 1
        reader.owner_authority = owner.authority
        reader.owner_incarnation = owner.incarnation
        reader.revision = 0
        reader.through_sequence = 0
        reader.head_sequence = 0
        reader.status = nil
        return true
    end
    if owner.incarnation > reader.owner_incarnation then reader.owner_incarnation = owner.incarnation end
    return true
end
local function unavailable(reader: Reader, detail: string)
    reader.availability = "unavailable"
    reader.detail = detail
end
function M.update_intent(reader: Reader, idempotency_key: string): Intent?
    if not reader.thread_id then return nil end
    return {generation = reader.generation, target = M.UPDATE, request = {thread_id = reader.thread_id, idempotency_key = idempotency_key}}
end
function M.apply_update(reader: Reader, generation: integer, reply: Reply)
    if not current(reader, generation) then return end
    if not reply.ok then unavailable(reader, fault_text(reply)); return end
    local projection, decode_error = decode_projection(reply.value, false)
    if not projection then unavailable(reader, decode_error or "invalid status update from the thread owner"); return end
    accept_owner(reader, projection.owner)
    if projection.revision >= reader.revision then
        reader.revision = projection.revision
        reader.through_sequence = projection.through_sequence
    end
    reader.head_sequence = math.max(reader.head_sequence, projection.head_sequence)
    reader.needs_refresh = reader.through_sequence < reader.head_sequence
end
function M.read_intent(reader: Reader): Intent?
    if not reader.thread_id then return nil end
    return {generation = reader.generation, target = M.READ, request = {thread_id = reader.thread_id}}
end
function M.apply_read(reader: Reader, generation: integer, reply: Reply)
    if not current(reader, generation) then return end
    if not reply.ok then unavailable(reader, fault_text(reply)); return end
    local projection, decode_error = decode_projection(reply.value, true)
    if not projection or not projection.status then
        unavailable(reader, decode_error or "invalid status from the thread owner"); return
    end
    accept_owner(reader, projection.owner)
    if projection.revision < reader.revision and reader.status ~= nil then return end
    reader.revision = projection.revision
    reader.through_sequence = projection.through_sequence
    reader.head_sequence = math.max(reader.head_sequence, projection.head_sequence)
    reader.status = projection.status
    if reader.through_sequence < reader.head_sequence then
        reader.availability = "stale"
        reader.needs_refresh = true
    else
        reader.availability = "ready"
        reader.detail = ""
        reader.needs_refresh = false
    end
end
function M.watch_intent(reader: Reader): Intent?
    if not reader.thread_id then return nil end
    return {generation = reader.generation, target = M.WATCH, request = {thread_id = reader.thread_id,
        after_sequence = reader.head_sequence, wait_ms = M.WAIT_MS}}
end
function M.apply_watch(reader: Reader, generation: integer, reply: Reply)
    if not current(reader, generation) then return end
    if reply.ok then reader.needs_refresh = true
    else reader.availability = reader.status ~= nil and "unavailable" or reader.availability; reader.detail = fault_text(reply) end
end
function M.lost(reader: Reader)
    if not reader.thread_id then return end
    unavailable(reader, "no answer from the thread owner")
end
function M.needs_refresh(reader: Reader): boolean
    return reader.thread_id ~= nil and reader.needs_refresh
end
function M.value(reader: Reader): Value
    return {thread_id = reader.thread_id, generation = reader.generation, owner_authority = reader.owner_authority,
        owner_incarnation = reader.owner_incarnation, availability = reader.availability, detail = reader.detail,
        status = reader.status, revision = reader.revision, through_sequence = reader.through_sequence,
        head_sequence = reader.head_sequence, stale = reader.through_sequence < reader.head_sequence}
end
return M
