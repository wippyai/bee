-- MIT. One ordered hook batch per window. Commit requests survive lost
-- replies; only owner-confirmed commits may be acknowledged at the gateway.
local checkpoint = require("checkpoint")
local bounds = require("bounds")
local M = {}
M.COMMIT = "bee.threads.carrier:commit"
M.CLAIM = "bee.gateway:hook_claim"
M.ACK = "bee.gateway:hook_ack"
M.SEAL = "bee.gateway:seal"
M.IDLE_MS = 1000
M.RETRY_MS = 1000
M.CLAIM_LIMIT = 16
type Object = {[string]: unknown}
type Work = "checkpoint" | "claim" | "commit" | "ack" | "seal" | "idle" | "done"
type Batch = {records: {{[string]: unknown}}, event_ids: {string}, activity: string?}
type Decoder = (string, string?, unknown) -> (Batch?, string?)
type Reply = {ok: boolean, error: {code: string, message: string}?, value: unknown, replayed: boolean?}
type Intent = {target: string, request: Object}
type InFlight = {identity: string, intent: Intent}
type Config = {
    thread_id: string, attempt_id: string, epoch: integer,
    binding_ref: string, binding_digest: string, profile_id: string,
    profile_digest: string, plan_digest: string, session_ref: string?,
    gateway_binding: string?, hooks_enabled: boolean, drain_ms: integer, decoder: Decoder,
}
type State = {
    thread_id: string, attempt_id: string, epoch: integer, revision: integer,
    binding_id: string?, checkpoint: checkpoint.Checkpoint,
    hooks_enabled: boolean, drain_ms: integer, decoder: Decoder,
    work: Work, due: integer, clock: integer, inflight: InFlight?,
    batch: Batch?, checkpoint_intent: Intent?, commit: Intent?, ack: Intent?,
    closing: boolean, closed: boolean, sealed: boolean, started: boolean,
    drain_deadline: integer?, unresolved: boolean,
    activity: string?,
}
local function object(value: unknown): Object
    return bounds.object(value) or {}
end
local function definite(reply: Reply): boolean
    local fault = reply.error
    if not fault then return false end
    return fault.code == "CONFLICT" or fault.code == "DENIED" or fault.code == "INVALID"
        or fault.code == "INVALID_ARGUMENT" or fault.code == "UNAUTHENTICATED" or fault.code == "NOT_FOUND"
end
local function retry(state: State)
    state.due = state.clock + M.RETRY_MS
end
local function failed(state: State, reply: Reply): boolean
    if reply.ok then return false end
    if definite(reply) then
        state.unresolved = true
        state.work = "done"
    else
        retry(state)
    end
    return true
end
local function valid_revision(state: State, value: unknown): boolean
    local result = object(value)
    return result.attempt_id == state.attempt_id and result.carrier_epoch == state.epoch
        and bounds.integer(result.checkpoint_revision) == state.revision + 1
end
local function idle(state: State)
    state.work = state.closing and "done" or "idle"
    state.due = state.clock + M.IDLE_MS
end
function M.new(config: Config): State
    local point = checkpoint.new({binding_ref = config.binding_ref, binding_digest = config.binding_digest,
        profile_id = config.profile_id, profile_digest = config.profile_digest,
        plan_digest = config.plan_digest, gateway_binding = config.gateway_binding}, config.epoch)
    point.retained_session_ref = config.session_ref
    return {
        thread_id = config.thread_id, attempt_id = config.attempt_id, epoch = config.epoch, revision = 0,
        binding_id = config.gateway_binding, checkpoint = point,
        hooks_enabled = config.hooks_enabled and config.gateway_binding ~= nil,
        drain_ms = config.drain_ms, decoder = config.decoder,
        work = "checkpoint", due = 0, clock = 0, inflight = nil,
        batch = nil, checkpoint_intent = nil, commit = nil, ack = nil,
        closing = false, closed = false, sealed = false, started = false,
        drain_deadline = nil, unresolved = false, activity = nil,
    }
end
function M.decode(raw: unknown): Reply?
    local reply = bounds.object(raw)
    if not reply or type(reply.ok) ~= "boolean" then return nil end
    local fault: {code: string, message: string}? = nil
    if not reply.ok then
        local declared = bounds.object(reply.error)
        if not declared then return nil end
        local code, message = bounds.line(declared.code, 80), bounds.text(declared.message, 4096)
        if not code or code == "" or not message then return nil end
        fault = {code = code, message = message}
    end
    return {ok = reply.ok, error = fault, value = reply.value, replayed = reply.replayed == true}
