-- MIT. Activation request and durable row decoding.
local sql = require("sql")
local hash = require("hash")
local bounds = require("bounds")
local canonical = require("canonical")
local transaction = require("transaction")
local migration_work = require("migration_work")
local M = {}
local MAX_ARTIFACT = 262144
local MAX_RESOLUTION = 1048576
local MAX_PREFLIGHT = 131072
local MAX_MIGRATION_WORK = 1048576
local MAX_APPLICATION_ADMISSION = 65536
local MAX_MIGRATION_RECEIPT = 262144
local MAX_DIAGNOSTICS = 8192
local MAX_REVISION = 9007199254740991
-- An activation whose approval request ended without approval settles with
-- how it ended; it never reached its effect.
local OUTCOMES: {[string]: boolean} = {applied = true, blocked = true, failed = true, uncertain = true,
    denied = true, expired = true, withdrawn = true}

type Result = transaction.Result
type Store = {db: sql.DB, node: string, workspace: string, closed: boolean}
type Object = {[string]: unknown}
type Blob = {bytes: string, digest: string}
type PrepareRequest = {operation: "prepare_activation", intent_id: string, expected_revision: integer, idempotency_key: string, overlay_owner: string, source_node: string, source_workspace: string, version: string, plan_digest: string, plan_revision: integer, selection_revision: integer, artifact_digest: string, artifact: Blob, resolution: Blob, preflight: Blob, migration_work: Blob, application_admission: Blob?, grant_predecessor_digest: string?}

type BindRequest = {operation: "bind_approval", intent_id: string, expected_revision: integer, idempotency_key: string, approval_id: string, approval_proposal_digest: string, approval_owner_incarnation: integer, grant_reuse_digest: string?}

type LeaseRequest = {operation: "authorize_lease", intent_id: string, expected_revision: integer, idempotency_key: string, lease_id: string, lease_expected_revision: integer, proposal_capabilities: {unknown}}

type ConsumeRequest = {operation: "begin_consume", intent_id: string, expected_revision: integer, idempotency_key: string}

type ConsumptionRequest = {operation: "record_consumption", intent_id: string, expected_revision: integer, idempotency_key: string, consumer_id: string, proposal_digest: string, effect_key: string}

type ApplyRequest = {operation: "begin_apply", intent_id: string, expected_revision: integer, idempotency_key: string}

type MigrationRequest = {operation: "record_migrations", intent_id: string, expected_revision: integer, idempotency_key: string, receipt: Blob, complete: boolean, diagnostics: string}

type OutcomeRequest = {operation: "record_outcome", intent_id: string, expected_revision: integer, idempotency_key: string, outcome: string, diagnostics: string}
type RemoveRequest = {operation: "remove_activation", overlay_owner: string, expected_revision: integer, idempotency_key: string, diagnostics: string}
type RevertRequest = {operation: "revert_activation", overlay_owner: string, expected_revision: integer, idempotency_key: string, compensation: Blob, diagnostics: string}
type StatusRequest = {operation: "activation_status", intent_id: string}
type DecodedRequest = {operation: "prepare_activation", request: PrepareRequest} | {operation: "bind_approval", request: BindRequest} | {operation: "authorize_lease", request: LeaseRequest} | {operation: "begin_consume", request: ConsumeRequest} | {operation: "record_consumption", request: ConsumptionRequest} | {operation: "begin_apply", request: ApplyRequest} | {operation: "record_migrations", request: MigrationRequest} | {operation: "record_outcome", request: OutcomeRequest} | {operation: "activation_status", request: StatusRequest} | {operation: "revert_activation", request: RevertRequest} | {operation: "remove_activation", request: RemoveRequest}


local function failure(code: string, message: string, value: unknown?): Result
    return transaction.failure(code, message, value)
end
local function id(value: unknown): string?
    return bounds.id(value)
end
local function count(value: unknown, positive: boolean): integer?
    if type(value) ~= "number" or value ~= math.floor(value) or value < 0 or value > MAX_REVISION then return nil end
    if positive and value < 1 then return nil end
    return math.floor(value)
