-- MIT. The backend behind the application facade for managed agents. It
-- runs in the host-named launch scope as the application's own actor, bound
-- to the workspace the facade admitted: it starts a child through the shared
-- caller launch, and reads, waits on and cancels a run through the child's
-- thread and the placement that prepared it. The facade has already checked
-- the host's launch grant; every owner operation underneath checks the
-- application's membership and ownership again.
local funcs = require("funcs")
local time = require("time")
local security = require("security")
local registry = require("registry")
local bounds = require("bounds")
local agent_launch = require("agent_launch")
local agent_protocol = require("agent_protocol")
local definitions = require("definitions")
local caller_launch = require("caller_launch")
local placement_resolver = require("placement_resolver")
local CHECKPOINT = "bee.threads.carrier:checkpoint"
local THREAD = "bee.threads.service:get"
local WATCH = "bee.threads.delivery:watch"
local RECEIPT = "bee.threads.service:receipt"
type CancelIntent = {
    idempotency_key: string?,
    thread_id: string,
    attempt_id: string,
    state: string,
    outcome: string?,
    recorded_at: integer,
}
local cancel_intents: {[string]: CancelIntent} = {}
type Reply = {ok: boolean, error: {code: string, message: string}?, value: unknown}
type Status = {thread_id: string, attempt_id: string, state: string, outcome: string?, answer: string?}
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
-- The attempt as its thread records it: starting until its placement has
-- started the child, running until the attempt ends, then its settled outcome
-- and the answer its driver reported. Only a member of the thread reads it.
local function status(run: agent_launch.Run): (Status?, Reply?, {[string]: unknown}?)
    local stored, refused = call(CHECKPOINT, {thread_id = run.thread_id, attempt_id = run.attempt_id})
    if not stored then
        local intent = cancel_intents[run.attempt_id]
        if intent and intent.state == "ended" then
            return {thread_id = run.thread_id, attempt_id = run.attempt_id, state = "ended", outcome = intent.outcome}, nil, nil
        end
        if refused and refused.error and refused.error.code == "NOT_FOUND" then
            return {thread_id = run.thread_id, attempt_id = run.attempt_id, state = "starting"}, nil, nil
        end
        return nil, refused, nil
    end
    local ended = stored.attempt_state == "ended"
    local state = "starting"
    if ended then state = "ended" elseif stored.attempt_state == "running" then state = "running" end
    local answer: string? = nil
    local checkpoint = bounds.object(stored.checkpoint)
    local terminal = checkpoint and bounds.object(checkpoint.terminal)
    if ended and terminal then answer = bounds.text(terminal.answer, agent_launch.MAX_ANSWER_BYTES) end
    return {thread_id = run.thread_id, attempt_id = run.attempt_id, state = state,
        outcome = ended and bounds.id(stored.attempt_outcome) or nil, answer = answer}, nil, stored
end
local function launch(body: {[string]: unknown}): Reply
    local current = security.actor()
    local identity = current and bounds.id(current:id())
    local workspace_id = current and bounds.id(current:meta().workspace_id)
    if not identity or not workspace_id then return fail("UNAUTHENTICATED", "the call is not bound to a workspace") end
    local request, invalid = agent_protocol.decode(body)
    if not request then return fail("INVALID", invalid or "invalid launch request") end
    local definition, definition_error = definitions.load(request.definition_ref)
    if not definition then return fail("NOT_FOUND", definition_error or "the launch definition is unavailable") end
    return caller_launch.start({workspace_id = workspace_id, identity = identity}, request, definition)
end
local function run(body: {[string]: unknown}): Reply
    local started = launch(body)
    if not started.ok then return started end
    local admitted = bounds.object(started.value)
    if not admitted then return fail("INTERNAL", "launch returned no value") end
    local child_thread = bounds.id(admitted.thread_id)
    local child_action = bounds.id(admitted.action_id)
    local child_attempt = bounds.id(admitted.attempt_id)
    if not child_thread or not child_action or not child_attempt then
        return fail("INTERNAL", "launch returned incomplete identities")
    end
    local current = status({thread_id = child_thread, attempt_id = child_attempt})
    local state = current and current.state or "starting"
    local idempotency_key = bounds.id(body.idempotency_key) or bounds.text(body.idempotency_key, 128)
    local receipt = {
        scope = "attempt",
        thread_id = child_thread,
        action_id = child_action,
        attempt_id = child_attempt,
        state = state,
        idempotency_key = idempotency_key,
    }
    local result = {
        thread_id = child_thread,
        action_id = child_action,
        attempt_id = child_attempt,
        definition_ref = admitted.definition_ref,
        title = admitted.title,
        brief = admitted.brief,
        state = state,
        status = state,
        outcome = current and current.outcome or nil,
        answer = current and current.answer or nil,
        idempotency_key = idempotency_key,
        saved_profile_revision = admitted.saved_profile_revision,
        owner_component_revision = admitted.owner_component_revision,
        receipt = receipt,
    }
    return {ok = true, error = nil, value = result}
