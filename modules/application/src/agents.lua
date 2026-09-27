-- MIT. Managed agents from an application or an agent: launch one on an
-- existing or a new thread, read its status, wait for it through its thread
-- and cancel it. Every call runs as the calling process's own actor through
-- the harness's application facade; the host decides which launch
-- definitions the caller may start and which overrides each admits, and the
-- library grants nothing.
local funcs = require("funcs")
local time = require("time")
local caller = require("caller")
local agent_protocol = require("agent_protocol")
local bounds = require("bounds")
local record_types = require("record_types")
local M = {}
M.FACADE = "bee.harness.launch:agent_call"
-- The longest one wait call blocks; a longer wait is a series of them.
M.WAIT_SLICE_MS = 60000
-- A launch request is agent_protocol.Launch: workdir {resource = name} or
-- {root_ref = root, path = folder}; thread {thread_id = id} or {title = text};
-- placement "native" or "docker".
type Run = {thread_id: string, action_id: string, attempt_id: string, definition_ref: string, title: string, brief: string}
type RunState = "starting" | "running" | "ended" | "cancelling"
type Fault = {code: string, message: string, retryable: boolean}
type Receipt = {scope: "attempt", thread_id: string, action_id: string, attempt_id: string, state: RunState, idempotency_key: string?}
type RunReceipt = {thread_id: string, action_id: string, attempt_id: string, definition_ref: string, title: string, brief: string,
    state: RunState, status: RunState?, outcome: record_types.Outcome?, answer: string?, error: Fault?, idempotency_key: string?,
    saved_profile_revision: integer?, owner_component_revision: integer?, receipt: Receipt}
-- state is starting, running, ended or cancelling; outcome and answer are
-- set once the attempt has ended.
type Status = {thread_id: string, attempt_id: string, state: RunState, outcome: record_types.Outcome?, answer: string?, error: Fault?,
    idempotency_key: string?, cancel_intent: boolean?, uncertain: boolean?}
local owner = caller.new(function(target: string, request: unknown): (unknown, string?)
    local reply, err = funcs.call(target, request)
    if err then return nil, tostring(err) end
    return reply, nil
end)
local function state(value: unknown): RunState?
    if value == "starting" then return "starting" end
    if value == "running" then return "running" end
    if value == "ended" then return "ended" end
    if value == "cancelling" then return "cancelling" end
    return nil
end
local function invoke(request: {[string]: unknown}): ({[string]: unknown}?, caller.Fault?)
    local reply = owner:invoke(M.FACADE, request) or caller.unknown()
    if not reply.ok then return nil, reply.error or {code = "INTERNAL", message = "the agent facade refused without a fault"} end
    local value = bounds.object(reply.value)
    if not value then return nil, {code = "INTERNAL", message = "the agent facade returned no object value"} end
    return value, nil
end
local function outcome(value: unknown): record_types.Outcome?
    if value == "succeeded" then return "succeeded" end
    if value == "failed" then return "failed" end
    if value == "cancelled" then return "cancelled" end
    if value == "uncertain" then return "uncertain" end
    return nil
end
local function decode_fault(value: unknown): Fault?
    if value == nil then return nil end
    local object = bounds.object(value)
    if not object or bounds.fields(object, {"code", "message", "retryable"}) then return nil end
    local code = bounds.id(object.code)
    local message = bounds.text(object.message, bounds.MAX_FAULT_MESSAGE_BYTES)
    if not code or not message or type(object.retryable) ~= "boolean" then return nil end
    return {code = code, message = message, retryable = object.retryable}
end
local function bounded_text(value: unknown, limit: integer): string?
    return bounds.text(value, limit)
