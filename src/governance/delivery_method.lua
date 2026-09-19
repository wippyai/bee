-- MIT. Public delivery facade for an authoring agent. It authenticates the
-- caller's exact delivery operation, then composes the existing owner facades
-- (publication, destination and preflight) as that same actor. It writes no
-- overlay and creates no approval: publication prepare and destination stage
-- are the agent's acts, while review, selection, approval and apply remain
-- other owners' and the person's.
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local bounds = require("bounds")
local json = require("json")
local preflight = require("preflight")
local guide = require("guide")
local transaction = require("transaction")

local M = {}
type Result = transaction.Result
type Object = {[string]: unknown}

local PROFILES = "bee.governance:publication_profiles"
local PUBLICATION = "bee.governance:publication_call"
local DESTINATION = "bee.governance:destination_call"

-- One delivery action per operation, checked against the caller's own actor
-- before any owner facade runs.
local ACTIONS: {[string]: string} = {
    request = "bee.governance.delivery.manage",
    status = "bee.governance.delivery.read",
    publish = "bee.governance.delivery.publish",
}

function M.required_action(raw: unknown): string?
    local operation = bounds.id(raw)
    if not operation then return nil end
    return ACTIONS[operation]
end

local function failure(code: string, message: string): Result
    return transaction.failure(code, message)
end

local function object(value: unknown): Object?
    return bounds.object(value)
end

-- The host profile names the component and source workspace for one
-- destination workspace; the agent names only the workspace it authored in.
local function profile_for(workspace_id: string, source_workspace: string): (Object?, string?)
    local entry, entry_error = registry.get(PROFILES)
    if not entry then return nil, tostring(entry_error or "publication profiles are unavailable") end
    local data = object(entry.data)
    local rows = data and data.profiles
    if type(rows) ~= "table" then return nil, "publication profiles are unavailable" end
    for _, raw in ipairs(rows :: {unknown}) do
        local profile = object(raw)
        if profile and profile.workspace_id == workspace_id and profile.source_workspace == source_workspace then
            return profile, nil
        end
    end
    return nil, "the host has no publication profile for this application"
end

local function forward(target: string, request: unknown): (Object?, Result?)
    local raw, call_error = funcs.call(target, request)
    if call_error then return nil, failure("UNAVAILABLE", target .. ": " .. tostring(call_error)) end
    local reply = object(raw)
    if not reply then return nil, failure("INTERNAL", target .. " returned a malformed reply") end
    if reply.ok ~= true then
        local fault = object(reply.error) or {}
        local code = bounds.id(fault.code) or bounds.id(reply.code) or "INTERNAL"
        local message = bounds.text(fault.message, 2048) or bounds.text(reply.message, 2048) or "delivery operation failed"
        -- The destination's own refusal value carries a remedy; keep it.
        local value = object(reply.value)
        return nil, transaction.failure(code :: string, message :: string,
            value and value.remedy ~= nil and {remedy = value.remedy} or value)
    end
    local value = object(reply.value)
    if not value then return nil, failure("INTERNAL", target .. " returned no value") end
    return value, nil
end