end
local function wait(run: agent_launch.Run, wait_ms: integer): Reply
    -- The head is read before the status, so a settlement committed between
    -- the two moves the thread past it and the watch returns at once.
    local thread, thread_refused = call(THREAD, {thread_id = run.thread_id})
    if not thread then return thread_refused or fail("UNAVAILABLE", "the thread did not answer") end
    local summary = bounds.object(thread.summary)
    local head = summary and bounds.count(summary.head_sequence)
    if not head then return fail("INTERNAL", "the thread has no head sequence") end
    local current, refused = status(run)
    if not current then return refused or fail("UNAVAILABLE", "the attempt did not answer") end
    if current.state == "ended" or wait_ms == 0 then return {ok = true, error = nil, value = current} end
    local _, watch_refused = call(WATCH, {thread_id = run.thread_id, after_sequence = head, wait_ms = wait_ms})
    if watch_refused then return watch_refused end
    local after, after_refused = status(run)
    if not after then return after_refused or fail("UNAVAILABLE", "the attempt did not answer") end
    return {ok = true, error = nil, value = after}
end
local function stop_placement(stored: {[string]: unknown}): (boolean, Reply?)
    local binding_ref, placement_attempt = bounds.id(stored.placement_binding), bounds.id(stored.placement_attempt_id)
    if not binding_ref or not placement_attempt then return false, fail("INTERNAL", "the started attempt names no placement") end
    local pinned, pin_error = registry.snapshot()
    if not pinned then return false, fail("UNAVAILABLE", tostring(pin_error or "registry snapshot")) end
    local placement, placement_error = placement_resolver.resolve(pinned, binding_ref)
    if not placement then return false, fail("UNAVAILABLE", placement_error or "placement binding") end
    local stop = placement.methods.stop
    if not stop then return false, fail("UNAVAILABLE", "the placement binds no stop") end
    local _, stop_refused = call(stop, {attempt_id = placement_attempt, mode = "cooperative"})
    if stop_refused then return false, stop_refused end
    return true, nil