end
local function status_of(value: {[string]: unknown}): (Status?, caller.Fault?)
    if bounds.fields(value, {"thread_id", "attempt_id", "state", "outcome", "answer", "error", "idempotency_key", "cancel_intent", "uncertain"}) then
        return nil, {code = "INTERNAL", message = "the agent facade returned a malformed status"}
    end
    local thread_id, attempt_id = bounds.id(value.thread_id), bounds.id(value.attempt_id)
    local current_state = state(value.state)
    local current_outcome: record_types.Outcome? = nil
    if value.outcome ~= nil then current_outcome = outcome(value.outcome); if not current_outcome then return nil, {code = "INTERNAL", message = "the agent facade returned an invalid outcome"} end end
    local answer = value.answer == nil and nil or bounded_text(value.answer, 32768)
    local fault = value.error == nil and nil or decode_fault(value.error)
    local idempotency_key = value.idempotency_key == nil and nil or bounded_text(value.idempotency_key, 128)
    if not thread_id or not attempt_id or not current_state
        or (value.answer ~= nil and not answer) or (value.error ~= nil and not fault)
        or (value.idempotency_key ~= nil and not idempotency_key)
        or (value.cancel_intent ~= nil and type(value.cancel_intent) ~= "boolean")
        or (value.uncertain ~= nil and type(value.uncertain) ~= "boolean") then
        return nil, {code = "INTERNAL", message = "the agent facade returned a malformed status"}
    end
    local cancel_intent: boolean? = nil
    if type(value.cancel_intent) == "boolean" then cancel_intent = value.cancel_intent end
    local uncertain: boolean? = nil
    if type(value.uncertain) == "boolean" then uncertain = value.uncertain end
    return {thread_id = thread_id, attempt_id = attempt_id, state = current_state, outcome = current_outcome,
        answer = answer, error = fault, idempotency_key = idempotency_key,
        cancel_intent = cancel_intent, uncertain = uncertain}, nil
end
function M.decode_run_receipt(value: unknown): (RunReceipt?, string?)
    local object = bounds.object(value)
    if not object then return nil, "run receipt must be an object" end
    local unknown = bounds.fields(object, {"thread_id", "action_id", "attempt_id", "definition_ref", "title", "brief",
        "state", "status", "outcome", "answer", "error", "idempotency_key", "saved_profile_revision",
        "owner_component_revision", "receipt"})
    if unknown then return nil, "run receipt: " .. unknown end
    local thread_id, action_id, attempt_id = bounds.id(object.thread_id), bounds.id(object.action_id), bounds.id(object.attempt_id)
    local definition_ref = bounds.id(object.definition_ref)
    local title, brief = bounds.text(object.title, 160), bounds.text(object.brief, 16384)
    local current_state = state(object.state)
    local current_status: RunState? = nil
    if object.status ~= nil then current_status = state(object.status); if not current_status then return nil, "run receipt.status is invalid" end end
    local current_outcome: record_types.Outcome? = nil
    if object.outcome ~= nil then current_outcome = outcome(object.outcome); if not current_outcome then return nil, "run receipt.outcome is invalid" end end
    local answer = object.answer == nil and nil or bounds.text(object.answer, 32768)
    local fault = object.error == nil and nil or decode_fault(object.error)
    local idempotency_key = object.idempotency_key == nil and nil or bounds.text(object.idempotency_key, 128)
    local profile_revision = object.saved_profile_revision == nil and nil or bounds.count(object.saved_profile_revision)
    local component_revision = object.owner_component_revision == nil and nil or bounds.count(object.owner_component_revision)
    local raw_receipt = bounds.object(object.receipt)
    if not thread_id or not action_id or not attempt_id or not definition_ref or not title or not brief or not current_state
        or (object.answer ~= nil and not answer) or (object.error ~= nil and not fault)
        or (object.idempotency_key ~= nil and not idempotency_key)
        or (object.saved_profile_revision ~= nil and (not profile_revision or profile_revision < 1))
        or (object.owner_component_revision ~= nil and (not component_revision or component_revision < 1))
        or not raw_receipt then return nil, "run receipt fields are malformed" end
    local receipt_unknown = bounds.fields(raw_receipt, {"scope", "thread_id", "action_id", "attempt_id", "state", "idempotency_key"})
    local receipt_thread, receipt_action, receipt_attempt = bounds.id(raw_receipt.thread_id), bounds.id(raw_receipt.action_id), bounds.id(raw_receipt.attempt_id)
    local receipt_state = state(raw_receipt.state)
    local receipt_key = raw_receipt.idempotency_key == nil and nil or bounds.text(raw_receipt.idempotency_key, 128)
    if receipt_unknown or raw_receipt.scope ~= "attempt" or receipt_thread ~= thread_id or receipt_action ~= action_id
        or receipt_attempt ~= attempt_id or receipt_state ~= current_state
        or (raw_receipt.idempotency_key ~= nil and not receipt_key) then return nil, "run receipt evidence is malformed" end
    if not receipt_thread or not receipt_action or not receipt_attempt or not receipt_state then
        return nil, "run receipt evidence is malformed"
    end
    local receipt: Receipt = {scope = "attempt", thread_id = receipt_thread, action_id = receipt_action,
        attempt_id = receipt_attempt, state = receipt_state, idempotency_key = receipt_key}
    return {thread_id = thread_id, action_id = action_id, attempt_id = attempt_id, definition_ref = definition_ref,
        title = title, brief = brief, state = current_state, status = current_status, outcome = current_outcome,
        answer = answer, error = fault, idempotency_key = idempotency_key, saved_profile_revision = profile_revision,
        owner_component_revision = component_revision, receipt = receipt}, nil
