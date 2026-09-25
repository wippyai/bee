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
    local bytes: string = object.bytes :: string
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
local function authorization_digest(store: Store, input: Request, artifact: Blob, resolution: Blob,
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
local function load(tx: sql.Transaction, store: Store, intent_id: string): (Object?, Result?)
    return one(tx, "SELECT i.*, e.revision, e.phase, e.approval_id, e.approval_proposal_digest, e.approval_owner_incarnation, e.grant_reuse_digest, e.consumed_consumer_id, e.consumed_proposal_digest, e.consumed_effect_key, e.outcome, e.diagnostics, e.migrations_completed, e.migration_receipt_bytes, e.migration_receipt_digest, e.updated_at AS execution_updated_at FROM bee_governance_activation_intents i JOIN bee_governance_activation_execution e ON e.owner_node = i.owner_node AND e.workspace_id = i.workspace_id AND e.intent_id = i.intent_id WHERE i.owner_node = ? AND i.workspace_id = ? AND i.intent_id = ?", {store.node, store.workspace, intent_id}, "activation intent")
end
local function slot(tx: sql.Transaction, store: Store, overlay_owner: string, create: boolean): (Object?, Result?)
    local row, err = one(tx, "SELECT * FROM bee_governance_activation_slots WHERE owner_node = ? AND workspace_id = ? AND overlay_owner = ?", {store.node, store.workspace, overlay_owner}, "activation slot")
    if err or row or not create then return row, err end
    local _, insert_error = tx:execute("INSERT INTO bee_governance_activation_slots (owner_node, workspace_id, overlay_owner, revision, updated_at) VALUES (?, ?, ?, 0, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))", {store.node, store.workspace, overlay_owner})
    if insert_error then return nil, storage(insert_error, "create activation slot") end
    return one(tx, "SELECT * FROM bee_governance_activation_slots WHERE owner_node = ? AND workspace_id = ? AND overlay_owner = ?", {store.node, store.workspace, overlay_owner}, "activation slot")
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
local function replay(store: Store, tx: sql.Transaction, actor: string, input: Request, measured: string): Result?
    local key = id(input.idempotency_key)
    if not key then return failure("INVALID", "idempotency_key is required") end
    local row, err = one(tx, "SELECT actor_id, operation, request_digest, intent_id FROM bee_governance_activation_receipts WHERE owner_node = ? AND workspace_id = ? AND idempotency_key = ?", {store.node, store.workspace, key}, "activation receipt")
    if err or not row then return err end
    if row.actor_id ~= actor then return failure("DENIED", "idempotency key belongs to another actor") end
    if row.operation ~= input.operation or row.request_digest ~= measured or row.intent_id ~= input.intent_id then return failure("CONFLICT", "idempotency key was used by a different activation request") end
    local current, current_error = load(tx, store, row.intent_id :: string)
    if current_error or not current then return current_error or failure("INTERNAL", "activation receipt has no intent") end
    local current_slot, slot_error = slot(tx, store, current.overlay_owner :: string, false)
    if slot_error then return slot_error end
    return transaction.success(view(store, current, current_slot), true)
end
local function save_receipt(store: Store, tx: sql.Transaction, actor: string, input: Request, measured: string, row: Object): Result?
    local count_row, count_error = one(tx, "SELECT COUNT(*) AS count FROM bee_governance_activation_receipts WHERE owner_node = ? AND workspace_id = ?", {store.node, store.workspace}, "activation receipt count")
    if count_error or not count_row then return count_error or failure("INTERNAL", "activation receipt count is missing") end
    local receipts = count(count_row.count, false)
    if not receipts then return failure("INTERNAL", "activation receipt count is corrupt") end
    if receipts >= MAX_RECEIPTS then return failure("CAPACITY_EXHAUSTED", "activation receipt capacity is exhausted") end
    local _, err = tx:execute("INSERT INTO bee_governance_activation_receipts (owner_node, workspace_id, idempotency_key, actor_id, operation, request_digest, intent_id, result_revision) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", {store.node, store.workspace, input.idempotency_key, actor, input.operation, measured, row.intent_id, row.revision})
    if err then return storage(err, "record activation receipt") end
    return nil
end
local function transition(store: Store, actor: string, input: Request, accepted: {[string]: boolean}, update: (sql.Transaction, Object) -> Result): Result
    local measured, measure_error = request_digest(input)
    if not measured then return measure_error :: Result end
    return transaction.write(store.db, "governance activation", function(tx: sql.Transaction): Result
        local already = replay(store, tx, actor, input, measured :: string)
        if already then return already end
        local row, row_error = load(tx, store, input.intent_id :: string)
        if row_error or not row then return row_error or failure("NOT_FOUND", "activation intent does not exist") end
        if input.expected_revision ~= row.revision then return failure("CONFLICT", "expected_revision does not match activation intent") end
        if not accepted[row.phase :: string] then return failure("CONFLICT", "activation intent is not in the required phase") end
        local result = update(tx, row)
        if not result.ok then return result end
        return result
    end)
end

local function decode(raw: unknown): (Request?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "activation request must be an object" end
    local operation = value.operation
    if operation == "activation_status" then
        local extra = unknown(value, {"operation", "intent_id"})
        if extra then return nil, extra end
        local intent_id = id(value.intent_id)
        if not intent_id then return nil, "intent_id is required" end
        return {operation = operation, intent_id = intent_id}, nil
    end
    local common = {"operation", "intent_id", "expected_revision", "idempotency_key"}
    local intent_id, key, expected = id(value.intent_id), id(value.idempotency_key), count(value.expected_revision, false)
    if not intent_id or not key or expected == nil then return nil, "intent_id, expected_revision and idempotency_key are required" end
    local result: Request = {operation = operation, intent_id = intent_id, expected_revision = expected, idempotency_key = key}
    if operation == "prepare_activation" then
        if expected ~= 0 then return nil, "prepare_activation requires expected_revision zero" end
        local extra = unknown(value, {"operation", "intent_id", "expected_revision", "idempotency_key", "overlay_owner", "source_node", "source_workspace", "version", "plan_digest", "plan_revision", "selection_revision", "artifact", "resolution", "preflight", "migration_work", "application_admission", "grant_predecessor_digest"})
        if extra then return nil, extra end
        result.overlay_owner = id(value.overlay_owner)
        result.source_node, result.source_workspace, result.version = id(value.source_node), id(value.source_workspace), id(value.version)
        result.plan_digest = hex_digest(value.plan_digest)
        result.plan_revision, result.selection_revision = count(value.plan_revision, true), count(value.selection_revision, true)
        local artifact, artifact_error = checked_blob(value.artifact, MAX_ARTIFACT, "artifact")
        local resolution, resolution_error = checked_blob(value.resolution, MAX_RESOLUTION, "resolution")
        local preflight, preflight_error = checked_blob(value.preflight, MAX_PREFLIGHT, "preflight")
        local work, work_error = checked_blob(value.migration_work, MAX_MIGRATION_WORK, "migration work")
        local admission, admission_error = optional_blob(value.application_admission, MAX_APPLICATION_ADMISSION, "application admission")
        if not result.overlay_owner or not result.source_node or not result.source_workspace or not result.version or not result.plan_digest or not result.plan_revision or not result.selection_revision or not artifact or not resolution or not preflight or not work or admission_error then return nil, artifact_error or resolution_error or preflight_error or work_error or admission_error or "activation facts are invalid" end
        result.artifact_digest = artifact.digest
        result.artifact, result.resolution, result.preflight, result.migration_work = artifact, resolution, preflight, work
        result.application_admission = admission
        result.grant_predecessor_digest = value.grant_predecessor_digest == nil
            and nil or hex_digest(value.grant_predecessor_digest)
        if value.grant_predecessor_digest ~= nil and not result.grant_predecessor_digest then
            return nil, "grant predecessor digest is invalid"
        end
        return result, nil
    end
    if operation == "bind_approval" then
        local extra = unknown(value, {"operation", "intent_id", "expected_revision", "idempotency_key", "approval_id", "approval_proposal_digest", "approval_owner_incarnation", "grant_reuse_digest"})
        if extra then return nil, extra end
        result.approval_id, result.approval_proposal_digest = id(value.approval_id), hex_digest(value.approval_proposal_digest)
        result.approval_owner_incarnation = count(value.approval_owner_incarnation, true)
        result.grant_reuse_digest = value.grant_reuse_digest == nil and nil or hex_digest(value.grant_reuse_digest)
        if not result.approval_id or not result.approval_proposal_digest or not result.approval_owner_incarnation then return nil, "approval identity is invalid" end
        if value.grant_reuse_digest ~= nil and result.grant_reuse_digest ~= result.approval_proposal_digest then
            return nil, "grant reuse digest is invalid"
        end
    elseif operation == "begin_consume" then
        local extra = unknown(value, {"operation", "intent_id", "expected_revision", "idempotency_key"})
        if extra then return nil, extra end
    elseif operation == "record_consumption" then
        local extra = unknown(value, {"operation", "intent_id", "expected_revision", "idempotency_key", "consumer_id", "proposal_digest", "effect_key"})
        if extra then return nil, extra end
        result.consumer_id, result.proposal_digest, result.effect_key = id(value.consumer_id), hex_digest(value.proposal_digest), id(value.effect_key)
        if not result.consumer_id or not result.proposal_digest or not result.effect_key then return nil, "consumption identity is invalid" end
    elseif operation == "begin_apply" then
        local extra = unknown(value, common)
        if extra then return nil, extra end
    elseif operation == "record_migrations" then
        local extra = unknown(value, {"operation", "intent_id", "expected_revision", "idempotency_key", "receipt", "complete", "diagnostics"})
        if extra then return nil, extra end
        local receipt, receipt_error = checked_blob(value.receipt, MAX_MIGRATION_RECEIPT, "migration receipt")
        result.complete = value.complete
        result.diagnostics = bounds.text(value.diagnostics or "", MAX_DIAGNOSTICS)
        if not receipt or type(result.complete) ~= "boolean" or not result.diagnostics then
            return nil, receipt_error or "migration result is invalid"
        end
        result.receipt = receipt
    elseif operation == "record_outcome" then
        local extra = unknown(value, {"operation", "intent_id", "expected_revision", "idempotency_key", "outcome", "diagnostics"})
        if extra then return nil, extra end
        local outcome = type(value.outcome) == "string" and value.outcome or nil
        result.outcome = outcome and OUTCOMES[outcome] and outcome or nil
        result.diagnostics = bounds.text(value.diagnostics or "", MAX_DIAGNOSTICS)
        if not result.outcome or not result.diagnostics then return nil, "outcome is invalid" end
    else
        return nil, "unsupported activation operation"
    end
    return result, nil
end

function M.prepare(store: Store, actor: string, input: Request): Result
    local measured, measure_error = request_digest(input)
    if not measured then return measure_error :: Result end
    return transaction.write(store.db, "governance activation", function(tx: sql.Transaction): Result
        local already = replay(store, tx, actor, input, measured :: string)
        if already then return already end
        local existing, existing_error = load(tx, store, input.intent_id :: string)
        if existing_error then return existing_error end
        if existing then return failure("CONFLICT", "activation intent already exists") end
        local count_row, count_error = one(tx, "SELECT COUNT(*) AS count FROM bee_governance_activation_intents WHERE owner_node = ? AND workspace_id = ?", {store.node, store.workspace}, "activation intent count")
        if count_error or not count_row then return count_error or failure("INTERNAL", "activation intent count is missing") end
        local intents = count(count_row.count, false)
        if not intents then return failure("INTERNAL", "activation intent count is corrupt") end
        if intents >= MAX_INTENTS then return failure("CAPACITY_EXHAUSTED", "activation intent capacity is exhausted") end
        local authorized = authorization_digest(store, input, input.artifact :: Blob,
            input.resolution :: Blob, input.preflight :: Blob, input.migration_work :: Blob,
            input.application_admission :: Blob?)
        if not authorized then return failure("INTERNAL", "measure activation authorization") end
        local effect_bytes = canonical.encode({schema_revision = "bee.governance-effect@1", authorization_digest = authorized})
        local effect_key = effect_bytes and digest(effect_bytes)
        if not effect_key then return failure("INTERNAL", "measure activation effect key") end
        local admission = input.application_admission :: Blob?
        local _, insert_error = tx:execute("INSERT INTO bee_governance_activation_intents (owner_node, workspace_id, intent_id, actor_id, overlay_owner, source_node, source_workspace, version, plan_digest, plan_revision, selection_revision, artifact_bytes, artifact_digest, resolution_bytes, resolution_digest, preflight_bytes, preflight_digest, migration_work_bytes, migration_work_digest, application_admission_bytes, application_admission_digest, grant_predecessor_digest, authorization_digest, effect_key, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))", {store.node, store.workspace, input.intent_id, actor, input.overlay_owner, input.source_node, input.source_workspace, input.version, input.plan_digest, input.plan_revision, input.selection_revision, input.artifact.bytes, input.artifact.digest, input.resolution.bytes, input.resolution.digest, input.preflight.bytes, input.preflight.digest, input.migration_work.bytes, input.migration_work.digest, admission and admission.bytes or nil, admission and admission.digest or nil, input.grant_predecessor_digest, authorized, effect_key})
        if insert_error then return storage(insert_error, "prepare activation") end
        local _, execution_error = tx:execute("INSERT INTO bee_governance_activation_execution (owner_node, workspace_id, intent_id, revision, phase, updated_at) VALUES (?, ?, ?, 1, 'prepared', strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))", {store.node, store.workspace, input.intent_id})
        if execution_error then return storage(execution_error, "create activation execution") end
        local row, row_error = load(tx, store, input.intent_id :: string)
        if row_error or not row then return row_error or failure("INTERNAL", "read prepared activation") end
        local receipt_error = save_receipt(store, tx, actor, input, measured :: string, row)
        if receipt_error then return receipt_error end
        return transaction.success(view(store, row, nil), false)
    end)
end
local function finish(store: Store, tx: sql.Transaction, actor: string, input: Request, measured: string, row: Object, current_slot: Object?): Result
    local receipt_error = save_receipt(store, tx, actor, input, measured, row)
    if receipt_error then return receipt_error end
    return transaction.success(view(store, row, current_slot), false)
end
function M.bind_approval(store: Store, actor: string, input: Request): Result
    local measured = request_digest(input) :: string
    return transition(store, actor, input, {prepared = true}, function(tx, row)
        local next_revision = (row.revision :: number) + 1
        local updated, err = tx:execute("UPDATE bee_governance_activation_execution SET phase = 'approval_bound', approval_id = ?, approval_proposal_digest = ?, approval_owner_incarnation = ?, grant_reuse_digest = ?, revision = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE owner_node = ? AND workspace_id = ? AND intent_id = ? AND revision = ?", {input.approval_id, input.approval_proposal_digest, input.approval_owner_incarnation, input.grant_reuse_digest, next_revision, store.node, store.workspace, row.intent_id, row.revision})
        local update_error = cas_result(updated, err, "bind activation approval")
        if update_error then return update_error :: Result end
        local changed, changed_error = load(tx, store, row.intent_id :: string)
        if changed_error or not changed then return changed_error or failure("INTERNAL", "read bound activation") end
        return finish(store, tx, actor, input, measured, changed, nil)
    end)
end
function M.begin_consume(store: Store, actor: string, input: Request): Result
    local measured = request_digest(input) :: string
    return transition(store, actor, input, {approval_bound = true, consuming = true}, function(tx, row)
        local next_revision = (row.revision :: number) + 1
        local updated, err = tx:execute("UPDATE bee_governance_activation_execution SET phase = 'consuming', revision = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE owner_node = ? AND workspace_id = ? AND intent_id = ? AND revision = ?", {next_revision, store.node, store.workspace, row.intent_id, row.revision})
        local update_error = cas_result(updated, err, "begin activation consumption")
        if update_error then return update_error :: Result end
        local changed, changed_error = load(tx, store, row.intent_id :: string)
        if changed_error or not changed then return changed_error or failure("INTERNAL", "read consuming activation") end
        return finish(store, tx, actor, input, measured, changed, nil)
    end)
end
function M.record_consumption(store: Store, actor: string, input: Request): Result
    local measured = request_digest(input) :: string
    return transition(store, actor, input, {consuming = true}, function(tx, row)
        if row.effect_key ~= input.effect_key or row.approval_proposal_digest ~= input.proposal_digest then return failure("CONFLICT", "consumption does not match the bound approval") end
        local next_revision = (row.revision :: number) + 1
        local updated, err = tx:execute("UPDATE bee_governance_activation_execution SET phase = 'authorized', consumed_consumer_id = ?, consumed_proposal_digest = ?, consumed_effect_key = ?, revision = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE owner_node = ? AND workspace_id = ? AND intent_id = ? AND revision = ?", {input.consumer_id, input.proposal_digest, input.effect_key, next_revision, store.node, store.workspace, row.intent_id, row.revision})
        local update_error = cas_result(updated, err, "record activation consumption")
        if update_error then return update_error :: Result end
        local changed, changed_error = load(tx, store, row.intent_id :: string)
        if changed_error or not changed then return changed_error or failure("INTERNAL", "read authorized activation") end
        local current_slot, slot_error = slot(tx, store, row.overlay_owner :: string, true)
        if slot_error or not current_slot then return slot_error or failure("INTERNAL", "read activation slot") end
        if current_slot.desired_intent_id ~= nil and current_slot.desired_intent_id ~= row.intent_id then
            local active, active_error = load(tx, store, current_slot.desired_intent_id :: string)
            if active_error or not active then
                return active_error or failure("INTERNAL", "desired activation intent is missing")
            end
            if active.phase == "applying" or (active.phase == "settled" and active.outcome == "uncertain") then
                return failure("CONFLICT", "another activation effect requires settlement")
            end
        end
        local slot_revision = (count(current_slot.revision, false) :: number) + 1
        local slot_updated, slot_error_write = tx:execute("UPDATE bee_governance_activation_slots SET revision = ?, desired_intent_id = ?, desired_execution_revision = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE owner_node = ? AND workspace_id = ? AND overlay_owner = ? AND revision = ?", {slot_revision, row.intent_id, next_revision, store.node, store.workspace, row.overlay_owner, current_slot.revision})
        local slot_update_error = cas_result(slot_updated, slot_error_write, "authorize activation slot")
        if slot_update_error then return slot_update_error :: Result end
        local changed_slot, changed_slot_error = slot(tx, store, row.overlay_owner :: string, false)
        if changed_slot_error or not changed_slot then return changed_slot_error or failure("INTERNAL", "read authorized activation slot") end
        return finish(store, tx, actor, input, measured, changed, changed_slot)
    end)
end
function M.begin_apply(store: Store, actor: string, input: Request): Result
    local measured = request_digest(input) :: string
    return transition(store, actor, input, {authorized = true, applying = true}, function(tx: sql.Transaction, row: Object): Result
        local current_slot, slot_error = slot(tx, store, row.overlay_owner :: string, false)
        if slot_error then return slot_error :: Result end
        if not current_slot or current_slot.desired_intent_id ~= row.intent_id then return failure("CONFLICT", "activation is no longer the desired slot") end
        local work, work_error = migration_work.decode(row.migration_work_bytes, row.migration_work_digest)
        if not work then return failure("INTERNAL", tostring(work_error or "decode activation migration work")) end
        local completed = #work.migrations == 0 and 1 or 0
        local next_revision = (row.revision :: number) + 1
        local updated, err = tx:execute("UPDATE bee_governance_activation_execution SET phase = 'applying', migrations_completed = ?, revision = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE owner_node = ? AND workspace_id = ? AND intent_id = ? AND revision = ?", {completed, next_revision, store.node, store.workspace, row.intent_id, row.revision})
        local update_error = cas_result(updated, err, "begin activation apply")
        if update_error then return update_error :: Result end
        local changed, changed_error = load(tx, store, row.intent_id :: string)
        if changed_error or not changed then return changed_error or failure("INTERNAL", "read applying activation") end
        return finish(store, tx, actor, input, measured, changed, nil)
    end)
end

local function migration_receipt(input: Request, work: any): ({[string]: Object}?, string?)
    local decoded, decode_error = json.decode((input.receipt :: Blob).bytes)
    local value = bounds.object(decoded)
    if decode_error or not value or value.schema_revision ~= "bee.governance-migration-receipt@1"
        or type(value.rows) ~= "table" then return nil, "migration receipt is malformed" end
    local encoded, encode_error = canonical.encode(value, MAX_MIGRATION_RECEIPT)
    if not encoded or encoded ~= (input.receipt :: Blob).bytes then
        return nil, tostring(encode_error or "migration receipt is not canonical")
    end
    local expected: {[string]: any} = {}
    for _, item in ipairs(work.migrations) do expected[item.target_db .. "\n" .. item.id] = item end
    local rows: {[string]: Object} = {}
    local count_rows = 0
    for key in pairs(value.rows :: table) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return nil, "migration receipt rows must be a dense list" end
        count_rows = count_rows + 1
    end
    if count_rows ~= #(value.rows :: table) or count_rows > migration_work.MAX_MIGRATIONS then
        return nil, "migration receipt rows exceed their bound or are sparse"
    end
    for index = 1, count_rows do
        local row = bounds.object((value.rows :: table)[index])
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

function M.record_migrations(store: Store, actor: string, input: Request): Result
    local measured = request_digest(input) :: string
    return transition(store, actor, input, {applying = true}, function(tx: sql.Transaction, row: Object): Result
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
        local next_revision = (row.revision :: number) + 1
        local updated, update_error = tx:execute("UPDATE bee_governance_activation_execution SET migrations_completed = ?, migration_receipt_bytes = ?, migration_receipt_digest = ?, diagnostics = ?, revision = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE owner_node = ? AND workspace_id = ? AND intent_id = ? AND revision = ?", {input.complete and 1 or 0, (input.receipt :: Blob).bytes, (input.receipt :: Blob).digest, input.diagnostics, next_revision, store.node, store.workspace, row.intent_id, row.revision})
        local cas_error = cas_result(updated, update_error, "record activation migrations")
        if cas_error then return cas_error :: Result end
        local changed, changed_error = load(tx, store, row.intent_id :: string)
        if changed_error or not changed then return changed_error or failure("INTERNAL", "read migration progress") end
        return finish(store, tx, actor, input, measured, changed, nil)
    end)
end

function M.record_outcome(store: Store, actor: string, input: Request): Result
    local measured = request_digest(input) :: string
    return transition(store, actor, input, {applying = true, settled = true}, function(tx: sql.Transaction, row: Object): Result
        if input.outcome == "applied"
            and not (row.migrations_completed == true or tonumber(row.migrations_completed) == 1) then
            return failure("CONFLICT", "activation migrations are not complete")
        end
        if row.phase == "settled" and row.outcome ~= "uncertain"
            and not (row.outcome == "applied" and input.outcome == "uncertain") then
            return failure("CONFLICT", "activation outcome is already final")
        end
        local next_revision = (row.revision :: number) + 1
        local updated, err = tx:execute("UPDATE bee_governance_activation_execution SET phase = 'settled', outcome = ?, diagnostics = ?, revision = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE owner_node = ? AND workspace_id = ? AND intent_id = ? AND revision = ?", {input.outcome, input.diagnostics, next_revision, store.node, store.workspace, row.intent_id, row.revision})
        local update_error = cas_result(updated, err, "record activation outcome")
        if update_error then return update_error :: Result end
        local changed, changed_error = load(tx, store, row.intent_id :: string)
        if changed_error or not changed then return changed_error or failure("INTERNAL", "read activation outcome") end
        local current_slot, slot_error = slot(tx, store, row.overlay_owner :: string, false)
        if slot_error then return slot_error :: Result end
        local result_slot: Object? = current_slot
        if input.outcome == "applied" then
            if not current_slot or current_slot.desired_intent_id ~= row.intent_id then return failure("CONFLICT", "activation is no longer the desired slot") end
            local slot_revision = (count(current_slot.revision, false) :: number) + 1
            local slot_updated, slot_error_write = tx:execute("UPDATE bee_governance_activation_slots SET revision = ?, observed_intent_id = ?, observed_execution_revision = ?, observed_artifact_digest = ?, observed_outcome = 'applied', updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE owner_node = ? AND workspace_id = ? AND overlay_owner = ? AND revision = ?", {slot_revision, row.intent_id, next_revision, row.artifact_digest, store.node, store.workspace, row.overlay_owner, current_slot.revision})
            local slot_update_error = cas_result(slot_updated, slot_error_write, "record observed activation")
            if slot_update_error then return slot_update_error :: Result end
            local refreshed_slot, refresh_error = slot(tx, store, row.overlay_owner :: string, false)
            if refresh_error then return refresh_error :: Result end
            result_slot = refreshed_slot
        elseif current_slot and current_slot.observed_intent_id == row.intent_id then
            local slot_revision = (count(current_slot.revision, false) :: number) + 1
            local slot_updated, slot_error_write = tx:execute("UPDATE bee_governance_activation_slots SET revision = ?, observed_execution_revision = ?, observed_outcome = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE owner_node = ? AND workspace_id = ? AND overlay_owner = ? AND revision = ?", {slot_revision, next_revision, input.outcome, store.node, store.workspace, row.overlay_owner, current_slot.revision})
            local slot_update_error = cas_result(slot_updated, slot_error_write, "record observed activation failure")
            if slot_update_error then return slot_update_error :: Result end
            local refreshed_slot, refresh_error = slot(tx, store, row.overlay_owner :: string, false)
            if refresh_error then return refresh_error :: Result end
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
        local row, err = load(tx, store, intent_id :: string)
        if err or not row then return err or failure("NOT_FOUND", "activation intent does not exist") end
        local current_slot, slot_error = slot(tx, store, row.overlay_owner :: string, false)
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
        local current_slot, slot_error = slot(tx, store, overlay_owner :: string, false)
        if slot_error then return slot_error end
        if not current_slot or current_slot.desired_intent_id == nil then
            return failure("NOT_FOUND", "no desired activation exists")
        end
        local row, row_error = load(tx, store, current_slot.desired_intent_id :: string)
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
        local work_by_intent: Object = {}
        for _, row in ipairs(rows) do
            local work = work_by_intent[row.intent_id :: string]
            if not work then
                local decoded, decode_error = migration_work.decode(row.migration_work_bytes, row.migration_work_digest)
                if not decoded then return failure("INTERNAL", tostring(decode_error or "decode applied migration intent")) end
                work, work_by_intent[row.intent_id :: string] = decoded, decoded
            end
            local captured: Object? = nil
            for _, raw_item in ipairs((work :: any).migrations) do
                local item = bounds.object(raw_item)
                if item and item.target_db == row.target_db and item.id == row.migration_id then captured = item; break end
            end
            if not captured or captured.ordinal ~= row.ordinal or captured.checksum ~= row.checksum
                or captured.package ~= row.component then
                return failure("CONFLICT", "applied migration fact differs from its immutable intent: " .. tostring(row.migration_id))
            end
            local database, database_error = migration_work.database(work, row.target_db)
            if not database then return failure("INTERNAL", tostring(database_error or "read applied database binding")) end
            local prior = bounds.object(databases[row.target_db :: string])
            if prior and (prior.database_id ~= database.database_id or prior.table_prefix ~= database.table_prefix
                or prior.kind ~= database.kind or prior.package ~= database.package or prior.digest ~= database.digest) then
                return failure("CONFLICT", "applied migration database evidence differs: " .. tostring(row.target_db))
            end
            databases[row.target_db :: string] = database
            local key = (row.target_db :: string) .. "\n" .. (row.migration_id :: string)
            if migrations[key] then return failure("CONFLICT", "applied migration identities overlap across package names") end
            migrations[key] = {
                id = row.migration_id, target_db = row.target_db, ordinal = row.ordinal, checksum = row.checksum}
        end
        return transaction.success({migrations = migrations, databases = databases}, false)
    end)
end
function M.call(store: Store, actor_raw: string, raw: unknown): Result
    if store.closed then return failure("CLOSED", "governance activation store is closed") end
    local actor = id(actor_raw)
    if not actor then return failure("INVALID", "activation actor is invalid") end
    local input, decode_error = decode(raw)
    if not input then return failure("INVALID", decode_error or "invalid activation request") end
    if input.operation == "activation_status" then return M.get(store, input.intent_id) end
    if input.operation == "prepare_activation" then return M.prepare(store, actor, input) end
    if input.operation == "bind_approval" then return M.bind_approval(store, actor, input) end
    if input.operation == "begin_consume" then return M.begin_consume(store, actor, input) end
    if input.operation == "record_consumption" then return M.record_consumption(store, actor, input) end
    if input.operation == "begin_apply" then return M.begin_apply(store, actor, input) end
    if input.operation == "record_migrations" then return M.record_migrations(store, actor, input) end
    return M.record_outcome(store, actor, input)
end
function M.close(store: Store): (boolean, string?)
    if store.closed then return true, nil end
    store.closed = true
    local released, err = store.db:release()
    if released ~= true or err then return false, "close governance activation database" end
    return true, nil
end
local MAX_DESIRED_SLOTS = 1024

-- Every workspace slot on this node that holds an authorized desired intent,
-- in a stable order. Boot recovery follows exactly these slots.
function M.desired_slots(resource: string, node_raw: string): Result
    if type(resource) ~= "string" or resource == "" then return failure("UNAVAILABLE", "governance activation database is not linked") end
    local node = id(node_raw)
    if not node then return failure("INVALID", "governance activation node is invalid") end
    local db, err = database.open({resource = resource, ledger = {table = "bee_governance_migrations", label = "governance"}, migrations = migrations.all()})
    if not db then return failure("UNAVAILABLE", tostring(err or "open governance activation database")) end
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
    return {db = db, node = node, workspace = workspace, closed = false}, nil
end
return M
