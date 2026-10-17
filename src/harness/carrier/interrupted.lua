-- MIT. Settle an interrupted window only after native exit is observed and
-- recoverable hook deliveries have drained under a fresh carrier epoch.
local checkpoint_types = require("checkpoint_types")
local continuation = require("continuation")
local checkpoint = require("checkpoint")
local bounds = require("bounds")
local hooks = require("hooks")
local delivery = require("delivery")
local records = require("records")
local funcs = require("funcs")
local channel = require("channel")
local time = require("time")
local uuid = require("uuid")
local prestart = require("prestart")
local M = {}
type RawCall = (string, unknown) -> (unknown, string?)
type Resume = (hooks.Config, checkpoint_types.Checkpoint?, integer) -> (hooks.State?, string?)
local function placement_target(request: continuation.Request, method: string): string?
    return request.placement_methods[method]
end
local BUDGET_MS = 5000
local function now(): integer return math.floor(time.now():unix_nano() / 1000000) end
local function key(): string
    local id, err = uuid.v7()
    if not id then error(tostring(err)) end
    return id
end
local function call(raw_call: RawCall, target: string, request: unknown): ({[string]: unknown}?, string?)
    local raw, err = raw_call(target, request)
    if err then return nil, tostring(err) end
    local reply = bounds.object(raw)
    if not reply or reply.ok ~= true then return nil, target .. " refused recovery" end
    local value = bounds.object(reply.value)
    if not value then return nil, target .. " returned invalid recovery data" end
    return value, nil
end
local function matches(attempt: {[string]: unknown}, request: continuation.Request): boolean
    return attempt.attempt_id == request.previous_attempt_id and attempt.action_id == request.action_id
        and attempt.owner_id == request.owner_id and attempt.session_ref == request.session_ref
end
-- A window that closed before its process started leaves its attempt
-- prepared without a checkpoint. A new carrier epoch fences it; placement
-- proves no child started, and the attempt settles as failed.
local function settle_unstarted(raw_call: RawCall, request: continuation.Request, stored: {[string]: unknown}): (boolean, string?)
    local claimed, claim_error = call(raw_call, "bee.threads.binding:claim", {thread_id = request.thread_id,
        attempt_id = request.previous_attempt_id, idempotency_key = key()})
    if not claimed then return false, claim_error end
    local epoch = bounds.integer(claimed.carrier_epoch)
    if claimed.attempt_id ~= request.previous_attempt_id or not epoch or epoch < 1 then return false, "carrier claim belongs to another attempt" end
    local inspection = prestart.inspect(raw_call, placement_target(request, "status"), placement_target(request, "stop"),
        bounds.id(stored.placement_attempt_id) or request.previous_attempt_id, "failed", "the window closed before its process started")
    if inspection.outcome ~= "failed" then return false, continuation.MAY_RUN end
    local failure = {code = "launch_failed", message = inspection.reason, retryable = false}
    local turn_id = bounds.id(stored.open_turn_id)
    if turn_id then
        local ended, end_error = call(raw_call, "bee.threads.binding:end_turn", {thread_id = request.thread_id, action_id = request.action_id,
            attempt_id = request.previous_attempt_id, turn_id = turn_id, carrier_epoch = epoch, idempotency_key = key(),
            turn_end = {outcome = "failed", answer_message_ids = {}, evidence_refs = {}, error = failure}})
        if not ended then return false, end_error end
    end
    local settled, settle_error = call(raw_call, "bee.threads.binding:receipt", {thread_id = request.thread_id,
        idempotency_key = "launch:" .. request.previous_attempt_id .. ":window:unstarted:" .. tostring(epoch),
        action_id = request.action_id, attempt_id = request.previous_attempt_id, carrier_epoch = epoch,
        receipt = {scope = "attempt", outcome = "failed", evidence_refs = {}, error = failure}})
    if not settled then return false, settle_error end
    return true, nil