end
local function digest(value: string): string?
    local result, err = hash.sha256(value)
    if err or not result then return nil end
    return result
end
local hex_digest = bounds.digest_hex

local function checked_blob(value: unknown, limit: integer, label: string): (Blob?, string?)
    local object = bounds.object(value)
    if not object or type(object.bytes) ~= "string" or #object.bytes == 0 or #object.bytes > limit then return nil, label .. " bytes are invalid" end
    local measured = hex_digest(object.digest)
    if not measured then return nil, label .. " digest is invalid" end
    local bytes: string = object.bytes
    local actual = digest(bytes)
    if not actual or actual ~= measured then return nil, label .. " digest does not match bytes" end
    return {bytes = bytes, digest = measured}, nil
end
local function optional_blob(value: unknown, limit: integer, label: string): (Blob?, string?)
    if value == nil then return nil, nil end
    return checked_blob(value, limit, label)
end
local function unknown(value: Object, allowed: {string}): string?
    return bounds.fields(value, allowed)
end
local function authorization_digest(store: Store, input: PrepareRequest, artifact: Blob, resolution: Blob,
    preflight: Blob, work: Blob, admission: Blob?): string?
    local encoded = canonical.encode({schema_revision = "bee.governance-activation@1", owner_node = store.node,
        workspace_id = store.workspace, overlay_owner = input.overlay_owner, source_node = input.source_node,
        source_workspace = input.source_workspace, version = input.version, plan_digest = input.plan_digest,
        plan_revision = input.plan_revision, selection_revision = input.selection_revision,
        artifact_digest = artifact.digest, resolution_digest = resolution.digest, preflight_digest = preflight.digest,
        migration_work_digest = work.digest,
        application_admission_digest = admission and admission.digest or nil,
        grant_predecessor_digest = input.grant_predecessor_digest})
    if not encoded then return nil end
    return digest(encoded)
