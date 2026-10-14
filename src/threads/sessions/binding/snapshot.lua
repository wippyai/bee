local bounds = require("bounds")
local profile_values = require("profile_values")
local M = {}
type Object = {[string]: unknown}
local function object(value: unknown): Object? return bounds.object(value) end
local function ref(value: unknown): string?
    if type(value) ~= "string" or #value < 1 or #value > 256 or value:find("%c") then return nil end
    return value
end
function M.decode(value: unknown): (Object?, string?)
    local row = object(value)
    if not row or type(row.session) ~= "string" or type(row.title) ~= "string"
        or type(row.state) ~= "string" or type(row.revision) ~= "number" then
        return nil, "Threads returned a malformed session snapshot"
    end
    local queued = type(row.queued) == "number" and row.queued or 0
    local lifecycle = row.state
    if lifecycle ~= "active" and lifecycle ~= "suspended" and lifecycle ~= "closing" and lifecycle ~= "closed" then
        return nil, "Threads returned an unsupported session lifecycle"
    end
    local activity = row.activity
    if activity ~= "idle" and activity ~= "working" and activity ~= "blocked" and activity ~= "stalled" then
        return nil, "Threads returned an unsupported session activity"
    end
    local activity_evidence: Object? = nil
    if row.activity_evidence ~= nil then
        local evidence = object(row.activity_evidence)
        local turn = evidence and ref(evidence.turn)
        local last = evidence and bounds.count(evidence.last_progress_at_ms)
        local quiet_period = evidence and bounds.count(evidence.quiet_period_ms)
        local quiet_for = evidence and bounds.count(evidence.quiet_for_ms)
        if not evidence or bounds.fields(evidence, {"kind", "turn", "last_progress_at_ms", "quiet_period_ms", "quiet_for_ms"})
            or evidence.kind ~= "quiet" or not turn or not last or not quiet_period or quiet_period < 1
            or not quiet_for or quiet_for < quiet_period then
            return nil, "Threads returned malformed quiet-period evidence"
        end
        activity_evidence = {kind = "quiet", turn = turn, last_progress_at_ms = last,
            quiet_period_ms = quiet_period, quiet_for_ms = quiet_for}
    end
    local at = type(row.updated_at) == "string" and row.updated_at or row.created_at
    if type(at) ~= "string" then return nil, "Threads omitted the session timestamp" end
    local route = object(row.route) or {}
    local saved_profile: Object? = nil
    if route.saved_profile_id ~= nil or route.saved_profile_revision ~= nil then
        local id, revision = ref(route.saved_profile_id), bounds.integer(route.saved_profile_revision)
        if not id or not revision or revision < 1 then return nil, "Session saved profile is malformed" end
        saved_profile = {id = id, revision = revision}
    end
    local limits: Object = table.create(0, 1)
    for name, limit in pairs(object(route.budgets) or {}) do limits[name] = limit end
    return {terminal = route.delivery == "hook", session = row.session, thread_ref = row.thread_ref, workspace = row.workspace,
        driver = route.driver_binding_ref, provider = route.provider, definition = route.definition, last_result = row.last_result,
        revision = row.revision, incarnation = 1, title = row.title,
        lifecycle = lifecycle, activity = activity, activity_evidence = activity_evidence,
        execution = {state = row.execution_running == true and "running" or "quiescent", evidence_at = at, stale = false},
        queue_count = queued, effective_limits = limits,
        saved_profile = saved_profile, effective_profile = profile_values.upgrade(route.effective_profile), profile_digest = route.profile_digest, budget_consumption = row.budget_consumption, continuity = {mode = "provider_resume"}, actions = {}}, nil
end

return M
