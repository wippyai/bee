-- MIT. Small destination-owned activation ledger. Intent facts are immutable;
-- execution progress and recovery pointers are stored separately. This module
-- does not resolve, approve, apply, or contact another node.
local sql = require("sql")
local catalog_revision = require("catalog_revision")
local bounds = require("bounds")
local canonical = require("canonical")
local json = require("json")
local transaction = require("transaction")
local migration_work = require("migration_work")
local lease_store = require("lease_store")

local M = {}
local part_activation_queries = require("part_activation_queries")
type Result = part_activation_queries.Result
type Store = part_activation_queries.Store
type Object = part_activation_queries.Object
local failure = part_activation_queries.failure
local id = part_activation_queries.id
local count = part_activation_queries.count
local unknown = part_activation_queries.unknown
local authorization_digest = part_activation_queries.authorization_digest
type Intent = part_activation_queries.Intent
type Slot = part_activation_queries.Slot
local MAX_INTENTS = part_activation_queries.MAX_INTENTS
local storage = part_activation_queries.storage
local one = part_activation_queries.one
local load = part_activation_queries.load
local slot = part_activation_queries.slot
local view = part_activation_queries.view
M.get = part_activation_queries.get
M.bound_to = part_activation_queries.bound_to
M.desired = part_activation_queries.desired
M.applied = part_activation_queries.applied
M.listing = part_activation_queries.listing
M.baseline = part_activation_queries.baseline
M.reverted_from = part_activation_queries.reverted_from
M.desired_slots = part_activation_queries.desired_slots
M.applied_databases = part_activation_queries.applied_databases
local part_activation_decode = require("part_activation_decode")
local MAX_MIGRATION_RECEIPT = part_activation_decode.MAX_MIGRATION_RECEIPT
type Blob = part_activation_decode.Blob
type PrepareRequest = part_activation_decode.PrepareRequest
type BindRequest = part_activation_decode.BindRequest
type LeaseRequest = part_activation_decode.LeaseRequest
type ConsumeRequest = part_activation_decode.ConsumeRequest
type ConsumptionRequest = part_activation_decode.ConsumptionRequest
type ApplyRequest = part_activation_decode.ApplyRequest
type MigrationRequest = part_activation_decode.MigrationRequest
type OutcomeRequest = part_activation_decode.OutcomeRequest
type RemoveRequest = part_activation_decode.RemoveRequest
type RevertRequest = part_activation_decode.RevertRequest
type StatusRequest = part_activation_decode.StatusRequest
type DecodedRequest = part_activation_decode.DecodedRequest
local digest = part_activation_decode.digest
local decode = part_activation_decode.decode
local MAX_RECEIPTS = 512
local MAX_REQUEST = 4194304
local ENDINGS: {[string]: boolean} = {denied = true, expired = true, withdrawn = true}
type Request = Object
type Mutation = PrepareRequest | BindRequest | LeaseRequest | ConsumeRequest | ConsumptionRequest | ApplyRequest | MigrationRequest | OutcomeRequest
local function request_digest(value: Request): (string?, Result?)
    local encoded = canonical.encode(value, MAX_REQUEST)
    if not encoded then return nil, failure("INVALID", "activation request cannot be measured") end
    local measured = digest(encoded)
    if not measured then return nil, failure("INTERNAL", "measure activation request") end
    return measured, nil