end
type Intent = {
    owner_node: string,
    workspace_id: string,
    intent_id: string,
    actor_id: string,
    overlay_owner: string,
    source_node: string,
    source_workspace: string,
    version: string,
    plan_digest: string,
    plan_revision: integer,
    selection_revision: integer,
    artifact_bytes: string,
    artifact_digest: string,
    resolution_bytes: string,
    resolution_digest: string,
    preflight_bytes: string,
    preflight_digest: string,
    authorization_digest: string,
    effect_key: string,
    created_at: string,
    migration_work_bytes: string?,
    migration_work_digest: string?,
    application_admission_bytes: string?,
    application_admission_digest: string?,
    grant_predecessor_digest: string?,
    revision: integer,
    phase: string,
    approval_id: string?,
    approval_proposal_digest: string?,
    approval_owner_incarnation: integer?,
    consumed_consumer_id: string?,
    consumed_proposal_digest: string?,
    consumed_effect_key: string?,
    outcome: string?,
    diagnostics: string?,
    migrations_completed: integer,
    migration_receipt_bytes: string?,
    migration_receipt_digest: string?,
    grant_reuse_digest: string?,
    execution_updated_at: string
}
local function decode_intent(row: Object): (Intent?, Result?)
    local owner_node = row.owner_node
    if type(owner_node) ~= "string" then return nil, failure("INTERNAL", "activation intent is malformed") end
    local workspace_id = row.workspace_id
    if type(workspace_id) ~= "string" then return nil, failure("INTERNAL", "activation intent is malformed") end
    local intent_id = row.intent_id
    if type(intent_id) ~= "string" then return nil, failure("INTERNAL", "activation intent is malformed") end
    local actor_id = row.actor_id
    if type(actor_id) ~= "string" then return nil, failure("INTERNAL", "activation intent is malformed") end
    local overlay_owner = row.overlay_owner
    if type(overlay_owner) ~= "string" then return nil, failure("INTERNAL", "activation intent is malformed") end
    local source_node = row.source_node
    if type(source_node) ~= "string" then return nil, failure("INTERNAL", "activation intent is malformed") end
    local source_workspace = row.source_workspace
    if type(source_workspace) ~= "string" then return nil, failure("INTERNAL", "activation intent is malformed") end
    local version = row.version
    if type(version) ~= "string" then return nil, failure("INTERNAL", "activation intent is malformed") end
    local plan_digest = row.plan_digest
    if type(plan_digest) ~= "string" then return nil, failure("INTERNAL", "activation intent is malformed") end
    local plan_revision = count(row.plan_revision, false)
    if plan_revision == nil then return nil, failure("INTERNAL", "activation intent is malformed") end
    local selection_revision = count(row.selection_revision, false)
    if selection_revision == nil then return nil, failure("INTERNAL", "activation intent is malformed") end
    local artifact_bytes = row.artifact_bytes
    if type(artifact_bytes) ~= "string" then return nil, failure("INTERNAL", "activation intent is malformed") end
    local artifact_digest = row.artifact_digest
    if type(artifact_digest) ~= "string" then return nil, failure("INTERNAL", "activation intent is malformed") end
    local resolution_bytes = row.resolution_bytes
    if type(resolution_bytes) ~= "string" then return nil, failure("INTERNAL", "activation intent is malformed") end
    local resolution_digest = row.resolution_digest
    if type(resolution_digest) ~= "string" then return nil, failure("INTERNAL", "activation intent is malformed") end
    local preflight_bytes = row.preflight_bytes
    if type(preflight_bytes) ~= "string" then return nil, failure("INTERNAL", "activation intent is malformed") end
    local preflight_digest = row.preflight_digest
    if type(preflight_digest) ~= "string" then return nil, failure("INTERNAL", "activation intent is malformed") end
    local authorization_digest = row.authorization_digest
    if type(authorization_digest) ~= "string" then return nil, failure("INTERNAL", "activation intent is malformed") end
    local effect_key = row.effect_key
    if type(effect_key) ~= "string" then return nil, failure("INTERNAL", "activation intent is malformed") end
    local created_at = row.created_at
    if type(created_at) ~= "string" then return nil, failure("INTERNAL", "activation intent is malformed") end
    local migration_work_bytes: string? = nil
    if row.migration_work_bytes ~= nil then
        local value = row.migration_work_bytes
        if type(value) ~= "string" then return nil, failure("INTERNAL", "activation intent is malformed") end
        migration_work_bytes = value
    end
    local migration_work_digest: string? = nil
    if row.migration_work_digest ~= nil then
        local value = row.migration_work_digest
        if type(value) ~= "string" then return nil, failure("INTERNAL", "activation intent is malformed") end
        migration_work_digest = value
    end
    local application_admission_generation = bounds.member(row.application_admission_generation, {"current", "prior"})
    if not application_admission_generation then return nil, failure("INTERNAL", "activation admission generation is invalid") end
    local application_admission_bytes: string? = nil
    if row.application_admission_bytes ~= nil then
        local value = row.application_admission_bytes
        if type(value) ~= "string" then return nil, failure("INTERNAL", "activation intent is malformed") end
        application_admission_bytes = value
    end
    local application_admission_digest: string? = nil
    if row.application_admission_digest ~= nil then
        local value = row.application_admission_digest
        if type(value) ~= "string" then return nil, failure("INTERNAL", "activation intent is malformed") end
        application_admission_digest = value
    end
    local grant_predecessor_digest: string? = nil
    if row.grant_predecessor_digest ~= nil then
        local value = row.grant_predecessor_digest
        if type(value) ~= "string" then return nil, failure("INTERNAL", "activation intent is malformed") end
        grant_predecessor_digest = value
    end
    local revision = count(row.revision, false)
    if revision == nil then return nil, failure("INTERNAL", "activation intent is malformed") end
    local phase = row.phase
    if type(phase) ~= "string" then return nil, failure("INTERNAL", "activation intent is malformed") end
    local approval_id: string? = nil
    if row.approval_id ~= nil then
        local value = row.approval_id
        if type(value) ~= "string" then return nil, failure("INTERNAL", "activation intent is malformed") end
        approval_id = value
    end
    local approval_proposal_digest: string? = nil
    if row.approval_proposal_digest ~= nil then
        local value = row.approval_proposal_digest
        if type(value) ~= "string" then return nil, failure("INTERNAL", "activation intent is malformed") end
        approval_proposal_digest = value
    end
    local approval_owner_incarnation: integer? = nil
    if row.approval_owner_incarnation ~= nil then
        approval_owner_incarnation = count(row.approval_owner_incarnation, false)
        if approval_owner_incarnation == nil then return nil, failure("INTERNAL", "activation intent is malformed") end
    end
    local consumed_consumer_id: string? = nil
    if row.consumed_consumer_id ~= nil then
        local value = row.consumed_consumer_id
        if type(value) ~= "string" then return nil, failure("INTERNAL", "activation intent is malformed") end
        consumed_consumer_id = value
    end
    local consumed_proposal_digest: string? = nil
    if row.consumed_proposal_digest ~= nil then
        local value = row.consumed_proposal_digest
        if type(value) ~= "string" then return nil, failure("INTERNAL", "activation intent is malformed") end
        consumed_proposal_digest = value
    end
    local consumed_effect_key: string? = nil
    if row.consumed_effect_key ~= nil then
        local value = row.consumed_effect_key
        if type(value) ~= "string" then return nil, failure("INTERNAL", "activation intent is malformed") end
        consumed_effect_key = value
    end
    local outcome: string? = nil
    if row.outcome ~= nil then
        local value = row.outcome
        if type(value) ~= "string" then return nil, failure("INTERNAL", "activation intent is malformed") end
        outcome = value
    end
    local diagnostics: string? = nil
    if row.diagnostics ~= nil then
        local value = row.diagnostics
        if type(value) ~= "string" then return nil, failure("INTERNAL", "activation intent is malformed") end
        diagnostics = value
    end
    local migrations_completed = count(row.migrations_completed, false)
    if migrations_completed == nil then return nil, failure("INTERNAL", "activation intent is malformed") end
    local migration_receipt_bytes: string? = nil
    if row.migration_receipt_bytes ~= nil then
        local value = row.migration_receipt_bytes
        if type(value) ~= "string" then return nil, failure("INTERNAL", "activation intent is malformed") end
        migration_receipt_bytes = value
    end
    local migration_receipt_digest: string? = nil
    if row.migration_receipt_digest ~= nil then
        local value = row.migration_receipt_digest
        if type(value) ~= "string" then return nil, failure("INTERNAL", "activation intent is malformed") end
        migration_receipt_digest = value
    end
    local grant_reuse_digest: string? = nil
    if row.grant_reuse_digest ~= nil then
        local value = row.grant_reuse_digest
        if type(value) ~= "string" then return nil, failure("INTERNAL", "activation intent is malformed") end
        grant_reuse_digest = value
    end
    local execution_updated_at = row.execution_updated_at
    if type(execution_updated_at) ~= "string" then return nil, failure("INTERNAL", "activation intent is malformed") end
    return {
        owner_node = owner_node,
        workspace_id = workspace_id,
        intent_id = intent_id,
        actor_id = actor_id,
        overlay_owner = overlay_owner,
        source_node = source_node,
        source_workspace = source_workspace,
        version = version,
        plan_digest = plan_digest,
        plan_revision = plan_revision,
        selection_revision = selection_revision,
        artifact_bytes = artifact_bytes,
        artifact_digest = artifact_digest,
        resolution_bytes = resolution_bytes,
        resolution_digest = resolution_digest,
        preflight_bytes = preflight_bytes,
        preflight_digest = preflight_digest,
        authorization_digest = authorization_digest,
        effect_key = effect_key,
        created_at = created_at,
        migration_work_bytes = migration_work_bytes,
        migration_work_digest = migration_work_digest,
        application_admission_bytes = application_admission_bytes,
        application_admission_digest = application_admission_digest,
        application_admission_generation = application_admission_generation,
        grant_predecessor_digest = grant_predecessor_digest,
        revision = revision,
        phase = phase,
        approval_id = approval_id,
        approval_proposal_digest = approval_proposal_digest,
        approval_owner_incarnation = approval_owner_incarnation,
        consumed_consumer_id = consumed_consumer_id,
        consumed_proposal_digest = consumed_proposal_digest,
        consumed_effect_key = consumed_effect_key,
        outcome = outcome,
        diagnostics = diagnostics,
        migrations_completed = migrations_completed,
        migration_receipt_bytes = migration_receipt_bytes,
        migration_receipt_digest = migration_receipt_digest,
        grant_reuse_digest = grant_reuse_digest,
        execution_updated_at = execution_updated_at
    }, nil
