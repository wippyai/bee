-- MIT. One external CLI process belongs to one immutable pulled turn.
local M = {}
local budget_values = require("budget")

type Budget = budget_values.Budget

type Request = {
    attempt_id: string,
    claim: string,
    observation_target: string,
    generation: integer,
    recovery: boolean?,
    prompt: string,
    sender: {kind: "session" | "principal", id: string},
    driver_binding_ref: string,
    profile_id: string,
    driver_methods: {[string]: string},
    placement_methods: {[string]: string},
    admission: {[string]: unknown},
    previous_attempt_id: string?,
    checkpoint: {[string]: unknown}?,
    budget: Budget?,
    session_budget: Budget?,
    session_consumption: budget_values.Counters?,
    session_wall_ms: integer?,
    supervision: budget_values.Supervision?,
}

type IO = {
    reconcile: (string) -> (unknown, string?),
    cleanup: (string) -> (unknown, string?),
    plan: (unknown) -> (unknown?, string?),
    prepare: (unknown) -> (unknown, string?),
    listen: () -> (unknown, string?),
    attach: (string, integer) -> (unknown, string?),
    admit_gateway: (integer) -> (string?, string?),
    gateway_ready: (string) -> string?,
    revoke_gateway: (string) -> (),
    start: (string, string?) -> (unknown, string?),
    observe: (unknown, unknown, string, boolean, unknown, Request) -> (unknown, string?),
    close: (unknown) -> (),
}


local function object(value: unknown): {[string]: unknown}?
    if type(value) == "table" then return value end
    return nil
end

local function id(value: unknown): string?
    if type(value) ~= "string" or value == "" or #value > 256 or value:find("[%c%s]") then return nil end
    return value
end

