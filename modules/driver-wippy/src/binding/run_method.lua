-- MIT. Entry point for the in-process driver adapter and shared run lifecycle.
local bounds = require("bounds")
local runner = require("runner")
local managed_run = require("managed_run")
local types = require("types")

local M = {}
M.MAX_WAIT_MS = 30000
local DRIVER_STATUS = {carrier_epoch_starts = true, cancel_status_first = true,
    cancel_status_pending = true, tolerate_checkpoint_failure = true}

type RunRequest = {operation: "run", thread_id: string, action_id: string, attempt_id: string,
    agent_ref: string?, brief: string?, workspace_id: string?, host_config: types.HostConfig?,
    idempotency_key: string?, carrier_epoch: integer?}
type StatusRequest = {operation: "status", thread_id: string, attempt_id: string}
type WaitRequest = {operation: "wait", thread_id: string, attempt_id: string, wait_ms: integer}
type CancelRequest = {operation: "cancel", thread_id: string, attempt_id: string,
    wait_ms: integer, idempotency_key: string}
type Request = RunRequest | StatusRequest | WaitRequest | CancelRequest
type ScopedStatus = {thread_id: string, attempt_id: string, scope: "attempt", state: types.RunState,
    outcome: types.Outcome?, answer: string?, idempotency_key: string?}
type Receipt = {scope: "attempt", thread_id: string, action_id: string, attempt_id: string,
    state: types.RunState, idempotency_key: string?}
type DecodedRunResult = {ok: boolean, error: string?, outcome: types.Outcome, answer: string?,
    thread_id: string, action_id: string, attempt_id: string, receipt: Receipt?, state: types.RunState?, status: types.RunState?}

local function fail(code: string, message: string): {[string]: unknown}
    return {ok = false, error = {code = code, message = message}, value = nil}
end

local function exact_fields(object: {[string]: unknown}, allowed: {string}, label: string): string?
    local extra = bounds.fields(object, allowed)
    if extra then return label .. ": " .. extra end
    return nil
end

local function required_id(object: {[string]: unknown}, key: string): (string?, string?)
    local value = bounds.id(object[key])
    if not value then return nil, key .. " must be a bounded identifier" end
    return value, nil
end

local function optional_id(object: {[string]: unknown}, key: string): (string?, string?)
    if object[key] == nil then return nil, nil end
    return required_id(object, key)
end

local function optional_text(object: {[string]: unknown}, key: string, limit: integer): (string?, string?)
    if object[key] == nil then return nil, nil end
    local value = bounds.text(object[key], limit)
    if value == nil then return nil, key .. " must be text of at most " .. tostring(limit) .. " bytes" end
    return value, nil
end

local function workspace_id(value: string?): (string?, string?)
    if value == nil then return nil, nil end
    if #value ~= 32 or value:find("[^0-9a-f]") then return nil, "workspace_id must be a lowercase workspace identity" end
    return value, nil
end

local function wait_ms(object: {[string]: unknown}, default: integer): (integer?, string?)
    if object.wait_ms == nil then return default, nil end
    local value = bounds.integer(object.wait_ms)
    if not value or value < 0 then return nil, "wait_ms must be a nonnegative integer" end
    if value > M.MAX_WAIT_MS then return M.MAX_WAIT_MS, nil end
    return value, nil
end

local function run_state(value: unknown): types.RunState?
    if value == "starting" then return "starting" end
    if value == "running" then return "running" end
    if value == "ended" then return "ended" end
    if value == "cancelling" then return "cancelling" end
    return nil
end

local function decode_outcome(value: unknown): types.Outcome?
    if value == "succeeded" then return "succeeded" end
    if value == "failed" then return "failed" end
    if value == "cancelled" then return "cancelled" end
    if value == "uncertain" then return "uncertain" end
    return nil
end