end
function M.recover(request: continuation.Request, call_override: RawCall?, resume_override: Resume?): (boolean, string?)
    local raw_call: RawCall
    if call_override then
        raw_call = call_override
    else
        raw_call = function(target: string, input: unknown): (unknown, string?)
            local raw, err = funcs.call(target, input)
            if err then return nil, tostring(err) end
            return raw, nil
        end
    end
    local resume: Resume
    if resume_override then
        resume = resume_override
    else
        resume = hooks.resume
    end
    local unstarted, unstarted_error = continuation.unstarted(raw_call, request)
    if unstarted_error then return false, unstarted_error end
    if unstarted then
        if unstarted.attempt_state == "ended" then return true, nil end
        return settle_unstarted(raw_call, request, unstarted)
    end
    local previous, invalid = continuation.inspect_window(function(target: string, input: unknown): (unknown, string?)
        local raw, err = raw_call(target, input)
        if err then return nil, tostring(err) end
        return raw, nil
    end, request, false)
    if invalid == continuation.NEVER_RECORDED then return true, nil end
    if not previous then return false, invalid end
    if previous.stored.attempt_state == "ended" then return true, nil end
    -- Reconciliation observes the recorded native identity; a dead presenter
    -- or a copied checkpoint cannot establish process exit.
    local reconcile_target = placement_target(request, "reconcile")
    if not reconcile_target then return false, "placement binding has no reconcile method" end
    local native, native_error = call(raw_call, reconcile_target, {attempt_id = request.previous_attempt_id})
    if not native then return false, native_error end
    if not matches(native, request) or not continuation.process_gone(native.execution_state) then
        return false, continuation.MAY_RUN
    end
    local claimed, claim_error = call(raw_call, "bee.threads.binding:claim", {thread_id = request.thread_id,
        attempt_id = request.previous_attempt_id, idempotency_key = key()})
    if not claimed then return false, claim_error end
    if claimed.attempt_id ~= request.previous_attempt_id or claimed.action_id ~= request.action_id then
        return false, "carrier claim belongs to another attempt"
    end
    local epoch, revision = bounds.integer(claimed.carrier_epoch), bounds.integer(claimed.checkpoint_revision)
    local point, decode_error = checkpoint.decode(claimed.checkpoint)
    if not epoch or epoch < 1 or not revision or revision < 1 or not point then
        return false, "invalid recovered checkpoint: " .. tostring(decode_error)
    end
    if not point.plan_digest then return false, "recovered checkpoint has no plan digest" end
    local state, state_error = resume({thread_id = request.thread_id, attempt_id = request.previous_attempt_id,
        epoch = epoch, binding_ref = previous.point.binding_ref, binding_digest = previous.point.binding_digest,
        profile_id = previous.point.profile_id, profile_digest = previous.point.profile_digest,
        plan_digest = point.plan_digest, session_ref = request.session_ref,
        gateway_binding = previous.binding, hooks_enabled = true, drain_ms = BUDGET_MS, decoder = records.batch}, point, revision)
    if not state then return false, state_error end
    local driver = delivery.new(state, function(intent: hooks.Intent): (funcs.Future?, string?)
        local future, err = funcs.async(intent.target, intent.request)
        if err then return nil, tostring(err) end
        return future, nil
    end, key)
    local deadline = now() + BUDGET_MS
    local draining = false
    while now() < deadline do
        if hooks.may_start(state) and not draining then
            delivery.shutdown(driver, now(), false)
            draining = true
        end
        if hooks.finished(state) then break end
        local pending = delivery.advance(driver, now())
        local timer = assert(time.timer(tostring(math.max(1, math.min(delivery.due(driver), deadline) - now())) .. "ms"))
        local cases = {timer:channel():case_receive()}
        if pending then cases[#cases + 1] = pending.response:case_receive() end
        local selected = channel.select(cases)
        timer:stop()
        if pending and selected.channel == pending.response then delivery.complete(driver, pending, now()) end
    end
    delivery.cancel(driver)
    if not draining or not hooks.finished(state) or state.unresolved then
        return false, "interrupted window hooks are not fully drained"
    end
    local settled, settle_error = call(raw_call, "bee.threads.binding:receipt", {thread_id = request.thread_id,
        idempotency_key = "launch:" .. request.previous_attempt_id .. ":window:recovered:" .. tostring(epoch),
        action_id = request.action_id, attempt_id = request.previous_attempt_id, carrier_epoch = epoch,
        receipt = {scope = "attempt", outcome = "uncertain", evidence_refs = {},
            error = {code = "native_window_interrupted", message = "native process exited without its window owner; recoverable hook deliveries reconciled", retryable = false}}})
    if not settled then return false, settle_error end
    return true, nil
end
return M