end
type Slot = {
    owner_node: string,
    workspace_id: string,
    overlay_owner: string,
    revision: integer,
    desired_intent_id: string?,
    desired_execution_revision: integer?,
    observed_intent_id: string?,
    observed_execution_revision: integer?,
    observed_artifact_digest: string?,
    observed_outcome: string?,
    updated_at: string,
    baseline_intent_id: string?,
    baseline_execution_revision: integer?,
    baseline_artifact_digest: string?
}
local function decode_slot(row: Object): (Slot?, Result?)
    local owner_node = row.owner_node
    if type(owner_node) ~= "string" then return nil, failure("INTERNAL", "activation slot is malformed") end
    local workspace_id = row.workspace_id
    if type(workspace_id) ~= "string" then return nil, failure("INTERNAL", "activation slot is malformed") end
    local overlay_owner = row.overlay_owner
    if type(overlay_owner) ~= "string" then return nil, failure("INTERNAL", "activation slot is malformed") end
    local revision = count(row.revision, false)
    if revision == nil then return nil, failure("INTERNAL", "activation slot is malformed") end
    local desired_intent_id: string? = nil
    if row.desired_intent_id ~= nil then
        local value = row.desired_intent_id
        if type(value) ~= "string" then return nil, failure("INTERNAL", "activation slot is malformed") end
        desired_intent_id = value
    end
    local desired_execution_revision: integer? = nil
    if row.desired_execution_revision ~= nil then
        desired_execution_revision = count(row.desired_execution_revision, false)
        if desired_execution_revision == nil then return nil, failure("INTERNAL", "activation slot is malformed") end
    end
    local observed_intent_id: string? = nil
    if row.observed_intent_id ~= nil then
        local value = row.observed_intent_id
        if type(value) ~= "string" then return nil, failure("INTERNAL", "activation slot is malformed") end
        observed_intent_id = value
    end
    local observed_execution_revision: integer? = nil
    if row.observed_execution_revision ~= nil then
        observed_execution_revision = count(row.observed_execution_revision, false)
        if observed_execution_revision == nil then return nil, failure("INTERNAL", "activation slot is malformed") end
    end
    local observed_artifact_digest: string? = nil
    if row.observed_artifact_digest ~= nil then
        local value = row.observed_artifact_digest
        if type(value) ~= "string" then return nil, failure("INTERNAL", "activation slot is malformed") end
        observed_artifact_digest = value
    end
    local observed_outcome: string? = nil
    if row.observed_outcome ~= nil then
        local value = row.observed_outcome
        if type(value) ~= "string" then return nil, failure("INTERNAL", "activation slot is malformed") end
        observed_outcome = value
    end
    local updated_at = row.updated_at
    if type(updated_at) ~= "string" then return nil, failure("INTERNAL", "activation slot is malformed") end
    local baseline_intent_id: string? = nil
    if row.baseline_intent_id ~= nil then
        local value = row.baseline_intent_id
        if type(value) ~= "string" then return nil, failure("INTERNAL", "activation slot is malformed") end
        baseline_intent_id = value
    end
    local baseline_execution_revision: integer? = nil
    if row.baseline_execution_revision ~= nil then
        baseline_execution_revision = count(row.baseline_execution_revision, false)
        if baseline_execution_revision == nil then return nil, failure("INTERNAL", "activation slot is malformed") end
    end
    local baseline_artifact_digest: string? = nil
    if row.baseline_artifact_digest ~= nil then
        local value = row.baseline_artifact_digest
        if type(value) ~= "string" then return nil, failure("INTERNAL", "activation slot is malformed") end
        baseline_artifact_digest = value
    end
    return {
        owner_node = owner_node,
        workspace_id = workspace_id,
        overlay_owner = overlay_owner,
        revision = revision,
        desired_intent_id = desired_intent_id,
        desired_execution_revision = desired_execution_revision,
        observed_intent_id = observed_intent_id,
        observed_execution_revision = observed_execution_revision,
        observed_artifact_digest = observed_artifact_digest,
        observed_outcome = observed_outcome,
        updated_at = updated_at,
        baseline_intent_id = baseline_intent_id,
        baseline_execution_revision = baseline_execution_revision,
        baseline_artifact_digest = baseline_artifact_digest
    }, nil
