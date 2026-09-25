-- MIT. Session-owned asynchronous status I/O. The host supplies an executor
-- under the existing viewer identity; this adapter never selects actor/scope.
local funcs = require("funcs")
local channel = require("channel")
local reader = require("reader")
local caller = require("caller")
local M = {}
type Channel = channel.Channel
type Phase = "update" | "read" | "watch"
type Start = (reader.Intent) -> (funcs.Future?, string?)
type Pending = {future: funcs.Future, response: Channel<unknown>, generation: integer, phase: Phase, deadline: integer}
type State = {reader: reader.Reader, start: Start, pending: Pending?, phase: Phase, due: integer, closed: boolean}
M.RETRY_MS = 5000
M.TIMEOUT_MS = 35000
function M.new(start: Start): State
    return {reader = reader.new(), start = start, pending = nil, phase = "update", due = 0, closed = false}
end
local function cancel(state: State)
    local pending = state.pending
    state.pending = nil
    if pending then pending.future:cancel() end
end
function M.bind(state: State, thread_id: string?, now: integer)
    if state.closed then return end
    cancel(state)
    if thread_id then reader.bind(state.reader, thread_id) else reader.unbind(state.reader) end
    state.phase = "update"
    state.due = now
end
local function failed(state: State, now: integer)
    reader.lost(state.reader)
    state.phase = "update"
    state.due = now + M.RETRY_MS
end
-- Call at most once per owner event-loop turn. now is the owner's monotonic
-- millisecond clock. A deadline retires the future before another is admitted.
function M.advance(state: State, key: string, now: integer): Pending?
    if state.closed or not state.reader.thread_id then return nil end
    local pending = state.pending
    if pending then
        if now >= pending.deadline then cancel(state); failed(state, now) end
        return state.pending
    end
    if now < state.due then return nil end
    local intent: reader.Intent? = nil
    if state.phase == "update" then intent = reader.update_intent(state.reader, key)
    elseif state.phase == "read" then intent = reader.read_intent(state.reader)
    else intent = reader.watch_intent(state.reader) end
    if not intent then return nil end
    local future, err = state.start(intent)
    if err or not future then failed(state, now); return nil end
    -- The runtime implementation always returns its response channel, while
    -- the current funcs.Future manifest exposes this method as `any`.
    local response = future:response() :: Channel<unknown>
    if not response then future:cancel(); failed(state, now); return nil end
    local admitted: Pending = {future = future, response = response, generation = intent.generation,
        phase = state.phase, deadline = now + M.TIMEOUT_MS}
    state.pending = admitted
    return admitted
end
-- Invoke only after this exact pending response channel became ready. A late
-- response from a retired future never consumes or updates the current one.
function M.complete(state: State, pending: Pending, now: integer): boolean
    if state.closed or state.pending ~= pending then return false end
    state.pending = nil
    local result, err = pending.future:result()
    if err or not result then failed(state, now); return true end
    local reply = caller.decode(result:data())
    if not reply then failed(state, now); return true end
    if pending.phase == "update" then reader.apply_update(state.reader, pending.generation, reply)
    elseif pending.phase == "read" then reader.apply_read(state.reader, pending.generation, reply)
    else reader.apply_watch(state.reader, pending.generation, reply) end
    if not reply.ok or (pending.phase == "read" and state.reader.availability == "unavailable") then
        state.phase = "update"
        state.due = now + M.RETRY_MS
    else
        if pending.phase == "update" then state.phase = "read"
        elseif pending.phase == "watch" or reader.needs_refresh(state.reader) then state.phase = "update"
        else state.phase = "watch" end
        -- Leave a scheduling boundary even when a remote reply was immediate.
        state.due = now + 1
    end
    return true
end
function M.close(state: State)
    state.closed = true
    cancel(state)
    reader.unbind(state.reader)
end
return M
