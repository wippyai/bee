-- MIT. Small destination-owned activation ledger. Intent facts are immutable;
-- execution progress and recovery pointers are stored separately. This module
-- does not resolve, approve, apply, or contact another node.
local sql = require("sql")
local hash = require("hash")
local bounds = require("bounds")
local canonical = require("canonical")
local json = require("json")
local database = require("database")
local transaction = require("transaction")
local migrations = require("migrations")
local migration_work = require("migration_work")
local lease_store = require("lease_store")

local M = {}
local MAX_INTENTS = 128
local MAX_RECEIPTS = 512
local MAX_ARTIFACT = 262144
local MAX_RESOLUTION = 1048576
local MAX_PREFLIGHT = 131072
local MAX_MIGRATION_WORK = 1048576
local MAX_APPLICATION_ADMISSION = 65536
local MAX_MIGRATION_RECEIPT = 262144
local MAX_DIAGNOSTICS = 8192
local MAX_REQUEST = 4194304
local MAX_REVISION = 9007199254740991
local OUTCOMES: {[string]: boolean} = {applied = true, blocked = true, failed = true, uncertain = true}

type Result = transaction.Result
type Store = {db: sql.DB, node: string, workspace: string, closed: boolean}
type Object = {[string]: unknown}
type Blob = {bytes: string, digest: string}
type Request = Object
type PrepareRequest = {operation: "prepare_activation", intent_id: string, expected_revision: integer, idempotency_key: string, overlay_owner: string, source_node: string, source_workspace: string, version: string, plan_digest: string, plan_revision: integer, selection_revision: integer, artifact_digest: string, artifact: Blob, resolution: Blob, preflight: Blob, migration_work: Blob, application_admission: Blob?, grant_predecessor_digest: string?}

type BindRequest = {operation: "bind_approval", intent_id: string, expected_revision: integer, idempotency_key: string, approval_id: string, approval_proposal_digest: string, approval_owner_incarnation: integer, grant_reuse_digest: string?}

type LeaseRequest = {operation: "authorize_lease", intent_id: string, expected_revision: integer, idempotency_key: string, lease_id: string, lease_expected_revision: integer, proposal_capabilities: {unknown}}

type ConsumeRequest = {operation: "begin_consume", intent_id: string, expected_revision: integer, idempotency_key: string}

type ConsumptionRequest = {operation: "record_consumption", intent_id: string, expected_revision: integer, idempotency_key: string, consumer_id: string, proposal_digest: string, effect_key: string}

type ApplyRequest = {operation: "begin_apply", intent_id: string, expected_revision: integer, idempotency_key: string}

type MigrationRequest = {operation: "record_migrations", intent_id: string, expected_revision: integer, idempotency_key: string, receipt: Blob, complete: boolean, diagnostics: string}

type OutcomeRequest = {operation: "record_outcome", intent_id: string, expected_revision: integer, idempotency_key: string, outcome: string, diagnostics: string}
type RevertRequest = {operation: "revert_activation", overlay_owner: string, expected_revision: integer, idempotency_key: string, compensation: Blob, diagnostics: string}
type StatusRequest = {operation: "activation_status", intent_id: string}
type Mutation = PrepareRequest | BindRequest | LeaseRequest | ConsumeRequest | ConsumptionRequest | ApplyRequest | MigrationRequest | OutcomeRequest
type DecodedRequest = {operation: "prepare_activation", request: PrepareRequest} | {operation: "bind_approval", request: BindRequest} | {operation: "authorize_lease", request: LeaseRequest} | {operation: "begin_consume", request: ConsumeRequest} | {operation: "record_consumption", request: ConsumptionRequest} | {operation: "begin_apply", request: ApplyRequest} | {operation: "record_migrations", request: MigrationRequest} | {operation: "record_outcome", request: OutcomeRequest} | {operation: "activation_status", request: StatusRequest} | {operation: "revert_activation", request: RevertRequest}


local function failure(code: string, message: string, value: unknown?): Result
    return transaction.failure(code, message, value)
end
local function storage(err: unknown, action: string): Result
    if transaction.busy(err) then return transaction.storage_failure("governance activation database is busy") end
    return failure("INTERNAL", action)
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
local function hex_digest(value: unknown): string?
    if type(value) ~= "string" or #value ~= 64 or not value:match("^[0-9a-f]+$") then return nil end
    return value
end
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
local function request_digest(value: Request): (string?, Result?)
    local encoded = canonical.encode(value, MAX_REQUEST)
    if not encoded then return nil, failure("INVALID", "activation request cannot be measured") end
    local measured = digest(encoded)
    if not measured then return nil, failure("INTERNAL", "measure activation request") end
    return measured, nil
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
local function one(tx: sql.Transaction, statement: string, params: {unknown}, label: string): (Object?, Result?)
    local rows, err = tx:query(statement, params)
    if err or not rows then return nil, storage(err, "read " .. label) end
    if #rows > 1 then return nil, failure("INTERNAL", label .. " rows are duplicated") end
    return rows[1], nil
end
local function cas_result(result: unknown, err: unknown, action: string): Result?
    if err then return storage(err, action) end
    local value = bounds.object(result)
    if not value or value.rows_affected ~= 1 then return failure("CONFLICT", action .. " lost its revision fence") end
    return nil
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

local function load(tx: sql.Transaction, store: Store, intent_id: string): (Intent?, Result?)
    local row, err = one(tx, "SELECT i.*, e.revision, e.phase, e.approval_id, e.approval_proposal_digest, e.approval_owner_incarnation, e.grant_reuse_digest, e.consumed_consumer_id, e.consumed_proposal_digest, e.consumed_effect_key, e.outcome, e.diagnostics, e.migrations_completed, e.migration_receipt_bytes, e.migration_receipt_digest, e.updated_at AS execution_updated_at FROM bee_governance_activation_intents i JOIN bee_governance_activation_execution e ON e.owner_node = i.owner_node AND e.workspace_id = i.workspace_id AND e.intent_id = i.intent_id WHERE i.owner_node = ? AND i.workspace_id = ? AND i.intent_id = ?", {store.node, store.workspace, intent_id}, "activation intent")
    if err or not row then return nil, err end
    return decode_intent(row)
end
local function slot(tx: sql.Transaction, store: Store, overlay_owner: string, create: boolean): (Slot?, Result?)
    local row, err = one(tx, "SELECT * FROM bee_governance_activation_slots WHERE owner_node = ? AND workspace_id = ? AND overlay_owner = ?", {store.node, store.workspace, overlay_owner}, "activation slot")
    if err then return nil, err end
    if row then return decode_slot(row) end
    if not create then return nil, nil end
    local _, insert_error = tx:execute("INSERT INTO bee_governance_activation_slots (owner_node, workspace_id, overlay_owner, revision, updated_at) VALUES (?, ?, ?, 0, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))", {store.node, store.workspace, overlay_owner})
    if insert_error then return nil, storage(insert_error, "create activation slot") end
    local created, created_error = one(tx, "SELECT * FROM bee_governance_activation_slots WHERE owner_node = ? AND workspace_id = ? AND overlay_owner = ?", {store.node, store.workspace, overlay_owner}, "activation slot")
    if created_error or not created then return nil, created_error end
    return decode_slot(created)
