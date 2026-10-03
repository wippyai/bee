-- MIT. Shared managed-run state transitions for placed and in-process drivers.
local funcs = require("funcs")
local time = require("time")
local process = require("process")
local registry = require("registry")
local bounds = require("bounds")
local placement_resolver = require("placement_resolver")
local placement_decode = require("placement_decode")
local prestart = require("prestart")

local M = {}
local MAX_ANSWER_BYTES = 16384
local CARRIER = "bee.threads.binding"
local THREADS = "bee.threads.binding"
local DELIVERY = "bee.threads.binding"
local CHECKPOINT = CARRIER .. ":checkpoint"
local CANCEL_INTENT = CARRIER .. ":cancel_intent"
local CANCEL_STATUS = CARRIER .. ":cancel_status"
local RECEIPT = THREADS .. ":receipt"
local THREAD = THREADS .. ":get"
local WATCH = DELIVERY .. ":watch"

type Reply = {ok: boolean, error: {code: string, message: string}?, value: unknown}
type Run = {thread_id: string, attempt_id: string}
type Status = {thread_id: string, attempt_id: string, state: string, outcome: string?, answer: string?, error: {[string]: unknown}?}
type Stop = ({[string]: unknown}) -> (boolean, Reply?)
type StatusOptions = {carrier_epoch_starts: boolean?, cancel_status_first: boolean?,
    cancel_status_pending: boolean?, tolerate_checkpoint_failure: boolean?, reconcile_prestart: boolean?}
type CancelOptions = {prestart: string?, stop: Stop?}
type Context = {thread_id: string, action_id: string, attempt_id: string, carrier_epoch: integer,
    checkpoint_revision: integer, checkpoint: unknown, cancelled: () -> boolean,
    commit: (string, {{[string]: unknown}}, {[string]: unknown}) -> (boolean, string?)}
type ExecutionResult = {outcome: string, answer: string?, error: string?, settle: boolean?, checkpoint: {[string]: unknown}?}
type Adapter = (Context, {[string]: unknown}) -> ExecutionResult
type ExecutionRequest = {thread_id: string, action_id: string, attempt_id: string,
    idempotency_key: string?, carrier_epoch: integer?}

local function fail(code: string, message: string): Reply
    return {ok = false, error = {code = code, message = message}, value = nil}
end

local function answer_of(value: unknown): ({[string]: unknown}?, Reply?)
    local object = bounds.object(value)
    if not object then return nil, fail("INTERNAL", "the owner returned a malformed reply") end
    if object.ok ~= true then
        local fault = bounds.object(object.error)
        return nil, fail(tostring(fault and fault.code or "REFUSED"), tostring(fault and fault.message or "the owner refused"))
    end
    local result = bounds.object(object.value)
    if not result then return nil, fail("INTERNAL", "the owner returned no value") end
    return result, nil
end

local function call(target: string, request: unknown): ({[string]: unknown}?, Reply?)
    local raw, call_error = funcs.call(target, request)
    if call_error then return nil, fail("UNAVAILABLE", tostring(call_error)) end
    return answer_of(raw)
end

local function raw_call(target: string, request: unknown): (unknown, string?)
    return funcs.call(target, request)
end

local function checkpoint_intent(stored: {[string]: unknown}): (string?, string?)
    local intent = bounds.object(stored.cancel_intent)
    local state = intent and bounds.member(intent.state, {"cancelling", "ended"})
    if not state then return nil, nil end
    return state, bounds.member(intent.outcome, {"succeeded", "failed", "cancelled", "uncertain"})
end

local function carrier_active(attempt_id: string): (boolean?, string?)
    local pid, lookup_error = process.registry.lookup(prestart.CARRIER_REGISTRY_PREFIX .. attempt_id)
    if lookup_error and errors.is(lookup_error, errors.NOT_FOUND) then return false, nil end
    if lookup_error then return nil, tostring(lookup_error) end
    return pid ~= nil, nil
end

