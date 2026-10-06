-- MIT. Typed local projection and request builder for the destination delivery
-- facade, the Library's source of delivered application versions. A notice is
-- what a person reads; fault keeps the owner's own words for the details view.
-- This model has no authority beyond the app's own call.
local bounds = require("bounds")
local preflight = require("preflight")

local M = {}
M.CALL = "bee.gov.binding:destination_call"
M.MAX_PLANS = 128
M.MAX_AVAILABLE = 512
M.MAX_ACTIVATIONS = 128
M.MAX_NODES = 64
M.NAMES = "bee.node.binding:names"
M.MAX_CHANGES = 512
type Object = {[string]: unknown}
type Fault = {code: string, message: string}
-- A destination reply: a value, or the owner's refusal.
type Reply = {ok: true, error: nil, value: unknown} | {ok: false, error: Fault, value: nil}
type Status = "staged" | "reviewed" | "rejected"
type Available = {owner_id: string, feed: string, version_key: string, component: string,
    version: string, source_workspace: string, content_digest: string, descriptor_digest: string,
    total_bytes: integer, author: string?}
type Plan = {owner_node: string, workspace_id: string, source_node: string, source_workspace: string,
    version: string, plan_digest: string, candidate_digest: string, artifact_digest: string,
    preflight_digest: string, revision: integer, status: Status, review_status: string?,
    review_reason: string?, reviewer_id: string?, selected: boolean,
    selection_revision: integer?, preflight_bytes: string?}
type Intent = {owner_node: string, workspace_id: string, intent_id: string, overlay_owner: string,
    source_node: string, source_workspace: string, version: string, revision: integer,
    phase: string, outcome: string?, diagnostics: string?, approval_id: string?,
    approval_proposal_digest: string?, consumed_proposal_digest: string?,
    observed_intent_id: string?, observed_artifact_digest: string?, observed_outcome: string?,
    baseline_intent_id: string?, application: string?}
type EntryChange = {id: string, kind: string, digest: string}
type Changes = {plan_digest: string, candidate_digest: string, artifact_digest: string,
    base_digest: string, composed_base_digest: string, base_revision: integer,
    composed_base_revision: integer, added: {EntryChange}, changed: {EntryChange}, removed: {EntryChange}}
type Verdict = "ready" | "blocked" | "unread" | "unreadable"
-- A heading row names its section in text and may carry a summary.
type ReviewRow = {text: string, heading: boolean, summary: string?}
type PendingPrepare = {plan_key: string, intent_id: string, receipt_key: string}
type PendingStep = {intent_id: string, receipt_key: string}
type PendingStage = {available_key: string, idempotency_key: string}
type State = {workspace_id: string, owner_node: string?, names: {[string]: string}, available: {Available}, selected_available_key: string?,
    plans: {Plan}, activations: {Intent}, selected_key: string?, detail: Plan?, intent: Intent?,
    technical: boolean, notice: string, fault: string, pending_prepare: PendingPrepare?,
    pending_step: PendingStep?, pending_recover_key: string?, restored_intent_id: string?, pending_stage: PendingStage?,
    review_key: string?, report: preflight.Report?, report_error: string?,
    changes: Changes?, changes_error: string?}

local PLAN_FIELDS = {"owner_node", "workspace_id", "source_node", "source_workspace", "version", "plan_digest",
    "candidate_digest", "artifact_digest", "preflight_digest", "revision", "status", "review_status",
    "review_reason", "reviewer_id", "selected", "selection_revision", "candidate_bytes", "artifact_bytes",
    "preflight_bytes"}
local CHANGE_FIELDS = {"owner_node", "workspace_id", "source_node", "source_workspace", "version",
    "plan_digest", "candidate_digest", "artifact_digest", "base_revision", "base_digest",
    "composed_base_revision", "composed_base_digest", "added", "changed", "removed"}
local INTENT_FIELDS = {"owner_node", "workspace_id", "intent_id", "actor_id", "overlay_owner", "source_node",
    "source_workspace", "version", "plan_digest", "plan_revision", "selection_revision", "artifact_bytes",
    "artifact_digest", "resolution_bytes", "resolution_digest", "preflight_bytes", "preflight_digest",
    "migration_work_bytes", "migration_work_digest", "grant_predecessor_digest", "grant_reuse_digest",
    "application_admission_bytes", "application_admission_digest", "application_admission_generation",
    "authorization_digest", "effect_key", "revision", "phase",
    "approval_id", "approval_proposal_digest",
    "approval_owner_incarnation", "consumed_consumer_id", "consumed_proposal_digest", "consumed_effect_key",
    "outcome", "diagnostics", "migrations_completed", "migration_receipt_bytes", "migration_receipt_digest",
    "slot_revision", "desired_intent_id", "desired_execution_revision",
    "observed_intent_id", "observed_execution_revision", "observed_artifact_digest", "observed_outcome",
    "baseline_intent_id", "application"}
local DESCRIPTOR_FIELDS = {"schema", "owner_id", "feed", "key", "object_id", "version_id", "content_digest",
    "manifest_digest", "content_kind", "total_bytes", "manifest", "digest"}