end
local function view(store: Store, row: Object, current_slot: Object?): Object
    local result: Object = {owner_node = store.node, workspace_id = store.workspace, intent_id = row.intent_id,
        actor_id = row.actor_id, overlay_owner = row.overlay_owner, source_node = row.source_node, source_workspace = row.source_workspace,
        version = row.version, plan_digest = row.plan_digest, plan_revision = row.plan_revision,
        selection_revision = row.selection_revision, artifact_bytes = row.artifact_bytes,
        artifact_digest = row.artifact_digest, resolution_bytes = row.resolution_bytes,
        resolution_digest = row.resolution_digest, preflight_bytes = row.preflight_bytes,
        preflight_digest = row.preflight_digest, authorization_digest = row.authorization_digest,
        migration_work_bytes = row.migration_work_bytes, migration_work_digest = row.migration_work_digest,
        application_admission_bytes = row.application_admission_bytes,
        application_admission_digest = row.application_admission_digest,
        grant_predecessor_digest = row.grant_predecessor_digest,
        effect_key = row.effect_key, revision = row.revision, phase = row.phase,
        approval_id = row.approval_id, approval_proposal_digest = row.approval_proposal_digest,
        grant_reuse_digest = row.grant_reuse_digest,
        approval_owner_incarnation = row.approval_owner_incarnation, consumed_consumer_id = row.consumed_consumer_id,
        consumed_proposal_digest = row.consumed_proposal_digest, consumed_effect_key = row.consumed_effect_key,
        outcome = row.outcome, diagnostics = row.diagnostics,
        migrations_completed = row.migrations_completed == true or tonumber(row.migrations_completed) == 1,
        migration_receipt_bytes = row.migration_receipt_bytes,
        migration_receipt_digest = row.migration_receipt_digest}
    if current_slot then
        result.slot_revision = current_slot.revision
        result.desired_intent_id, result.desired_execution_revision = current_slot.desired_intent_id, current_slot.desired_execution_revision
        result.observed_intent_id, result.observed_execution_revision = current_slot.observed_intent_id, current_slot.observed_execution_revision
        result.observed_artifact_digest, result.observed_outcome = current_slot.observed_artifact_digest, current_slot.observed_outcome
    end
    return result
end
local function replay(store: Store, tx: sql.Transaction, actor: string, input: Mutation, measured: string): Result?
    local key = id(input.idempotency_key)
    if not key then return failure("INVALID", "idempotency_key is required") end
    local row, err = one(tx, "SELECT actor_id, operation, request_digest, intent_id FROM bee_governance_activation_receipts WHERE owner_node = ? AND workspace_id = ? AND idempotency_key = ?", {store.node, store.workspace, key}, "activation receipt")
    if err or not row then return err end
    if row.actor_id ~= actor then return failure("DENIED", "idempotency key belongs to another actor") end
    if row.operation ~= input.operation or row.request_digest ~= measured or row.intent_id ~= input.intent_id then return failure("CONFLICT", "idempotency key was used by a different activation request") end
    local receipt_intent = id(row.intent_id)
    if not receipt_intent then return failure("INTERNAL", "activation receipt has no intent") end
    local current, current_error = load(tx, store, receipt_intent)
    if current_error or not current then return current_error or failure("INTERNAL", "activation receipt has no intent") end
    local current_slot, slot_error = slot(tx, store, current.overlay_owner, false)
    if slot_error then return slot_error end
    return transaction.success(view(store, current, current_slot), true)
end
local function save_receipt(store: Store, tx: sql.Transaction, actor: string, input: Mutation, measured: string, row: Object): Result?
    local count_row, count_error = one(tx, "SELECT COUNT(*) AS count FROM bee_governance_activation_receipts WHERE owner_node = ? AND workspace_id = ?", {store.node, store.workspace}, "activation receipt count")
    if count_error or not count_row then return count_error or failure("INTERNAL", "activation receipt count is missing") end
    local receipts = count(count_row.count, false)
    if not receipts then return failure("INTERNAL", "activation receipt count is corrupt") end
    if receipts >= MAX_RECEIPTS then return failure("CAPACITY_EXHAUSTED", "activation receipt capacity is exhausted") end
    local _, err = tx:execute("INSERT INTO bee_governance_activation_receipts (owner_node, workspace_id, idempotency_key, actor_id, operation, request_digest, intent_id, result_revision) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", {store.node, store.workspace, input.idempotency_key, actor, input.operation, measured, row.intent_id, row.revision})
    if err then return storage(err, "record activation receipt") end
    return nil
end
local function transition(store: Store, actor: string, input: Mutation, accepted: {[string]: boolean}, update: (sql.Transaction, Intent) -> Result): Result
    local measured, measure_error = request_digest(input)
    if not measured then return assert(measure_error) end
    return transaction.write(store.db, "governance activation", function(tx: sql.Transaction): Result
        local already = replay(store, tx, actor, input, measured)
        if already then return already end
        local row, row_error = load(tx, store, input.intent_id)
        if row_error or not row then return row_error or failure("NOT_FOUND", "activation intent does not exist") end
        if input.expected_revision ~= row.revision then return failure("CONFLICT", "expected_revision does not match activation intent") end
        if not accepted[row.phase] then return failure("CONFLICT", "activation intent is not in the required phase") end
        local result = update(tx, row)
        if not result.ok then return result end
        return result
    end)
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