local function reconcile_orphan_prestart(run: Run, stored: {[string]: unknown}): Reply?
    if stored.attempt_state ~= "prepared" or (bounds.count(stored.carrier_epoch) or 0) < 1 then return nil end
    local active, active_error = carrier_active(run.attempt_id)
    if active_error then return fail("UNAVAILABLE", "carrier liveness could not be checked: " .. active_error) end
    if active then return nil end

    local outcome = "failed"
    local reason = "carrier exited during launch preparation"
    local placement_binding = bounds.id(stored.placement_binding)
    local placement_attempt = bounds.id(stored.placement_attempt_id)
    if placement_binding and placement_attempt then
        local pinned, pin_error = registry.snapshot()
        if not pinned then
            outcome = "uncertain"
            reason = reason .. "; placement could not be inspected: " .. tostring(pin_error or "registry snapshot")
        else
            local placement, placement_error = placement_resolver.resolve(pinned, placement_binding)
            if not placement then
                outcome = "uncertain"
                reason = reason .. "; placement could not be inspected: " .. tostring(placement_error or "placement binding")
            else
                local inspection = prestart.inspect(raw_call, placement.methods.status, placement.methods.stop,
                    placement_attempt, outcome, reason)
                outcome, reason = inspection.outcome, inspection.reason
            end
        end
    else
        reason = reason .. "; no placement attempt identity was recorded"
    end

    local epoch = bounds.count(stored.carrier_epoch)
    local action_id = bounds.id(stored.action_id)
    if not epoch or not action_id then return fail("INTERNAL", "the prepared attempt has no carrier epoch or action") end
    local code = outcome == "failed" and "carrier_lost" or "carrier_lost_uncertain"
    local failure = {code = code, message = reason, retryable = false}
    local turn_id = bounds.id(stored.open_turn_id)
    if turn_id then
        local _, end_refused = call(THREADS .. ":end_turn", {thread_id = run.thread_id, action_id = action_id,
            attempt_id = run.attempt_id, turn_id = turn_id, carrier_epoch = epoch,
            idempotency_key = "reconcile:" .. run.attempt_id .. ":end_turn",
            turn_end = {outcome = outcome, answer_message_ids = {}, evidence_refs = {}, error = failure}})
        if end_refused then return end_refused end
    end
    local _, receipt_refused = call(RECEIPT, {thread_id = run.thread_id, action_id = action_id, attempt_id = run.attempt_id,
        carrier_epoch = epoch, idempotency_key = "reconcile:" .. run.attempt_id .. ":receipt",
        receipt = {scope = "attempt", outcome = outcome, evidence_refs = {}, error = failure}})
    return receipt_refused
end