local function decode(value: unknown): (Request?, string?)
    local request = object(value)
    if not request then return nil, "turn request must be an object" end
    local allowed = {"attempt_id", "claim", "observation_target", "generation", "prompt", "sender", "driver_binding_ref", "profile_id", "driver_methods",
        "placement_methods", "admission", "previous_attempt_id", "checkpoint", "recovery", "budget", "session_budget", "session_consumption", "supervision"}
    local fields: {[string]: boolean} = {}
    for _, field in ipairs(allowed) do fields[field] = true end
    for field in pairs(request) do
        if not fields[tostring(field)] then return nil, "turn request has unknown field " .. tostring(field) end
    end
    local attempt_id = id(request.attempt_id)
    if not attempt_id then return nil, "attempt_id is invalid" end
    local claim = id(request.claim)
    if not claim then return nil, "claim is invalid" end
    if request.observation_target ~= "bee.threads.binding:turn_observation" then
        return nil, "observation_target is not the Threads turn observation operation"
    end
    if type(request.generation) ~= "number" or math.floor(request.generation) ~= request.generation or request.generation < 1 then
        return nil, "generation must be a positive integer"
    end
    if type(request.prompt) ~= "string" or #request.prompt == 0 or #request.prompt > 16384 then return nil, "prompt must be nonempty bounded text" end
    if request.recovery ~= nil and type(request.recovery) ~= "boolean" then return nil, "recovery must be boolean" end
    local generation = math.floor(request.generation)
    local prompt: string = request.prompt
    local sender = object(request.sender)
    if not sender or (sender.kind ~= "session" and sender.kind ~= "principal") or not id(sender.id) then
        return nil, "sender must be an authenticated session or principal identity"
    end
    local sender_id = assert(id(sender.id))
    local sender_kind = sender.kind
    if sender_kind ~= "session" and sender_kind ~= "principal" then return nil, "sender must be an authenticated session or principal identity" end
    local decoded_sender = {kind = sender_kind, id = sender_id}
    local driver_binding_ref = id(request.driver_binding_ref)
    if not driver_binding_ref then return nil, "driver_binding_ref is invalid" end
    local profile_id = id(request.profile_id)
    if not profile_id then return nil, "profile_id is invalid" end
    local driver_methods = object(request.driver_methods)
    if not driver_methods then return nil, "driver_methods must be an object" end
    local resolved_driver: {[string]: string} = {}
    for _, method in ipairs({"prepare", "dispatch", "normalize"}) do
        local target = id(driver_methods[method])
        if not target then
            return nil, "driver_methods." .. method .. " is invalid"
        end
        resolved_driver[method] = target
    end
    local placement_methods = object(request.placement_methods)
    if not placement_methods then return nil, "placement_methods must be an object" end
    local prepare_target = id(placement_methods.prepare)
    local placement_prefix = prepare_target and prepare_target:match("^(bee[.]placement[.][A-Za-z0-9_.-]+[.]binding:)prepare$")
    if not placement_prefix then return nil, "placement prepare is not a Bee placement operation" end
    local resolved_placement: {[string]: string} = {}
    for _, method in ipairs({"prepare", "attach", "start", "stop", "reconcile", "cleanup"}) do
        local target = placement_prefix .. method
        if placement_methods[method] ~= target then
            return nil, "placement_methods." .. method .. " differs from the selected placement binding"
        end
        resolved_placement[method] = target
    end
    local admission = object(request.admission)
    if not admission or admission.attempt_id ~= attempt_id then return nil, "session admission attempt differs from the turn" end
    if admission.profile_id ~= profile_id then return nil, "session admission profile differs from the selected profile" end
    local previous_attempt_id: string? = nil
    if request.previous_attempt_id ~= nil then
        previous_attempt_id = id(request.previous_attempt_id)
        if not previous_attempt_id or previous_attempt_id == attempt_id then return nil, "previous_attempt_id is invalid" end
    end
    local checkpoint = object(request.checkpoint)
    if request.checkpoint ~= nil and not checkpoint then return nil, "checkpoint must be an object" end
    local selected_budget, budget_error = budget_values.decode(request.budget)
    if budget_error then return nil, budget_error end
    local session_budget, session_budget_error = budget_values.decode(request.session_budget)
    if session_budget_error then return nil, session_budget_error end
    local consumption = object(request.session_consumption)
    local session_counters: budget_values.Counters? = nil
    local session_wall_ms: integer? = nil
    if consumption then
        local steps, tools, tokens, wall = bounds.count(consumption.provider_steps), bounds.count(consumption.tool_calls), bounds.count(consumption.tokens), bounds.count(consumption.wall_time_ms)
        if not steps or not tools or not tokens or not wall then return nil, "session consumption is malformed" end
        session_counters = {turns = steps, tool_calls = tools, tokens = tokens}
        session_wall_ms = wall
    elseif session_budget then return nil, "session budget requires durable consumption" end
    local supervision, supervision_error = budget_values.supervision(request.supervision)
    if supervision_error then return nil, supervision_error end
    local resume_ref = checkpoint and checkpoint.resume_ref or nil
    if resume_ref ~= nil and not id(resume_ref) then return nil, "checkpoint.resume_ref is invalid" end
    local sender_label = "[Bee sender " .. tostring(sender.kind) .. " " .. tostring(sender.id) .. "]\n"
    if #sender_label + #request.prompt > 16384 then return nil, "prompt and sender identity exceed 16384 bytes" end
    return {
        attempt_id = attempt_id, claim = claim, observation_target = "bee.threads.binding:turn_observation",
        generation = generation, recovery = request.recovery == true, prompt = sender_label .. prompt,
        sender = decoded_sender,
        driver_binding_ref = driver_binding_ref, profile_id = profile_id, driver_methods = resolved_driver,
        placement_methods = resolved_placement, admission = admission,
        previous_attempt_id = previous_attempt_id, checkpoint = checkpoint, budget = selected_budget, session_budget = session_budget, session_consumption = session_counters,
        session_wall_ms = session_wall_ms, supervision = supervision,
    }, nil
end

local function placement_attempt(value: unknown): ({[string]: unknown}?, string?)
    local object_value = object(value)
    if not object_value then return nil, "placement returned no attempt" end
    local attempt = object(object_value.attempt) or object_value
    if not id(attempt.attempt_id) or not id(attempt.execution_state) then return nil, "placement returned a malformed attempt" end
    return attempt, nil
end

local function placement_pending(attempt: {[string]: unknown}): boolean
    return attempt.execution_state == "intended" or attempt.execution_state == "starting"
        or attempt.execution_state == "running" or attempt.execution_state == "stopping"
end

type Recovery = "ready" | "pending" | "uncertain"

local function pending(request: Request, reason: string, attempt: unknown?): {[string]: unknown}
    return {state = "pending", outcome = "pending", attempt_id = request.attempt_id,
        evidence = {code = "placement_active", message = reason, placement = attempt}}
end