end
function M.launch(request: agent_protocol.Launch): (Run?, caller.Fault?)
    local body: {[string]: unknown} = {operation = "launch", definition_ref = request.definition_ref, brief = request.brief,
        idempotency_key = request.idempotency_key, workspace_id = request.workspace_id, saved_profile_id = request.saved_profile_id,
        saved_profile_revision = request.saved_profile_revision, workdir = request.workdir, thread = request.thread, placement = request.placement,
        agent_ref = request.agent_ref, owner_component_revision = request.owner_component_revision, spec_digest = request.spec_digest}
    local value, fault = invoke(body)
    if not value then return nil, fault end
    local thread_id, action_id, attempt_id = bounds.id(value.thread_id), bounds.id(value.action_id), bounds.id(value.attempt_id)
    local definition_ref = bounds.id(value.definition_ref)
    local title, brief = bounds.text(value.title, 160), bounds.text(value.brief, 16384)
    if not thread_id or not action_id or not attempt_id or not definition_ref or not title or not brief then
        return nil, {code = "INTERNAL", message = "the agent facade returned a malformed run"}
    end
    return {thread_id = thread_id, action_id = action_id, attempt_id = attempt_id, definition_ref = definition_ref, title = title, brief = brief}, nil
end
-- Runs an agent and returns a durable receipt promptly.
function M.run(request: agent_protocol.Launch): (RunReceipt?, caller.Fault?)
    local body: {[string]: unknown} = {operation = "run", definition_ref = request.definition_ref, brief = request.brief,
        idempotency_key = request.idempotency_key, workspace_id = request.workspace_id, saved_profile_id = request.saved_profile_id,
        saved_profile_revision = request.saved_profile_revision, workdir = request.workdir, thread = request.thread, placement = request.placement,
        agent_ref = request.agent_ref, owner_component_revision = request.owner_component_revision, spec_digest = request.spec_digest}
    local value, fault = invoke(body)
    if not value then return nil, fault end
    local receipt, receipt_error = M.decode_run_receipt(value)
    if not receipt then return nil, {code = "INTERNAL", message = receipt_error or "the agent facade returned a malformed run receipt"} end
    return receipt, nil
end
function M.status(run: Run): (Status?, caller.Fault?)
    local value, fault = invoke({operation = "status", thread_id = run.thread_id, attempt_id = run.attempt_id})
    if not value then return nil, fault end
    return status_of(value)
end
-- Waits until the run ends or timeout_ms passes, reading its thread; the
-- last status says which. A timeout leaves the run as it is.
function M.wait(run: Run, timeout_ms: integer): (Status?, caller.Fault?)
    local deadline = time.now():unix_nano() / 1000000 + math.max(timeout_ms, 0)
    while true do
        local remaining = math.floor(deadline - time.now():unix_nano() / 1000000)
        local slice = math.max(0, math.min(remaining, M.WAIT_SLICE_MS))
        local value, fault = invoke({operation = "wait", thread_id = run.thread_id, attempt_id = run.attempt_id, wait_ms = slice})
        if not value then return nil, fault end
        local current, invalid = status_of(value)
        if not current then return nil, invalid end
        if current.state == "ended" or remaining <= 0 then return current, nil end
    end
end
-- Asks the run's placement to stop its child; the run then ends cancelled.
-- A run whose child has not started yet is settled as cancelled with an attempt receipt.
-- Records an idempotent cancel intent and waits for terminal carrier record if timeout_ms is set.
function M.cancel(run: Run, timeout_ms: integer?, idempotency_key: string?): (Status?, caller.Fault?)
    local req: {[string]: unknown} = {operation = "cancel", thread_id = run.thread_id, attempt_id = run.attempt_id}
    if timeout_ms ~= nil then req.wait_ms = math.max(0, timeout_ms) end
    if idempotency_key ~= nil then req.idempotency_key = idempotency_key end
    local value, fault = invoke(req)
    if not value then return nil, fault end
    return status_of(value)
end
return M
