-- MIT. The backend behind the application facade for managed agents. It
-- runs in the host-named launch scope as the application's own actor, bound
-- to the workspace the facade admitted: it starts a child through the shared
-- caller launch, and reads, waits on and cancels a run through the child's
-- thread and the placement that prepared it. The facade has already checked
-- the host's launch grant; every owner operation underneath checks the
-- application's membership and ownership again.
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local bounds = require("bounds")
local agent_launch = require("agent_launch")
local definitions = require("definitions")
local caller_launch = require("caller_launch")
local placement_resolver = require("placement_resolver")
local CHECKPOINT = "bee.threads.carrier:checkpoint"
local THREAD = "bee.threads.service:get"
local WATCH = "bee.threads.delivery:watch"
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
    local request, invalid = agent_launch.decode_request(body)
    if not request then return fail("INVALID", invalid or "invalid launch request") end
    local definition, definition_error = definitions.load(request.definition_ref)
    if not definition then return fail("NOT_FOUND", definition_error or "the launch definition is unavailable") end
    return caller_launch.start({workspace_id = workspace_id, identity = identity}, request, definition)
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
-- Cancelling stops the attempt's child through the placement that started
-- it, which accepts only the attempt's owner; the carrier then observes the
-- exit and settles the attempt cancelled. A run whose child has not started
-- yet is refused as NOT_STARTED, to be cancelled once it runs.
local function cancel(run: agent_launch.Run): Reply
    local current, refused, stored = status(run)
    if not current then return refused or fail("UNAVAILABLE", "the attempt did not answer") end
    if current.state == "ended" then return {ok = true, error = nil, value = current} end
    if not stored or current.state ~= "running" then return fail("NOT_STARTED", "the attempt's child has not started yet") end
    local binding_ref, placement_attempt = bounds.id(stored.placement_binding), bounds.id(stored.placement_attempt_id)
    if not binding_ref or not placement_attempt then return fail("INTERNAL", "the started attempt names no placement") end
    local pinned, pin_error = registry.snapshot()
    if not pinned then return fail("UNAVAILABLE", tostring(pin_error or "registry snapshot")) end
    local placement, placement_error = placement_resolver.resolve(pinned, binding_ref)
    if not placement then return fail("UNAVAILABLE", placement_error or "placement binding") end
    local stop = placement.methods.stop
    if not stop then return fail("UNAVAILABLE", "the placement binds no stop") end
    local _, stop_refused = call(stop, {attempt_id = placement_attempt, mode = "cooperative"})
    if stop_refused then return stop_refused end
    return {ok = true, error = nil, value = {thread_id = run.thread_id, attempt_id = run.attempt_id, state = "cancelling"}}
end
local function handle(raw: unknown): Reply
    local object = bounds.object(raw)
    if not object then return fail("INVALID", "request must be an object") end
    local operation = bounds.member(object.operation, {"launch", "status", "wait", "cancel"})
    if not operation then return fail("INVALID", "operation must be launch, status, wait or cancel") end
    local body: {[string]: unknown} = {}
    for key, value in pairs(object) do
        if key ~= "operation" then body[key] = value end
    end
    if operation == "launch" then return launch(body) end
    local allowed: {string} = {"thread_id", "attempt_id"}
    if operation == "wait" then allowed = {"thread_id", "attempt_id", "wait_ms"} end
    local run, invalid = agent_launch.decode_run(body, allowed)
    if not run then return fail("INVALID", invalid or "invalid run") end
    if operation == "status" then
        local current, refused = status(run)
        if not current then return refused or fail("UNAVAILABLE", "the attempt did not answer") end
        return {ok = true, error = nil, value = current}
    elseif operation == "wait" then
        local wait_ms = bounds.integer(body.wait_ms == nil and 0 or body.wait_ms)
        if not wait_ms or wait_ms < 0 or wait_ms > agent_launch.MAX_WAIT_MS then
            return fail("INVALID", "wait_ms must be between 0 and " .. tostring(agent_launch.MAX_WAIT_MS))
        end
        return wait(run, wait_ms)
    end
    return cancel(run)
end
return {handle = handle}