local function reconcile_orphan_running(run: Run, stored: {[string]: unknown}): Reply?
    if stored.attempt_state ~= "running" or (bounds.count(stored.carrier_epoch) or 0) < 1 then return nil end
    local active, active_error = carrier_active(run.attempt_id)
    if active_error then return fail("UNAVAILABLE", "carrier liveness could not be checked: " .. active_error) end
    if active then return nil end

    local placement_binding = bounds.id(stored.placement_binding)
    local placement_attempt = bounds.id(stored.placement_attempt_id)
    if not placement_binding or not placement_attempt then return nil end
    local pinned, pin_error = registry.snapshot()
    if not pinned then return fail("UNAVAILABLE", "placement status could not be inspected: " .. tostring(pin_error or "registry snapshot")) end
    local placement, placement_error = placement_resolver.resolve(pinned, placement_binding)
    if not placement then return fail("UNAVAILABLE", placement_error or "placement binding") end
    local status_target = placement.methods.status
    if not status_target then return fail("UNAVAILABLE", "placement binds no status operation") end
    local raw, call_error = raw_call(status_target, {attempt_id = placement_attempt})
    if call_error then return fail("UNAVAILABLE", "placement status failed: " .. tostring(call_error)) end
    local reply = bounds.object(raw)
    if not reply then return fail("INTERNAL", "placement returned a malformed status reply") end
    if reply.ok ~= true then
        local fault = bounds.object(reply.error)
        local code = bounds.member(fault and fault.code, {"NOT_FOUND", "DENIED", "INVALID_ARGUMENT", "UNAVAILABLE", "INTERNAL"})
        if code == "NOT_FOUND" then return nil end
        return fail(code or "REFUSED", tostring(fault and fault.message or "placement status refused"))
    end
    local observed, decode_error = placement_decode.status(reply.value)
    if not observed then return fail("INTERNAL", "placement status is malformed: " .. tostring(decode_error)) end
    if observed.attempt.execution_state ~= "exited"
        or observed.liveness.observed ~= true or observed.liveness.alive ~= false then
        return nil
    end
    if observed.attempt.runner ~= nil then
        local evidence_target = placement.methods.evidence
        if not evidence_target then return fail("UNAVAILABLE", "placement binds no evidence operation") end
        local after = math.max(0, observed.attempt.evidence_count - 64)
        local page, evidence_refused = call(evidence_target,
            {attempt_id = placement_attempt, after = after, limit = 64})
        if not page then return evidence_refused or fail("UNAVAILABLE", "placement evidence did not answer") end
        local evidence = bounds.array(page.evidence, 64)
        if not evidence then return fail("INTERNAL", "placement evidence is malformed") end
        local latest_runner_start, latest_runner_finish = 0, 0
        for _, raw_evidence in ipairs(evidence) do
            local item = bounds.object(raw_evidence)
            local sequence = item and bounds.count(item.sequence)
            local kind = item and bounds.text(item.kind, 128)
            if sequence and kind == "runner.started" then latest_runner_start = math.max(latest_runner_start, sequence)
            elseif sequence and kind == "runner.finished" then latest_runner_finish = math.max(latest_runner_finish, sequence) end
        end
        if latest_runner_finish == 0 or latest_runner_finish < latest_runner_start then return nil end
    end

    local epoch = bounds.count(stored.carrier_epoch)
    local action_id = bounds.id(stored.action_id)
    if not epoch or not action_id then return fail("INTERNAL", "the running attempt has no carrier epoch or action") end
    local failure = {code = "carrier_lost", message = "the carrier exited before recording a terminal receipt; placement confirmed the child process exited", retryable = false}
    local turn_id = bounds.id(stored.open_turn_id)
    if turn_id then
        local _, end_refused = call(THREADS .. ":end_turn", {thread_id = run.thread_id, action_id = action_id,
            attempt_id = run.attempt_id, turn_id = turn_id, carrier_epoch = epoch,
            idempotency_key = "reconcile:" .. run.attempt_id .. ":end_turn",
            turn_end = {outcome = "uncertain", answer_message_ids = {}, evidence_refs = {}, error = failure}})
        if end_refused then return end_refused end
    end
    local _, receipt_refused = call(RECEIPT, {thread_id = run.thread_id, action_id = action_id, attempt_id = run.attempt_id,
        carrier_epoch = epoch, idempotency_key = "reconcile:" .. run.attempt_id .. ":receipt",
        receipt = {scope = "attempt", outcome = "uncertain", evidence_refs = {}, error = failure}})
    return receipt_refused
end

