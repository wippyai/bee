-- MIT. One external CLI process belongs to one immutable pulled turn.
local M = {}

type IO = {
    reconcile: (string) -> (unknown, string?),
    cleanup: (string) -> (unknown, string?),
    driver: (string, string, unknown) -> (unknown, string?),
    prepare: (unknown) -> (unknown, string?),
    listen: () -> (unknown, string?),
    attach: (string, integer) -> (unknown, string?),
    start: (string) -> (unknown, string?),
    observe: (unknown, unknown, string, boolean, unknown) -> (unknown, string?),
    close: (unknown) -> (),
}

type Request = {
    attempt_id: string,
    generation: integer,
    prompt: string,
    sender: {kind: "session" | "principal", id: string},
    driver_binding_ref: string,
    profile_id: string,
    driver_methods: {[string]: string},
    driver_options: {[string]: unknown},
    placement_methods: {[string]: string},
    placement_request: {[string]: unknown},
    previous_attempt_id: string?,
    checkpoint: {[string]: unknown}?,
}

local PLACEMENT_METHODS = {
    prepare = "bee.placement.native.binding:prepare", attach = "bee.placement.native.binding:attach",
    start = "bee.placement.native.binding:start", reconcile = "bee.placement.native.binding:reconcile",
    cleanup = "bee.placement.native.binding:cleanup",
}

local function object(value: unknown): {[string]: unknown}?
    if type(value) == "table" then return value :: {[string]: unknown} end
    return nil
end

local function id(value: unknown): string?
    if type(value) ~= "string" or value == "" or #value > 256 or value:find("[%c%s]") then return nil end
    return value
end