local function failed_start(request: Request, attempt: {[string]: unknown}, observed: unknown?): ({[string]: unknown}?, string?)
    local cause = bounds.text(attempt.start_failure, 4096)
    if not cause then return nil, "placement start_failed omitted its exact cause" end
    local observation = object(observed)
    return {state = "settled", outcome = "failed", attempt_id = request.attempt_id,
        error = {code = "START_FAILED", message = cause}, observations = observation and observation.observations or {},
        checkpoint = {attempt_id = request.attempt_id, resume_ref = request.checkpoint and request.checkpoint.resume_ref},
        evidence = attempt}, nil
end
local function cancelled_start(request: Request, attempt: {[string]: unknown}, observed: unknown?): {[string]: unknown}
    local observation = object(observed)
    return {state = "settled", outcome = "cancelled", error = {code = "CANCELLED", message = "explicit stop before child creation"},
        attempt_id = request.attempt_id, checkpoint = {attempt_id = request.attempt_id, resume_ref = request.checkpoint and request.checkpoint.resume_ref},
        observations = observation and observation.observations or {}, evidence = attempt}
end

local function call_previous(io: IO, attempt_id: string): (Recovery, string?, unknown?)
    local value, call_error = io.reconcile(attempt_id)
    if call_error then return "uncertain", "reconcile previous placement attempt: " .. call_error, nil end
    local attempt, decode_error = placement_attempt(value)
    if not attempt then return "uncertain", "reconcile previous placement attempt: " .. tostring(decode_error), nil end
    if placement_pending(attempt) then
        return "pending", "previous placement attempt is still " .. tostring(attempt.execution_state), attempt
    end
    if not attempt.start_cancelled and attempt.execution_state ~= "start_failed" and (attempt.execution_state ~= "exited" or attempt.exit_source == nil) then
        return "uncertain", "previous placement attempt has no proven exit", attempt
    end
    local cleaned, cleanup_error = io.cleanup(attempt_id)
    if cleanup_error then return "pending", "cleanup previous placement attempt: " .. cleanup_error, attempt end
    local cleanup_attempt, cleanup_decode_error = placement_attempt(cleaned)
    if not cleanup_attempt then return "pending", "cleanup previous placement attempt: " .. tostring(cleanup_decode_error), attempt end
    if cleanup_attempt.attempt_id ~= attempt_id then
        return "uncertain", "cleanup previous placement attempt returned another attempt", cleanup_attempt
    end
    if cleanup_attempt.cleanup_state ~= "complete" then
        return "pending", "previous placement cleanup is " .. tostring(cleanup_attempt.cleanup_state or "unproven"), cleanup_attempt
    end
    return "ready", nil, cleanup_attempt
end

local function uncertain(request: Request, reason: string, attempt: unknown?): {[string]: unknown}
    return {state = "uncertain", outcome = "uncertain", attempt_id = request.attempt_id,
        evidence = {code = "external_interruption", message = reason, placement = attempt}}
end