function M.status(run: Run, options: StatusOptions?): (Status?, Reply?, {[string]: unknown}?)
    local opts = options or {}
    if opts.cancel_status_first then
        local intent, intent_refused = call(CANCEL_STATUS, {thread_id = run.thread_id, attempt_id = run.attempt_id})
        if intent then
            if bounds.member(intent.state, {"cancelling", "ended"}) then
                return {thread_id = run.thread_id, attempt_id = run.attempt_id,
                    state = intent.state == "ended" and "ended" or "cancelling", outcome = "cancelled"}, nil, nil
            end
        elseif intent_refused and intent_refused.error and intent_refused.error.code ~= "NOT_FOUND" and not opts.tolerate_checkpoint_failure then
            return nil, intent_refused, nil
        end
    end

    local stored, refused = call(CHECKPOINT, {thread_id = run.thread_id, attempt_id = run.attempt_id})
    if not stored then
        if refused and refused.error and refused.error.code == "NOT_FOUND" then
            local intent, intent_refused = call(CANCEL_STATUS, {thread_id = run.thread_id, attempt_id = run.attempt_id})
            if intent and bounds.member(intent.state, {"ended"}) then
                return {thread_id = run.thread_id, attempt_id = run.attempt_id, state = "ended", outcome = "cancelled"}, nil, nil
            end
            if intent and opts.cancel_status_pending and bounds.member(intent.state, {"cancelling"}) then
                return {thread_id = run.thread_id, attempt_id = run.attempt_id, state = "cancelling", outcome = "cancelled"}, nil, nil
            end
            if intent_refused and intent_refused.error and intent_refused.error.code ~= "NOT_FOUND" and not opts.tolerate_checkpoint_failure then
                return nil, intent_refused, nil
            end
            return {thread_id = run.thread_id, attempt_id = run.attempt_id, state = "starting"}, nil, nil
        end
        if opts.tolerate_checkpoint_failure then
            return {thread_id = run.thread_id, attempt_id = run.attempt_id, state = "starting"}, nil, nil
        end
        return nil, refused, nil
    end

    if opts.reconcile_prestart then
        local reconcile_refused = reconcile_orphan_prestart(run, stored)
        if reconcile_refused then return nil, reconcile_refused, stored end
        if stored.attempt_state == "prepared" then
            local refreshed, refresh_refused = call(CHECKPOINT, {thread_id = run.thread_id, attempt_id = run.attempt_id})
            if refreshed then stored = refreshed
            elseif refresh_refused then return nil, refresh_refused, stored end
        elseif stored.attempt_state == "running" then
            local orphan_refused = reconcile_orphan_running(run, stored)
            if orphan_refused then return nil, orphan_refused, stored end
            local refreshed, refresh_refused = call(CHECKPOINT, {thread_id = run.thread_id, attempt_id = run.attempt_id})
            if refreshed then stored = refreshed
            elseif refresh_refused then return nil, refresh_refused, stored end
        end
    end

    local ended = stored.attempt_state == "ended"
    local state = "starting"
    if ended then
        state = "ended"
    elseif stored.attempt_state == "running" or (opts.carrier_epoch_starts and stored.carrier_epoch ~= nil) then
        state = "running"
    end
    local answer: string? = nil
    local checkpoint = bounds.object(stored.checkpoint)
    local terminal = checkpoint and bounds.object(checkpoint.terminal)
    local failure = ended and (bounds.object(stored.attempt_error) or (terminal and bounds.object(terminal.error))) or nil
    if ended and terminal then answer = bounds.text(terminal.answer, MAX_ANSWER_BYTES) end
    if not ended then
        local intent_state = checkpoint_intent(stored)
        if intent_state == "ended" then
            return {thread_id = run.thread_id, attempt_id = run.attempt_id, state = "ended", outcome = "cancelled"}, nil, stored
        elseif intent_state == "cancelling" and state == "running" then
            return {thread_id = run.thread_id, attempt_id = run.attempt_id, state = "cancelling"}, nil, stored
        end
    end
    local outcome = ended and bounds.member(stored.attempt_outcome, {"succeeded", "failed", "cancelled", "uncertain"}) or nil
    if ended and not outcome and terminal then
        outcome = bounds.member(terminal.outcome, {"succeeded", "failed", "cancelled", "uncertain"})
    end
    return {thread_id = run.thread_id, attempt_id = run.attempt_id, state = state,
        outcome = outcome, answer = answer, error = failure}, nil, stored
end

function M.wait(run: Run, wait_ms: integer, options: StatusOptions?): Reply
    local thread, thread_refused = call(THREAD, {thread_id = run.thread_id})
    if not thread then return thread_refused or fail("UNAVAILABLE", "the thread did not answer") end
    local summary = bounds.object(thread.summary)
    local head = summary and bounds.count(summary.head_sequence)
    if not head then return fail("INTERNAL", "the thread has no head sequence") end
    local current, refused = M.status(run, options)
    if not current then return refused or fail("UNAVAILABLE", "the attempt did not answer") end
    if current.state == "ended" or wait_ms == 0 then return {ok = true, error = nil, value = current} end
    local _, watch_refused = call(WATCH, {thread_id = run.thread_id, after_sequence = head, wait_ms = wait_ms})
    if watch_refused then return watch_refused end
    local after, after_refused = M.status(run, options)
    if not after then return after_refused or fail("UNAVAILABLE", "the attempt did not answer") end
    return {ok = true, error = nil, value = after}
end

local function record_intent(run: Run, state: string, outcome: string?, idempotency_key: string?): Reply?
    local request: {[string]: unknown} = {thread_id = run.thread_id, attempt_id = run.attempt_id, state = state}
    if outcome ~= nil then request.outcome = outcome end
    if idempotency_key ~= nil then request.idempotency_key = idempotency_key end
    local _, refused = call(CANCEL_INTENT, request)
    return refused
end

