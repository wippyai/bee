-- MIT. Typed local projection and request builder for the destination delivery
-- facade. This model has no authority beyond the caller supplied by the app.
local bounds = require("bounds")
local caller = require("caller")
local json = require("json")

local M = {}
M.CALL = "bee.governance:destination_call"
M.MAX_PLANS = 128
M.MAX_AVAILABLE = 512
type Object = {[string]: unknown}
type Status = "staged" | "reviewed" | "rejected" | "approval_bound"
type Available = {owner_id: string, feed: string, version_key: string, component: string,
    version: string, source_workspace: string, content_digest: string, descriptor_digest: string,
    total_bytes: integer}
type Plan = {owner_node: string, workspace_id: string, source_node: string, source_workspace: string,
    version: string, plan_digest: string, candidate_digest: string, artifact_digest: string,
    preflight_digest: string, revision: integer, status: Status, review_status: string?,
    review_reason: string?, reviewer_id: string?, approval_id: string?, selected: boolean,
    selection_revision: integer?}
type Intent = {owner_node: string, workspace_id: string, intent_id: string, overlay_owner: string,
    source_node: string, source_workspace: string, version: string, revision: integer,
    phase: string, outcome: string?, diagnostics: string?, approval_id: string?}
type PendingPrepare = {plan_key: string, intent_id: string, receipt_key: string}
type PendingStep = {intent_id: string, receipt_key: string}
type PendingStage = {available_key: string, idempotency_key: string}
type Pane = "available" | "plans"
type State = {workspace_id: string, available: {Available}, selected_available_key: string?, pane: Pane,
    plans: {Plan}, selected_key: string?, detail: Plan?, intent: Intent?,
    offset: integer, technical: boolean, notice: string, pending_prepare: PendingPrepare?,
    pending_step: PendingStep?, pending_recover_key: string?, restored_intent_id: string?, pending_stage: PendingStage?}

local PLAN_FIELDS = {"owner_node", "workspace_id", "source_node", "source_workspace", "version", "plan_digest",
    "candidate_digest", "artifact_digest", "preflight_digest", "revision", "status", "review_status",
    "review_reason", "reviewer_id", "approval_id", "approval_plan_digest", "approval_proposal_digest",
    "approval_owner_incarnation", "selected", "selection_revision", "candidate_bytes", "artifact_bytes", "preflight_bytes"}
local INTENT_FIELDS = {"owner_node", "workspace_id", "intent_id", "actor_id", "overlay_owner", "source_node",
    "source_workspace", "version", "plan_digest", "plan_revision", "selection_revision", "artifact_bytes",
    "artifact_digest", "resolution_bytes", "resolution_digest", "preflight_bytes", "preflight_digest",
    "authorization_digest", "effect_key", "revision", "phase", "approval_id", "approval_proposal_digest",
    "approval_owner_incarnation", "consumed_consumer_id", "consumed_proposal_digest", "consumed_effect_key",
    "outcome", "diagnostics", "slot_revision", "desired_intent_id", "desired_execution_revision",
    "observed_intent_id", "observed_execution_revision", "observed_artifact_digest", "observed_outcome"}
local DESCRIPTOR_FIELDS = {"schema", "owner_id", "feed", "key", "object_id", "version_id", "content_digest",
    "manifest_digest", "content_kind", "total_bytes", "manifest", "digest"}