function M.prepare(store: Store, actor: string, input: PrepareRequest): Result
    local measured, measure_error = request_digest(input)
    if not measured then return assert(measure_error) end
    return transaction.write(store.db, "governance activation", function(tx: sql.Transaction): Result
        local already = replay(store, tx, actor, input, measured)
        if already then return already end
        local existing, existing_error = load(tx, store, input.intent_id)
        if existing_error then return existing_error end
        if existing then return failure("CONFLICT", "activation intent already exists") end
        local count_row, count_error = one(tx, "SELECT COUNT(*) AS count FROM bee_governance_activation_intents WHERE owner_node = ? AND workspace_id = ?", {store.node, store.workspace}, "activation intent count")
        if count_error or not count_row then return count_error or failure("INTERNAL", "activation intent count is missing") end
        local intents = count(count_row.count, false)
        if not intents then return failure("INTERNAL", "activation intent count is corrupt") end
        if intents >= MAX_INTENTS then return failure("CAPACITY_EXHAUSTED", "activation intent capacity is exhausted") end
        local authorized = authorization_digest(store, input, input.artifact,
            input.resolution, input.preflight, input.migration_work,
            input.application_admission)
        if not authorized then return failure("INTERNAL", "measure activation authorization") end
        local effect_bytes = canonical.encode({schema_revision = "bee.governance-effect@1", authorization_digest = authorized})
        local effect_key = effect_bytes and digest(effect_bytes)
        if not effect_key then return failure("INTERNAL", "measure activation effect key") end
        local admission = input.application_admission
        local _, insert_error = tx:execute("INSERT INTO bee_governance_activation_intents (owner_node, workspace_id, intent_id, actor_id, overlay_owner, source_node, source_workspace, version, plan_digest, plan_revision, selection_revision, artifact_bytes, artifact_digest, resolution_bytes, resolution_digest, preflight_bytes, preflight_digest, migration_work_bytes, migration_work_digest, application_admission_bytes, application_admission_digest, grant_predecessor_digest, authorization_digest, effect_key, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))", {store.node, store.workspace, input.intent_id, actor, input.overlay_owner, input.source_node, input.source_workspace, input.version, input.plan_digest, input.plan_revision, input.selection_revision, input.artifact.bytes, input.artifact.digest, input.resolution.bytes, input.resolution.digest, input.preflight.bytes, input.preflight.digest, input.migration_work.bytes, input.migration_work.digest, admission and admission.bytes or nil, admission and admission.digest or nil, input.grant_predecessor_digest, authorized, effect_key})
        if insert_error then return storage(insert_error, "prepare activation") end
        local _, execution_error = tx:execute("INSERT INTO bee_governance_activation_execution (owner_node, workspace_id, intent_id, revision, phase, updated_at) VALUES (?, ?, ?, 1, 'prepared', strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))", {store.node, store.workspace, input.intent_id})
        if execution_error then return storage(execution_error, "create activation execution") end
        local row, row_error = load(tx, store, input.intent_id)
        if row_error or not row then return row_error or failure("INTERNAL", "read prepared activation") end
        local receipt_error = save_receipt(store, tx, actor, input, measured, row)
        if receipt_error then return receipt_error end
        return transaction.success(view(store, row, nil), false)
    end)
end
local function finish(store: Store, tx: sql.Transaction, actor: string, input: Mutation, measured: string, row: Intent, current_slot: Object?): Result
    local receipt_error = save_receipt(store, tx, actor, input, measured, row)
    if receipt_error then return receipt_error end
    return transaction.success(view(store, row, current_slot), false)
end
-- The tx-level steps below serve both the ordinary approval path and the lease
-- authorization, which performs all of them in one commit.
local function bind_in(tx: sql.Transaction, store: Store, row: Intent, input: {approval_id: string, approval_proposal_digest: string, approval_owner_incarnation: integer, grant_reuse_digest: string?}): (Intent?, Result?)
    local next_revision = (row.revision) + 1
    local updated, err = tx:execute("UPDATE bee_governance_activation_execution SET phase = 'approval_bound', approval_id = ?, approval_proposal_digest = ?, approval_owner_incarnation = ?, grant_reuse_digest = ?, revision = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE owner_node = ? AND workspace_id = ? AND intent_id = ? AND revision = ?", {input.approval_id, input.approval_proposal_digest, input.approval_owner_incarnation, input.grant_reuse_digest, next_revision, store.node, store.workspace, row.intent_id, row.revision})
    local update_error = cas_result(updated, err, "bind activation approval")
    if update_error then return nil, update_error end
    local changed, changed_error = load(tx, store, row.intent_id)
    if changed_error or not changed then return nil, changed_error or failure("INTERNAL", "read bound activation") end
    return changed, nil
end
local function begin_in(tx: sql.Transaction, store: Store, row: Intent): (Intent?, Result?)
    local next_revision = (row.revision) + 1
    local updated, err = tx:execute("UPDATE bee_governance_activation_execution SET phase = 'consuming', revision = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE owner_node = ? AND workspace_id = ? AND intent_id = ? AND revision = ?", {next_revision, store.node, store.workspace, row.intent_id, row.revision})
    local update_error = cas_result(updated, err, "begin activation consumption")
    if update_error then return nil, update_error end
    local changed, changed_error = load(tx, store, row.intent_id)
    if changed_error or not changed then return nil, changed_error or failure("INTERNAL", "read consuming activation") end
    return changed, nil
end
local function record_in(tx: sql.Transaction, store: Store, row: Intent, input: {consumer_id: string, proposal_digest: string, effect_key: string}): (Intent?, Slot?, Result?)
    if row.effect_key ~= input.effect_key or row.approval_proposal_digest ~= input.proposal_digest then return nil, nil, failure("CONFLICT", "consumption does not match the bound approval") end
    local next_revision = (row.revision) + 1
    local updated, err = tx:execute("UPDATE bee_governance_activation_execution SET phase = 'authorized', consumed_consumer_id = ?, consumed_proposal_digest = ?, consumed_effect_key = ?, revision = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE owner_node = ? AND workspace_id = ? AND intent_id = ? AND revision = ?", {input.consumer_id, input.proposal_digest, input.effect_key, next_revision, store.node, store.workspace, row.intent_id, row.revision})
    local update_error = cas_result(updated, err, "record activation consumption")
    if update_error then return nil, nil, update_error end
    local changed, changed_error = load(tx, store, row.intent_id)
    if changed_error or not changed then return nil, nil, changed_error or failure("INTERNAL", "read authorized activation") end
    local current_slot, slot_error = slot(tx, store, row.overlay_owner, true)
    if slot_error or not current_slot then return nil, nil, slot_error or failure("INTERNAL", "read activation slot") end
    if current_slot.desired_intent_id ~= nil and current_slot.desired_intent_id ~= row.intent_id then
        local active, active_error = load(tx, store, current_slot.desired_intent_id)
        if active_error or not active then
            return nil, nil, active_error or failure("INTERNAL", "desired activation intent is missing")
        end
        if active.phase == "applying" or (active.phase == "settled" and active.outcome == "uncertain") then
            return nil, nil, failure("CONFLICT", "another activation effect requires settlement")
        end
    end
    local slot_revision = current_slot.revision + 1
    local slot_updated, slot_error_write = tx:execute("UPDATE bee_governance_activation_slots SET revision = ?, desired_intent_id = ?, desired_execution_revision = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE owner_node = ? AND workspace_id = ? AND overlay_owner = ? AND revision = ?", {slot_revision, row.intent_id, next_revision, store.node, store.workspace, row.overlay_owner, current_slot.revision})
    local slot_update_error = cas_result(slot_updated, slot_error_write, "authorize activation slot")
    if slot_update_error then return nil, nil, slot_update_error end
    local changed_slot, changed_slot_error = slot(tx, store, row.overlay_owner, false)
    if changed_slot_error or not changed_slot then return nil, nil, changed_slot_error or failure("INTERNAL", "read authorized activation slot") end
    return changed, changed_slot, nil
