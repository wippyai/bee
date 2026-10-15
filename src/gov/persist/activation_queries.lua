-- MIT. Activation snapshots, baselines and installed database queries.
local sql = require("sql")
local bounds = require("bounds")
local transaction = require("transaction")
local migration_work = require("migration_work")
local part_activation_decode = require("part_activation_decode")
local M = {}
type Result = part_activation_decode.Result
type Store = part_activation_decode.Store
type Object = part_activation_decode.Object
local failure = part_activation_decode.failure
local id = part_activation_decode.id
local count = part_activation_decode.count
local unknown = part_activation_decode.unknown
local authorization_digest = part_activation_decode.authorization_digest
type Intent = part_activation_decode.Intent
local decode_intent = part_activation_decode.decode_intent
type Slot = part_activation_decode.Slot
local decode_slot = part_activation_decode.decode_slot
local MAX_INTENTS = 128
local function storage(err: unknown, action: string): Result
    return transaction.sql_failure(err, action)
end
local function one(tx: sql.Transaction, statement: string, params: {unknown}, label: string): (Object?, Result?)
    local rows, err = tx:query(statement, params)
    if err or not rows then return nil, storage(err, "read " .. label) end
    if #rows > 1 then return nil, failure("INTERNAL", label .. " rows are duplicated") end
    return rows[1], nil
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
        application_admission_generation = row.application_admission_generation,
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
-- The intent an approval was bound to, for the worker that applies an
-- approved activation.
function M.bound_to(store: Store, approval_raw: unknown): Result
    if store.closed then return failure("CLOSED", "governance activation store is closed") end
    local approval_id = id(approval_raw)
    if not approval_id then return failure("INVALID", "approval_id is invalid") end
    return transaction.read(store.db, "governance activation", function(tx): Result
        local rows, query_error = tx:query("SELECT intent_id FROM bee_governance_activation_execution WHERE owner_node = ? AND workspace_id = ? AND approval_id = ?",
            {store.node, store.workspace, approval_id})
        if query_error or not rows then return failure("STORAGE", "read approved activation") end
        local first = rows[1]
        local found = first and id(first.intent_id) or nil
        if not found then return failure("NOT_FOUND", "no activation is bound to approval " .. approval_id) end
        local row, err = load(tx, store, found)
        if err or not row then return err or failure("INTERNAL", "approved activation intent is missing") end
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
        if err or not rows then return storage(err, "read applied migrations") end
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
-- listing: the workspace's activations, newest first, each with the pointers of
-- its overlay slot. It carries no evidence bytes, so a person-facing list reads
-- every install, update and attempt without loading their artifacts.
function M.listing(store: Store): Result
    if store.closed then return failure("CLOSED", "governance activation store is closed") end
    return transaction.read(store.db, "governance activation", function(tx): Result
        local slot_rows, slot_error = tx:query("SELECT overlay_owner, revision, desired_intent_id, observed_intent_id, observed_outcome, baseline_intent_id FROM bee_governance_activation_slots WHERE owner_node = ? AND workspace_id = ? LIMIT ?",
            {store.node, store.workspace, MAX_INTENTS})
        if slot_error or not slot_rows then return storage(slot_error, "list activation slots") end
        local slots: {[string]: Object} = {}
        for _, slot_row in ipairs(slot_rows) do
            local owner = id(slot_row.overlay_owner)
            if not owner then return failure("INTERNAL", "activation slot is malformed") end
            slots[owner] = slot_row
        end
        local rows, err = tx:query("SELECT i.intent_id, i.overlay_owner, i.source_node, i.source_workspace, i.version, e.revision, e.phase, e.approval_id, e.outcome, e.diagnostics FROM bee_governance_activation_intents i JOIN bee_governance_activation_execution e ON e.owner_node = i.owner_node AND e.workspace_id = i.workspace_id AND e.intent_id = i.intent_id WHERE i.owner_node = ? AND i.workspace_id = ? ORDER BY i.created_at DESC, i.intent_id DESC LIMIT ?",
            {store.node, store.workspace, MAX_INTENTS})
        if err or not rows then return storage(err, "list activations") end
        local activations: {Object} = {}
        for _, row in ipairs(rows) do
            local intent_id, overlay_owner = id(row.intent_id), id(row.overlay_owner)
            local revision = count(row.revision, true)
            if not intent_id or not overlay_owner or revision == nil or type(row.phase) ~= "string"
                or type(row.source_node) ~= "string" or type(row.source_workspace) ~= "string"
                or type(row.version) ~= "string" then
                return failure("INTERNAL", "activation intent is malformed")
            end
            local item: Object = {owner_node = store.node, workspace_id = store.workspace, intent_id = intent_id,
                overlay_owner = overlay_owner, source_node = row.source_node, source_workspace = row.source_workspace,
                version = row.version, revision = revision, phase = row.phase, approval_id = row.approval_id,
                outcome = row.outcome, diagnostics = row.diagnostics}
            local current_slot = slots[overlay_owner]
            if current_slot then
                item.slot_revision = current_slot.revision
                item.desired_intent_id = current_slot.desired_intent_id
                item.observed_intent_id = current_slot.observed_intent_id
                item.observed_outcome = current_slot.observed_outcome
                item.baseline_intent_id = current_slot.baseline_intent_id
            end
            activations[#activations + 1] = item
        end
        return transaction.success({workspace_id = store.workspace, activations = activations}, false)
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
-- reverted_from reads the generation a recorded revert replaced, when that
-- revert went back to the target intent; restoring the target installs over it.
function M.reverted_from(store: Store, overlay_raw: unknown, target_raw: unknown): Result
    if store.closed then return failure("CLOSED", "governance activation store is closed") end
    local overlay_owner, target = id(overlay_raw), id(target_raw)
    if not overlay_owner or not target then return failure("INVALID", "activation revert identity is invalid") end
    return transaction.read(store.db, "governance activation", function(tx): Result
        local reverted, revert_error = one(tx, "SELECT reverted_from_intent_id, target_intent_id FROM bee_governance_activation_reverts WHERE owner_node = ? AND workspace_id = ? AND overlay_owner = ?", {store.node, store.workspace, overlay_owner}, "activation revert")
        if revert_error then return revert_error end
        if not reverted or reverted.target_intent_id ~= target then
            return failure("NOT_FOUND", "no recorded revert went back to this activation")
        end
        local from = id(reverted.reverted_from_intent_id)
        if not from then return failure("INTERNAL", "reverted activation intent is missing") end
        local row, row_error = load(tx, store, from)
        if row_error or not row then return row_error or failure("INTERNAL", "reverted activation intent is missing") end
        local current_slot, slot_error = slot(tx, store, overlay_owner, false)
        if slot_error then return slot_error end
        return transaction.success(view(store, row, current_slot), false)
    end)
end
local MAX_DESIRED_SLOTS = 1024

-- A bounded revision token for the workspace's process-local application
-- admission overlays. The broker can compare this cheaply and project the
-- full catalog only when the token changes.
-- Every workspace slot on this node that holds an authorized desired intent,
-- in a stable order. Boot recovery follows exactly these slots.
function M.desired_slots(resource: string, node_raw: string): Result
    if type(resource) ~= "string" or resource == "" then return failure("UNAVAILABLE", "governance activation database is not linked") end
    local node = id(node_raw)
    if not node then return failure("INVALID", "governance activation node is invalid") end
    local db, err = sql.get(resource)
    if not db then return failure("UNAVAILABLE", transaction.error_message("open governance activation database", err)) end
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
    return transaction.release(db, "governance activation", result)
end

-- applied_databases: every database this node's applied migrations wrote,
-- once per overlay owner and logical target, with the physical database the
-- applying intent bound. Migration ledgers live in these databases, so they
-- hold data whether or not their application is installed.
function M.applied_databases(resource: string, node_raw: string): Result
    if type(resource) ~= "string" or resource == "" then return failure("UNAVAILABLE", "governance activation database is not linked") end
    local node = id(node_raw)
    if not node then return failure("INVALID", "governance activation node is invalid") end
    local db, err = sql.get(resource)
    if not db then return failure("UNAVAILABLE", transaction.error_message("open governance activation database", err)) end
    local result = transaction.read(db, "governance activation", function(tx): Result
        local rows, query_error = tx:query("SELECT DISTINCT a.workspace_id, i.overlay_owner, a.target_db, a.intent_id, i.migration_work_bytes, i.migration_work_digest FROM bee_governance_applied_migrations a JOIN bee_governance_activation_intents i ON i.owner_node = a.owner_node AND i.workspace_id = a.workspace_id AND i.intent_id = a.intent_id WHERE a.owner_node = ? ORDER BY a.workspace_id, i.overlay_owner, a.target_db, a.intent_id LIMIT ?",
            {node, MAX_DESIRED_SLOTS + 1})
        if query_error or not rows then return storage(query_error, "list applied migration databases") end
        if #rows > MAX_DESIRED_SLOTS then return failure("CAPACITY", "applied migration databases exceed their bound") end
        local databases: {Object} = {}
        local seen: {[string]: string} = {}
        local schemas: {[string]: {[string]: boolean}} = {}
        for _, row in ipairs(rows) do
            local workspace_id, overlay_owner = id(row.workspace_id), id(row.overlay_owner)
            local work, work_error = migration_work.decode(row.migration_work_bytes, row.migration_work_digest)
            if not workspace_id or not overlay_owner or not work then
                return failure("INTERNAL", tostring(work_error or "applied migration database is malformed"))
            end
            local database, database_error = migration_work.database(work, row.target_db)
            if not database then return failure("INTERNAL", tostring(database_error)) end
            local key = workspace_id .. "\n" .. overlay_owner .. "\n" .. database.target_db
            local prior = seen[key]
            if prior and prior ~= database.database_id then
                return failure("CONFLICT", "applied migration database evidence differs: " .. database.target_db)
            end
            schemas[key] = schemas[key] or {}
            for _, migration in ipairs(work.migrations) do
                if migration.target_db == database.target_db then schemas[key][migration.id] = true end
            end
            if not prior then
                seen[key] = database.database_id
                databases[#databases + 1] = {workspace_id = workspace_id, overlay_owner = overlay_owner,
                    target_db = database.target_db, database_id = database.database_id}
            end
        end
        for _, database in ipairs(databases) do
            local key = tostring(database.workspace_id) .. "\n" .. tostring(database.overlay_owner) .. "\n" .. tostring(database.target_db)
            local ids: {string} = {}
            for migration_id in pairs(schemas[key]) do ids[#ids + 1] = migration_id end
            table.sort(ids)
            database.migrations = ids
        end
        return transaction.success({databases = databases}, false)
    end)
    return transaction.release(db, "governance activation", result)
end
M.failure = failure
M.id = id
M.count = count
M.unknown = unknown
M.authorization_digest = authorization_digest
M.decode_intent = decode_intent
M.decode_slot = decode_slot
M.MAX_INTENTS = MAX_INTENTS
M.storage = storage
M.one = one
M.load = load
M.slot = slot
M.view = view
M.MAX_DESIRED_SLOTS = MAX_DESIRED_SLOTS
return M