local MANIFEST_FIELDS = {"schema_revision", "source_workspace", "component", "artifact_digest", "author"}
local STATUSES: {[string]: boolean} = {staged = true, reviewed = true, rejected = true}
local PHASES: {[string]: boolean} = {prepared = true, approval_bound = true, consuming = true,
    authorized = true, applying = true, settled = true}
local OUTCOMES: {[string]: boolean} = {applied = true, blocked = true, failed = true, uncertain = true}

local function object(value: unknown): Object?
    return bounds.object(value)
end
local function digest(value: unknown): string?
    if type(value) ~= "string" or #value ~= 64 or not value:match("^[0-9a-f]+$") then return nil end
    return value
end
local function optional_id(value: unknown): string?
    if value == nil then return nil end
    return bounds.id(value)
end
local function optional_text(value: unknown, limit: integer): string?
    if value == nil then return nil end
    return bounds.text(value, limit)
end
local function optional_digest(value: unknown): boolean
    return value == nil or digest(value) ~= nil
end
local function optional_count(value: unknown, positive: boolean): integer?
    if value == nil then return nil end
    local result = bounds.count(value)
    if not result or (positive and result < 1) then return nil end
    return result
end
local function optional_count_valid(value: unknown, positive: boolean): boolean
    if value == nil then return true end
    local result = bounds.count(value)
    return result ~= nil and (not positive or result >= 1)