end
function M.bind_approval(store: Store, actor: string, input: BindRequest): Result
    local measured, measure_error = request_digest(input)
    if not measured then return assert(measure_error) end
    return transition(store, actor, input, {prepared = true}, function(tx, row)
        local changed, bind_error = bind_in(tx, store, row, input)
        if not changed then return assert(bind_error) end
        return finish(store, tx, actor, input, measured, changed, nil)
    end)
end
function M.begin_consume(store: Store, actor: string, input: ConsumeRequest): Result
    local measured, measure_error = request_digest(input)
    if not measured then return assert(measure_error) end
    return transition(store, actor, input, {approval_bound = true, consuming = true}, function(tx, row)
        local changed, begin_error = begin_in(tx, store, row)
        if not changed then return assert(begin_error) end
        return finish(store, tx, actor, input, measured, changed, nil)
    end)
end
function M.record_consumption(store: Store, actor: string, input: ConsumptionRequest): Result
    local measured, measure_error = request_digest(input)
    if not measured then return assert(measure_error) end
    return transition(store, actor, input, {consuming = true}, function(tx, row)
        local changed, changed_slot, record_error = record_in(tx, store, row, input)
        if not changed then return assert(record_error) end
        return finish(store, tx, actor, input, measured, changed, changed_slot)
    end)
end
-- authorize_lease: reserve one lease use, record its proof and authorize the
-- intent in a single commit, so the use and the authorization cannot diverge
-- after an interruption. A replay of the same intent and lease returns the
-- authorized intent.
function M.authorize_lease(store: Store, actor: string, input: LeaseRequest): Result
    return transaction.write(store.db, "governance activation", function(tx: sql.Transaction): Result
        local row, row_error = load(tx, store, input.intent_id)
        if row_error or not row then return row_error or failure("NOT_FOUND", "activation intent does not exist") end
        if row.phase ~= "prepared" then
            local proof = one(tx, "SELECT lease_id, approval_id FROM bee_governance_lease_uses WHERE owner_node = ? AND workspace_id = ? AND intent_id = ?", {store.node, store.workspace, row.intent_id}, "lease use")
            if proof and proof.lease_id == input.lease_id and proof.approval_id == row.approval_id then
                local current_slot = slot(tx, store, row.overlay_owner, false)
                return transaction.success(view(store, row, current_slot), true)
            end
            return failure("CONFLICT", "activation intent is not in the required phase")
        end
        if input.expected_revision ~= row.revision then return failure("CONFLICT", "expected_revision does not match activation intent") end
        local lease, reserve_error = lease_store.reserve_in(tx, store, {lease_id = input.lease_id,
            expected_revision = input.lease_expected_revision, intent_id = input.intent_id,
            proposal_capabilities = input.proposal_capabilities})
        if not lease then return assert(reserve_error) end
        local bound, bind_error = bind_in(tx, store, row, {approval_id = lease.source_approval_id,
            approval_proposal_digest = lease.source_approval_proposal_digest,
            approval_owner_incarnation = lease.source_approval_owner_incarnation})
        if not bound then return assert(bind_error) end
        local consuming, begin_error = begin_in(tx, store, bound)
        if not consuming then return assert(begin_error) end
        local authorized, authorized_slot, record_error = record_in(tx, store, consuming, {consumer_id = "bee.gov.lease_apply",
            proposal_digest = lease.source_approval_proposal_digest, effect_key = consuming.effect_key})
        if not authorized then return assert(record_error) end
        return transaction.success(view(store, authorized, authorized_slot), false)
    end)
end
function M.begin_apply(store: Store, actor: string, input: ApplyRequest): Result
    local measured, measure_error = request_digest(input)
    if not measured then return assert(measure_error) end
    return transition(store, actor, input, {authorized = true, applying = true}, function(tx: sql.Transaction, row: Intent): Result
        local current_slot, slot_error = slot(tx, store, row.overlay_owner, false)
        if slot_error then return slot_error end
        if not current_slot or current_slot.desired_intent_id ~= row.intent_id then return failure("CONFLICT", "activation is no longer the desired slot") end
        local work, work_error = migration_work.decode(row.migration_work_bytes, row.migration_work_digest)
        if not work then return failure("INTERNAL", tostring(work_error or "decode activation migration work")) end
        local completed = #work.migrations == 0 and 1 or 0
        if row.consumed_consumer_id == "bee.gov.lease_apply" then
            local admit_error = lease_store.admit_in(tx, store, row.intent_id, row.approval_id, row.approval_proposal_digest)
            if admit_error then return admit_error end
        end
        local next_revision = (row.revision) + 1
        local updated, err = tx:execute("UPDATE bee_governance_activation_execution SET phase = 'applying', migrations_completed = ?, revision = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE owner_node = ? AND workspace_id = ? AND intent_id = ? AND revision = ?", {completed, next_revision, store.node, store.workspace, row.intent_id, row.revision})
        local update_error = cas_result(updated, err, "begin activation apply")
        if update_error then return update_error end
        local changed, changed_error = load(tx, store, row.intent_id)
        if changed_error or not changed then return changed_error or failure("INTERNAL", "read applying activation") end
        return finish(store, tx, actor, input, measured, changed, nil)
    end)
end

local function migration_receipt(input: MigrationRequest, work: migration_work.Work): ({[string]: Object}?, string?)
    local decoded, decode_error = json.decode((input.receipt).bytes)
    local value = bounds.object(decoded)
    if decode_error or not value or value.schema_revision ~= "bee.governance-migration-receipt@1"
        or type(value.rows) ~= "table" then return nil, "migration receipt is malformed" end
    local encoded, encode_error = canonical.encode(value, MAX_MIGRATION_RECEIPT)
    if not encoded or encoded ~= (input.receipt).bytes then
        return nil, tostring(encode_error or "migration receipt is not canonical")
    end
    local expected: {[string]: migration_work.Migration} = {}
    for _, item in ipairs(work.migrations) do expected[item.target_db .. "\n" .. item.id] = item end
    local rows: {[string]: Object} = {}
    local count_rows = 0
    for key in pairs(value.rows) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return nil, "migration receipt rows must be a dense list" end
        count_rows = count_rows + 1
    end
    if count_rows ~= #(value.rows) or count_rows > migration_work.MAX_MIGRATIONS then
        return nil, "migration receipt rows exceed their bound or are sparse"
    end
    for index = 1, count_rows do
        local row = bounds.object((value.rows)[index])
        if not row or bounds.fields(row, {"id", "target_db", "module", "status", "reason"}) then
            return nil, "migration receipt row is malformed"
        end
        local id_value, target, component = id(row.id), id(row.target_db), bounds.text(row.module, 160)
        local status_value = row.status
        local selected = id_value and target and expected[target .. "\n" .. id_value] or nil
        if not selected or component ~= selected.package or (status_value ~= "applied" and status_value ~= "skipped")
            or rows[target .. "\n" .. id_value] then return nil, "migration receipt differs from captured work" end
        rows[target .. "\n" .. id_value] = row
    end
    if input.complete then
        for key in pairs(expected) do if not rows[key] then return nil, "complete migration receipt omits captured work" end end
    end
    return rows, nil
