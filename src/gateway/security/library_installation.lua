-- MIT. Bound Hub requests use the Library's governed destination.
local bounds = require("bounds")
local governed = require("governed")
local installation = require("installation")
local canonical = require("canonical")
local hash = require("hash")
local M = {}
type Object = {[string]: unknown}
type Reply = {ok: boolean, value: unknown, error: {code: string, message: string}?}
type Binding = {binding_id: string, subject: string, action_id: string, attempt_id: string, thread_id: string, workspace_id: string?}
type Call = (Object) -> Reply
local function fail(code: string, message: string): Reply
    return {ok = false, value = nil, error = {code = code, message = message}}
end
local function context(binding: Binding): installation.Context
    return {binding_id = binding.binding_id, thread_id = binding.thread_id, action_id = binding.action_id, attempt_id = binding.attempt_id}
end
local function prefix(binding: Binding): string
    local key = assert(installation.idempotency_key(context(binding), string.rep("0", 64)))
    return "gov:" .. key:sub(#"hub-install:" + 1) .. "."
end
local function outcome(binding: Binding, request_id: string, value: unknown): Reply
    local intent = bounds.object(value)
    if not intent or intent.workspace_id ~= binding.workspace_id or intent.intent_id ~= request_id
        or request_id ~= prefix(binding) .. tostring(intent.artifact_digest) then
        return fail("DENIED", "activation does not belong to this binding and attempt")
    end
    local phase = bounds.id(intent.phase)
    if not phase then return fail("UNAVAILABLE", "activation has no phase") end
    local status = (phase == "approval_bound" or phase == "prepared") and "pending" or "approved"
    if phase == "settled" then
        status = intent.outcome == "applied" and "applied" or
            ((intent.outcome == "denied" or intent.outcome == "expired" or intent.outcome == "withdrawn") and "refused" or "failed")
    end
    local source = bounds.id(intent.source_workspace)
    return {ok = true, value = {request_id = request_id, approval_id = intent.approval_id, status = status,
        component = source and source:match("^hub:(.+)$") or nil, version = intent.version,
        phase = phase, outcome = intent.outcome, message = intent.diagnostics, plan_digest = intent.plan_digest}}
end
function M.status(call: Call, binding: Binding, request_id: string): Reply
    if request_id:sub(1, #prefix(binding)) ~= prefix(binding) then return fail("DENIED", "activation does not belong to this binding and attempt") end
    local reply = call({operation = "status", workspace_id = binding.workspace_id, intent_id = request_id})
    if not reply.ok then return reply end
    return outcome(binding, request_id, reply.value)
end
function M.request(call: Call, binding: Binding, planned: Object, parameters: {installation.Parameter}): Reply
    local component, version, digest = bounds.id(planned.component), bounds.id(planned.version), bounds.id(planned.artifact_digest)
    if not component or not version or not digest or #digest ~= 64 or not digest:match("^[0-9a-f]+$") then
        return fail("INCOMPLETE", "governed Hub plan is malformed")
    end
    local workspace = binding.workspace_id
    if not workspace then return fail("DENIED", "this binding names no workspace") end
    local request_id = prefix(binding) .. digest
    local previous = M.status(call, binding, request_id)
    if previous.ok or not previous.error or previous.error.code ~= "NOT_FOUND" then return previous end
    local state = governed.new(workspace)
    local function fold(request: Object): Reply?
        local reply = call(request)
        if not reply.ok then return reply end
        if not governed.apply_plan(state, reply :: governed.Reply) then return fail("INCOMPLETE", state.fault) end
        return nil
    end
    local problem = fold({operation = "stage_hub", workspace_id = workspace, component = component, version = version,
        parameters = parameters, artifact_digest = digest, idempotency_key = request_id .. "-stage"})
    if problem then return problem end
    local item = assert(state.detail)
    problem = fold(governed.get_request(state, item))
    if problem then return problem end
    item = assert(state.detail)
    if governed.verdict(state, item) ~= "ready" then
        local diagnostic = state.report and state.report.diagnostics[1]
        return fail("BLOCKED", state.report_error or (diagnostic and (diagnostic.target .. ": " .. diagnostic.message))
            or "governed application is not ready for approval")
    end
    local review = governed.review_request(state, item, true, request_id .. "-review")
    review.review_reason = "Requested through Hub Library tools"
    problem = fold(review)
    if problem then return problem end
    item = assert(state.detail)
    problem = fold(governed.select_request(state, item, request_id .. "-select"))
    if problem then return problem end
    local prepared = call(governed.prepare_request(state, assert(state.detail), request_id, request_id .. "-prepare"))
    if not prepared.ok then return prepared end
    return outcome(binding, request_id, prepared.value)
end
function M.installed(call: Call, binding: Binding, component: string): (Object?, Reply?)
    local reply = call({operation = "activations", workspace_id = binding.workspace_id})
    if not reply.ok then return nil, reply end
    local value = bounds.object(reply.value)
    local rows = value and bounds.array(value.activations, 128)
    if not rows then return nil, fail("UNAVAILABLE", "application inventory is malformed") end
    for _, raw in ipairs(rows) do
        local item = bounds.object(raw)
        if item and item.source_workspace == "hub:" .. component and item.intent_id == item.observed_intent_id
            and item.phase == "settled" and item.outcome == "applied" then
            local current = call({operation = "status", workspace_id = binding.workspace_id, intent_id = item.intent_id})
            if not current.ok then return nil, current end
            return bounds.object(current.value), nil
        end
    end
    return nil, nil
end
function M.removal(binding: Binding, component: string, current: Object): (Object?, string?, string?)
    local intent_id, source_node = bounds.id(current.intent_id), bounds.id(current.source_node)
    local version, artifact_digest = bounds.id(current.version), bounds.id(current.artifact_digest)
    if not intent_id or not source_node or not version or not artifact_digest then return nil, nil, "installed activation is malformed" end
    local bytes, problem = canonical.encode({component = component, intent_id = intent_id, artifact_digest = artifact_digest, action = "uninstall"})
    local digest = bytes and hash.sha256(bytes) or nil
    if not digest then return nil, nil, problem or "cannot measure application removal" end
    return {kind = "operation", ref = installation.REF, revision = digest, input_digest = digest,
        payload = {route = "governed", action = "uninstall", component = component, version = version,
            source = "hub", plan_digest = digest, migration_policy = "block", intent_id = intent_id,
            artifact_digest = artifact_digest, source_node = source_node, source_workspace = "hub:" .. component,
            binding_id = binding.binding_id, thread_id = binding.thread_id, action_id = binding.action_id, attempt_id = binding.attempt_id,
            dependency_changes = {"remove " .. component .. " " .. version}, permission_changes = {"remove the application's grants"},
            migrations = {"Saved data and its migration ledger remain"}, auto_start = {}}},
        "Remove " .. component .. " " .. version .. " from this workspace? Saved data stays.", nil
end
function M.remove(call: Call, binding: Binding, proposal: Object, receipt: string): Object
    local payload = bounds.object(proposal.payload)
    if not payload or payload.route ~= "governed" or payload.action ~= "uninstall"
        or payload.binding_id ~= binding.binding_id or payload.thread_id ~= binding.thread_id
        or payload.action_id ~= binding.action_id or payload.attempt_id ~= binding.attempt_id
        or payload.source_workspace ~= "hub:" .. tostring(payload.component) or not bounds.id(payload.intent_id) then
        return {ok = false, code = "DENIED", message = "removal does not belong to this binding and attempt"}
    end
    local checked, _, invalid = M.removal(binding, tostring(payload.component), payload)
    if not checked or canonical.encode(checked) ~= canonical.encode(proposal) then
        return {ok = false, code = "DENIED", message = invalid or "application removal proposal differs from its activation"}
    end
    local result = call({operation = "uninstall", workspace_id = binding.workspace_id, source_workspace = payload.source_workspace,
        expected_intent_id = payload.intent_id, receipt_key = receipt})
    if not result.ok then return {ok = false, code = result.error and result.error.code, message = result.error and result.error.message} end
    return {ok = true, value = {state = "complete", message = "Application removed; saved data stays"}}
end
return M
