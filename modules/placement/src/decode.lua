-- Decoders for placement values that cross an owner boundary.
local bounds = require("bounds")
local types = require("types")
local M = {}

local function digest(value: unknown): string?
    local decoded = bounds.text(value, 64)
    if not decoded or #decoded ~= 64 or not decoded:match("^[0-9a-f]+$") then return nil end
    return decoded
end

function M.execution(value: unknown): types.ExecutionState?
    if value == "intended" then return "intended" end
    if value == "starting" then return "starting" end
    if value == "running" then return "running" end
    if value == "stopping" then return "stopping" end
    if value == "exited" then return "exited" end
    if value == "uncertain" then return "uncertain" end
    return nil
end

function M.cleanup(value: unknown): types.CleanupState?
    if value == "pending" then return "pending" end
    if value == "complete" then return "complete" end
    if value == "uncertain" then return "uncertain" end
    return nil
end

function M.capability(value: unknown): types.Capability?
    if value == "direct_process" then return "direct_process" end
    if value == "process_group" then return "process_group" end
    if value == "contained_tree" then return "contained_tree" end
    return nil
end

function M.exit_observation(value: unknown): types.ExitObservation?
    if value == "independent" then return "independent" end
    if value == "eof_gated" then return "eof_gated" end
    return nil
end

function M.attempt(value: unknown): (types.Attempt?, string?)
    local object = bounds.object(value)
    if not object then return nil, "attempt must be an object" end
    local unknown_field = bounds.fields(object, {"attempt_id", "action_id", "owner_id", "owner_incarnation", "request_digest", "execution_state", "cleanup_state", "capability", "required_cleanup", "exit_observation", "exit_source", "start_failure", "attachment_generation", "exit", "session_ref", "home_ref", "runner", "evidence_count", "created_at", "updated_at", "notice"})
    if unknown_field then return nil, "attempt: " .. unknown_field end
    local attempt_id, action_id, owner_id = bounds.id(object.attempt_id), bounds.id(object.action_id), bounds.id(object.owner_id)
    local owner_incarnation = bounds.count(object.owner_incarnation)
    local request_digest = digest(object.request_digest)
    local execution_state, cleanup_state = M.execution(object.execution_state), M.cleanup(object.cleanup_state)
    local capability_value, required_cleanup = M.capability(object.capability), M.capability(object.required_cleanup)
    local observation = M.exit_observation(object.exit_observation)
    local attachment_generation, evidence_count = bounds.count(object.attachment_generation), bounds.count(object.evidence_count)
    local created_at, updated_at = bounds.timestamp(object.created_at), bounds.timestamp(object.updated_at)
    if not attempt_id or not action_id or not owner_id or not owner_incarnation or owner_incarnation < 1
        or not request_digest or not execution_state or not cleanup_state or not capability_value or not required_cleanup
        or not observation or attachment_generation == nil or evidence_count == nil or not created_at or not updated_at then
        return nil, "attempt has invalid or missing fields"
    end
    local exit_source: string? = nil
    local start_failure: string? = nil
    if object.start_failure ~= nil then
        start_failure = bounds.text(object.start_failure, 4096)
        if not start_failure then return nil, "attempt start_failure is invalid" end
    end
    if object.exit_source ~= nil then
        exit_source = bounds.id(object.exit_source)
        if not exit_source then return nil, "attempt exit_source is invalid" end
    end
    local session_ref: string? = nil
    if object.session_ref ~= nil then
        session_ref = bounds.id(object.session_ref)
        if not session_ref then return nil, "attempt session_ref is invalid" end
    end
    local home_ref: string? = nil
    if object.home_ref ~= nil then
        home_ref = bounds.id(object.home_ref)
        if not home_ref then return nil, "attempt home_ref is invalid" end
    end
    local runner: string? = nil
    if object.runner ~= nil then
        runner = bounds.id(object.runner)
        if not runner then return nil, "attempt runner is invalid" end
    end
    local exit: types.Exit? = nil
    if object.exit ~= nil then
        local declared_exit = bounds.object(object.exit)
        if not declared_exit then return nil, "attempt exit must be an object" end
        local exit_field = bounds.fields(declared_exit, {"code", "signal"})
        if exit_field then return nil, "attempt exit: " .. exit_field end
        local code = declared_exit.code == nil and nil or bounds.integer(declared_exit.code)
        local signal = declared_exit.signal == nil and nil or bounds.integer(declared_exit.signal)
        if (declared_exit.code ~= nil and code == nil) or (declared_exit.signal ~= nil and signal == nil) then return nil, "attempt exit values are invalid" end
        exit = {code = code, signal = signal}
    end
    local notice: types.LoginNotice? = nil
    if object.notice ~= nil then
        local declared_notice = bounds.object(object.notice)
        if not declared_notice then return nil, "attempt notice must be an object" end
        local notice_field = bounds.fields(declared_notice, {"code", "provider", "command"})
        local provider, command = bounds.id(declared_notice.provider), bounds.line(declared_notice.command, 2048)
        if notice_field or declared_notice.code ~= "LOGIN_REQUIRED" or not provider or not command then return nil, "attempt notice is malformed" end
        notice = {code = "LOGIN_REQUIRED", provider = provider, command = command}
    end
    return {attempt_id = attempt_id, action_id = action_id, owner_id = owner_id, owner_incarnation = owner_incarnation,
        request_digest = request_digest, execution_state = execution_state, cleanup_state = cleanup_state, capability = capability_value,
        required_cleanup = required_cleanup, exit_observation = observation, exit_source = exit_source, start_failure = start_failure,
        attachment_generation = attachment_generation, exit = exit, session_ref = session_ref, home_ref = home_ref, runner = runner,
        evidence_count = evidence_count, created_at = created_at, updated_at = updated_at, notice = notice}, nil