local function settle_before_start(run: Run, action_id: string): Reply?
    local fresh, _, fresh_stored = M.status(run)
    if not fresh or fresh.state == "ended" or fresh.state == "running" or fresh.state == "cancelling" or not fresh_stored then
        return nil
    end
    local fresh_action = bounds.id(fresh_stored.action_id) or action_id
    local _, refused = call(RECEIPT, {thread_id = run.thread_id,
        idempotency_key = "cancel:" .. run.attempt_id .. ":receipt", action_id = fresh_action,
        attempt_id = run.attempt_id, receipt = {scope = "attempt", outcome = "cancelled", evidence_refs = {},
            error = {code = "cancelled", message = "the run was cancelled before its child started", retryable = false}}})
    return refused
end

function M.cancel(run: Run, wait_ms: integer?, idempotency_key: string?, options: CancelOptions?): Reply
    local opts = options or {}
    local budget: integer = wait_ms or 0
    local current, refused, stored = M.status(run)
    if not current then return refused or fail("UNAVAILABLE", "the attempt did not answer") end
    if current.state == "ended" then return {ok = true, error = nil, value = current} end

    if budget == 0 then
        local before_start = not stored or (current.state ~= "running" and current.state ~= "cancelling")
        if before_start and idempotency_key ~= nil and opts.prestart ~= "signal" then
            local intent_refused = record_intent(run, "ended", "cancelled", idempotency_key)
            if intent_refused then return intent_refused end
            if stored then
                local action_id = bounds.id(stored.action_id)
                if action_id then settle_before_start(run, action_id) end
            end
            local final = M.status(run)
            if final and final.state == "ended" then return {ok = true, error = nil, value = final} end
            return {ok = true, error = nil, value = {thread_id = run.thread_id, attempt_id = run.attempt_id,
                state = "ended", outcome = "cancelled"}}
        end
        if before_start and opts.prestart ~= "signal" then
            local intent_refused = record_intent(run, "cancelling", nil, idempotency_key)
            if intent_refused then return intent_refused end
            return fail("NOT_STARTED", "the attempt's child has not started yet")
        end
        local intent_refused = record_intent(run, "cancelling", nil, idempotency_key)
        if intent_refused then return intent_refused end
        if opts.stop then
            local stopped, stop_refused = opts.stop(stored or {})
            if not stopped then return stop_refused or fail("UNAVAILABLE", "stop failed") end
        end
        return {ok = true, error = nil, value = {thread_id = run.thread_id, attempt_id = run.attempt_id, state = "cancelling"}}
    end

    local intent_refused = record_intent(run, "cancelling", nil, idempotency_key)
    if intent_refused then return intent_refused end
    local deadline = math.floor(time.now():unix_nano() / 1000000) + budget
    local stopped = false
    while math.floor(time.now():unix_nano() / 1000000) < deadline do
        if not stopped then
            local live, status_error, cur_stored = M.status(run)
            if not live then return status_error or fail("UNAVAILABLE", "the attempt did not answer") end
            if live and live.state == "ended" then return {ok = true, error = nil, value = live} end
            if live and (live.state == "running" or live.state == "cancelling") and cur_stored then
                if opts.stop then
                    local ok_stop, stop_refused = opts.stop(cur_stored)
                    if ok_stop then
                        stopped = true
                    else
                        return stop_refused or fail("UNAVAILABLE", "stop failed")
                    end
                else
                    stopped = true
                end
            else
                time.sleep("50ms")
            end
        else
            local remaining = deadline - math.floor(time.now():unix_nano() / 1000000)
            if remaining <= 0 then break end
            local wait_slice = remaining > 1000 and 1000 or remaining
            local wait_reply = M.wait(run, wait_slice)
            if not wait_reply.ok then return wait_reply end
            if wait_reply.value then
                local after = bounds.object(wait_reply.value)
                if after and after.state == "ended" then return {ok = true, error = nil, value = after} end
            end
        end
    end

    local final_status, final_error = M.status(run)
    if not final_status then return final_error or fail("UNAVAILABLE", "the attempt did not answer") end
    if final_status and final_status.state == "ended" then return {ok = true, error = nil, value = final_status} end
    return fail("DEADLINE_EXCEEDED", "Cancellation observation wait_ms=" .. tostring(budget) .. " expired; recorded state=" .. tostring(final_status.state))
end

function M.cancelled(run: Run): boolean
    local intent = call(CANCEL_STATUS, {thread_id = run.thread_id, attempt_id = run.attempt_id})
    return intent ~= nil and bounds.member(intent.state, {"cancelling", "ended"}) ~= nil
end