local function diagnostic_rows(report: Object): {unknown}
    local rows: {unknown} = {}
    local reported = report.diagnostics
    if type(reported) ~= "table" then return rows end
    for _, raw in ipairs(reported :: {unknown}) do
        local item = object(raw)
        if item then
            rows[#rows + 1] = {code = item.code, target = item.target, message = item.message, remedy = item.remedy}
        end
    end
    return rows
end

-- Publication prepare, then a destination stage, then the destination's own
-- preflight verdict. The agent learns ready or the exact diagnostics, and the
-- human steps that follow are stated here because the agent cannot take them.
local function request_operation(workspace_id: string, source_workspace: string,
    version: string, snapshot_digest: string): Result
    local profile, profile_error = profile_for(workspace_id, source_workspace)
    if not profile then return failure("BLOCKED", profile_error) end
    local component = bounds.text(profile.component, 160)
    if not component or component == "" then return failure("BLOCKED", "publication profile names no component") end

    local prepared, prepare_error = forward(PUBLICATION, {operation = "prepare", workspace_id = workspace_id,
        component = component, version = version, snapshot_digest = snapshot_digest})
    if not prepared then return prepare_error :: Result end
    local descriptor = object(prepared.descriptor)
    if not descriptor then return failure("INTERNAL", "publication returned no descriptor") end

    local available, available_error = forward(DESTINATION, {operation = "available", workspace_id = workspace_id})
    if not available then return available_error :: Result end
    local found = false
    for _, raw in ipairs((available.versions or {}) :: {unknown}) do
        local item = object(raw)
        if item and item.key == descriptor.key and item.digest == descriptor.digest then found = true end
    end
    if not found then return failure("BLOCKED", "the prepared version is not discoverable at this destination") end

    local staged, stage_error = forward(DESTINATION, {operation = "stage", workspace_id = workspace_id,
        source_owner = descriptor.owner_id, feed = descriptor.feed, version_key = descriptor.key,
        descriptor_digest = descriptor.digest, idempotency_key = "deliver-" .. source_workspace .. "-" .. version})
    if not staged then return stage_error :: Result end
    if staged.status ~= "staged" then return failure("BLOCKED", "the version did not stage at this destination") end

    local plan, plan_error = forward(DESTINATION, {operation = "get", workspace_id = workspace_id,
        source_node = descriptor.owner_id, source_workspace = source_workspace, version = version})
    if not plan then return plan_error :: Result end
    local report, report_error = preflight.decode_report(plan.preflight_bytes, plan.preflight_digest)
    if not report then return failure("INTERNAL", "staged preflight report: " .. tostring(report_error)) end
    local ready = report.ready == true and #report.diagnostics == 0 and #report.pending_migrations == 0
    return transaction.success({ready = ready, plan_digest = plan.plan_digest,
        artifact_digest = plan.artifact_digest, version = version, source_workspace = source_workspace,
        component = component, diagnostics = diagnostic_rows(report),
        pending_migrations = #report.pending_migrations,
        human_steps = {"review the plan in App Delivery", "select it there", "prepare the activation there",
            "approve it in Approvals", "let the activation owner apply the overlay", "open it from the start menu"},
        human_steps_where = {review = "App Delivery", approve = "Approvals", open = "start menu"}}, false)
end

-- Read the staged plan and, when an intent is named, its activation status.
local function status_operation(workspace_id: string, source_workspace: string, version: string,
    source_node: string?, intent_id: string?): Result
    local node = source_node
    if not node then
        local profile, profile_error = profile_for(workspace_id, source_workspace)
        if not profile then return failure("BLOCKED", profile_error) end
        node = bounds.id(profile.source_node)
    end
    local plan, plan_error = forward(DESTINATION, {operation = "get", workspace_id = workspace_id,
        source_node = node, source_workspace = source_workspace, version = version})
    if not plan then return plan_error :: Result end
    local value: Object = {version = version, source_workspace = source_workspace, plan_digest = plan.plan_digest,
        artifact_digest = plan.artifact_digest, plan_status = plan.status,
        review_status = plan.review_status, selected = plan.selected}
    if intent_id then
        local intent, intent_error = forward(DESTINATION, {operation = "status", workspace_id = workspace_id,
            intent_id = intent_id})
        if not intent then return intent_error :: Result end
        value.activation = {phase = intent.phase, outcome = intent.outcome, plan_digest = intent.plan_digest}
    end
    return transaction.success(value, false)
end

-- Publish is the exact locally reviewed and applied version; publication
-- refuses anything else, so the agent cannot publish around the person.
local function publish_operation(workspace_id: string, source_workspace: string, version: string): Result
    local profile, profile_error = profile_for(workspace_id, source_workspace)
    if not profile then return failure("BLOCKED", profile_error) end
    local component = bounds.text(profile.component, 160)
    if not component or component == "" then return failure("BLOCKED", "publication profile names no component") end
    local published, publish_error = forward(PUBLICATION, {operation = "publish", workspace_id = workspace_id,
        component = component, version = version})
    if not published then return publish_error :: Result end
    return transaction.success({version = version, component = component, published = true,
        sequence = published.sequence, descriptor = published.descriptor,
        human_steps = guide.delivery_steps()}, false)
end

function M.call(raw: unknown): Result
    local request = object(raw)
    if not request then return failure("INVALID", "delivery request must be an object") end
    local extra = bounds.fields(request, {"operation", "workspace_id", "source_workspace", "version",
        "snapshot_digest", "source_node", "intent_id"})
    if extra then return failure("INVALID", extra) end
    local operation = bounds.id(request.operation)
    local workspace_id, source_workspace = bounds.id(request.workspace_id), bounds.id(request.source_workspace)
    local version = bounds.id(request.version)
    if not operation or not ACTIONS[operation] then return failure("INVALID", "unknown delivery operation") end
    if not workspace_id or not source_workspace or not version then
        return failure("INVALID", "delivery needs operation, workspace_id, source_workspace and version")
    end
    local actor = security.actor()
    local action = ACTIONS[operation]
    if not actor or not security.can(action, workspace_id) then
        return failure("DENIED", "delivery operation is not authorized")
    end
    if operation == "request" then
        local snapshot_digest = request.snapshot_digest
        if type(snapshot_digest) ~= "string" or #snapshot_digest ~= 64 or not snapshot_digest:match("^[0-9a-f]+$") then
            return failure("INVALID", "request needs the frozen snapshot_digest")
        end
        local frozen_digest: string = snapshot_digest :: string
        return request_operation(workspace_id, source_workspace, version, frozen_digest)
    end
    if operation == "status" then
        return status_operation(workspace_id, source_workspace, version,
            bounds.id(request.source_node), bounds.id(request.intent_id))
    end
    return publish_operation(workspace_id, source_workspace, version)
end

return {handle = M.call}