end

local function decode(raw: unknown): (DecodedRequest?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "activation request must be an object" end
    local operation = value.operation
    if operation == "activation_status" then
        local extra = unknown(value, {"operation", "intent_id"})
        if extra then return nil, extra end
        local intent_id = id(value.intent_id)
        if not intent_id then return nil, "intent_id is required" end
        return {operation = "activation_status", request = {operation = "activation_status", intent_id = intent_id}}, nil
    end
    if operation == "remove_activation" then
        local extra = unknown(value, {"operation", "overlay_owner", "expected_revision", "idempotency_key", "diagnostics"})
        if extra then return nil, extra end
        local overlay_owner, key = id(value.overlay_owner), id(value.idempotency_key)
        local expected = count(value.expected_revision, false)
        local diagnostics = bounds.text(value.diagnostics or "", MAX_DIAGNOSTICS)
        if not overlay_owner or not key or expected == nil or not diagnostics then
            return nil, "remove requires overlay_owner, expected_revision and idempotency_key"
        end
        return {operation = "remove_activation", request = {operation = "remove_activation", overlay_owner = overlay_owner, expected_revision = expected, idempotency_key = key, diagnostics = diagnostics}}, nil
    end
    if operation == "revert_activation" then
        local extra = unknown(value, {"operation", "overlay_owner", "expected_revision", "idempotency_key", "compensation", "diagnostics"})
        if extra then return nil, extra end
        local overlay_owner = id(value.overlay_owner)
        local key = id(value.idempotency_key)
        local expected = count(value.expected_revision, false)
        local compensation, compensation_error = checked_blob(value.compensation, MAX_MIGRATION_RECEIPT, "compensation")
        local diagnostics = bounds.text(value.diagnostics or "", MAX_DIAGNOSTICS)
        if not overlay_owner or not key or expected == nil or not compensation or not diagnostics then
            return nil, compensation_error or "revert requires overlay_owner, expected_revision, idempotency_key and a compensation receipt"
        end
        return {operation = "revert_activation", request = {operation = "revert_activation", overlay_owner = overlay_owner, expected_revision = expected,
            idempotency_key = key, compensation = compensation, diagnostics = diagnostics}}, nil
    end
    local common = {"operation", "intent_id", "expected_revision", "idempotency_key"}
    local intent_id, key, expected = id(value.intent_id), id(value.idempotency_key), count(value.expected_revision, false)
    if not intent_id or not key or expected == nil then return nil, "intent_id, expected_revision and idempotency_key are required" end
    if operation == "prepare_activation" then
        if expected ~= 0 then return nil, "prepare_activation requires expected_revision zero" end
        local extra = unknown(value, {"operation", "intent_id", "expected_revision", "idempotency_key", "overlay_owner", "source_node", "source_workspace", "version", "plan_digest", "plan_revision", "selection_revision", "artifact", "resolution", "preflight", "migration_work", "application_admission", "grant_predecessor_digest"})
        if extra then return nil, extra end
        local overlay_owner = id(value.overlay_owner)
        local source_node, source_workspace, version = id(value.source_node), id(value.source_workspace), id(value.version)
        local plan_digest = hex_digest(value.plan_digest)
        local plan_revision, selection_revision = count(value.plan_revision, true), count(value.selection_revision, true)
        local artifact, artifact_error = checked_blob(value.artifact, MAX_ARTIFACT, "artifact")
        local resolution, resolution_error = checked_blob(value.resolution, MAX_RESOLUTION, "resolution")
        local preflight, preflight_error = checked_blob(value.preflight, MAX_PREFLIGHT, "preflight")
        local work, work_error = checked_blob(value.migration_work, MAX_MIGRATION_WORK, "migration work")
        local admission, admission_error = optional_blob(value.application_admission, MAX_APPLICATION_ADMISSION, "application admission")
        if not overlay_owner or not source_node or not source_workspace or not version or not plan_digest or not plan_revision or not selection_revision or not artifact or not resolution or not preflight or not work or admission_error then return nil, artifact_error or resolution_error or preflight_error or work_error or admission_error or "activation facts are invalid" end
        local artifact_digest = artifact.digest
        local grant_predecessor_digest = value.grant_predecessor_digest == nil
            and nil or hex_digest(value.grant_predecessor_digest)
        if value.grant_predecessor_digest ~= nil and not grant_predecessor_digest then
            return nil, "grant predecessor digest is invalid"
        end
        return {operation = "prepare_activation", request = {operation = "prepare_activation", intent_id = intent_id, expected_revision = expected, idempotency_key = key, overlay_owner = overlay_owner, source_node = source_node, source_workspace = source_workspace, version = version, plan_digest = plan_digest, plan_revision = plan_revision, selection_revision = selection_revision, artifact_digest = artifact_digest, artifact = artifact, resolution = resolution, preflight = preflight, migration_work = work, application_admission = admission, grant_predecessor_digest = grant_predecessor_digest}}, nil
    end
    if operation == "bind_approval" then
        local extra = unknown(value, {"operation", "intent_id", "expected_revision", "idempotency_key", "approval_id", "approval_proposal_digest", "approval_owner_incarnation", "grant_reuse_digest"})
        if extra then return nil, extra end
        local approval_id, approval_proposal_digest = id(value.approval_id), hex_digest(value.approval_proposal_digest)
        local approval_owner_incarnation = count(value.approval_owner_incarnation, true)
        local grant_reuse_digest = value.grant_reuse_digest == nil and nil or hex_digest(value.grant_reuse_digest)
        if not approval_id or not approval_proposal_digest or not approval_owner_incarnation then return nil, "approval identity is invalid" end
        if value.grant_reuse_digest ~= nil and grant_reuse_digest ~= approval_proposal_digest then
            return nil, "grant reuse digest is invalid"
        end
        return {operation = "bind_approval", request = {operation = "bind_approval", intent_id = intent_id, expected_revision = expected, idempotency_key = key, approval_id = approval_id, approval_proposal_digest = approval_proposal_digest, approval_owner_incarnation = approval_owner_incarnation, grant_reuse_digest = grant_reuse_digest}}, nil
    elseif operation == "authorize_lease" then
        local extra = unknown(value, {"operation", "intent_id", "expected_revision", "idempotency_key", "lease_id", "lease_expected_revision", "proposal_capabilities"})
        if extra then return nil, extra end
        local lease_id, lease_expected_revision = id(value.lease_id), count(value.lease_expected_revision, true)
        local proposal_capabilities = bounds.dense_list(value.proposal_capabilities, 128, "proposed capabilities")
        if not lease_id or not lease_expected_revision or not proposal_capabilities then return nil, "lease authorization identity is invalid" end
        return {operation = "authorize_lease", request = {operation = "authorize_lease", intent_id = intent_id, expected_revision = expected, idempotency_key = key, lease_id = lease_id, lease_expected_revision = lease_expected_revision, proposal_capabilities = proposal_capabilities}}, nil
    elseif operation == "begin_consume" then
        local extra = unknown(value, {"operation", "intent_id", "expected_revision", "idempotency_key"})
        if extra then return nil, extra end
        return {operation = "begin_consume", request = {operation = "begin_consume", intent_id = intent_id, expected_revision = expected, idempotency_key = key}}, nil
    elseif operation == "record_consumption" then
        local extra = unknown(value, {"operation", "intent_id", "expected_revision", "idempotency_key", "consumer_id", "proposal_digest", "effect_key"})
        if extra then return nil, extra end
        local consumer_id, proposal_digest, effect_key = id(value.consumer_id), hex_digest(value.proposal_digest), id(value.effect_key)
        if not consumer_id or not proposal_digest or not effect_key then return nil, "consumption identity is invalid" end
        return {operation = "record_consumption", request = {operation = "record_consumption", intent_id = intent_id, expected_revision = expected, idempotency_key = key, consumer_id = consumer_id, proposal_digest = proposal_digest, effect_key = effect_key}}, nil
    elseif operation == "begin_apply" then
        local extra = unknown(value, common)
        if extra then return nil, extra end
        return {operation = "begin_apply", request = {operation = "begin_apply", intent_id = intent_id, expected_revision = expected, idempotency_key = key}}, nil
    elseif operation == "record_migrations" then
        local extra = unknown(value, {"operation", "intent_id", "expected_revision", "idempotency_key", "receipt", "complete", "diagnostics"})
        if extra then return nil, extra end
        local receipt, receipt_error = checked_blob(value.receipt, MAX_MIGRATION_RECEIPT, "migration receipt")
        local complete = value.complete
        local diagnostics = bounds.text(value.diagnostics or "", MAX_DIAGNOSTICS)
        if not receipt or type(complete) ~= "boolean" or not diagnostics then
            return nil, receipt_error or "migration result is invalid"
        end
        return {operation = "record_migrations", request = {operation = "record_migrations", intent_id = intent_id, expected_revision = expected, idempotency_key = key, receipt = receipt, complete = complete, diagnostics = diagnostics}}, nil
    elseif operation == "record_outcome" then
        local extra = unknown(value, {"operation", "intent_id", "expected_revision", "idempotency_key", "outcome", "diagnostics"})
        if extra then return nil, extra end
        local outcome = type(value.outcome) == "string" and value.outcome or nil
        local outcome = outcome and OUTCOMES[outcome] and outcome or nil
        local diagnostics = bounds.text(value.diagnostics or "", MAX_DIAGNOSTICS)
        if not outcome or not diagnostics then return nil, "outcome is invalid" end
        return {operation = "record_outcome", request = {operation = "record_outcome", intent_id = intent_id, expected_revision = expected, idempotency_key = key, outcome = outcome, diagnostics = diagnostics}}, nil
    else
        return nil, "unsupported activation operation"
    end
end

M.MAX_ARTIFACT = MAX_ARTIFACT
M.MAX_RESOLUTION = MAX_RESOLUTION
M.MAX_PREFLIGHT = MAX_PREFLIGHT
M.MAX_MIGRATION_WORK = MAX_MIGRATION_WORK
M.MAX_APPLICATION_ADMISSION = MAX_APPLICATION_ADMISSION
M.MAX_MIGRATION_RECEIPT = MAX_MIGRATION_RECEIPT
M.MAX_DIAGNOSTICS = MAX_DIAGNOSTICS
M.MAX_REVISION = MAX_REVISION
M.OUTCOMES = OUTCOMES
M.failure = failure
M.id = id
M.count = count
M.digest = digest
M.hex_digest = hex_digest
M.checked_blob = checked_blob
M.optional_blob = optional_blob
M.unknown = unknown
M.authorization_digest = authorization_digest
M.decode_intent = decode_intent
M.decode_slot = decode_slot
M.decode = decode
return M
