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
local M = {}
M.FACADE = "bee.harness.launch:agent_call"
-- The longest one wait call blocks; a longer wait is a series of them.
M.WAIT_SLICE_MS = 60000
-- A launch request is agent_protocol.Launch: workdir {resource = name} or
-- {root_ref = root, path = folder}; thread {thread_id = id} or {title = text};
-- placement "native" or "docker".
type Run = {thread_id: string, action_id: string, attempt_id: string, definition_ref: string, title: string, brief: string}
type RunReceipt = {thread_id: string, action_id: string, attempt_id: string, definition_ref: string, title: string, brief: string,
    state: string, status: string?, outcome: string?, answer: string?, idempotency_key: string?,
    saved_profile_revision: integer?, owner_component_revision: integer?, receipt: {[string]: unknown}?}
-- state is starting, running, ended or cancelling; outcome and answer are
-- set once the attempt has ended.
type Status = {thread_id: string, attempt_id: string, state: string, outcome: string?, answer: string?}
local owner = caller.new(function(target: string, request: unknown): (unknown, string?)
    local reply, err = funcs.call(target, request)
    if err then return nil, tostring(err) end
    return reply, nil
end)
local function text(value: unknown): string?
    if type(value) ~= "string" or value == "" then return nil end
    return value
end
local function invoke(request: {[string]: unknown}): ({[string]: unknown}?, caller.Fault?)
    local reply = owner:invoke(M.FACADE, request) or caller.unknown()
    if not reply.ok then return nil, reply.error or {code = "INTERNAL", message = "the agent facade refused without a fault"} end
    if type(reply.value) ~= "table" then return nil, {code = "INTERNAL", message = "the agent facade returned no value"} end
    return reply.value :: {[string]: unknown}, nil
end
local function status_of(value: {[string]: unknown}): (Status?, caller.Fault?)
    local thread_id, attempt_id, state = text(value.thread_id), text(value.attempt_id), text(value.state)
    if not thread_id or not attempt_id or not state then return nil, {code = "INTERNAL", message = "the agent facade returned a malformed status"} end
    return {thread_id = thread_id, attempt_id = attempt_id, state = state, outcome = text(value.outcome), answer = text(value.answer)}, nil
end
function M.launch(request: agent_protocol.Launch): (Run?, caller.Fault?)
    local body: {[string]: unknown} = {operation = "launch", definition_ref = request.definition_ref, brief = request.brief,
        idempotency_key = request.idempotency_key, workspace_id = request.workspace_id, saved_profile_id = request.saved_profile_id,
        saved_profile_revision = request.saved_profile_revision, workdir = request.workdir, thread = request.thread, placement = request.placement,
        agent_ref = request.agent_ref, owner_component_revision = request.owner_component_revision, spec_digest = request.spec_digest}
    local value, fault = invoke(body)
    if not value then return nil, fault end
    local thread_id, action_id, attempt_id = text(value.thread_id), text(value.action_id), text(value.attempt_id)
    local definition_ref, title, brief = text(value.definition_ref), text(value.title), text(value.brief)
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
    local thread_id, action_id, attempt_id = text(value.thread_id), text(value.action_id), text(value.attempt_id)
    local definition_ref, title, brief = text(value.definition_ref), text(value.title), text(value.brief)
    local state = text(value.state) or "starting"
    if not thread_id or not action_id or not attempt_id or not definition_ref or not title or not brief then
        return nil, {code = "INTERNAL", message = "the agent facade returned a malformed run receipt"}
    end
    return {
        thread_id = thread_id,
        action_id = action_id,
        attempt_id = attempt_id,
        definition_ref = definition_ref,
        title = title,
        brief = brief,
        state = state,
        status = text(value.status) or state,
        outcome = text(value.outcome),
        answer = text(value.answer),
        idempotency_key = text(value.idempotency_key),
        saved_profile_revision = type(value.saved_profile_revision) == "number" and math.floor(value.saved_profile_revision) or nil,
        owner_component_revision = type(value.owner_component_revision) == "number" and math.floor(value.owner_component_revision) or nil,
        receipt = type(value.receipt) == "table" and (value.receipt :: {[string]: unknown}) or nil,
    }, nil
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