function M.execute(io: IO, value: unknown): ({[string]: unknown}?, string?)
    local request, decode_error = decode(value)
    if not request then return nil, decode_error end

    if request.recovery then
        local recovered, recovery_error = io.reconcile(request.attempt_id)
        if recovery_error then return uncertain(request, "current placement recovery cannot be proven: " .. recovery_error) end
        local attempt, attempt_error = placement_attempt(recovered)
        if not attempt or attempt.attempt_id ~= request.attempt_id then
            return uncertain(request, "current placement recovery returned invalid evidence: " .. tostring(attempt_error), recovered)
        end
        if attempt.execution_state == "start_failed" or attempt.start_failure ~= nil then return failed_start(request, attempt) end
        if attempt.start_cancelled then return cancelled_start(request, attempt), nil end
        if placement_pending(attempt) then return pending(request, "recovered placement is still active", attempt) end
        return uncertain(request, "recovered placement has no durable terminal report", attempt)
    end

    -- Recovery is a precondition for every new driver invocation.
    if request.previous_attempt_id then
        local recovery, recovery_error, attempt = call_previous(io, request.previous_attempt_id)
        if recovery == "pending" then return pending(request, recovery_error or "previous attempt is still active", attempt) end
        if recovery == "uncertain" then return uncertain(request, recovery_error or "previous attempt did not reconcile", attempt) end
    end

    local planned_value, plan_error = io.plan(request)
    if plan_error then return nil, "admit external turn: " .. plan_error end
    local planned = object(planned_value)
    local placement_request = planned and object(planned.placement_request)
    local normalize_target = planned and id(planned.normalize_target)
    if not placement_request or not normalize_target then return nil, "admit external turn returned an incomplete placement plan" end
    if placement_request.attempt_id ~= request.attempt_id then return nil, "placement plan names another attempt" end
    if placement_request.binding_ref ~= request.driver_binding_ref or placement_request.profile_id ~= request.profile_id then
        return nil, "placement plan differs from the selected driver route"
    end
    if placement_request.placement_binding_ref ~= request.placement_methods.prepare:gsub("prepare$", "binding") then
        return nil, "placement plan differs from the selected placement route"
    end
    local intent_value, intent_error = io.prepare(placement_request)
    if intent_error then return nil, "persist placement intent: " .. intent_error end
    local intent, intent_decode_error = placement_attempt(intent_value)
    if not intent then return nil, "persist placement intent: " .. tostring(intent_decode_error) end
    if intent.attempt_id ~= request.attempt_id then return nil, "placement intent names another attempt" end
    if intent.execution_state ~= "intended" then
        local reconciled, reconcile_error = io.reconcile(request.attempt_id)
        if reconcile_error then return uncertain(request, "current placement attempt cannot be reconciled: " .. reconcile_error, intent) end
        local attempt, attempt_error = placement_attempt(reconciled)
        if not attempt then return uncertain(request, "current placement attempt cannot be reconciled: " .. tostring(attempt_error), intent) end
        if attempt.attempt_id ~= request.attempt_id then
            return uncertain(request, "current placement reconciliation returned another attempt", attempt)
        end
        if attempt.execution_state == "start_failed" or attempt.start_failure ~= nil then return failed_start(request, attempt) end
        if attempt.start_cancelled then return cancelled_start(request, attempt), nil end
        if placement_pending(attempt) then
            return pending(request, "current placement attempt is still " .. tostring(attempt.execution_state), attempt)
        end
        return uncertain(request, "turn already has a placement attempt without a durable terminal checkpoint", attempt)
    end

    local listener, listen_error = io.listen()
    if listen_error then return nil, "listen for placement output: " .. listen_error end
    local attached, attach_error = io.attach(request.attempt_id, request.generation)
    if attach_error then io.close(listener); return nil, "attach placement output: " .. attach_error end
    local attach_attempt, attach_decode_error = placement_attempt(attached)
    if not attach_attempt or attach_attempt.attempt_id ~= request.attempt_id then
        io.close(listener)
        return nil, "attach placement output: " .. tostring(attach_decode_error or "placement returned another attempt")
    end
    local gateway_binding: string? = nil
    if placement_request.gateway ~= nil then
        local admitted, gateway_error = io.admit_gateway(request.generation)
        if gateway_error or not admitted then
            io.close(listener)
            return nil, "admit attempt gateway: " .. tostring(gateway_error or "gateway returned no binding")
        end
        gateway_binding = admitted
        local ready_error = io.gateway_ready(gateway_binding)
        if ready_error then
            io.revoke_gateway(gateway_binding)
            io.close(listener)
            return nil, "wait for attempt gateway: " .. ready_error
        end
    end
    local started, start_error = io.start(request.attempt_id, gateway_binding)
    if start_error then
        if gateway_binding then io.revoke_gateway(gateway_binding) end
        io.close(listener)
        local reconciled, reconcile_error = io.reconcile(request.attempt_id)
        if reconcile_error then return uncertain(request, "start outcome cannot be reconciled: " .. reconcile_error) end
        local attempt = placement_attempt(reconciled)
        if attempt and attempt.attempt_id == request.attempt_id and placement_pending(attempt) then
            return pending(request, "placement start did not settle; attempt is still " .. tostring(attempt.execution_state), attempt)
        end
        if attempt and (attempt.execution_state == "start_failed" or attempt.start_failure ~= nil) then return failed_start(request, attempt) end
        if attempt and attempt.start_cancelled then return cancelled_start(request, attempt), nil end
        return uncertain(request, "start returned without a proven result: " .. start_error, attempt)
    end
    local started_attempt, started_decode_error = placement_attempt(started)
    if not started_attempt or started_attempt.attempt_id ~= request.attempt_id then
        io.close(listener)
        return uncertain(request, "placement start returned malformed evidence: " .. tostring(started_decode_error))
    end

    local observed, observe_error = io.observe(listener, started_attempt, normalize_target,
        request.checkpoint ~= nil and request.checkpoint.resume_ref ~= nil, request.checkpoint, request)
    io.close(listener)
    local reconciled, reconcile_error = io.reconcile(request.attempt_id)
    if reconcile_error then return uncertain(request, "placement exit cannot be proven: " .. reconcile_error, observed) end
    local final_attempt, final_decode_error = placement_attempt(reconciled)
    if final_attempt and final_attempt.attempt_id == request.attempt_id and (final_attempt.execution_state == "start_failed" or final_attempt.start_failure ~= nil) then return failed_start(request, final_attempt, observed) end
    if final_attempt and final_attempt.attempt_id == request.attempt_id and final_attempt.start_cancelled == true then
        return cancelled_start(request, final_attempt, observed), nil
    end
    if not final_attempt or final_attempt.attempt_id ~= request.attempt_id or final_attempt.execution_state ~= "exited" or final_attempt.exit_source == nil then
        return uncertain(request, "placement exit cannot be proven: " .. tostring(final_decode_error or "attempt is not proven exited"), final_attempt)
    end
    local observation = object(observed)
    local exceeded = observation and observation.budget_exceeded
    if exceeded ~= nil then
        if exceeded ~= "provider_steps" and exceeded ~= "tokens" and exceeded ~= "tool_calls" and exceeded ~= "wall_time_ms" then
            return uncertain(request, "executor reported an unsupported budget kind", final_attempt)
        end
        local artifacts = {"placement attempt " .. request.attempt_id,
            "execution state " .. tostring(final_attempt.execution_state),
            "exit observed by " .. tostring(final_attempt.exit_source),
            "budget " .. exceeded .. " exceeded"}
        return {state = "settled", outcome = "budget_exceeded",
            error = {code = "BUDGET_EXCEEDED", message = exceeded .. " exceeded"},
            attempt_id = request.attempt_id, checkpoint = {attempt_id = request.attempt_id,
                resume_ref = request.checkpoint and request.checkpoint.resume_ref},
            observations = observation.observations or {},
            evidence = {summary = "placement proved the CLI exited after the " .. exceeded .. " budget", artifacts = artifacts}}, nil
    end
    if observation and observation.stalled == true then
        return {state = "settled", outcome = "cancelled", error = {code = "STALLED", message = "quiet period exceeded; placement proved the process stopped"},
            attempt_id = request.attempt_id, checkpoint = {attempt_id = request.attempt_id, resume_ref = request.checkpoint and request.checkpoint.resume_ref},
            observations = observation.observations or {}, evidence = final_attempt}, nil
    end
    if observation and observation.stopped == true then
        return {state = "settled", outcome = "cancelled", error = {code = "CANCELLED", message = "placement stopped the process"},
            attempt_id = request.attempt_id, checkpoint = {attempt_id = request.attempt_id,
                resume_ref = request.checkpoint and request.checkpoint.resume_ref},
            observations = observation.observations or {}, evidence = final_attempt}, nil
    end
    if observe_error then return uncertain(request, "driver stream ended without a durable terminal report: " .. observe_error, final_attempt) end
    local terminal = observation and object(observation.terminal) or nil
    if not terminal or terminal.outcome == "uncertain" then
        return uncertain(request, "driver stream ended without a terminal result", final_attempt)
    end
    if terminal.outcome ~= "succeeded" and terminal.outcome ~= "failed" and terminal.outcome ~= "cancelled" then
        return uncertain(request, "driver reported an unsupported terminal outcome", final_attempt)
    end
    local resume_ref: string? = nil
    if terminal.resume_ref ~= nil then
        resume_ref = id(terminal.resume_ref)
        if not resume_ref then return uncertain(request, "driver resume identity is malformed", final_attempt) end
    end
    if terminal.outcome == "succeeded" and not resume_ref then
        return uncertain(request, "driver terminal report has no resume identity", final_attempt)
    end
    local checkpoint = {resume_ref = resume_ref, attempt_id = request.attempt_id, terminal = terminal}
    return {state = "settled", outcome = terminal.outcome, answer = terminal.answer, error = terminal.error, usage = terminal.usage,
        attempt_id = request.attempt_id, checkpoint = checkpoint, observations = observation.observations or {}, evidence = final_attempt}, nil
end

return M