end

function M.record_migrations(store: Store, actor: string, input: MigrationRequest): Result
    local measured, measure_error = request_digest(input)
    if not measured then return assert(measure_error) end
    return transition(store, actor, input, {applying = true}, function(tx: sql.Transaction, row: Intent): Result
        if row.migrations_completed == true or tonumber(row.migrations_completed) == 1 then
            return failure("CONFLICT", "activation migrations are already complete")
        end
        local work, work_error = migration_work.decode(row.migration_work_bytes, row.migration_work_digest)
        if not work then return failure("INTERNAL", tostring(work_error or "decode activation migration work")) end
        local receipt_rows, receipt_error = migration_receipt(input, work)
        if not receipt_rows then return failure("INVALID", receipt_error or "invalid migration receipt") end
        for _, item in ipairs(work.migrations) do
            if receipt_rows[item.target_db .. "\n" .. item.id] then
                local prior, prior_error = one(tx, "SELECT checksum, ordinal, component FROM bee_governance_applied_migrations WHERE owner_node = ? AND workspace_id = ? AND target_db = ? AND migration_id = ?", {store.node, store.workspace, item.target_db, item.id}, "applied migration")
                if prior_error then return prior_error end
                if prior and (prior.checksum ~= item.checksum or prior.ordinal ~= item.ordinal or prior.component ~= item.package) then
                    return failure("CONFLICT", "applied migration fact differs from captured work: " .. item.id)
                end
                if not prior then
                    local _, insert_error = tx:execute("INSERT INTO bee_governance_applied_migrations (owner_node, workspace_id, target_db, migration_id, component, ordinal, checksum, intent_id, applied_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))", {store.node, store.workspace, item.target_db, item.id, item.package, item.ordinal, item.checksum, row.intent_id})
                    if insert_error then return storage(insert_error, "record applied migration") end
                end
            end
        end
        local next_revision = (row.revision) + 1
        local updated, update_error = tx:execute("UPDATE bee_governance_activation_execution SET migrations_completed = ?, migration_receipt_bytes = ?, migration_receipt_digest = ?, diagnostics = ?, revision = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE owner_node = ? AND workspace_id = ? AND intent_id = ? AND revision = ?", {input.complete and 1 or 0, (input.receipt).bytes, (input.receipt).digest, input.diagnostics, next_revision, store.node, store.workspace, row.intent_id, row.revision})
        local cas_error = cas_result(updated, update_error, "record activation migrations")
        if cas_error then return cas_error end
        local changed, changed_error = load(tx, store, row.intent_id)
        if changed_error or not changed then return changed_error or failure("INTERNAL", "read migration progress") end
        return finish(store, tx, actor, input, measured, changed, nil)
    end)
end

function M.record_outcome(store: Store, actor: string, input: OutcomeRequest): Result
    local measured, measure_error = request_digest(input)
    if not measured then return assert(measure_error) end
    return transition(store, actor, input, {applying = true, settled = true}, function(tx: sql.Transaction, row: Intent): Result
        if input.outcome == "applied"
            and not (row.migrations_completed == true or tonumber(row.migrations_completed) == 1) then
            return failure("CONFLICT", "activation migrations are not complete")
        end
        if row.phase == "settled" and row.outcome ~= "uncertain"
            and not (row.outcome == "applied" and input.outcome == "uncertain") then
            return failure("CONFLICT", "activation outcome is already final")
        end
        local next_revision = (row.revision) + 1
        local updated, err = tx:execute("UPDATE bee_governance_activation_execution SET phase = 'settled', outcome = ?, diagnostics = ?, revision = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE owner_node = ? AND workspace_id = ? AND intent_id = ? AND revision = ?", {input.outcome, input.diagnostics, next_revision, store.node, store.workspace, row.intent_id, row.revision})
        local update_error = cas_result(updated, err, "record activation outcome")
        if update_error then return update_error end
        local changed, changed_error = load(tx, store, row.intent_id)
        if changed_error or not changed then return changed_error or failure("INTERNAL", "read activation outcome") end
        local current_slot, slot_error = slot(tx, store, row.overlay_owner, false)
        if slot_error then return slot_error end
        local result_slot: Object? = current_slot
        if input.outcome == "applied" then
            if not current_slot or current_slot.desired_intent_id ~= row.intent_id then return failure("CONFLICT", "activation is no longer the desired slot") end
            -- Retain the previously observed complete generation as the last
            -- good baseline before this one replaces it. Only an applied
            -- observation is a revert target; a failed or uncertain attempt
            -- is never promoted to baseline.
            local baseline_intent_id, baseline_execution_revision, baseline_artifact_digest =
                current_slot.baseline_intent_id, current_slot.baseline_execution_revision, current_slot.baseline_artifact_digest
            if current_slot.observed_intent_id ~= nil and current_slot.observed_outcome == "applied"
                and current_slot.observed_intent_id ~= row.intent_id then
                baseline_intent_id, baseline_execution_revision = current_slot.observed_intent_id, current_slot.observed_execution_revision
                baseline_artifact_digest = current_slot.observed_artifact_digest
            end
            local slot_revision = current_slot.revision + 1
            local slot_updated, slot_error_write = tx:execute("UPDATE bee_governance_activation_slots SET revision = ?, observed_intent_id = ?, observed_execution_revision = ?, observed_artifact_digest = ?, observed_outcome = 'applied', baseline_intent_id = ?, baseline_execution_revision = ?, baseline_artifact_digest = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE owner_node = ? AND workspace_id = ? AND overlay_owner = ? AND revision = ?", {slot_revision, row.intent_id, next_revision, row.artifact_digest, baseline_intent_id, baseline_execution_revision, baseline_artifact_digest, store.node, store.workspace, row.overlay_owner, current_slot.revision})
            local slot_update_error = cas_result(slot_updated, slot_error_write, "record observed activation")
            if slot_update_error then return slot_update_error end
            local refreshed_slot, refresh_error = slot(tx, store, row.overlay_owner, false)
            if refresh_error then return refresh_error end
            result_slot = refreshed_slot
        elseif current_slot and current_slot.observed_intent_id == row.intent_id then
            local slot_revision = current_slot.revision + 1
            local slot_updated, slot_error_write = tx:execute("UPDATE bee_governance_activation_slots SET revision = ?, observed_execution_revision = ?, observed_outcome = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE owner_node = ? AND workspace_id = ? AND overlay_owner = ? AND revision = ?", {slot_revision, next_revision, input.outcome, store.node, store.workspace, row.overlay_owner, current_slot.revision})
            local slot_update_error = cas_result(slot_updated, slot_error_write, "record observed activation failure")
            if slot_update_error then return slot_update_error end
            local refreshed_slot, refresh_error = slot(tx, store, row.overlay_owner, false)
            if refresh_error then return refresh_error end
            result_slot = refreshed_slot
        end
        return finish(store, tx, actor, input, measured, changed, result_slot)
    end)