local MANIFEST_FIELDS = {"schema_revision", "source_workspace", "component", "artifact_digest"}
local STATUSES: {[string]: boolean} = {staged = true, reviewed = true, rejected = true, approval_bound = true}
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
    local source = value :: table
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
    local status: string? = nil
    if type(value.status) == "string" then
        local candidate = value.status :: string
        if STATUSES[candidate] then status = candidate end
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
    local review_reason, reviewer_id, approval_id = optional_text(value.review_reason, 512), optional_id(value.reviewer_id), optional_id(value.approval_id)
    if (value.review_reason ~= nil and not review_reason) or (value.reviewer_id ~= nil and not reviewer_id)
        or (value.approval_id ~= nil and not approval_id) then return nil, "plan review metadata is malformed" end
    local selection_revision = optional_count(value.selection_revision, true)
    if (selected and not selection_revision) or (not selected and value.selection_revision ~= nil) then
        return nil, "plan selection state is malformed"
    end
    if not optional_digest(value.approval_plan_digest) or not optional_digest(value.approval_proposal_digest)
        or not optional_count_valid(value.approval_owner_incarnation, true)
        or not valid_blob(value.candidate_bytes, 262144) or not valid_blob(value.artifact_bytes, 262144)
        or not valid_blob(value.preflight_bytes, 131072) then return nil, "plan evidence is malformed" end
    return {owner_node = owner_node, workspace_id = workspace, source_node = source_node,
        source_workspace = source_workspace, version = version, plan_digest = plan_digest,
        candidate_digest = candidate_digest, artifact_digest = artifact_digest, preflight_digest = preflight_digest,
        revision = revision, status = status :: Status, review_status = review_status,
        review_reason = review_reason, reviewer_id = reviewer_id, approval_id = approval_id,
        selected = selected, selection_revision = selection_revision}, nil
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
    return {owner_id = owner_id, feed = feed, version_key = version_key, component = component,
        version = version, source_workspace = source_workspace, content_digest = content_digest,
        descriptor_digest = descriptor_digest, total_bytes = total_bytes}, nil
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
        local candidate = value.phase :: string
        if PHASES[candidate] then phase = candidate end
    end
    local outcome = optional_id(value.outcome)
    if value.outcome ~= nil and (not outcome or not OUTCOMES[outcome]) then return nil, "activation outcome is malformed" end
    local diagnostics, approval_id = optional_text(value.diagnostics, 8192), optional_id(value.approval_id)
    if not owner_node or workspace ~= workspace_id or not intent_id or not overlay_owner or not source_node
        or not source_workspace or not version or not revision or not phase
        or (value.diagnostics ~= nil and not diagnostics) or (value.approval_id ~= nil and not approval_id) then
        return nil, "activation identity or state is malformed"
    end
    if not optional_digest(value.plan_digest) or not optional_digest(value.artifact_digest)
        or not optional_digest(value.resolution_digest) or not optional_digest(value.preflight_digest)
        or not optional_digest(value.authorization_digest) or not optional_digest(value.approval_proposal_digest)
        or not optional_digest(value.consumed_proposal_digest) or not optional_digest(value.observed_artifact_digest)
        or not optional_count_valid(value.plan_revision, true) or not optional_count_valid(value.selection_revision, true)
        or not optional_count_valid(value.approval_owner_incarnation, true) or not optional_count_valid(value.slot_revision, false)
        or not optional_count_valid(value.desired_execution_revision, false) or not optional_count_valid(value.observed_execution_revision, false)
        or not valid_blob(value.artifact_bytes, 262144) or not valid_blob(value.resolution_bytes, 1048576)
        or not valid_blob(value.preflight_bytes, 131072) then return nil, "activation evidence is malformed" end
    return {owner_node = owner_node, workspace_id = workspace, intent_id = intent_id, overlay_owner = overlay_owner,
        source_node = source_node, source_workspace = source_workspace, version = version,
        revision = revision, phase = phase, outcome = outcome, diagnostics = diagnostics, approval_id = approval_id}, nil
end
local function message(reply: caller.Reply?): string
    if not reply then return "No answer from the destination; check status before retrying" end
    if reply.error then
        local detail = bounds.line(reply.error.message, 240) or "destination refused the request"
        return bounds.line(reply.error.code, 40) and (reply.error.code .. ": " .. detail) or detail
    end
    return "Destination returned an invalid reply"
