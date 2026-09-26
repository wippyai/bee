-- MIT. The backend behind the application facade for managed agents. It
-- launches through caller admission and delegates every run transition to
-- the shared lifecycle with the selected placement's stop operation.
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local bounds = require("bounds")
local agent_launch = require("agent_launch")
local agent_protocol = require("agent_protocol")
local definitions = require("definitions")
local caller_launch = require("caller_launch")
local placement_resolver = require("placement_resolver")
local managed_run = require("managed_run")

type Reply = {ok: boolean, error: {code: string, message: string}?, value: unknown}

local function fail(code: string, message: string): Reply
    return {ok = false, error = {code = code, message = message}, value = nil}
end

local function call(target: string, request: unknown): ({[string]: unknown}?, Reply?)
    local raw, call_error = funcs.call(target, request)
    if call_error then return nil, fail("UNAVAILABLE", tostring(call_error)) end
    local object = bounds.object(raw)
    if not object then return nil, fail("INTERNAL", "the owner returned a malformed reply") end
    if object.ok ~= true then
        local fault = bounds.object(object.error)
        return nil, fail(tostring(fault and fault.code or "REFUSED"), tostring(fault and fault.message or "the owner refused"))
    end
    local value = bounds.object(object.value)
    if not value then return nil, fail("INTERNAL", "the owner returned no value") end
    return value, nil
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
    local current = managed_run.status({thread_id = child_thread, attempt_id = child_attempt})
    local state = current and current.state or "starting"
    local idempotency_key = bounds.id(body.idempotency_key) or bounds.text(body.idempotency_key, 128)
    local receipt = {scope = "attempt", thread_id = child_thread, action_id = child_action,
        attempt_id = child_attempt, state = state, idempotency_key = idempotency_key}
    return {ok = true, error = nil, value = {
        thread_id = child_thread, action_id = child_action, attempt_id = child_attempt,
        definition_ref = admitted.definition_ref, title = admitted.title, brief = admitted.brief,
        state = state, status = state, outcome = current and current.outcome or nil,
        answer = current and current.answer or nil, idempotency_key = idempotency_key,
        saved_profile_revision = admitted.saved_profile_revision,
        owner_component_revision = admitted.owner_component_revision, receipt = receipt,
    }}
end

local function stop_placement(stored: {[string]: unknown}): (boolean, Reply?)
    local binding_ref = bounds.id(stored.placement_binding)
    local placement_attempt = bounds.id(stored.placement_attempt_id)
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
        local current, refused = managed_run.status(run_ref)
        if not current then return refused or fail("UNAVAILABLE", "the attempt did not answer") end
        return {ok = true, error = nil, value = current}
    elseif operation == "wait" then
        local wait_ms = bounds.integer(body.wait_ms == nil and 0 or body.wait_ms)
        if not wait_ms or wait_ms < 0 or wait_ms > agent_launch.MAX_WAIT_MS then
            return fail("INVALID", "wait_ms must be between 0 and " .. tostring(agent_launch.MAX_WAIT_MS))
        end
        return managed_run.wait(run_ref, wait_ms)
    end
    local wait_ms = body.wait_ms ~= nil and bounds.integer(body.wait_ms) or nil
    if body.wait_ms ~= nil and (not wait_ms or wait_ms < 0 or wait_ms > agent_launch.MAX_WAIT_MS) then
        return fail("INVALID", "wait_ms must be between 0 and " .. tostring(agent_launch.MAX_WAIT_MS))
    end
    local idempotency_key = body.idempotency_key ~= nil
        and (bounds.id(body.idempotency_key) or bounds.text(body.idempotency_key, 64)) or nil
    return managed_run.cancel(run_ref, wait_ms, idempotency_key, {prestart = "settle", stop = stop_placement})
end

return {handle = handle}