end
function M.next_intent(state: State, key: string, now: integer): Intent?
    if key == "" then return nil end
    state.clock = now
    if state.inflight or state.work == "done" or now < state.due then return nil end
    if state.work == "checkpoint" then
        if not state.checkpoint_intent then
            state.checkpoint_intent = {target = M.COMMIT, request = {
                thread_id = state.thread_id, idempotency_key = "launch:" .. state.attempt_id .. ":window:checkpoint",
                attempt_id = state.attempt_id, carrier_epoch = state.epoch, expected_revision = 0,
                checkpoint = state.checkpoint, records = {},
            }}
        end
        return state.checkpoint_intent
    end
    if state.work == "commit" then return state.commit end
    if state.work == "ack" then return state.ack end
    local binding_id = state.binding_id
    if not binding_id or not state.hooks_enabled then return nil end
    if state.work == "seal" then return {target = M.SEAL, request = {binding_id = binding_id}} end
    state.work = "claim"
    return {target = M.CLAIM, request = {binding_id = binding_id, carrier_epoch = state.epoch, limit = M.CLAIM_LIMIT}}
end
function M.begin(state: State, identity: string, intent: Intent): boolean
    if state.inflight or identity == "" or state.work == "done" then return false end
    state.inflight = {identity = identity, intent = intent}
    return true
end
function M.lost(state: State, identity: string): boolean
    local inflight = state.inflight
    if not inflight or inflight.identity ~= identity then return false end
    state.inflight = nil
    retry(state)
    return true
end
function M.backoff(state: State, now: integer)
    state.clock = now
    retry(state)
end
function M.apply(state: State, identity: string, reply: Reply): boolean
    local inflight = state.inflight
    if not inflight or inflight.identity ~= identity then return false end
    state.inflight = nil
    if failed(state, reply) then return true end
    local result = object(reply.value)
    if state.work == "checkpoint" or state.work == "commit" then
        if not valid_revision(state, reply.value) then retry(state); return true end
        state.revision = state.revision + 1
        if state.work == "checkpoint" then
            state.started = true
            state.work = "idle"
        else
            local batch, binding_id = state.batch, state.binding_id
            if not batch or not binding_id then
                state.unresolved = true
                state.work = "done"
                return true
            end
            state.ack = {target = M.ACK, request = {binding_id = binding_id, carrier_epoch = state.epoch, event_ids = batch.event_ids}}
            state.activity = batch.activity or state.activity
            state.commit = nil
            state.work = "ack"
        end
    elseif state.work == "claim" then
        local binding_id = state.binding_id
        if not binding_id or result.binding_id ~= binding_id or result.carrier_epoch ~= state.epoch then retry(state); return true end
        local batch, err = state.decoder(binding_id, nil, result.hooks)
        if not batch or err then retry(state); return true end
        if #batch.event_ids == 0 then idle(state); return true end
        state.batch = batch
        state.commit = {target = M.COMMIT, request = {
            thread_id = state.thread_id, idempotency_key = "launch:" .. state.attempt_id .. ":window:hooks:" .. tostring(state.revision),
            attempt_id = state.attempt_id, carrier_epoch = state.epoch, expected_revision = state.revision,
            checkpoint = state.checkpoint, records = batch.records,
        }}
        state.work = "commit"
    elseif state.work == "ack" then
        local count, batch = bounds.integer(result.acknowledged), state.batch
        -- An exact retry may acknowledge zero: the first call committed the
        -- whole transaction but its reply was lost. IDs come from this claim.
        if result.binding_id ~= state.binding_id or not count or count < 0 or not batch or count > #batch.event_ids then retry(state); return true end
        state.ack, state.batch = nil, nil
        state.work = "claim"
    elseif state.work == "seal" then
        if result.binding_id ~= state.binding_id or result.sealed ~= true then retry(state); return true end
        state.sealed = true
        state.work = state.commit and "commit" or (state.ack and "ack" or "claim")
    end
    state.due = state.clock
    return true
end
function M.shutdown(state: State, now: integer, closed: boolean)
    state.clock = now
    if closed then state.closed = true end
    if state.closing then return end
    state.closing = true
    state.drain_deadline = now + state.drain_ms
    state.inflight = nil
    state.due = now
    if state.unresolved or not state.hooks_enabled or not state.binding_id then
        state.work = "done"
    else
        state.work = "seal"
    end
end
function M.expire(state: State, now: integer)
    state.clock = now
    local deadline = state.drain_deadline
    if state.work == "done" or not deadline or now < deadline then return end
    state.unresolved = true
    state.inflight = nil
    state.work = "done"
    state.due = now
end
function M.may_start(state: State): boolean return state.started end
function M.finished(state: State): boolean return state.work == "done" and state.inflight == nil end
function M.outcome(state: State): "cancelled" | "uncertain"
    if state.unresolved or not state.closed or not M.finished(state) then return "uncertain" end
    return "cancelled"
end
return M