end
local function result_object(reply: caller.Reply?): Object?
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
    return {workspace_id = workspace_id, available = {}, selected_available_key = nil, pane = "available",
        plans = {}, selected_key = nil, detail = nil, intent = nil,
        offset = 0, technical = false, notice = "", pending_prepare = nil, pending_step = nil,
        pending_recover_key = nil, restored_intent_id = nil, pending_stage = nil}
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
    state.notice = ""
end
function M.toggle_pane(state: State)
    state.pane = state.pane == "available" and "plans" or "available"
    state.notice = ""
end
function M.select(state: State, key: string?)
    state.selected_key = key
    if state.detail and M.key(state.detail) ~= key then state.detail = nil end
    state.notice = ""
end
function M.move(state: State, step: integer)
    if #state.plans == 0 then return end
    local index = 1
    for current, item in ipairs(state.plans) do if M.key(item) == state.selected_key then index = current; break end end
    index = math.floor(math.max(1, math.min(#state.plans, index + step)))
    M.select(state, M.key(state.plans[index]))
end
function M.move_available(state: State, step: integer)
    if #state.available == 0 then return end
    local index = 1
    for current, item in ipairs(state.available) do
        if M.available_key(item) == state.selected_available_key then index = current; break end
    end
    index = math.floor(math.max(1, math.min(#state.available, index + step)))
    M.select_available(state, M.available_key(state.available[index]))
end
local function visible(state: State)
    local index = 1
    for current, item in ipairs(state.plans) do if M.key(item) == state.selected_key then index = current; break end end
    if index <= state.offset then state.offset = index - 1 end
end
function M.apply_list(state: State, reply: caller.Reply?)
    local value = result_object(reply)
    if not value then state.notice = message(reply); return false end
    local extra = bounds.fields(value, {"owner_node", "workspace_id", "plans"})
    if extra or bounds.id(value.owner_node) == nil or value.workspace_id ~= state.workspace_id then
        state.notice = "Destination returned an invalid plan list"; return false
    end
    local rows = dense(value.plans, M.MAX_PLANS)
    if not rows then state.notice = "Destination returned an invalid plan list"; return false end
    local decoded: {Plan} = {}
    local seen: {[string]: boolean} = {}
    for _, raw in ipairs(rows) do
        local item, err = plan(raw, state.workspace_id)
        if not item then state.notice = err or "Destination returned an invalid plan"; return false end
        local key = M.key(item)
        if seen[key] then state.notice = "Destination returned duplicate plans"; return false end
        seen[key] = true
        decoded[#decoded + 1] = item
    end
    state.plans = decoded
    if not state.selected_key or not seen[state.selected_key] then
        state.selected_key = decoded[1] and M.key(decoded[1]) or nil
        state.detail = nil
    end
    if state.detail then
        local found = false
        for _, item in ipairs(decoded) do if M.key(item) == M.key(state.detail :: Plan) then found = true end end
        if not found then state.detail = nil end
    end
    visible(state)
    state.notice = #decoded == 0 and "No staged application versions in this workspace" or ""
    return true
end
function M.apply_available(state: State, reply: caller.Reply?)
    local value = result_object(reply)
    if not value then state.notice = message(reply); return false end
    if bounds.fields(value, {"workspace_id", "versions"}) or value.workspace_id ~= state.workspace_id then
        state.notice = "Destination returned an invalid available version list"; return false
    end
    local rows = dense(value.versions, M.MAX_AVAILABLE)
    if not rows then state.notice = "Destination returned an invalid available version list"; return false end
    local decoded: {Available} = {}
    local seen: {[string]: boolean} = {}
    for _, raw in ipairs(rows) do
        local item, err = available(raw)
        if not item then state.notice = err or "Destination returned an invalid available version"; return false end
        local key = M.available_key(item)
        if seen[key] then state.notice = "Destination returned duplicate available versions"; return false end
        seen[key] = true
        decoded[#decoded + 1] = item
    end
    state.available = decoded
    if not state.selected_available_key or not seen[state.selected_available_key] then
        state.selected_available_key = decoded[1] and M.available_key(decoded[1]) or nil
    end
    state.notice = #decoded == 0 and "No application versions are available from configured sources" or ""
    return true
end
function M.apply_plan(state: State, reply: caller.Reply?)
    local value = result_object(reply)
    if not value then state.notice = message(reply); return false end
    local item, err = plan(value, state.workspace_id)
    if not item then state.notice = err or "Destination returned an invalid plan"; return false end
    state.detail = item
    for index, current in ipairs(state.plans) do
        if M.key(current) == M.key(item) then state.plans[index] = item; break end
    end
    state.notice = "Plan details refreshed"
    return true
end
function M.apply_stage(state: State, reply: caller.Reply?, source: Available): boolean
    local value = result_object(reply)
    if not value then state.notice = message(reply); return false end
    local item, err = plan(value, state.workspace_id)
    if not item then state.notice = err or "Destination returned an invalid staged plan"; return false end
    if item.status ~= "staged" or item.source_node ~= source.owner_id
        or item.source_workspace ~= source.source_workspace or item.version ~= source.version then
        state.notice = "Destination returned a staged plan for a different version"; return false
    end
    local found = false
    for index, current in ipairs(state.plans) do
        if M.key(current) == M.key(item) then state.plans[index] = item; found = true; break end
    end
    if not found then
        if #state.plans >= M.MAX_PLANS then
            state.notice = "Destination plan list is full; refresh before staging another version"; return false
        end
        state.plans[#state.plans + 1] = item
    end
    state.selected_key = M.key(item)
    state.detail = nil
    state.pane = "plans"
    state.notice = "Staged for local review; no installation performed"
    return true
end
function M.apply_activation(state: State, reply: caller.Reply?): boolean
    local value = result_object(reply)
    if not value then state.notice = message(reply); return false end
    local item, err = intent(value, state.workspace_id)
    if not item then state.notice = err or "Destination returned an invalid activation"; return false end
    state.intent = item
    state.notice = "Activation " .. item.phase
    return true
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
function M.get_request(state: State, item: Plan): Object
    return {operation = "get", workspace_id = state.workspace_id, source_node = item.source_node,
        source_workspace = item.source_workspace, version = item.version}
end
function M.review_request(state: State, item: Plan, accepted: boolean, key: string): Object
    return {operation = "review", workspace_id = state.workspace_id, source_node = item.source_node,
        source_workspace = item.source_workspace, version = item.version, expected_revision = item.revision,
        idempotency_key = key, review_status = accepted and "accepted" or "rejected",
        review_reason = "Reviewed in Bee App Delivery"}
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
function M.step_request(state: State, intent_id: string, key: string): Object
    return {operation = "step", workspace_id = state.workspace_id, intent_id = intent_id, receipt_key = key}
end
function M.status_request(state: State, intent_id: string): Object
    return {operation = "status", workspace_id = state.workspace_id, intent_id = intent_id}
end
function M.recover_request(state: State, key: string): Object
    return {operation = "recover", workspace_id = state.workspace_id, receipt_key = key}
end
function M.checkpoint(state: State): string
    local value: Object = {selected_key = state.selected_key, selected_available_key = state.selected_available_key,
        pane = state.pane, technical = state.technical}
    if state.intent then value.intent_id = state.intent.intent_id elseif state.restored_intent_id then value.intent_id = state.restored_intent_id end
    if state.pending_prepare then
        value.pending_prepare = {plan_key = state.pending_prepare.plan_key, intent_id = state.pending_prepare.intent_id,
            receipt_key = state.pending_prepare.receipt_key}
    end
    if state.pending_step then value.pending_step = {intent_id = state.pending_step.intent_id,
        receipt_key = state.pending_step.receipt_key} end
    if state.pending_recover_key then value.pending_recover_key = state.pending_recover_key end
    if state.pending_stage then
        value.pending_stage = {available_key = state.pending_stage.available_key,
            idempotency_key = state.pending_stage.idempotency_key}
    end
    local encoded, err = json.encode(value)
    if err or not encoded then return "{}" end
    return encoded
end
function M.restore(state: State, encoded: string): boolean
    local decoded: unknown = json.decode(encoded)
    local value = object(decoded)
    if not value or bounds.fields(value, {"selected_key", "selected_available_key", "pane", "technical", "intent_id",
        "pending_prepare", "pending_step", "pending_recover_key", "pending_stage"}) then return false end
    -- Selection keys are derived from decoded destination rows and contain NUL
    -- separators. They are lookup hints only and never become request identity.
    if value.selected_key ~= nil and not bounds.text(value.selected_key, 500) then return false end
    if value.selected_available_key ~= nil and not bounds.text(value.selected_available_key, 700) then return false end
    if value.pane ~= nil and value.pane ~= "available" and value.pane ~= "plans" then return false end
    if value.technical ~= nil and type(value.technical) ~= "boolean" then return false end
    if value.intent_id ~= nil and not bounds.id(value.intent_id) then return false end
    if value.pending_recover_key ~= nil and not bounds.id(value.pending_recover_key) then return false end
    local pending_prepare: PendingPrepare? = nil
    if value.pending_prepare ~= nil then
        local item = object(value.pending_prepare)
        if not item or bounds.fields(item, {"plan_key", "intent_id", "receipt_key"}) then return false end
        local plan_key, intent_id, receipt_key = bounds.text(item.plan_key, 500), bounds.id(item.intent_id), bounds.id(item.receipt_key)
        if not plan_key or not intent_id or not receipt_key then return false end
        pending_prepare = {plan_key = plan_key, intent_id = intent_id, receipt_key = receipt_key}
    end
    local pending_step: PendingStep? = nil
    if value.pending_step ~= nil then
        local item = object(value.pending_step)
        if not item or bounds.fields(item, {"intent_id", "receipt_key"}) then return false end
        local intent_id, receipt_key = bounds.id(item.intent_id), bounds.id(item.receipt_key)
        if not intent_id or not receipt_key then return false end
        pending_step = {intent_id = intent_id, receipt_key = receipt_key}
    end
    local pending_stage: PendingStage? = nil
    if value.pending_stage ~= nil then
        local item = object(value.pending_stage)
        if not item or bounds.fields(item, {"available_key", "idempotency_key"}) then return false end
        local available_key = bounds.text(item.available_key, 700)
        local idempotency_key = bounds.id(item.idempotency_key)
        if not available_key or not idempotency_key then return false end
        pending_stage = {available_key = available_key, idempotency_key = idempotency_key}
    end
    state.selected_key = type(value.selected_key) == "string" and value.selected_key or nil
    state.selected_available_key = type(value.selected_available_key) == "string" and value.selected_available_key or nil
    state.pane = value.pane == "plans" and "plans" or "available"
    state.technical = value.technical == true
    state.pending_prepare, state.pending_step = pending_prepare, pending_step
    state.pending_recover_key = type(value.pending_recover_key) == "string" and value.pending_recover_key or nil
    state.pending_stage = pending_stage
    -- A saved intent id has no trusted details; status re-decodes the current owner value.
    state.intent = nil
    state.restored_intent_id = bounds.id(value.intent_id)
    return true
end
function M.toggle_technical(state: State)
    state.technical = not state.technical
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
function M.available_status(state: State, item: Available): string
    for _, staged in ipairs(state.plans) do
        if M.key(staged) == M.available_plan_key(item) then return staged.status end
    end
    return "available"
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
function M.set_pending_stage(state: State, available_key: string, idempotency_key: string)
    state.pending_stage = {available_key = available_key, idempotency_key = idempotency_key}
end
function M.finish_mutation(state: State, operation: string, reply: caller.Reply?)
    if operation == "review" or operation == "select" then
        if M.apply_plan(state, reply) then
            if state.detail then state.detail = nil end
        end
    elseif operation == "prepare" or operation == "step" or operation == "recover" or operation == "status" then
        M.apply_activation(state, reply)
    end
end
return M