function M.execute(request: ExecutionRequest, adapter: Adapter): {[string]: unknown}
    local thread_id, action_id, attempt_id = request.thread_id, request.action_id, request.attempt_id
    local idempotency_key = request.idempotency_key or (attempt_id .. "-run")
    local initial_receipt = {scope = "attempt", thread_id = thread_id, action_id = action_id,
        attempt_id = attempt_id, state = "running", idempotency_key = idempotency_key}
    local function failed(message: string): {[string]: unknown}
        return {ok = false, error = message, outcome = "failed", thread_id = thread_id,
            action_id = action_id, attempt_id = attempt_id, receipt = initial_receipt}
    end

    local claimed, claim_error = call(CARRIER .. ":claim", {thread_id = thread_id, attempt_id = attempt_id,
        idempotency_key = idempotency_key .. "-claim"})
    if not claimed then return failed("claim attempt: " .. tostring(claim_error and claim_error.error and claim_error.error.message or "claim failed")) end
    local epoch = bounds.count(claimed.carrier_epoch) or 0
    if epoch < 1 then return failed("claim attempt: carrier epoch is not positive") end
    if request.carrier_epoch ~= nil and epoch ~= request.carrier_epoch + 1 then
        return failed("carrier epoch moved under attempt: observed " .. tostring(request.carrier_epoch) .. ", claimed " .. tostring(epoch))
    end
    if claimed.attempt_state == "ended" then
        return {ok = true, outcome = tostring(claimed.attempt_outcome or "succeeded"), thread_id = thread_id,
            action_id = action_id, attempt_id = attempt_id, receipt = initial_receipt}
    end

    local stored = call(CHECKPOINT, {thread_id = thread_id, attempt_id = attempt_id})
    local checkpoint = stored and stored.checkpoint or nil
    local revision = bounds.count(claimed.checkpoint_revision) or (stored and bounds.count(stored.checkpoint_revision)) or 0
    local run: Run = {thread_id = thread_id, attempt_id = attempt_id}
    local context: Context
    context = {
        thread_id = thread_id,
        action_id = action_id,
        attempt_id = attempt_id,
        carrier_epoch = epoch,
        checkpoint_revision = revision,
        checkpoint = checkpoint,
        cancelled = function() return M.cancelled(run) end,
        commit = function(idem: string, records: {{[string]: unknown}}, next_checkpoint: {[string]: unknown}): (boolean, string?)
            local committed, commit_error = call(CARRIER .. ":commit", {thread_id = thread_id, attempt_id = attempt_id,
                carrier_epoch = epoch, expected_revision = revision, idempotency_key = idem,
                checkpoint = next_checkpoint, records = records})
            if not committed then
                local detail = commit_error and commit_error.error and commit_error.error.message or "commit failed"
                return false, tostring(detail)
            end
            revision = bounds.count(committed.checkpoint_revision) or (revision + 1)
            context.checkpoint_revision = revision
            context.checkpoint = next_checkpoint
            return true, nil
        end,
    }

    -- Preserve the provider adapter's own checkpoint format while the shared
    -- lifecycle owns every carrier write and terminal receipt.
    local result = adapter(context, request)
    if result.settle == false then return failed(result.error or "the in-process adapter refused the run") end
    local outcome = bounds.member(result.outcome, {"succeeded", "failed", "cancelled", "uncertain"}) or "failed"
    local terminal_checkpoint = result.checkpoint or bounds.object(context.checkpoint) or {}
    terminal_checkpoint.terminal = {outcome = outcome, answer = result.answer}
    context.commit(idempotency_key .. "-final", {}, terminal_checkpoint)
    call(RECEIPT, {thread_id = thread_id, action_id = action_id, attempt_id = attempt_id, carrier_epoch = epoch,
        idempotency_key = idempotency_key .. "-terminal-receipt", receipt = {scope = "attempt", outcome = outcome, evidence_refs = {}}})
    local final_receipt = {scope = "attempt", thread_id = thread_id, action_id = action_id,
        attempt_id = attempt_id, state = "ended", idempotency_key = idempotency_key}
    return {ok = outcome ~= "failed", error = result.error, outcome = outcome, answer = result.answer,
        thread_id = thread_id, action_id = action_id, attempt_id = attempt_id, receipt = final_receipt,
        state = "ended", status = "ended"}
end

return M