end
function M.get(store: Store, intent_raw: unknown): Result
    if store.closed then return failure("CLOSED", "governance activation store is closed") end
    local intent_id = id(intent_raw)
    if not intent_id then return failure("INVALID", "intent_id is invalid") end
    return transaction.read(store.db, "governance activation", function(tx): Result
        local row, err = load(tx, store, intent_id)
        if err or not row then return err or failure("NOT_FOUND", "activation intent does not exist") end
        local current_slot, slot_error = slot(tx, store, row.overlay_owner, false)
        if slot_error then return slot_error end
        return transaction.success(view(store, row, current_slot), false)
    end)
end
-- Recovery follows only the locally authorized desired pointer. Replicated
-- versions and the current review selection are deliberately outside this
-- read.
function M.desired(store: Store, overlay_raw: unknown): Result
    if store.closed then return failure("CLOSED", "governance activation store is closed") end
    local overlay_owner = id(overlay_raw)
    if not overlay_owner then return failure("INVALID", "activation overlay owner is invalid") end
    return transaction.read(store.db, "governance activation", function(tx): Result
        local current_slot, slot_error = slot(tx, store, overlay_owner, false)
        if slot_error then return slot_error end
        if not current_slot or current_slot.desired_intent_id == nil then
            return failure("NOT_FOUND", "no desired activation exists")
        end
        local row, row_error = load(tx, store, current_slot.desired_intent_id)
        if row_error or not row then return row_error or failure("INTERNAL", "desired activation intent is missing") end
        return transaction.success(view(store, row, current_slot), false)
    end)
end

function M.applied(store: Store, component_raw: unknown): Result
    if store.closed then return failure("CLOSED", "governance activation store is closed") end
    local component = bounds.text(component_raw, 160)
    if not component or component == "" then return failure("INVALID", "migration component is invalid") end
    return transaction.read(store.db, "governance activation", function(tx): Result
        -- Old package evidence retains its captured package and digest. Read it
        -- under the renamed package without rewriting immutable intent bytes.
        local rows, err = tx:query("SELECT a.target_db, a.migration_id, a.ordinal, a.checksum, a.component, a.intent_id, i.migration_work_bytes, i.migration_work_digest FROM bee_governance_applied_migrations a JOIN bee_governance_activation_intents i ON i.owner_node = a.owner_node AND i.workspace_id = a.workspace_id AND i.intent_id = a.intent_id WHERE a.owner_node = ? AND a.workspace_id = ? AND (a.component = ? OR (? = 'bee/gov' AND a.component = 'bee/governance')) ORDER BY a.target_db, a.ordinal, a.migration_id", {store.node, store.workspace, component, component})
        if not rows then return storage(err, "read applied migrations") end
        local migrations: Object = {}
        local databases: Object = {}
        local work_by_intent: {[string]: migration_work.Work} = {}
        for _, row in ipairs(rows) do
            local work = work_by_intent[row.intent_id]
            if not work then
                local decoded, decode_error = migration_work.decode(row.migration_work_bytes, row.migration_work_digest)
                if not decoded then return failure("INTERNAL", tostring(decode_error or "decode applied migration intent")) end
                work, work_by_intent[row.intent_id] = decoded, decoded
            end
            local captured: migration_work.Migration? = nil
            for _, item in ipairs(work.migrations) do
                if item.target_db == row.target_db and item.id == row.migration_id then captured = item; break end
            end
            if not captured or captured.ordinal ~= row.ordinal or captured.checksum ~= row.checksum
                or captured.package ~= row.component then
                return failure("CONFLICT", "applied migration fact differs from its immutable intent: " .. tostring(row.migration_id))
            end
            local database, database_error = migration_work.database(work, row.target_db)
            if not database then return failure("INTERNAL", tostring(database_error or "read applied database binding")) end
            local prior = bounds.object(databases[row.target_db])
            if prior and (prior.database_id ~= database.database_id or prior.table_prefix ~= database.table_prefix
                or prior.kind ~= database.kind or prior.package ~= database.package or prior.digest ~= database.digest) then
                return failure("CONFLICT", "applied migration database evidence differs: " .. tostring(row.target_db))
            end
            databases[row.target_db] = database
            local key = (row.target_db) .. "\n" .. (row.migration_id)
            if migrations[key] then return failure("CONFLICT", "applied migration identities overlap across package names") end
            migrations[key] = {
                id = row.migration_id, target_db = row.target_db, ordinal = row.ordinal, checksum = row.checksum}
        end
        return transaction.success({migrations = migrations, databases = databases}, false)
    end)
end
-- baseline: the retained last good generation for one overlay slot. It is
-- the exact applied intent a one-step revert restores. An observed pointer
-- with no retained baseline has nothing to revert to.
function M.baseline(store: Store, overlay_raw: unknown): Result
    if store.closed then return failure("CLOSED", "governance activation store is closed") end
    local overlay_owner = id(overlay_raw)
    if not overlay_owner then return failure("INVALID", "activation overlay owner is invalid") end
    return transaction.read(store.db, "governance activation", function(tx): Result
        local current_slot, slot_error = slot(tx, store, overlay_owner, false)
        if slot_error then return slot_error end
        if not current_slot or current_slot.baseline_intent_id == nil then
            return failure("NOT_FOUND", "no retained baseline generation exists")
        end
        local row, row_error = load(tx, store, current_slot.baseline_intent_id)
        if row_error or not row then return row_error or failure("INTERNAL", "baseline activation intent is missing") end
        return transaction.success(view(store, row, current_slot), false)
    end)