local function decode_request(raw: unknown): (Request?, string?)
    local object = bounds.object(raw)
    if not object then return nil, "request must be an object" end
    local operation = object.operation
    if operation ~= nil and type(operation) ~= "string" then return nil, "operation must be a string" end

    if operation == nil or operation == "run" then
        local extra = exact_fields(object, {"operation", "thread_id", "action_id", "attempt_id", "agent_ref", "brief",
            "workspace_id", "host_config", "idempotency_key", "carrier_epoch"}, "run request")
        if extra then return nil, extra end
        local thread_id, thread_error = required_id(object, "thread_id")
        local action_id, action_error = required_id(object, "action_id")
        local attempt_id, attempt_error = required_id(object, "attempt_id")
        if not thread_id then return nil, thread_error end
        if not action_id then return nil, action_error end
        if not attempt_id then return nil, attempt_error end

        local agent_ref, agent_error = optional_id(object, "agent_ref")
        if agent_error then return nil, agent_error end
        local brief, brief_error = optional_text(object, "brief", 16384)
        if brief_error then return nil, brief_error end
        local workspace_raw, workspace_error = optional_id(object, "workspace_id")
        if workspace_error then return nil, workspace_error end
        local selected_workspace, selected_workspace_error = workspace_id(workspace_raw)
        if selected_workspace_error then return nil, selected_workspace_error end

        local host_config: types.HostConfig? = nil
        if object.host_config ~= nil then
            if not bounds.object(object.host_config) then return nil, "host_config must be an object" end
            local decoded, config_error = runner.decode_host_config(object.host_config)
            if not decoded then return nil, "host_config: " .. tostring(config_error) end
            host_config = decoded
        end
        local idempotency_key, key_error = optional_text(object, "idempotency_key", 128)
        if key_error then return nil, key_error end
        if idempotency_key ~= nil and idempotency_key == "" then return nil, "idempotency_key must not be empty" end
        local carrier_epoch: integer? = nil
        if object.carrier_epoch ~= nil then
            carrier_epoch = bounds.count(object.carrier_epoch)
            if carrier_epoch == nil then return nil, "carrier_epoch must be a nonnegative integer" end
        end
        return {operation = "run", thread_id = thread_id, action_id = action_id, attempt_id = attempt_id,
            agent_ref = agent_ref, brief = brief, workspace_id = selected_workspace, host_config = host_config,
            idempotency_key = idempotency_key, carrier_epoch = carrier_epoch}, nil
    end

    if operation == "status" or operation == "wait" or operation == "cancel" then
        local allowed = {"operation", "thread_id", "attempt_id"}
        if operation == "wait" or operation == "cancel" then allowed[#allowed + 1] = "wait_ms" end
        if operation == "cancel" then allowed[#allowed + 1] = "idempotency_key" end
        local extra = exact_fields(object, allowed, operation .. " request")
        if extra then return nil, extra end
        local thread_id, thread_error = required_id(object, "thread_id")
        local attempt_id, attempt_error = required_id(object, "attempt_id")
        if not thread_id then return nil, thread_error end
        if not attempt_id then return nil, attempt_error end
        if operation == "status" then return {operation = "status", thread_id = thread_id, attempt_id = attempt_id}, nil end
        if operation == "wait" then
            local timeout, timeout_error = wait_ms(object, 1000)
            if timeout_error then return nil, timeout_error end
            if not timeout then return nil, "wait_ms is missing" end
            local request: WaitRequest = {operation = "wait", thread_id = thread_id, attempt_id = attempt_id, wait_ms = timeout}
            return request, nil
        end
        local timeout, timeout_error = wait_ms(object, 0)
        if timeout_error then return nil, timeout_error end
        if not timeout then return nil, "wait_ms is missing" end
        local key, key_error = optional_text(object, "idempotency_key", 128)
        if key_error then return nil, key_error end
        if key == nil then key = attempt_id .. "-cancel" end
        if key == "" then return nil, "idempotency_key must not be empty" end
        local request: CancelRequest = {operation = "cancel", thread_id = thread_id, attempt_id = attempt_id,
            wait_ms = timeout, idempotency_key = key}
        return request, nil
    end
    return nil, "unsupported operation: " .. operation
end

local function decode_status(value: unknown, expected_thread: string, expected_attempt: string): (ScopedStatus?, string?)
    local object = bounds.object(value)
    if not object then return nil, "status must be an object" end
    local extra = exact_fields(object, {"thread_id", "attempt_id", "state", "outcome", "answer", "error",
        "idempotency_key", "cancel_intent", "uncertain"}, "status")
    if extra then return nil, extra end
    local thread_id, attempt_id = bounds.id(object.thread_id), bounds.id(object.attempt_id)
    if thread_id ~= expected_thread or attempt_id ~= expected_attempt then return nil, "status identities do not match the request" end
    local state = run_state(object.state)
    if not state then return nil, "status.state is invalid" end
    local outcome: types.Outcome? = nil
    if object.outcome ~= nil then
        outcome = decode_outcome(object.outcome)
        if not outcome then return nil, "status.outcome is invalid" end
    end
    local answer: string? = nil
    if object.answer ~= nil then
        answer = bounds.text(object.answer, 32768)
        if answer == nil then return nil, "status.answer exceeds its byte bound" end
    end
    if object.error ~= nil then
        local fault = bounds.object(object.error)
        if not fault or bounds.fields(fault, {"code", "message", "retryable"}) then return nil, "status.error is malformed" end
        if not bounds.id(fault.code) or not bounds.text(fault.message, record_bounds.MAX_FAULT_MESSAGE_BYTES)
            or (fault.retryable ~= nil and type(fault.retryable) ~= "boolean") then return nil, "status.error is malformed" end
    end
    local idempotency_key, key_error = optional_text(object, "idempotency_key", 128)
    if key_error then return nil, key_error end
    if object.cancel_intent ~= nil and type(object.cancel_intent) ~= "boolean" then return nil, "status.cancel_intent must be a boolean" end
    if object.uncertain ~= nil and type(object.uncertain) ~= "boolean" then return nil, "status.uncertain must be a boolean" end
    return {thread_id = thread_id, attempt_id = attempt_id, scope = "attempt", state = state,
        outcome = outcome, answer = answer, idempotency_key = idempotency_key}, nil
end

local function decode_receipt(value: unknown, request: RunRequest): (Receipt?, string?)
    if value == nil then return nil, nil end
    local object = bounds.object(value)
    if not object then return nil, "receipt must be an object" end
    local extra = exact_fields(object, {"scope", "thread_id", "action_id", "attempt_id", "state", "idempotency_key"}, "receipt")
    if extra then return nil, extra end
    local state = run_state(object.state)
    local key, key_error = optional_text(object, "idempotency_key", 128)
    if key_error then return nil, key_error end
    if object.scope ~= "attempt" or object.thread_id ~= request.thread_id or object.action_id ~= request.action_id
        or object.attempt_id ~= request.attempt_id or not state then return nil, "receipt does not match the run request" end
    local decoded: Receipt = {scope = "attempt", thread_id = request.thread_id, action_id = request.action_id,
        attempt_id = request.attempt_id, state = state, idempotency_key = key}
    return decoded, nil
end

local function decode_run_result(value: unknown, request: RunRequest): (DecodedRunResult?, string?)
    local object = bounds.object(value)
    if not object then return nil, "managed run returned no result object" end
    local extra = exact_fields(object, {"ok", "error", "outcome", "answer", "thread_id", "action_id",
        "attempt_id", "receipt", "state", "status"}, "managed run result")
    if extra then return nil, extra end
    if type(object.ok) ~= "boolean" then return nil, "managed run result.ok must be a boolean" end
    local selected_outcome = decode_outcome(object.outcome)
    local thread_id, action_id, attempt_id = bounds.id(object.thread_id), bounds.id(object.action_id), bounds.id(object.attempt_id)
    if not selected_outcome or not thread_id or not action_id or not attempt_id
        or thread_id ~= request.thread_id or action_id ~= request.action_id or attempt_id ~= request.attempt_id then
        return nil, "managed run result identities or outcome are invalid"
    end
    local error_message: string? = nil
    if object.error ~= nil then
        error_message = bounds.text(object.error, record_bounds.MAX_FAULT_MESSAGE_BYTES)
        if error_message == nil then return nil, "managed run result.error is malformed" end
    end
    if object.ok ~= (selected_outcome ~= "failed") or (not object.ok and (not error_message or error_message == "")) then
        return nil, "managed run result success and outcome disagree"
    end
    local answer: string? = nil
    if object.answer ~= nil then
        answer = bounds.text(object.answer, 32768)
        if answer == nil then return nil, "managed run result.answer exceeds its byte bound" end
    end
    local receipt, receipt_error = decode_receipt(object.receipt, request)
    if receipt_error then return nil, receipt_error end
    local state: types.RunState? = nil
    if object.state ~= nil then
        state = run_state(object.state)
        if not state then return nil, "managed run result.state is invalid" end
    end
    local status: types.RunState? = nil
    if object.status ~= nil then
        status = run_state(object.status)
        if not status then return nil, "managed run result.status is invalid" end
    end
    local decoded: DecodedRunResult = {ok = object.ok, error = error_message, outcome = selected_outcome, answer = answer,
        thread_id = thread_id, action_id = action_id, attempt_id = attempt_id,
        receipt = receipt, state = state, status = status}
    return decoded, nil
end

local function run(request: RunRequest): {[string]: unknown}
    local function execute_in_process(context: types.ExecutionContext, _request: {[string]: unknown}): types.ExecutionResult
        return runner.execute(context, request)
    end
    local decoded, result_error = decode_run_result(managed_run.execute(request, execute_in_process), request)
    if not decoded then return fail("INTERNAL", "decode managed run result: " .. tostring(result_error)) end
    return {
        ok = decoded.ok,
        error = decoded.error and {code = "FAILED", message = decoded.error} or nil,
        value = {
            thread_id = decoded.thread_id,
            action_id = decoded.action_id,
            attempt_id = decoded.attempt_id,
            outcome = decoded.outcome,
            answer = decoded.answer,
            state = decoded.state,
            receipt = decoded.receipt,
        },
    }
end

local function status(request: StatusRequest): {[string]: unknown}
    local current = managed_run.status({thread_id = request.thread_id, attempt_id = request.attempt_id}, DRIVER_STATUS)
    if not current then return fail("FAILED", "the attempt did not answer") end
    local selected, status_error = decode_status(current, request.thread_id, request.attempt_id)
    if not selected then return fail("INTERNAL", "decode attempt status: " .. tostring(status_error)) end
    return {ok = true, value = selected}
end

local function status_reply(reply: unknown, thread_id: string, attempt_id: string, idempotency_key: string?): {[string]: unknown}
    local object = bounds.object(reply)
    if not object then return fail("INTERNAL", "managed run returned a malformed status reply") end
    local extra = exact_fields(object, {"ok", "error", "value", "replayed"}, "status reply")
    if extra then return fail("INTERNAL", "managed run returned a malformed status reply: " .. extra) end
    if type(object.ok) ~= "boolean" then return fail("INTERNAL", "managed run returned a malformed status reply") end
    if object.replayed ~= nil and type(object.replayed) ~= "boolean" then
        return fail("INTERNAL", "managed run returned a malformed replay flag")
    end
    if object.ok == false then
        if object.value ~= nil then return fail("INTERNAL", "failed status reply carries a value") end
        local fault = bounds.object(object.error)
        if not fault or bounds.fields(fault, {"code", "message"}) then return fail("INTERNAL", "managed run returned a malformed fault") end
        local code, message = bounds.id(fault.code), bounds.text(fault.message, record_bounds.MAX_FAULT_MESSAGE_BYTES)
        if not code or message == nil then return fail("INTERNAL", "managed run returned a malformed fault") end
        return fail(code, message)
    end
    if object.error ~= nil then return fail("INTERNAL", "successful status reply carries a fault") end
    local selected, status_error = decode_status(object.value, thread_id, attempt_id)
    if not selected then return fail("INTERNAL", "decode attempt status: " .. tostring(status_error)) end
    selected.idempotency_key = idempotency_key or selected.idempotency_key
    return {ok = true, value = selected}
end

local function handle(raw: unknown): {[string]: unknown}
    local request, request_error = decode_request(raw)
    if not request then return fail("INVALID", tostring(request_error)) end
    if request.operation == "run" then return run(request) end
    if request.operation == "status" then return status(request) end
    if request.operation == "wait" then
        local reply = managed_run.wait({thread_id = request.thread_id, attempt_id = request.attempt_id}, request.wait_ms, DRIVER_STATUS)
        return status_reply(reply, request.thread_id, request.attempt_id, nil)
    end
    local reply = managed_run.cancel({thread_id = request.thread_id, attempt_id = request.attempt_id},
        request.wait_ms, request.idempotency_key, {prestart = "signal"})
    return status_reply(reply, request.thread_id, request.attempt_id, request.idempotency_key)
end

return {handle = handle}
