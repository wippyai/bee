-- MIT. A typed status reader for a client session: it drives the thread
-- owner's status projection and hands the shell presentation values,
-- performing no I/O of its own. The owner it belongs to calls the intents
-- this reader emits and feeds the replies back; the presenter renders the
-- value and calls nothing. The reader advances the projection through the
-- authorized bounded update, reads the caller-derived status, and rechecks
-- through the read-only change-wait, coalescing wakeups into one refresh.
-- It carries thread identity, owner authority, its own generation and the
-- projection revision and cursor, fences replies after a thread switch or
-- replacement, shows unavailable or stale explicitly rather than as idle,
-- and never treats a lagging projection as certainty.
local text = require("text")
local caller = require("caller")
local M = {}
M.UPDATE = "bee.threads.projection:status_update"
M.READ = "bee.threads.projection:status_read"
M.WATCH = "bee.threads.delivery:watch"
M.WAIT_MS = 30000
type Reply = caller.Reply
type Object = {[string]: unknown}
type Intent = {generation: integer, target: string, request: Object}
type Availability = "unbound" | "loading" | "ready" | "stale" | "unavailable"
type Status = {
    activity: string, waiting_on_you: boolean, waiting_message_ids: {string},
    open_requests: integer, pending_approvals: integer, running_actions: integer,
    uncertain_actions: integer, open_actions: integer, last_outcome: unknown,
}
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
-- Bind to a thread: a new generation fences every reply from the previous
-- binding, and the reader starts from nothing known about the new thread.
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
-- Unbind: the reader shows nothing and its owner cancels any outstanding
-- change-wait. A late reply for the old binding is fenced by generation.
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
local function object(value: unknown): Object
    if type(value) == "table" then return value :: Object end
    return {}
end
local function integer(value: unknown): integer
    local number = tonumber(value)
    if not number then return 0 end
    return math.floor(number)
end
-- A reply is applied only under the current generation; anything else is a
-- late reply from a superseded binding and is dropped.
local function current(reader: Reader, generation: integer): boolean
    return reader.thread_id ~= nil and generation == reader.generation
end
-- Adopts the owner identity a reply carries. A changed durable authority is
-- a replacement owner: the projection is read from scratch, never continued.
-- A projection revision behind what the reader holds is a stale reply under
-- the same owner and moves nothing.
local function accept_owner(reader: Reader, value: Object): boolean
    local authority = tostring(value.owner_authority or "")
    local incarnation = integer(value.owner_incarnation)
    if authority == "" then return true end
    if reader.owner_authority == "" then
        reader.owner_authority = authority
        reader.owner_incarnation = incarnation
        return true
    end
    if authority ~= reader.owner_authority then
        -- A replacement owner: retire every outstanding intent by advancing
        -- the generation, so a delayed reply from the previous authority
        -- cannot switch the reader back, and read the new owner from scratch.
        reader.generation = reader.generation + 1
        reader.owner_authority = authority
        reader.owner_incarnation = incarnation
        reader.revision = 0
        reader.through_sequence = 0
        reader.head_sequence = 0
        reader.status = nil
        return true
    end
    -- Same authority: incarnation and revision compare only within it.
    if incarnation > reader.owner_incarnation then reader.owner_incarnation = incarnation end
    return true
end
function M.update_intent(reader: Reader, idempotency_key: string): Intent?
    if not reader.thread_id then return nil end
    return {generation = reader.generation, target = M.UPDATE, request = {thread_id = reader.thread_id, idempotency_key = idempotency_key}}
end
-- The bounded update advances the projection. If it stops short of the head
-- its round budget ended; the reader marks itself stale and asks for another
-- bounded refresh rather than looping until caught up.
function M.apply_update(reader: Reader, generation: integer, reply: Reply)
    if not current(reader, generation) then return end
    if not reply.ok or type(reply.value) ~= "table" then
        reader.availability = "unavailable"
        reader.detail = fault_text(reply)
        return
    end
    local value = object(reply.value)
    accept_owner(reader, value)
    local revision = integer(value.revision)
    local through = integer(value.through_sequence)
    local head = integer(value.head_sequence)
    if revision >= reader.revision then
        reader.revision = revision
        reader.through_sequence = through
    end
    reader.head_sequence = math.max(reader.head_sequence, head)
    reader.needs_refresh = reader.through_sequence < reader.head_sequence