end
-- revert_activation: one-step, generation-checked activation of the retained
-- baseline. Applied migrations stay immutable and forward-only; the revert
-- records the caller's compensating migration receipt and repoints the slot
-- at the baseline. It never rewrites an applied intent or an epoch.
function M.revert_activation(store: Store, actor: string, raw_input: Request): Result
    if store.closed then return failure("CLOSED", "governance activation store is closed") end
    local expected_revision = count(raw_input.expected_revision, false)
    if expected_revision == nil then return failure("INVALID", "expected_revision must be a non-negative integer") end
    local decoded, input_error = decode(raw_input)
    if not decoded then return failure("INVALID", input_error or "invalid activation request") end
    if decoded.operation ~= "revert_activation" then return failure("INVALID", "unsupported activation operation") end
    local input = decoded.request
    local measured, measure_error = request_digest(input)
    if not measured then return assert(measure_error) end
    return transaction.write(store.db, "governance activation", function(tx: sql.Transaction): Result
        local key = id(input.idempotency_key)
        local prior, prior_error = one(tx, "SELECT actor_id, operation, request_digest, result_revision FROM bee_governance_activation_receipts WHERE owner_node = ? AND workspace_id = ? AND idempotency_key = ?", {store.node, store.workspace, key}, "activation revert receipt")
        if prior_error then return prior_error end
        if prior then
            if prior.actor_id ~= actor then return failure("DENIED", "idempotency key belongs to another actor") end
            if prior.operation ~= input.operation or prior.request_digest ~= measured then
                return failure("CONFLICT", "idempotency key was used by a different activation request")
            end
            local reverted, revert_error = one(tx, "SELECT reverted_from_intent_id, target_intent_id, compensation_bytes, compensation_digest, diagnostics FROM bee_governance_activation_reverts WHERE owner_node = ? AND workspace_id = ? AND overlay_owner = ?", {store.node, store.workspace, input.overlay_owner}, "activation revert")
            if revert_error or not reverted then return revert_error or failure("INTERNAL", "activation revert receipt has no record") end
            local target_intent = id(reverted.target_intent_id)
            if not target_intent then return failure("INTERNAL", "reverted activation intent is missing") end
            local replayed_target, target_error = load(tx, store, target_intent)
            if target_error or not replayed_target then return target_error or failure("INTERNAL", "reverted activation intent is missing") end
            local current_slot, slot_error = slot(tx, store, input.overlay_owner, false)
            if slot_error then return slot_error end
            local result = view(store, replayed_target, current_slot)
            result.reverted_from_intent_id = reverted.reverted_from_intent_id
            result.compensation_bytes, result.compensation_digest = reverted.compensation_bytes, reverted.compensation_digest
            result.diagnostics = reverted.diagnostics
            return transaction.success(result, true)
        end
        local current_slot, slot_error = slot(tx, store, input.overlay_owner, true)
        if slot_error or not current_slot then return slot_error or failure("INTERNAL", "read activation slot") end
        if count(current_slot.revision, false) ~= expected_revision then
            return failure("CONFLICT", "expected_revision does not match the overlay slot")
        end
        if current_slot.observed_intent_id == nil or current_slot.observed_outcome ~= "applied" then
            return failure("CONFLICT", "overlay has no applied generation to revert")
        end
        if current_slot.baseline_intent_id == nil then
            return failure("CONFLICT", "no retained baseline generation to revert to")
        end
        if current_slot.baseline_intent_id == current_slot.observed_intent_id then
            return failure("CONFLICT", "the retained baseline is the observed generation")
        end
        local target, target_error = load(tx, store, current_slot.baseline_intent_id)
        if target_error or not target then return target_error or failure("INTERNAL", "baseline activation intent is missing") end
        if target.phase ~= "settled" or target.outcome ~= "applied" then
            return failure("CONFLICT", "the retained baseline is not an applied generation")
        end
        local reverted_from = current_slot.observed_intent_id
        local compensation: Blob = input.compensation
        local _, upsert_error = tx:execute("INSERT INTO bee_governance_activation_reverts (owner_node, workspace_id, overlay_owner, reverted_from_intent_id, target_intent_id, compensation_bytes, compensation_digest, diagnostics, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now')) ON CONFLICT(owner_node, workspace_id, overlay_owner) DO UPDATE SET reverted_from_intent_id = excluded.reverted_from_intent_id, target_intent_id = excluded.target_intent_id, compensation_bytes = excluded.compensation_bytes, compensation_digest = excluded.compensation_digest, diagnostics = excluded.diagnostics, created_at = excluded.created_at", {store.node, store.workspace, input.overlay_owner, reverted_from, current_slot.baseline_intent_id, compensation.bytes, compensation.digest, input.diagnostics})
        if upsert_error then return storage(upsert_error, "record activation revert") end
        local slot_revision = expected_revision + 1
        local slot_updated, slot_error_write = tx:execute("UPDATE bee_governance_activation_slots SET revision = ?, desired_intent_id = ?, desired_execution_revision = ?, observed_intent_id = NULL, observed_execution_revision = NULL, observed_artifact_digest = NULL, observed_outcome = NULL, baseline_intent_id = NULL, baseline_execution_revision = NULL, baseline_artifact_digest = NULL, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE owner_node = ? AND workspace_id = ? AND overlay_owner = ? AND revision = ?", {slot_revision, current_slot.baseline_intent_id, target.revision, store.node, store.workspace, input.overlay_owner, current_slot.revision})
        local slot_update_error = cas_result(slot_updated, slot_error_write, "revert activation slot")
        if slot_update_error then return slot_update_error end
        local refreshed_slot, refresh_error = slot(tx, store, input.overlay_owner, false)
        if refresh_error then return refresh_error end
        local _, receipt_error = tx:execute("INSERT INTO bee_governance_activation_receipts (owner_node, workspace_id, idempotency_key, actor_id, operation, request_digest, intent_id, result_revision) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", {store.node, store.workspace, input.idempotency_key, actor, input.operation, measured, current_slot.baseline_intent_id, target.revision})
        if receipt_error then return storage(receipt_error, "record activation revert receipt") end
        local result = view(store, target, refreshed_slot)
        result.reverted_from_intent_id = reverted_from
        result.compensation_bytes = compensation.bytes
        result.compensation_digest = compensation.digest
        result.diagnostics = input.diagnostics
        return transaction.success(result, false)
    end)
end
function M.call(store: Store, actor_raw: string, raw: unknown): Result
    if store.closed then return failure("CLOSED", "governance activation store is closed") end
    local actor = id(actor_raw)
    if not actor then return failure("INVALID", "activation actor is invalid") end
    local input, decode_error = decode(raw)
    if not input then return failure("INVALID", decode_error or "invalid activation request") end
    if input.operation == "activation_status" then return M.get(store, input.request.intent_id)
    elseif input.operation == "revert_activation" then return M.revert_activation(store, actor, input.request)
    elseif input.operation == "prepare_activation" then return M.prepare(store, actor, input.request)
    elseif input.operation == "bind_approval" then return M.bind_approval(store, actor, input.request)
    elseif input.operation == "authorize_lease" then return M.authorize_lease(store, actor, input.request)
    elseif input.operation == "begin_consume" then return M.begin_consume(store, actor, input.request)
    elseif input.operation == "record_consumption" then return M.record_consumption(store, actor, input.request)
    elseif input.operation == "begin_apply" then return M.begin_apply(store, actor, input.request)
    elseif input.operation == "record_migrations" then return M.record_migrations(store, actor, input.request)
    elseif input.operation == "record_outcome" then return M.record_outcome(store, actor, input.request)
    end
    return failure("INVALID", "unsupported activation operation")