end

function M.status(value: unknown): (types.Status?, string?)
    local object = bounds.object(value)
    if not object then return nil, "status must be an object" end
    local unknown_field = bounds.fields(object, {"attempt", "liveness", "private_home"})
    if unknown_field then return nil, "status: " .. unknown_field end
    local attempt, attempt_error = M.attempt(object.attempt)
    if not attempt then return nil, attempt_error end
    local liveness_object = bounds.object(object.liveness)
    if not liveness_object then return nil, "status liveness must be an object" end
    local liveness_field = bounds.fields(liveness_object, {"observed", "alive", "at", "detail"})
    local observed = liveness_object.observed
    local at = bounds.timestamp(liveness_object.at)
    local detail = bounds.text(liveness_object.detail, 4096)
    if liveness_field or type(observed) ~= "boolean" or not at or not detail then return nil, "status liveness is malformed" end
    local alive: boolean? = nil
    if liveness_object.alive ~= nil then
        if type(liveness_object.alive) ~= "boolean" then return nil, "status liveness alive flag is malformed" end
        alive = liveness_object.alive
    end
    local private_home: boolean? = nil
    if object.private_home ~= nil then
        if type(object.private_home) ~= "boolean" then return nil, "status private_home flag is malformed" end
        private_home = object.private_home
    end
    return {attempt = attempt, liveness = {observed = observed, alive = alive, at = at, detail = detail}, private_home = private_home}, nil
end

type StdinClosure = {closed: boolean, reason: string?}
function M.stdin_closure(value: unknown, attempt_id: string): (StdinClosure?, string?)
    local object = bounds.object(value)
    if not object then return nil, "close_stdin result must be an object" end
    local unknown_field = bounds.fields(object, {"attempt", "closed", "reason"})
    if unknown_field then return nil, "close_stdin: " .. unknown_field end
    local attempt, attempt_error = M.attempt(object.attempt)
    if not attempt then return nil, "close_stdin attempt: " .. tostring(attempt_error) end
    if attempt.attempt_id ~= attempt_id then return nil, "close_stdin returned another attempt" end
    if type(object.closed) ~= "boolean" then return nil, "close_stdin closed flag is invalid" end
    local reason: string? = nil
    if object.reason ~= nil then
        reason = bounds.text(object.reason, 4096)
        if not reason or reason == "" then return nil, "close_stdin refusal reason is invalid" end
    end
    if (object.closed == true and reason ~= nil) or (object.closed == false and reason == nil) then return nil, "close_stdin result and reason disagree" end
    return {closed = object.closed, reason = reason}, nil
end

return M