local function decode(value: unknown): (Request?, string?)
    local request = object(value)
    if not request then return nil, "turn request must be an object" end
    local allowed = {"attempt_id", "generation", "prompt", "sender", "driver_binding_ref", "profile_id", "driver_methods", "driver_options",
        "placement_methods", "placement_request", "previous_attempt_id", "checkpoint"}
    local fields: {[string]: boolean} = {}
    for _, field in ipairs(allowed) do fields[field] = true end
    for field in pairs(request) do
        if not fields[tostring(field)] then return nil, "turn request has unknown field " .. tostring(field) end
    end
    local attempt_id = id(request.attempt_id)
    if not attempt_id then return nil, "attempt_id is invalid" end
    if type(request.generation) ~= "number" or math.floor(request.generation) ~= request.generation or request.generation < 1 then
        return nil, "generation must be a positive integer"
    end
    if type(request.prompt) ~= "string" or #request.prompt == 0 or #request.prompt > 16384 then return nil, "prompt must be nonempty bounded text" end
    local sender = object(request.sender)
    if not sender or (sender.kind ~= "session" and sender.kind ~= "principal") or not id(sender.id) then
        return nil, "sender must be an authenticated session or principal identity"
    end
    local driver_binding_ref = id(request.driver_binding_ref)
    if not driver_binding_ref then return nil, "driver_binding_ref is invalid" end
    local profile_id = id(request.profile_id)
    if not profile_id then return nil, "profile_id is invalid" end
    local driver_methods = object(request.driver_methods)
    if not driver_methods then return nil, "driver_methods must be an object" end
    local binding_prefix = driver_binding_ref:gsub(":", ".") .. ":"
    for _, method in ipairs({"prepare", "dispatch", "normalize"}) do
        local target = id(driver_methods[method])
        if not target or target:sub(1, #binding_prefix) ~= binding_prefix
            or not target:match("^bee[.]driver[.][A-Za-z0-9_.-]+[.]binding:" .. method .. "$") then
            return nil, "driver_methods." .. method .. " is not an operation of the selected bee.driver binding"
        end
    end
    local driver_options = object(request.driver_options or {})
    if not driver_options then return nil, "driver_options must be an object" end
    if driver_options.control_enabled ~= nil or driver_options.permission_exchange ~= nil
        or driver_options.gateway_tools ~= nil or driver_options.gateway_hooks ~= nil then
        return nil, "turn execution does not accept injected controls or driver frames"
    end
    local placement_methods = object(request.placement_methods)
    if not placement_methods then return nil, "placement_methods must be an object" end
    for _, method in ipairs({"prepare", "attach", "start", "reconcile", "cleanup"}) do
        if placement_methods[method] ~= PLACEMENT_METHODS[method] then
            return nil, "placement_methods." .. method .. " is not the host-selected native binding"
        end
    end
    local placement_request = object(request.placement_request)
    if not placement_request then return nil, "placement_request must be an object" end
    if placement_request.attempt_id ~= attempt_id then return nil, "placement request attempt_id differs from the turn" end
    if placement_request.binding_ref ~= driver_binding_ref then
        return nil, "placement request binding_ref differs from the selected driver"
    end
    if placement_request.profile_id ~= profile_id then return nil, "placement request profile_id differs from the selected profile" end
    local previous_attempt_id: string? = nil
    if request.previous_attempt_id ~= nil then
        previous_attempt_id = id(request.previous_attempt_id)
        if not previous_attempt_id or previous_attempt_id == attempt_id then return nil, "previous_attempt_id is invalid" end
    end
    local checkpoint = object(request.checkpoint)
    if request.checkpoint ~= nil and not checkpoint then return nil, "checkpoint must be an object" end
    local resume_ref = checkpoint and checkpoint.resume_ref or nil
    if resume_ref ~= nil and not id(resume_ref) then return nil, "checkpoint.resume_ref is invalid" end
    local sender_label = "[Bee sender " .. tostring(sender.kind) .. " " .. tostring(sender.id) .. "]\n"
    if #sender_label + #request.prompt > 16384 then return nil, "prompt and sender identity exceed 16384 bytes" end
    return {
        attempt_id = attempt_id, generation = request.generation :: integer, prompt = sender_label .. (request.prompt :: string),
        sender = sender :: {kind: "session" | "principal", id: string},
        driver_binding_ref = driver_binding_ref, profile_id = profile_id, driver_methods = driver_methods :: {[string]: string},
        driver_options = driver_options, placement_methods = placement_methods :: {[string]: string},
        placement_request = placement_request, previous_attempt_id = previous_attempt_id, checkpoint = checkpoint,
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

local function call_previous(io: IO, attempt_id: string): (Recovery, string?, unknown?)
    local value, call_error = io.reconcile(attempt_id)
    if call_error then return "uncertain", "reconcile previous placement attempt: " .. call_error, nil end
    local attempt, decode_error = placement_attempt(value)
    if not attempt then return "uncertain", "reconcile previous placement attempt: " .. tostring(decode_error), nil end
    if placement_pending(attempt) then
        return "pending", "previous placement attempt is still " .. tostring(attempt.execution_state), attempt
    end
    if attempt.execution_state ~= "exited" or attempt.exit_source == nil then
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

local function driver_call(io: IO, request: Request): (string?, unknown?, string?)
    local resumed = request.checkpoint ~= nil and request.checkpoint.resume_ref ~= nil
    local method = resumed and "dispatch" or "prepare"
    local target = request.driver_methods[method]
    local args: {[string]: unknown} = {}
    for name, value in pairs(request.driver_options) do args[name] = value end
    args.profile_id = request.profile_id
    args.brief = request.prompt
    if resumed then args.resume_ref = request.checkpoint and request.checkpoint.resume_ref end
    local raw, call_error = io.driver(method, target, args)
    if call_error then return nil, nil, "driver " .. method .. ": " .. call_error end
    local reply = object(raw)
    if not reply or reply.ok ~= true or type(reply.launch) ~= "table" then
        return nil, nil, "driver " .. method .. " refused the turn"
    end
    return target, reply.launch, nil
end

local function uncertain(request: Request, reason: string, attempt: unknown?): {[string]: unknown}
    return {state = "uncertain", outcome = "uncertain", attempt_id = request.attempt_id,
        evidence = {code = "external_interruption", message = reason, placement = attempt}}
end

function M.execute(io: IO, value: unknown): ({[string]: unknown}?, string?)
    local request, decode_error = decode(value)
    if not request then return nil, decode_error end

    -- Recovery is a precondition for every new driver invocation.
    if request.previous_attempt_id then
        local recovery, recovery_error, attempt = call_previous(io, request.previous_attempt_id)
        if recovery == "pending" then return pending(request, recovery_error or "previous attempt is still active", attempt) end
        if recovery == "uncertain" then return uncertain(request, recovery_error or "previous attempt did not reconcile", attempt) end
    end

    local _, launch, driver_error = driver_call(io, request)
    if not launch then return nil, driver_error end
    local placement_request: {[string]: unknown} = {}
    for name, field in pairs(request.placement_request) do placement_request[name] = field end
    placement_request.launch = launch
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
    local started, start_error = io.start(request.attempt_id)
    if start_error then
        io.close(listener)
        local reconciled, reconcile_error = io.reconcile(request.attempt_id)
        if reconcile_error then return uncertain(request, "start outcome cannot be reconciled: " .. reconcile_error) end
        local attempt = placement_attempt(reconciled)
        if attempt and attempt.attempt_id == request.attempt_id and placement_pending(attempt) then
            return pending(request, "placement start did not settle; attempt is still " .. tostring(attempt.execution_state), attempt)
        end
        return uncertain(request, "start returned without a proven result: " .. start_error, attempt)
    end
    local started_attempt, started_decode_error = placement_attempt(started)
    if not started_attempt or started_attempt.attempt_id ~= request.attempt_id then
        io.close(listener)
        return uncertain(request, "placement start returned malformed evidence: " .. tostring(started_decode_error))
    end

    local observed, observe_error = io.observe(listener, started_attempt, request.driver_methods.normalize :: string,
        request.checkpoint ~= nil and request.checkpoint.resume_ref ~= nil, request.checkpoint)
    io.close(listener)
    local reconciled, reconcile_error = io.reconcile(request.attempt_id)
    if reconcile_error then return uncertain(request, "placement exit cannot be proven: " .. reconcile_error, observed) end
    local final_attempt, final_decode_error = placement_attempt(reconciled)
    if not final_attempt or final_attempt.execution_state ~= "exited" or final_attempt.exit_source == nil then
        return uncertain(request, "placement exit cannot be proven: " .. tostring(final_decode_error or "attempt is not proven exited"), final_attempt)
    end
    if observe_error then return uncertain(request, "driver stream ended without a durable terminal report: " .. observe_error, final_attempt) end
    local observation = object(observed)
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
    return {state = "settled", outcome = terminal.outcome, answer = terminal.answer, usage = terminal.usage,
        attempt_id = request.attempt_id, checkpoint = checkpoint, observations = observation.observations or {}, evidence = final_attempt}, nil
end

return M