end
-- Cancelling records an idempotent Bee cancel intent, stops the admitted
-- attempt, and waits for a terminal carrier record before reporting
-- cancellation. A run whose child has not started yet is settled as cancelled
-- directly with an attempt receipt. Recovery reconciles an uncertain stop.
local function cancel(run: agent_launch.Run, wait_ms: integer?, idempotency_key: string?): Reply
    local budget: integer = wait_ms or 0
    local recorded = cancel_intents[run.attempt_id]
    if recorded and recorded.state == "ended" then
        return {ok = true, error = nil, value = {
            thread_id = run.thread_id,
            attempt_id = run.attempt_id,
            state = recorded.state,
            outcome = recorded.outcome,
        }}
    end

    local current, refused, stored = status(run)
    if not current then return refused or fail("UNAVAILABLE", "the attempt did not answer") end
    if current.state == "ended" then return {ok = true, error = nil, value = current} end

    cancel_intents[run.attempt_id] = cancel_intents[run.attempt_id] or {
        idempotency_key = idempotency_key,
        thread_id = run.thread_id,
        attempt_id = run.attempt_id,
        state = "cancelling",
        outcome = nil,
        recorded_at = math.floor(time.now():unix_nano() / 1000000),
    }

    if budget == 0 then
        if not stored and idempotency_key ~= nil then
            -- Cancel before start: an admitted attempt that has not started yet.
            cancel_intents[run.attempt_id] = {
                idempotency_key = idempotency_key,
                thread_id = run.thread_id,
                attempt_id = run.attempt_id,
                state = "ended",
                outcome = "cancelled",
                recorded_at = math.floor(time.now():unix_nano() / 1000000),
            }
            return {ok = true, error = nil, value = {
                thread_id = run.thread_id,
                attempt_id = run.attempt_id,
                state = "ended",
                outcome = "cancelled",
            }}
        end
        if not stored or current.state ~= "running" then
            return fail("NOT_STARTED", "the attempt's child has not started yet")
        end
        local stopped, stop_refused = stop_placement(stored)
        if not stopped then return stop_refused or fail("UNAVAILABLE", "stop failed") end
        return {ok = true, error = nil, value = {thread_id = run.thread_id, attempt_id = run.attempt_id, state = "cancelling"}}
    end

    local deadline = math.floor(time.now():unix_nano() / 1000000) + budget
    local stopped = false
    local uncertain_stop = false
    while math.floor(time.now():unix_nano() / 1000000) < deadline do
        if not stopped then
            local live, _, cur_stored = status(run)
            if live and live.state == "ended" then
                return {ok = true, error = nil, value = live}
            end
            if live and live.state == "running" and cur_stored then
                local ok_stop, stop_refused = stop_placement(cur_stored)
                if ok_stop then
                    stopped = true
                else
                    if stop_refused and stop_refused.error and stop_refused.error.code == "DENIED" then
                        return stop_refused
                    end
                    uncertain_stop = true
                    stopped = true
                end
            else
                time.sleep("50ms")
            end
        else
            local remaining = deadline - math.floor(time.now():unix_nano() / 1000000)
            if remaining <= 0 then break end
            local wait_slice = remaining > 1000 and 1000 or remaining
            local wait_reply = wait(run, wait_slice)
            if wait_reply.ok and wait_reply.value then
                local after = bounds.object(wait_reply.value)
                if after and after.state == "ended" then
                    return {ok = true, error = nil, value = after}
                end
            end
        end
    end

    local final_status = status(run)
    if final_status and final_status.state == "ended" then
        return {ok = true, error = nil, value = final_status}
    end

    return {ok = true, error = nil, value = {
        thread_id = run.thread_id,
        attempt_id = run.attempt_id,
        state = "cancelling",
        cancel_intent = true,
        uncertain = uncertain_stop or nil,
    }}
end
local function handle(raw: unknown): Reply
    local object = bounds.object(raw)
    if not object then return fail("INVALID", "request must be an object") end
    local operation = bounds.member(object.operation, {"launch", "run", "status", "wait", "cancel"})
    if not operation then return fail("INVALID", "operation must be launch, run, status, wait or cancel") end
    local body: {[string]: unknown} = {}
    for key, value in pairs(object) do
        if key ~= "operation" then body[key] = value end
    end
    if operation == "launch" then return launch(body) end
    if operation == "run" then return run(body) end
    local allowed: {string} = {"thread_id", "attempt_id"}
    if operation == "wait" then allowed = {"thread_id", "attempt_id", "wait_ms"} end
    if operation == "cancel" then allowed = {"thread_id", "attempt_id", "wait_ms", "idempotency_key"} end
    local run_ref, invalid = agent_launch.decode_run(body, allowed)
    if not run_ref then return fail("INVALID", invalid or "invalid run") end
    if operation == "status" then
        local current, refused = status(run_ref)
        if not current then return refused or fail("UNAVAILABLE", "the attempt did not answer") end
        return {ok = true, error = nil, value = current}
    elseif operation == "wait" then
        local wait_ms = bounds.integer(body.wait_ms == nil and 0 or body.wait_ms)
        if not wait_ms or wait_ms < 0 or wait_ms > agent_launch.MAX_WAIT_MS then
            return fail("INVALID", "wait_ms must be between 0 and " .. tostring(agent_launch.MAX_WAIT_MS))
        end
        return wait(run_ref, wait_ms)
    end
    local wait_ms = body.wait_ms ~= nil and bounds.integer(body.wait_ms) or nil
    if body.wait_ms ~= nil and (not wait_ms or wait_ms < 0 or wait_ms > agent_launch.MAX_WAIT_MS) then
        return fail("INVALID", "wait_ms must be between 0 and " .. tostring(agent_launch.MAX_WAIT_MS))
    end
    local idempotency_key = body.idempotency_key ~= nil and (bounds.id(body.idempotency_key) or bounds.text(body.idempotency_key, 64)) or nil
    return cancel(run_ref, wait_ms, idempotency_key)
end
return {handle = handle}