end
local function cas_result(result: unknown, err: unknown, action: string): Result?
    if err then return storage(err, action) end
    local value = bounds.object(result)
    if not value or value.rows_affected ~= 1 then return failure("CONFLICT", action .. " lost its revision fence") end
    return nil
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
        -- One effect per authorization at a time: a request that ended without
        -- approval never reached its effect, so the next one is a new attempt.
        local ended_row, ended_error = one(tx, "SELECT COUNT(*) AS count FROM bee_governance_activation_intents i JOIN bee_governance_activation_execution e ON e.owner_node = i.owner_node AND e.workspace_id = i.workspace_id AND e.intent_id = i.intent_id WHERE i.owner_node = ? AND i.workspace_id = ? AND i.authorization_digest = ? AND e.phase = 'settled' AND e.outcome IN ('denied', 'expired', 'withdrawn')", {store.node, store.workspace, authorized}, "ended activation attempts")
        if ended_error or not ended_row then return ended_error or failure("INTERNAL", "ended activation attempts are missing") end
        local attempt = count(ended_row.count, false)
        if attempt == nil then return failure("INTERNAL", "ended activation attempts are corrupt") end
        local effect_bytes = canonical.encode(attempt == 0
            and {schema_revision = "bee.governance-effect@1", authorization_digest = authorized}
            or {schema_revision = "bee.governance-effect@2", authorization_digest = authorized, attempt = attempt})
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
    -- Blocked settles an authorized or applied generation whose stored
    -- artifact the current host rules reject.
    return transition(store, actor, input, {approval_bound = true, consuming = true, authorized = true, applying = true, settled = true}, function(tx: sql.Transaction, row: Intent): Result
        if row.phase == "authorized" and input.outcome ~= "blocked" then
            return failure("CONFLICT", "an authorized activation settles here only as blocked")
        end
        local waiting = row.phase == "approval_bound" or row.phase == "consuming"
        if (ENDINGS[input.outcome] == true) ~= waiting then
            return failure("CONFLICT", waiting and "an activation waiting for its approval ends only as denied, expired or withdrawn"
                or "only an activation waiting for its approval ends as denied, expired or withdrawn")
        end
        if input.outcome == "applied"
            and not (row.migrations_completed == true or tonumber(row.migrations_completed) == 1) then
            return failure("CONFLICT", "activation migrations are not complete")
        end
        -- A rolled-back applied generation is final but is not
        -- observed; once its overlay is restored the slot observes it again.
        local before_slot, before_error = slot(tx, store, row.overlay_owner, false)
        if before_error then return before_error end
        local restored = row.phase == "settled" and row.outcome == "applied" and input.outcome == "applied"
            and before_slot ~= nil and before_slot.desired_intent_id == row.intent_id
            and before_slot.observed_intent_id == nil
        if row.phase == "settled" and row.outcome ~= "uncertain" and not restored
            and not (row.outcome == "applied" and (input.outcome == "uncertain" or input.outcome == "blocked")) then
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
            -- Retain the observed complete generation as the last
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
-- removable says whether the person can remove the overlay a desired
-- generation names: it is applied and observed, or it is blocked by the
-- current host rules.
function M.removable(desired: {[string]: unknown}): boolean
    if desired.phase ~= "settled" then return false end
    if desired.outcome == "blocked" then return true end
    return desired.outcome == "applied" and desired.intent_id == desired.observed_intent_id
        and desired.observed_outcome == "applied"
end

-- remove_activation: the person's removal of an application. The slot forgets
-- its desired and observed generations, so boot recovery never restores it, and
-- the receipt records who asked. The intents stay as history.
function M.remove_activation(store: Store, actor: string, raw_input: Request): Result
    if store.closed then return failure("CLOSED", "governance activation store is closed") end
    local decoded, input_error = decode(raw_input)
    if not decoded then return failure("INVALID", input_error or "invalid activation request") end
    if decoded.operation ~= "remove_activation" then return failure("INVALID", "unsupported activation operation") end
    local input = decoded.request
    local measured, measure_error = request_digest(input)
    if not measured then return assert(measure_error) end
    return transaction.write(store.db, "governance activation", function(tx: sql.Transaction): Result
        local prior, prior_error = one(tx, "SELECT actor_id, operation, request_digest, intent_id FROM bee_governance_activation_receipts WHERE owner_node = ? AND workspace_id = ? AND idempotency_key = ?", {store.node, store.workspace, input.idempotency_key}, "activation remove receipt")
        if prior_error then return prior_error end
        if prior then
            if prior.actor_id ~= actor then return failure("DENIED", "idempotency key belongs to another actor") end
            if prior.operation ~= input.operation or prior.request_digest ~= measured then
                return failure("CONFLICT", "idempotency key was used by a different activation request")
            end
            local removed_id = id(prior.intent_id)
            if not removed_id then return failure("INTERNAL", "removed activation intent is missing") end
            local removed, removed_error = load(tx, store, removed_id)
            if not removed then return removed_error or failure("INTERNAL", "removed activation intent is missing") end
            local replay_slot, replay_error = slot(tx, store, input.overlay_owner, false)
            if replay_error then return replay_error end
            return transaction.success(view(store, removed, replay_slot), true)
        end
        local current_slot, slot_error = slot(tx, store, input.overlay_owner, false)
        if slot_error then return slot_error end
        if not current_slot or current_slot.desired_intent_id == nil then
            return failure("CONFLICT", "overlay has no installed generation to remove")
        end
        if count(current_slot.revision, false) ~= input.expected_revision then
            return failure("CONFLICT", "expected_revision does not match the overlay slot")
        end
        local removed, removed_error = load(tx, store, current_slot.desired_intent_id)
        if removed_error or not removed then return removed_error or failure("INTERNAL", "desired activation intent is missing") end
        if not M.removable(view(store, removed, current_slot)) then
            return failure("CONFLICT", "the overlay has a newer generation on its way; let it settle first")
        end
        local slot_updated, slot_write_error = tx:execute("UPDATE bee_governance_activation_slots SET revision = ?, desired_intent_id = NULL, desired_execution_revision = NULL, observed_intent_id = NULL, observed_execution_revision = NULL, observed_artifact_digest = NULL, observed_outcome = NULL, baseline_intent_id = NULL, baseline_execution_revision = NULL, baseline_artifact_digest = NULL, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE owner_node = ? AND workspace_id = ? AND overlay_owner = ? AND revision = ?", {input.expected_revision + 1, store.node, store.workspace, input.overlay_owner, current_slot.revision})
        local slot_update_error = cas_result(slot_updated, slot_write_error, "remove activation slot")
        if slot_update_error then return slot_update_error end
        local refreshed_slot, refresh_error = slot(tx, store, input.overlay_owner, false)
        if refresh_error then return refresh_error end
        local _, receipt_error = tx:execute("INSERT INTO bee_governance_activation_receipts (owner_node, workspace_id, idempotency_key, actor_id, operation, request_digest, intent_id, result_revision) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", {store.node, store.workspace, input.idempotency_key, actor, input.operation, measured, removed.intent_id, removed.revision})
        if receipt_error then return storage(receipt_error, "record activation remove receipt") end
        return transaction.success(view(store, removed, refreshed_slot), false)
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
    elseif input.operation == "remove_activation" then return M.remove_activation(store, actor, input.request)
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
    if released ~= true or err then return false, transaction.error_message("close governance activation database", err) end
    return true, nil
end
M.catalog_revision = catalog_revision.read

function M.open(resource: string, node_raw: string, workspace_raw: string): (Store?, string?)
    if type(resource) ~= "string" or resource == "" then return nil, "governance activation database is not linked" end
    local node, workspace = id(node_raw), id(workspace_raw)
    if not node or not workspace then return nil, "governance activation store identity is invalid" end
    local db, err = sql.get(resource)
    if not db then return nil, tostring(err) end
    return {db = db, node = node, workspace = workspace, closed = false}, nil
end
return M