end
function M.close(store: Store): (boolean, string?)
    if store.closed then return true, nil end
    store.closed = true
    local released, err = store.db:release()
    if released ~= true or err then return false, "close governance activation database" end
    return true, nil
end
local MAX_DESIRED_SLOTS = 1024

function M.applied_admission_source(resource: string, workspace_raw: unknown,
    overlay_raw: unknown, digest_raw: unknown): Result
    if type(resource) ~= "string" or resource == "" then
        return failure("UNAVAILABLE", "governance activation database is not linked")
    end
    local workspace, overlay_owner = id(workspace_raw), id(overlay_raw)
    local admission_digest = hex_digest(digest_raw)
    if not workspace or not overlay_owner or not admission_digest then
        return failure("INVALID", "applied application admission identity is invalid")
    end
    local db, err = database.open({resource = resource, ledger = {table = "bee_governance_migrations", label = "governance"}, migrations = migrations.all()})
    if not db then return failure("UNAVAILABLE", tostring(err or "open governance activation database")) end
    local result = transaction.read(db, "governance activation", function(tx): Result
        local rows, query_error = tx:query("SELECT DISTINCT i.source_node FROM bee_governance_activation_slots s JOIN bee_governance_activation_intents i ON i.owner_node = s.owner_node AND i.workspace_id = s.workspace_id AND i.intent_id = s.observed_intent_id AND i.overlay_owner = s.overlay_owner JOIN bee_governance_activation_execution e ON e.owner_node = i.owner_node AND e.workspace_id = i.workspace_id AND e.intent_id = i.intent_id AND e.revision = s.observed_execution_revision WHERE s.workspace_id = ? AND s.overlay_owner = ? AND s.observed_outcome = 'applied' AND e.outcome = 'applied' AND i.application_admission_digest = ? LIMIT 2", {workspace, overlay_owner, admission_digest})
        if query_error or not rows then return storage(query_error, "read applied application admission source") end
        if #rows > 1 then return failure("CONFLICT", "applied application admission source is ambiguous") end
        local row = rows[1]
        if not row then return failure("NOT_FOUND", "no applied activation slot matches application admission") end
        local source_node = id(row.source_node)
        if not source_node then
            return failure("INTERNAL", "applied application admission source is malformed")
        end
        return transaction.success({source_node = source_node}, false)
    end)
    db:release()
    return result
end

-- A bounded revision token for the workspace's process-local application
-- admission overlays. The broker can compare this cheaply and project the
-- full catalog only when the token changes.
function M.catalog_revision(resource: string, node_raw: unknown, workspace_raw: unknown): Result
    if type(resource) ~= "string" or resource == "" then
        return failure("UNAVAILABLE", "governance activation database is not linked")
    end
    local node, workspace = id(node_raw), id(workspace_raw)
    if not node or not workspace then return failure("INVALID", "governance activation identity is invalid") end
    local db, err = sql.get(resource)
    if not db then return failure("UNAVAILABLE", tostring(err or "open governance activation database")) end
    local function close_failure(code: string, message: string): Result
        db:release()
        return failure(code, message)
    end
    local revisions: {string} = {}
    local overlay_owners: {string} = {}
    local rows, query_error = db:query("SELECT overlay_owner, revision FROM bee_governance_activation_slots WHERE owner_node = ? AND workspace_id = ? ORDER BY overlay_owner LIMIT ?",
        {node, workspace, MAX_DESIRED_SLOTS + 1})
    if query_error or not rows then return close_failure("INTERNAL", "read governance activation revisions") end
    if #rows > MAX_DESIRED_SLOTS then return close_failure("CAPACITY", "governance activation slots exceed their bound") end
    for _, row in ipairs(rows) do
        local overlay_owner, revision = id(row.overlay_owner), count(row.revision, false)
        if not overlay_owner or revision == nil then return close_failure("INTERNAL", "governance activation revision is malformed") end
        revisions[#revisions + 1] = overlay_owner .. "=" .. tostring(revision)
        overlay_owners[#overlay_owners + 1] = overlay_owner
    end
    local released, release_error = db:release()
    if released ~= true or release_error then return failure("UNAVAILABLE", "close governance activation database") end
    return transaction.success({revision = table.concat(revisions, ";"), overlay_owners = overlay_owners}, false)
end

-- Every workspace slot on this node that holds an authorized desired intent,
-- in a stable order. Boot recovery follows exactly these slots.
function M.desired_slots(resource: string, node_raw: string): Result
    if type(resource) ~= "string" or resource == "" then return failure("UNAVAILABLE", "governance activation database is not linked") end
    local node = id(node_raw)
    if not node then return failure("INVALID", "governance activation node is invalid") end
    local db, err = database.open({resource = resource, ledger = {table = "bee_governance_migrations", label = "governance"}, migrations = migrations.all()})
    if not db then return failure("UNAVAILABLE", tostring(err or "open governance activation database")) end
    local migrated, migration_error = identity_migration.apply(db, node)
    if not migrated then
        db:release()
        return failure("UNAVAILABLE", tostring(migration_error or "migrate governance node identity"))
    end
    local result = transaction.read(db, "governance activation", function(tx): Result
        local rows, query_error = tx:query("SELECT workspace_id, overlay_owner FROM bee_governance_activation_slots WHERE owner_node = ? AND desired_intent_id IS NOT NULL ORDER BY workspace_id, overlay_owner LIMIT ?", {node, MAX_DESIRED_SLOTS + 1})
        if query_error or not rows then return storage(query_error, "list desired activation slots") end
        if #rows > MAX_DESIRED_SLOTS then return failure("CAPACITY", "desired activation slots exceed their bound") end
        local slots: {Object} = {}
        for _, row in ipairs(rows) do
            local workspace_id, overlay_owner = id(row.workspace_id), id(row.overlay_owner)
            if not workspace_id or not overlay_owner then return failure("INTERNAL", "desired activation slot is malformed") end
            slots[#slots + 1] = {workspace_id = workspace_id, overlay_owner = overlay_owner}
        end
        return transaction.success({slots = slots}, false)
    end)
    db:release()
    return result
end
function M.open(resource: string, node_raw: string, workspace_raw: string): (Store?, string?)
    if type(resource) ~= "string" or resource == "" then return nil, "governance activation database is not linked" end
    local node, workspace = id(node_raw), id(workspace_raw)
    if not node or not workspace then return nil, "governance activation store identity is invalid" end
    local db, err = database.open({resource = resource, ledger = {table = "bee_governance_migrations", label = "governance"}, migrations = migrations.all()})
    if not db then return nil, err end
    local migrated, migration_error = identity_migration.apply(db, node)
    if not migrated then
        db:release()
        return nil, migration_error or "migrate governance node identity"
    end
    return {db = db, node = node, workspace = workspace, closed = false}, nil
end
return M