end
function M.read_intent(reader: Reader): Intent?
    if not reader.thread_id then return nil end
    return {generation = reader.generation, target = M.READ, request = {thread_id = reader.thread_id}}
end
function M.apply_read(reader: Reader, generation: integer, reply: Reply)
    if not current(reader, generation) then return end
    if not reply.ok or type(reply.value) ~= "table" then
        reader.availability = "unavailable"
        reader.detail = fault_text(reply)
        return
    end
    local value = object(reply.value)
    local status = object(value.status)
    local activity = status.activity
    if type(value.status) ~= "table" or (activity ~= "idle" and activity ~= "running"
        and activity ~= "waiting" and activity ~= "uncertain") then
        reader.availability = "unavailable"
        reader.detail = "invalid status from the thread owner"
        return
    end
    accept_owner(reader, value)
    local revision = integer(value.revision)
    -- A read older than what the reader holds is a stale reply; keep the
    -- known status rather than moving backward.
    if revision < reader.revision and reader.status ~= nil then return end
    local through = integer(value.through_sequence)
    local head = integer(value.head_sequence)
    reader.revision = revision
    reader.through_sequence = through
    -- Projection revision and observed thread head advance independently.
    -- A read of the same projection cannot erase a head already observed.
    reader.head_sequence = math.max(reader.head_sequence, head)
    reader.status = {
        activity = tostring(status.activity or "idle"),
        waiting_on_you = status.waiting_on_you == true,
        waiting_message_ids = {},
        open_requests = integer(status.open_requests),
        pending_approvals = integer(status.pending_approvals),
        running_actions = integer(status.running_actions),
        uncertain_actions = integer(status.uncertain_actions),
        open_actions = integer(status.open_actions),
        last_outcome = status.last_outcome,
    }
    if type(status.waiting_message_ids) == "table" then
        for _, id in ipairs(status.waiting_message_ids :: {unknown}) do
            if type(id) == "string" then reader.status.waiting_message_ids[#reader.status.waiting_message_ids + 1] = id :: string end
        end
    end
    if through < reader.head_sequence then reader.availability = "stale"; reader.needs_refresh = true
    else reader.availability = "ready"; reader.detail = ""; reader.needs_refresh = false end
end
-- The change-wait watches past the last observed head: armed when the reader
-- is caught up, it wakes only when the thread moves beyond what the reader
-- has already seen. It is register-then-recheck at the owner and grants no
-- subscription progress.
function M.watch_intent(reader: Reader): Intent?
    if not reader.thread_id then return nil end
    return {generation = reader.generation, target = M.WATCH, request = {thread_id = reader.thread_id, after_sequence = reader.head_sequence, wait_ms = M.WAIT_MS}}
end
-- The change-wait is a wakeup hint only; its answer is a reason to refresh,
-- never subscription progress. It advances no cursor and reports nothing the
-- read does not.
function M.apply_watch(reader: Reader, generation: integer, reply: Reply)
    if not current(reader, generation) then return end
    if reply.ok then reader.needs_refresh = true
    else reader.availability = reader.status ~= nil and "unavailable" or reader.availability; reader.detail = fault_text(reply) end
end
-- Transport silence: the owner is unavailable; the last known status stays
-- visible, marked, and is never shown as idle.
function M.lost(reader: Reader)
    if not reader.thread_id then return end
    reader.availability = "unavailable"
    reader.detail = "no answer from the thread owner"
end
function M.needs_refresh(reader: Reader): boolean
    return reader.thread_id ~= nil and reader.needs_refresh
end
function M.value(reader: Reader): Value
    return {
        thread_id = reader.thread_id, generation = reader.generation, owner_authority = reader.owner_authority,
        owner_incarnation = reader.owner_incarnation, availability = reader.availability, detail = reader.detail,
        status = reader.status, revision = reader.revision, through_sequence = reader.through_sequence,
        head_sequence = reader.head_sequence, stale = reader.through_sequence < reader.head_sequence,
    }
end
return M