end
local function valid_blob(value: unknown, limit: integer): boolean
    return value == nil or (type(value) == "string" and #value <= limit)
end
local function dense(value: unknown, maximum: integer): {unknown}?
    if type(value) ~= "table" then return nil end
    local source = value
    local count = 0
    for key in pairs(source) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return nil end
        count = count + 1
    end
    if count > maximum then return nil end
    local result: {unknown} = {}
    for index = 1, count do
        if source[index] == nil then return nil end
        result[index] = source[index]
    end
    return result
end
local function plan(raw: unknown, workspace_id: string): (Plan?, string?)
    local value = object(raw)
    if not value then return nil, "plan is not an object" end
    local extra = bounds.fields(value, PLAN_FIELDS)
    if extra then return nil, "plan: " .. extra end
    local owner_node, workspace = bounds.id(value.owner_node), bounds.id(value.workspace_id)
    local source_node, source_workspace = bounds.id(value.source_node), bounds.id(value.source_workspace)
    local version = bounds.id(value.version)
    local plan_digest, candidate_digest = digest(value.plan_digest), digest(value.candidate_digest)
    local artifact_digest, preflight_digest = digest(value.artifact_digest), digest(value.preflight_digest)
    local revision = bounds.count(value.revision)
    local status: Status? = nil
    if type(value.status) == "string" then
        local candidate = value.status
        if candidate == "staged" or candidate == "reviewed" or candidate == "rejected" then status = candidate end
    end
    local selected = value.selected
    if not owner_node or workspace ~= workspace_id or not source_node or not source_workspace or not version
        or not plan_digest or not candidate_digest or not artifact_digest or not preflight_digest
        or not revision or revision < 1 or not status or type(selected) ~= "boolean" then
        return nil, "plan identity or state is malformed"
    end
    local review_status = optional_id(value.review_status)
    if value.review_status ~= nil and review_status ~= "accepted" and review_status ~= "rejected" then
        return nil, "plan review state is malformed"
    end
    local review_reason, reviewer_id = optional_text(value.review_reason, 512), optional_id(value.reviewer_id)
    if (value.review_reason ~= nil and not review_reason) or (value.reviewer_id ~= nil and not reviewer_id) then
        return nil, "plan review metadata is malformed"
    end
    local selection_revision = optional_count(value.selection_revision, true)
    if (selected and not selection_revision) or (not selected and value.selection_revision ~= nil) then
        return nil, "plan selection state is malformed"
    end
    if not valid_blob(value.candidate_bytes, 262144) or not valid_blob(value.artifact_bytes, 262144)
        or not valid_blob(value.preflight_bytes, 131072) then return nil, "plan evidence is malformed" end
    local decoded: Plan = {owner_node = owner_node, workspace_id = workspace, source_node = source_node,
        source_workspace = source_workspace, version = version, plan_digest = plan_digest,
        candidate_digest = candidate_digest, artifact_digest = artifact_digest, preflight_digest = preflight_digest,
        revision = revision, status = status, review_status = review_status,
        review_reason = review_reason, reviewer_id = reviewer_id, selected = selected, selection_revision = selection_revision,
        preflight_bytes = optional_text(value.preflight_bytes, 131072)}
    return decoded, nil
end
local function available(raw: unknown): (Available?, string?)
    local value = object(raw)
    if not value then return nil, "available version is not an object" end
    local extra = bounds.fields(value, DESCRIPTOR_FIELDS)
    if extra then return nil, "available version: " .. extra end
    local manifest = object(value.manifest)
    if not manifest then return nil, "available version manifest is malformed" end
    local manifest_extra = bounds.fields(manifest, MANIFEST_FIELDS)
    local owner_id, feed, version_key = bounds.id(value.owner_id), bounds.id(value.feed), bounds.id(value.key)
    local component, version = bounds.text(value.object_id, 160), bounds.id(value.version_id)
    local source_workspace = bounds.id(manifest.source_workspace)
    local content_digest, manifest_digest, descriptor_digest = digest(value.content_digest),
        digest(value.manifest_digest), digest(value.digest)
    local total_bytes = bounds.count(value.total_bytes)
    if manifest_extra then return nil, "available version manifest has unknown fields" end
    if value.schema ~= "bee.sync-version@1" or value.content_kind ~= "bee.governance-application-version@2" then
        return nil, "available version schema is unsupported"
    end
    if owner_id == nil or version_key == nil or version == nil or source_workspace == nil then
        return nil, "available version identity is malformed"
    end
    if feed ~= "governance.application_versions" then return nil, "available version feed is invalid" end
    if component == nil or component == "" then return nil, "available version component is invalid" end
    if manifest.schema_revision ~= "bee.governance-application-version@2" or manifest.component ~= component
        or digest(manifest.artifact_digest) == nil then return nil, "available version manifest is invalid" end
    if content_digest == nil or manifest_digest == nil or descriptor_digest == nil then
        return nil, "available version digest is malformed"
    end
    if total_bytes == nil or total_bytes < 1 or total_bytes > 16777216 then
        return nil, "available version size is malformed"
    end
    local author = optional_text(manifest.author, 80)
    if manifest.author ~= nil and not author then return nil, "available version author is malformed" end
    return {owner_id = owner_id, feed = feed, version_key = version_key, component = component,
        version = version, source_workspace = source_workspace, content_digest = content_digest,
        descriptor_digest = descriptor_digest, total_bytes = total_bytes, author = author}, nil
end
local function intent(raw: unknown, workspace_id: string): (Intent?, string?)
    local value = object(raw)
    if not value then return nil, "activation intent is not an object" end
    local extra = bounds.fields(value, INTENT_FIELDS)
    if extra then return nil, "activation intent: " .. extra end
    local owner_node, workspace, intent_id = bounds.id(value.owner_node), bounds.id(value.workspace_id), bounds.id(value.intent_id)
    local overlay_owner, source_node = bounds.id(value.overlay_owner), bounds.id(value.source_node)
    local source_workspace, version = bounds.id(value.source_workspace), bounds.id(value.version)
    local revision = bounds.count(value.revision)
    local phase: string? = nil
    if type(value.phase) == "string" then
        local candidate = value.phase
        if PHASES[candidate] then phase = candidate end
    end
    local outcome = optional_id(value.outcome)
    if value.outcome ~= nil and (not outcome or not OUTCOMES[outcome]) then return nil, "activation outcome is malformed" end
    local observed = optional_id(value.observed_outcome)
    if value.observed_outcome ~= nil and (not observed or not OUTCOMES[observed]) then return nil, "observed activation outcome is malformed" end
    local diagnostics, approval_id = optional_text(value.diagnostics, 8192), optional_id(value.approval_id)
    if not owner_node or workspace ~= workspace_id or not intent_id or not overlay_owner or not source_node
        or not source_workspace or not version or not revision or not phase
        or (value.diagnostics ~= nil and not diagnostics) or (value.approval_id ~= nil and not approval_id) then
        return nil, "activation identity or state is malformed"
    end
    if not optional_digest(value.plan_digest) or not optional_digest(value.artifact_digest)
        or not optional_digest(value.resolution_digest) or not optional_digest(value.preflight_digest)
        or not optional_digest(value.migration_work_digest) or not optional_digest(value.migration_receipt_digest)
        or not optional_digest(value.grant_predecessor_digest) or not optional_digest(value.grant_reuse_digest)
        or not optional_digest(value.authorization_digest) or not optional_digest(value.approval_proposal_digest)
        or not optional_digest(value.consumed_proposal_digest) or not optional_digest(value.observed_artifact_digest)
        or not optional_count_valid(value.plan_revision, true) or not optional_count_valid(value.selection_revision, true)
        or not optional_count_valid(value.approval_owner_incarnation, true) or not optional_count_valid(value.slot_revision, false)
        or not optional_count_valid(value.desired_execution_revision, false) or not optional_count_valid(value.observed_execution_revision, false)
        or not valid_blob(value.artifact_bytes, 262144) or not valid_blob(value.resolution_bytes, 1048576)
        or not valid_blob(value.preflight_bytes, 131072) or not valid_blob(value.migration_work_bytes, 1048576)
        or not valid_blob(value.migration_receipt_bytes, 262144)
        or not valid_blob(value.application_admission_bytes, 65536) or not optional_digest(value.application_admission_digest)
        or (value.application_admission_generation ~= nil and value.application_admission_generation ~= "current"
            and value.application_admission_generation ~= "prior")
        or (value.migrations_completed ~= nil and type(value.migrations_completed) ~= "boolean") then
        return nil, "activation evidence is malformed"
    end
    return {owner_node = owner_node, workspace_id = workspace, intent_id = intent_id, overlay_owner = overlay_owner,
        source_node = source_node, source_workspace = source_workspace, version = version,
        revision = revision, phase = phase, outcome = outcome, diagnostics = diagnostics, approval_id = approval_id,
        approval_proposal_digest = digest(value.approval_proposal_digest),
        consumed_proposal_digest = digest(value.consumed_proposal_digest),
        observed_intent_id = optional_id(value.observed_intent_id),
        observed_artifact_digest = digest(value.observed_artifact_digest),
        observed_outcome = observed, baseline_intent_id = optional_id(value.baseline_intent_id),
        application = optional_text(value.application, 256)}, nil
end
local function entry_change(raw: unknown): (EntryChange?, string?)
    local value = object(raw)
    if not value then return nil, "entry change is not an object" end
    local extra = bounds.fields(value, {"id", "kind", "digest"})
    if extra then return nil, "entry change: " .. extra end
    local id, kind = bounds.id(value.id), bounds.id(value.kind)
    local measured = digest(value.digest)
    if not id or not kind or not measured then return nil, "entry change is malformed" end
    return {id = id, kind = kind, digest = measured}, nil
end
local function entry_changes(raw: unknown): ({EntryChange}?, string?)
    local rows = dense(raw, M.MAX_CHANGES)
    if not rows then return nil, "entry change list is malformed" end
    local result: {EntryChange} = {}
    for index, item in ipairs(rows) do
        local change, change_error = entry_change(item)
        if not change then return nil, change_error end
        result[index] = change
    end
    return result, nil
end
local function changes(raw: unknown, workspace_id: string, item: Plan): (Changes?, string?)
    local value = object(raw)
    if not value then return nil, "plan changes are not an object" end
    local extra = bounds.fields(value, CHANGE_FIELDS)
    if extra then return nil, "plan changes: " .. extra end
    if bounds.id(value.owner_node) == nil or value.workspace_id ~= workspace_id
        or value.source_node ~= item.source_node or value.source_workspace ~= item.source_workspace
        or value.version ~= item.version then return nil, "plan changes name another version" end
    local plan_digest, candidate_digest = digest(value.plan_digest), digest(value.candidate_digest)
    local artifact_digest = digest(value.artifact_digest)
    local base_digest, composed_digest = digest(value.base_digest), digest(value.composed_base_digest)
    local base_revision = bounds.count(value.base_revision)
    local composed_revision = bounds.count(value.composed_base_revision)
    if not plan_digest or not candidate_digest or not artifact_digest or not base_digest
        or not composed_digest or base_revision == nil or composed_revision == nil then
        return nil, "plan change measurement is malformed"
    end
    if plan_digest ~= item.plan_digest or candidate_digest ~= item.candidate_digest
        or artifact_digest ~= item.artifact_digest then return nil, "plan changes measure another plan" end
    local added, added_error = entry_changes(value.added)
    if not added then return nil, added_error end
    local changed, changed_error = entry_changes(value.changed)
    if not changed then return nil, changed_error end
    local removed, removed_error = entry_changes(value.removed)
    if not removed then return nil, removed_error end
    return {plan_digest = plan_digest, candidate_digest = candidate_digest, artifact_digest = artifact_digest,
        base_digest = base_digest, composed_base_digest = composed_digest, base_revision = base_revision,
        composed_base_revision = composed_revision, added = added, changed = changed, removed = removed}, nil
end
-- The destination facade's reply envelope, or nil when the transport gave no
-- usable answer; the model treats nil as an unknown outcome to recover by
-- reading.
function M.reply(raw: unknown): Reply?
    local value = object(raw)
    if not value or type(value.ok) ~= "boolean" then return nil end
    if value.ok then
        if value.value == nil then return nil end
        return {ok = true, error = nil, value = value.value}
    end
    local fault = object(value.error)
    local code, detail = fault and bounds.line(fault.code, 40) or nil, fault and bounds.text(fault.message, 2048) or nil
    if not code or not detail then return nil end
    local refused: Fault = {code = code, message = detail}
    return {ok = false, error = refused, value = nil}
end
local UNREADABLE = "This version can't be read; try Refresh"
-- What a person reads for a reply that carries no value, then the owner's
-- words for it.
local function message(reply: Reply?): (string, string)
    if not reply then return "No answer yet; try Refresh", "No answer from the destination; check status before retrying" end
    if reply.error then
        local detail = bounds.line(reply.error.message, 240) or "destination refused the request"
        local technical = bounds.line(reply.error.code, 40) and (reply.error.code .. ": " .. detail) or detail
        return "That did not go through; Details (T) says why", technical
    end
    return UNREADABLE, "Destination returned an invalid reply"
end
-- fail records one problem for the person and for the details view.
local function fail(state: State, person: string, technical: string?)
    state.notice, state.fault = person, technical or person
end
local function refuse(state: State, reply: Reply?)
    local person, technical = message(reply)
    fail(state, person, technical)
end
local function result_object(reply: Reply?): Object?
    if not reply or not reply.ok then return nil end
    return object(reply.value)
end

function M.key(item: Plan): string
    return item.source_node .. "\0" .. item.source_workspace .. "\0" .. item.version
end
function M.available_key(item: Available): string
    return item.owner_id .. "\0" .. item.feed .. "\0" .. item.version_key .. "\0" .. item.descriptor_digest
end
function M.available_plan_key(item: Available): string
    return item.owner_id .. "\0" .. item.source_workspace .. "\0" .. item.version
end
function M.new(workspace_id: string): State
    return {workspace_id = workspace_id, owner_node = nil, names = {}, available = {}, selected_available_key = nil,
        plans = {}, activations = {}, selected_key = nil, detail = nil, intent = nil,
        technical = false, notice = "", fault = "", pending_prepare = nil, pending_step = nil,
        pending_recover_key = nil, restored_intent_id = nil, pending_stage = nil,
        review_key = nil, report = nil, report_error = nil, changes = nil, changes_error = nil}
end
-- Review evidence belongs to one plan. Nothing decoded for another version may
-- survive a selection change and describe the version now in front of a person.
function M.forget_review(state: State)
    state.review_key, state.report, state.report_error = nil, nil, nil
    state.changes, state.changes_error = nil, nil
end
function M.selected(state: State): Plan?
    for _, item in ipairs(state.plans) do if M.key(item) == state.selected_key then return item end end
    return nil
end
function M.selected_available(state: State): Available?
    for _, item in ipairs(state.available) do
        if M.available_key(item) == state.selected_available_key then return item end
    end
    return nil
end
function M.select_available(state: State, key: string?)
    state.selected_available_key = key
    state.notice, state.fault = "", ""
end
function M.select(state: State, key: string?)
    state.selected_key = key
    if state.detail and M.key(state.detail) ~= key then state.detail = nil end
    if state.review_key and state.review_key ~= key then M.forget_review(state) end
    state.notice, state.fault = "", ""
end
function M.apply_list(state: State, reply: Reply?)
    local value = result_object(reply)
    if not value then refuse(state, reply); return false end
    local extra = bounds.fields(value, {"owner_node", "workspace_id", "plans"})
    local owner_node = bounds.id(value.owner_node)
    if extra or owner_node == nil or value.workspace_id ~= state.workspace_id then
        fail(state, UNREADABLE, "Destination returned an invalid plan list"); return false
    end
    local rows = dense(value.plans, M.MAX_PLANS)
    if not rows then fail(state, UNREADABLE, "Destination returned an invalid plan list"); return false end
    local decoded: {Plan} = {}
    local seen: {[string]: boolean} = {}
    for _, raw in ipairs(rows) do
        local item, err = plan(raw, state.workspace_id)
        if not item then fail(state, UNREADABLE, err or "Destination returned an invalid plan"); return false end
        local key = M.key(item)
        if seen[key] then fail(state, UNREADABLE, "Destination returned duplicate plans"); return false end
        seen[key] = true
        decoded[#decoded + 1] = item
    end
    state.owner_node = owner_node
    state.plans = decoded
    if not state.selected_key or not seen[state.selected_key] then
        state.selected_key = decoded[1] and M.key(decoded[1]) or nil
        state.detail = nil
    end
    if state.detail then
        local found = false
        for _, item in ipairs(decoded) do if M.key(item) == M.key(state.detail) then found = true end end
        if not found then state.detail = nil end
    end
    if state.review_key and state.review_key ~= state.selected_key then M.forget_review(state) end
    state.notice, state.fault = "", ""
    return true
end
function M.apply_available(state: State, reply: Reply?)
    local value = result_object(reply)
    if not value then refuse(state, reply); return false end
    if bounds.fields(value, {"workspace_id", "versions"}) or value.workspace_id ~= state.workspace_id then
        fail(state, UNREADABLE, "Destination returned an invalid available version list"); return false
    end
    local rows = dense(value.versions, M.MAX_AVAILABLE)
    if not rows then fail(state, UNREADABLE, "Destination returned an invalid available version list"); return false end
    local decoded: {Available} = {}
    local seen: {[string]: boolean} = {}
    for _, raw in ipairs(rows) do
        local item, err = available(raw)
        if not item then fail(state, UNREADABLE, err or "Destination returned an invalid available version"); return false end
        local key = M.available_key(item)
        if seen[key] then fail(state, UNREADABLE, "Destination returned duplicate available versions"); return false end
        seen[key] = true
        decoded[#decoded + 1] = item
    end
    state.available = decoded
    if not state.selected_available_key or not seen[state.selected_available_key] then
        state.selected_available_key = decoded[1] and M.available_key(decoded[1]) or nil
    end
    state.notice, state.fault = "", ""
    return true
end
function M.apply_activations(state: State, reply: Reply?)
    local value = result_object(reply)
    if not value then refuse(state, reply); return false end
    if bounds.fields(value, {"workspace_id", "activations"}) or value.workspace_id ~= state.workspace_id then
        fail(state, UNREADABLE, "Destination returned an invalid activation list"); return false
    end
    local rows = dense(value.activations, M.MAX_ACTIVATIONS)
    if not rows then fail(state, UNREADABLE, "Destination returned an invalid activation list"); return false end
    local decoded: {Intent} = {}
    for _, raw in ipairs(rows) do
        local item, err = intent(raw, state.workspace_id)
        if not item then fail(state, UNREADABLE, err or "Destination returned an invalid activation"); return false end
        decoded[#decoded + 1] = item
    end
    state.activations = decoded
    state.notice, state.fault = "", ""
    return true
end
function M.apply_plan(state: State, reply: Reply?)
    local value = result_object(reply)
    if not value then refuse(state, reply); return false end
    local item, err = plan(value, state.workspace_id)
    if not item then fail(state, UNREADABLE, err or "Destination returned an invalid plan"); return false end
    state.detail = item
    for index, current in ipairs(state.plans) do
        if M.key(current) == M.key(item) then state.plans[index] = item; break end
    end
    -- A review or selection reply carries no evidence bytes; the report already
    -- read for this exact plan remains the report for it.
    if state.review_key ~= M.key(item) then M.forget_review(state) end
    if item.preflight_bytes ~= nil then
        state.review_key = M.key(item)
        local report, report_error = preflight.decode_report(item.preflight_bytes, item.preflight_digest)
        state.report = report
        if report then state.report_error = nil
        else state.report_error = report_error or "preflight report could not be decoded" end
    end
    state.notice, state.fault = "", ""
    return true
end
function M.apply_changes(state: State, reply: Reply?, item: Plan): boolean
    local value = result_object(reply)
    if not value then
        local _, technical = message(reply)
        state.changes, state.changes_error = nil, technical
        return false
    end
    local decoded, err = changes(value, state.workspace_id, item)
    if not decoded then
        state.changes, state.changes_error = nil, err or "Destination returned invalid plan changes"
        return false
    end
    state.changes, state.changes_error = decoded, nil
    return true
end
function M.apply_stage(state: State, reply: Reply?, source: Available): boolean
    local value = result_object(reply)
    if not value then refuse(state, reply); return false end
    local item, err = plan(value, state.workspace_id)
    if not item then fail(state, UNREADABLE, err or "Destination returned an invalid staged plan"); return false end
    if item.status ~= "staged" or item.source_node ~= source.owner_id
        or item.source_workspace ~= source.source_workspace or item.version ~= source.version then
        fail(state, UNREADABLE, "Destination returned a staged plan for a different version"); return false
    end
    local found = false
    for index, current in ipairs(state.plans) do
        if M.key(current) == M.key(item) then state.plans[index] = item; found = true; break end
    end
    if not found then
        if #state.plans >= M.MAX_PLANS then
            fail(state, "Too many versions are waiting; Refresh, then try again",
                "Destination plan list is full; refresh before staging another version")
            return false
        end
        state.plans[#state.plans + 1] = item
    end
    state.selected_key = M.key(item)
    state.detail = nil
    M.forget_review(state)
    state.notice, state.fault = "", "Staged for local review; no installation performed"
    return true
end
-- What a person reads for one activation phase.
function M.phase_notice(item: Intent): string
    if item.phase == "prepared" or item.phase == "approval_bound" then return "Waiting for your approval in Needs you" end
    if item.phase ~= "settled" then return "Installing" end
    if item.outcome == "applied" then return "Installed" end
    if item.outcome == "uncertain" then return "Installing; Refresh to see how it ended" end
    return "This version could not be installed; Details (T) says why"
end
function M.apply_activation(state: State, reply: Reply?): boolean
    local value = result_object(reply)
    if not value then refuse(state, reply); return false end
    local item, err = intent(value, state.workspace_id)
    if not item then fail(state, UNREADABLE, err or "Destination returned an invalid activation"); return false end
    state.intent = item
    fail(state, M.phase_notice(item), "Activation " .. item.phase)
    return true
end
-- The names the bees that made versions go by; a node that has none stays
-- unnamed.
function M.names_request(nodes: {string}): Object
    return {nodes = nodes}
end
function M.apply_names(state: State, reply: Reply?): boolean
    local value = result_object(reply)
    local names = value and object(value.names)
    if not value or not names or bounds.fields(value, {"names"}) then refuse(state, reply); return false end
    local decoded: {[string]: string} = {}
    for node, name in pairs(names) do
        local line = bounds.line(name, 80)
        if bounds.id(node) and line then decoded[node] = line end
    end
    for node, name in pairs(decoded) do state.names[node] = name end
    return true
end
function M.uninstall_request(state: State, source_workspace: string, key: string): Object
    return {operation = "uninstall", workspace_id = state.workspace_id, source_workspace = source_workspace,
        receipt_key = key}
end
function M.revert_request(state: State, source_workspace: string, key: string): Object
    return {operation = "revert", workspace_id = state.workspace_id, source_workspace = source_workspace,
        receipt_key = key}
end
function M.activations_request(state: State): Object
    return {operation = "activations", workspace_id = state.workspace_id}
end
function M.list_request(state: State): Object
    return {operation = "list", workspace_id = state.workspace_id}
end
function M.available_request(state: State): Object
    return {operation = "available", workspace_id = state.workspace_id}
end
function M.stage_request(state: State, item: Available, key: string): Object
    return {operation = "stage", workspace_id = state.workspace_id, source_owner = item.owner_id,
        feed = item.feed, version_key = item.version_key, descriptor_digest = item.descriptor_digest,
        idempotency_key = key}
end
function M.changes_request(state: State, item: Plan): Object
    return {operation = "changes", workspace_id = state.workspace_id, source_node = item.source_node,
        source_workspace = item.source_workspace, version = item.version}
end
function M.get_request(state: State, item: Plan): Object
    return {operation = "get", workspace_id = state.workspace_id, source_node = item.source_node,
        source_workspace = item.source_workspace, version = item.version}
end
function M.review_request(state: State, item: Plan, accepted: boolean, key: string): Object
    return {operation = "review", workspace_id = state.workspace_id, source_node = item.source_node,
        source_workspace = item.source_workspace, version = item.version, expected_revision = item.revision,
        idempotency_key = key, review_status = accepted and "accepted" or "rejected",
        review_reason = "Reviewed in Bee Library"}
end
function M.select_request(state: State, item: Plan, key: string): Object
    return {operation = "select", workspace_id = state.workspace_id, source_node = item.source_node,
        source_workspace = item.source_workspace, version = item.version, expected_revision = item.revision,
        idempotency_key = key}
end
function M.prepare_request(state: State, item: Plan, intent_id: string, key: string): Object
    return {operation = "prepare", workspace_id = state.workspace_id, source_node = item.source_node,
        source_workspace = item.source_workspace, version = item.version, intent_id = intent_id, receipt_key = key}
end
function M.can_advance(state: State): boolean
    local phase = state.intent and state.intent.phase
    return phase == "approval_bound" or phase == "consuming" or phase == "authorized" or phase == "applying"
end
function M.step_request(state: State, intent_id: string, key: string): Object
    return {operation = "step", workspace_id = state.workspace_id, intent_id = intent_id, receipt_key = key}
end
function M.status_request(state: State, intent_id: string): Object
    return {operation = "status", workspace_id = state.workspace_id, intent_id = intent_id}
end
-- The destination recovers the desired activation of one source overlay, so
-- the request names the chosen version's source.
function M.recover_request(state: State, item: Plan, key: string): Object
    return {operation = "recover", workspace_id = state.workspace_id, source_node = item.source_node,
        source_workspace = item.source_workspace, receipt_key = key}
end
function M.toggle_technical(state: State)
    state.technical = not state.technical
end
-- The verdict is the destination's own preflight report, read from the exact
-- bytes the plan stores and checked against the plan's preflight digest.
function M.verdict(state: State, item: Plan?): Verdict
    if not item or state.review_key ~= M.key(item) then return "unread" end
    if state.report_error ~= nil then return "unreadable" end
    local report = state.report
    if not report then return "unread" end
    if report.ready then return "ready" end
    return "blocked"
end
-- Selecting and accepting act on the plan. Neither is offered while the report
-- is unread, fails its digest check, or refuses the plan. The first result is
-- what a person reads; the second keeps the destination's words for details.
function M.refusal(state: State, item: Plan?): (string?, string?)
    if not item then return "Choose a version first", "Choose a staged version first" end
    local verdict = M.verdict(state, item)
    if verdict == "ready" then return nil, nil end
    if verdict == "unread" then
        return "This version is still being checked; try again in a moment",
            "Read this version's preflight report first; press Enter"
    end
    if verdict == "unreadable" then
        return "The check of this version can't be trusted; try Refresh",
            "Preflight report does not match its digest: " .. (state.report_error or "report could not be decoded")
    end
    local report = state.report
    local count = report and #report.diagnostics or 0
    return "This version can't be installed here: it fails " .. tostring(count) .. (count == 1 and " check" or " checks")
        .. "; Details (T) lists them",
        "Preflight blocks this version with " .. tostring(count) .. " diagnostics; it cannot be selected"
end
local function short(state: State, value: string): string
    if state.technical then return value end
    return value:sub(1, 12)
end
local function approval_row(state: State): string
    local intent = state.intent
    local consumed = intent and intent.consumed_proposal_digest or nil
    if consumed then return "consumed  proposal " .. short(state, consumed) end
    local proposed = intent and intent.approval_proposal_digest or nil
    if proposed then return "proposed  proposal " .. short(state, proposed) end
    return "unbound  no approval is requested for this version yet"
end
function M.review_rows(state: State): {ReviewRow}
    local rows: {ReviewRow} = {}
    local function put(text: string, heading: boolean, summary: string?)
        rows[#rows + 1] = {text = text, heading = heading, summary = summary}
    end
    local item = M.selected(state)
    if not item then
        put("No staged version is chosen", false)
        return rows
    end
    put("Review", true, item.source_workspace .. " · version " .. item.version)
    local verdict = M.verdict(state, item)
    if verdict == "ready" then put("Verdict ready; the destination's preflight found nothing that blocks activation", false)
    elseif verdict == "blocked" then put("Verdict blocked; the destination's preflight refuses this plan", false)
    elseif verdict == "unreadable" then
        put("Verdict unreadable; the preflight report does not match its digest", false)
        put(bounds.line(state.report_error, 240) or "report could not be decoded", false)
    else put("Verdict unread; press Enter on this version to read its plan", false) end
    local report = state.report
    if report and state.review_key == M.key(item) then
        put("Preflight " .. short(state, item.preflight_digest) .. "  base revision " .. tostring(report.base_revision), false)
        put("Diagnostics", true, tostring(#report.diagnostics) .. " · pending migrations " .. tostring(#report.pending_migrations))
        for _, diagnostic in ipairs(report.diagnostics) do
            put(diagnostic.code .. "  " .. bounds.line(diagnostic.target, 200), false)
            put("    " .. bounds.line(diagnostic.message, 240), false)
            put("    remedy " .. bounds.line(diagnostic.remedy, 240), false)
        end
        for _, pending in ipairs(report.pending_migrations) do
            local target_db, id = preflight.migration_parts(pending)
            put("PENDING_MIGRATION  " .. (bounds.line(id, 200) or "unreadable") .. " on " .. (bounds.line(target_db, 160) or "unreadable"), false)
        end
        if #report.diagnostics == 0 and #report.pending_migrations == 0 then
            put("No diagnostics and no pending migrations", false)
        end
    end
    local plan_changes = state.changes
    put("Changes", true)
    put("Artifact " .. short(state, item.artifact_digest) .. "  plan " .. short(state, item.plan_digest), false)
    if state.changes_error ~= nil then
        put("Entry changes unavailable: " .. (bounds.line(state.changes_error, 240) or "the destination gave no reason"), false)
    elseif not plan_changes then
        put("Entry changes unread; press Enter on this version to read them", false)
    else
        put("Composed base " .. short(state, plan_changes.composed_base_digest)
            .. "  revision " .. tostring(plan_changes.composed_base_revision), false)
        if plan_changes.composed_base_digest ~= plan_changes.base_digest then
            put("The composed base changed since this plan was staged; it was measured against "
                .. short(state, plan_changes.base_digest), false)
        end
        local function entries(label: string, list: {EntryChange})
            for _, change in ipairs(list) do
                put(label .. "  " .. change.id .. "  " .. change.kind .. "  " .. short(state, change.digest), false)
            end
        end
        entries("added", plan_changes.added)
        entries("changed", plan_changes.changed)
        entries("removed", plan_changes.removed)
        if #plan_changes.added == 0 and #plan_changes.changed == 0 and #plan_changes.removed == 0 then
            put("This plan adds, changes and removes no entry", false)
        end
    end
    put("Approval", true)
    put(approval_row(state), false)
    local intent = state.intent
    if intent and M.key(item) == (intent.source_node .. "\0" .. intent.source_workspace .. "\0" .. intent.version) then
        put("Activation", true)
        put(intent.phase .. (intent.outcome and ("  " .. intent.outcome) or "") .. "  " .. intent.intent_id, false)
        if intent.observed_intent_id ~= nil then
            put("Receipt  overlay " .. intent.overlay_owner .. "  intent " .. intent.observed_intent_id
                .. "  " .. (intent.observed_outcome or "no observed outcome"), false)
            if intent.observed_artifact_digest ~= nil then
                put("Receipt  artifact " .. short(state, intent.observed_artifact_digest), false)
            end
        end
        if intent.diagnostics ~= nil and intent.diagnostics ~= "" then
            put("Result: " .. (bounds.line(intent.diagnostics, 240) or "the owner gave no reason"), false)
        end
    end
    return rows
end
function M.accepts_review(item: Plan?): boolean
    return item ~= nil and item.status == "staged"
end
function M.can_select(item: Plan?): boolean
    return item ~= nil and item.status == "reviewed" and item.review_status == "accepted"
end
function M.can_prepare(state: State, item: Plan?): boolean
    if not item or not item.selected or not M.can_select(item) then return false end
    return state.intent == nil or M.key(item) ~= (state.intent.source_node .. "\0" .. state.intent.source_workspace .. "\0" .. state.intent.version)
end
-- The plan staged for an available version, once it is staged.
function M.staged_plan(state: State, item: Available): Plan?
    for _, staged in ipairs(state.plans) do
        if M.key(staged) == M.available_plan_key(item) then return staged end
    end
    return nil
end
function M.set_pending_prepare(state: State, item: Plan, intent_id: string, receipt_key: string)
    state.pending_prepare = {plan_key = M.key(item), intent_id = intent_id, receipt_key = receipt_key}
end
function M.set_pending_step(state: State, intent_id: string, receipt_key: string)
    state.pending_step = {intent_id = intent_id, receipt_key = receipt_key}
end
function M.set_pending_recover(state: State, receipt_key: string)
    state.pending_recover_key = receipt_key
end
return M
