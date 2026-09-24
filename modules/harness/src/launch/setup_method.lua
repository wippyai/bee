-- MIT. First-use resource setup authenticates the caller before entering the
-- fixed host setup scope; metadata never grants workspace management.
local funcs = require("funcs")
local security = require("security")
local bounds = require("bounds")
local admission = require("admission")
local BACKEND = "bee.harness.launch:setup_backend"
local SCOPE = "bee.harness.launch:harness_setup_execution_scope"
local function digest(value: unknown): string?
    local candidate = bounds.text(value, 64)
    if not candidate or #candidate ~= 64 or not candidate:match("^[0-9a-f]+$") then return nil end
    return candidate
end
local function handle(raw: unknown): {[string]: unknown}
    local request = bounds.object(raw)
    if not request then return {ok = false, error = "request must be an object"} end
    if bounds.fields(request, {"workspace_id", "definition_ref", "expected_plan_digest", "saved_profile_id", "saved_profile_revision", "workdir"}) then return {ok = false, error = "unknown field"} end
    local workspace, definition_ref = bounds.id(request.workspace_id), bounds.id(request.definition_ref)
    if not workspace then return {ok = false, error = "workspace_id is not an identifier"} end
    if not definition_ref then return {ok = false, error = "definition_ref is not an identifier"} end
    if not digest(request.expected_plan_digest) then return {ok = false, error = "expected_plan_digest must be a lowercase SHA-256 hex digest"} end
    if not security.can("bee.harness.setup", workspace) then return {ok = false, error = "setup is not authorized"} end
    local saved_id, saved_revision = bounds.id(request.saved_profile_id), bounds.count(request.saved_profile_revision)
    if request.saved_profile_id ~= nil or request.saved_profile_revision ~= nil then
        if not saved_id or not saved_revision or saved_revision < 1 then return {ok = false, error = "saved profile needs identity and positive revision"} end
    end
    local plan, plan_error = admission.resolve(definition_ref, nil, workspace, saved_id, saved_revision)
    if not plan then return {ok = false, error = tostring(plan_error and plan_error.error and plan_error.error.message or "launch plan unavailable")} end
    if plan.plan_digest ~= request.expected_plan_digest then return {ok = false, error = "selected launch plan changed"} end
    -- A folder under an admitted root becomes the working directory only
    -- where the definition and its launch policy both allow the override.
    local backend_request: {[string]: unknown} = {workspace_id = workspace, definition_ref = definition_ref, expected_definition_digest = plan.definition_digest}
    if request.workdir ~= nil then
        if not admission.overrides(plan, "workdir") then return {ok = false, error = "the launch does not allow a workdir override"} end
        backend_request.workdir = request.workdir
    end
    local scope, scope_error = security.named_scope(SCOPE)
    if not scope then return {ok = false, error = tostring(scope_error or "setup scope unavailable")} end
    local executor, executor_error = funcs.new():with_scope(scope)
    if not executor then return {ok = false, error = tostring(executor_error or "setup scope denied")} end
    local result, call_error = executor:call(BACKEND, backend_request)
    if call_error or type(result) ~= "table" then return {ok = false, error = tostring(call_error or "setup reply")} end
    return result :: {[string]: unknown}
end
return {handle = handle}
