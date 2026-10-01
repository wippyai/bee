-- MIT. Destination-owned approval-lease ledger. A lease is a person-granted,
-- bounded ceiling over capability grants; `use` atomically checks it and
-- records the proof of one authorized apply. This module does not resolve,
-- approve, apply or contact another owner.
local sql = require("sql")
local hash = require("hash")
local bounds = require("bounds")
local canonical = require("canonical")
local json = require("json")
local database = require("database")
local transaction = require("transaction")
local migrations = require("migrations")
local identity_migration = require("identity_migration")
local lease_model = require("lease_model")
local capability_model = require("capability_model")

local M = {}
local MAX_LEASES = 256
local MAX_RECEIPTS = 1024
local MAX_ENVELOPE_BYTES = 65536
local MAX_REVISION = 9007199254740991
local MAX_TTL_SECONDS = 86400 * 30

type Result = transaction.Result
type Store = {db: sql.DB, node: string, workspace: string, closed: boolean}
type Scope = {node: string, workspace: string}
type Object = {[string]: unknown}
type Request = Object
type GetRequest = {operation: "get", lease_id: string}
type ListRequest = {operation: "list", target: string?, history: boolean?}
type GrantRequest = {operation: "grant", idempotency_key: string, lease_id: string, target: string, envelope: {unknown}, source_approval_id: string, source_approval_proposal_digest: string, source_approval_owner_incarnation: integer, granted_by: string, ttl_seconds: integer?, max_applies: integer?}
type UseRequest = {operation: "use", idempotency_key: string, lease_id: string, expected_revision: integer, intent_id: string, proposal_capabilities: {unknown}}
type RevokeRequest = {operation: "revoke", idempotency_key: string, lease_id: string, expected_revision: integer, revoked_by: string}
type ReserveRequest = {lease_id: string, expected_revision: integer, intent_id: string, proposal_capabilities: {unknown}}
type DecodedRequest = GetRequest | ListRequest | GrantRequest | UseRequest | RevokeRequest
type Mutation = GrantRequest | UseRequest | RevokeRequest


local NOW = "strftime('%Y-%m-%dT%H:%M:%fZ', 'now')"

local function failure(code: string, message: string, value: unknown?): Result
    return transaction.failure(code, message, value)
end
local function storage(err: unknown, action: string): Result
    if transaction.busy(err) then return transaction.storage_failure("governance lease database is busy") end
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
local function hex_digest(value: unknown): string?
    if type(value) ~= "string" or #value ~= 64 or not value:match("^[0-9a-f]+$") then return nil end
    return value
end
local function digest(value: string): string?
    local result, err = hash.sha256(value)
    if err or not result then return nil end
    return result
end
local function one(tx: sql.Transaction, statement: string, params: {unknown}, label: string): (Object?, Result?)
    local rows, err = tx:query(statement, params)
    if err or not rows then return nil, storage(err, "read " .. label) end
    if #rows > 1 then return nil, failure("INTERNAL", label .. " rows are duplicated") end
    return rows[1], nil
end
local function cas(result: unknown, err: unknown, action: string): Result?
    if err then return storage(err, action) end
    local value = bounds.object(result)
    if not value or value.rows_affected ~= 1 then return failure("CONFLICT", action .. " lost its revision fence") end
    return nil
end
local function unknown(value: Object, allowed: {string}): string?
    return bounds.fields(value, allowed)
end
local function request_digest(value: Request): (string?, Result?)
    local encoded = canonical.encode(value, 4194304)
    if not encoded then return nil, failure("INVALID", "lease request cannot be measured") end
    local measured = digest(encoded)
    if not measured then return nil, failure("INTERNAL", "measure lease request") end
    return measured, nil
end

type Lease = {
    owner_node: string,
    workspace_id: string,
    lease_id: string,
    target: string,
    envelope_bytes: string,
    envelope_digest: string,
    source_approval_id: string,
    source_approval_proposal_digest: string,
    source_approval_owner_incarnation: integer,
    granted_by: string,
    created_at: string,
    expires_at: string?,
    max_applies: integer?,
    applies_used: integer,
    revision: integer,
    state: string,
    revoked_by: string?,
    revoked_at: string?,
    past_expiry: integer
}
local function decode_lease(row: Object): (Lease?, Result?)
    local owner_node = row.owner_node
    if type(owner_node) ~= "string" then return nil, failure("INTERNAL", "lease is malformed") end
    local workspace_id = row.workspace_id
    if type(workspace_id) ~= "string" then return nil, failure("INTERNAL", "lease is malformed") end
    local lease_id = row.lease_id
    if type(lease_id) ~= "string" then return nil, failure("INTERNAL", "lease is malformed") end
    local target = row.target
    if type(target) ~= "string" then return nil, failure("INTERNAL", "lease is malformed") end
    local envelope_bytes = row.envelope_bytes
    if type(envelope_bytes) ~= "string" then return nil, failure("INTERNAL", "lease is malformed") end
    local envelope_digest = row.envelope_digest
    if type(envelope_digest) ~= "string" then return nil, failure("INTERNAL", "lease is malformed") end
    local source_approval_id = row.source_approval_id
    if type(source_approval_id) ~= "string" then return nil, failure("INTERNAL", "lease is malformed") end
    local source_approval_proposal_digest = row.source_approval_proposal_digest
    if type(source_approval_proposal_digest) ~= "string" then return nil, failure("INTERNAL", "lease is malformed") end
    local source_approval_owner_incarnation = count(row.source_approval_owner_incarnation, false)
    if source_approval_owner_incarnation == nil then return nil, failure("INTERNAL", "lease is malformed") end
    local granted_by = row.granted_by
    if type(granted_by) ~= "string" then return nil, failure("INTERNAL", "lease is malformed") end
    local created_at = row.created_at
    if type(created_at) ~= "string" then return nil, failure("INTERNAL", "lease is malformed") end
    local expires_at: string? = nil
    if row.expires_at ~= nil then
        local value = row.expires_at
        if type(value) ~= "string" then return nil, failure("INTERNAL", "lease is malformed") end
        expires_at = value
    end
    local max_applies: integer? = nil
    if row.max_applies ~= nil then
        max_applies = count(row.max_applies, false)
        if max_applies == nil then return nil, failure("INTERNAL", "lease is malformed") end
    end
    local applies_used = count(row.applies_used, false)
    if applies_used == nil then return nil, failure("INTERNAL", "lease is malformed") end
    local revision = count(row.revision, false)
    if revision == nil then return nil, failure("INTERNAL", "lease is malformed") end
    local state = row.state
    if type(state) ~= "string" then return nil, failure("INTERNAL", "lease is malformed") end
    local revoked_by: string? = nil
    if row.revoked_by ~= nil then
        local value = row.revoked_by
        if type(value) ~= "string" then return nil, failure("INTERNAL", "lease is malformed") end
        revoked_by = value
    end
    local revoked_at: string? = nil
    if row.revoked_at ~= nil then
        local value = row.revoked_at
        if type(value) ~= "string" then return nil, failure("INTERNAL", "lease is malformed") end
        revoked_at = value
    end
    local past_expiry = count(row.past_expiry, false)
    if past_expiry == nil then return nil, failure("INTERNAL", "lease is malformed") end
    return {
        owner_node = owner_node,
        workspace_id = workspace_id,
        lease_id = lease_id,
        target = target,
        envelope_bytes = envelope_bytes,
        envelope_digest = envelope_digest,
        source_approval_id = source_approval_id,
        source_approval_proposal_digest = source_approval_proposal_digest,
        source_approval_owner_incarnation = source_approval_owner_incarnation,
        granted_by = granted_by,
        created_at = created_at,
        expires_at = expires_at,
        max_applies = max_applies,
        applies_used = applies_used,
        revision = revision,
        state = state,
        revoked_by = revoked_by,
        revoked_at = revoked_at,
        past_expiry = past_expiry
    }, nil
end

local function load(tx: sql.Transaction, store: Scope, lease_id: string): (Lease?, Result?)
    local row, err = one(tx, "SELECT *, (expires_at IS NOT NULL AND expires_at <= " .. NOW .. ") AS past_expiry FROM bee_governance_leases WHERE owner_node = ? AND workspace_id = ? AND lease_id = ?",
        {store.node, store.workspace, lease_id}, "lease")
    if err or not row then return nil, err end
    return decode_lease(row)
end

-- The effective state folds expiry and exhaustion into the stored
-- active/revoked flag so every reader sees the same answer.
local function effective(row: Object): string
    if row.state == "revoked" then return "revoked" end
    if tonumber(row.past_expiry) == 1 or row.past_expiry == true then return "expired" end
    local max = row.max_applies
    if type(max) == "number" and (row.applies_used) >= max then return "exhausted" end
    return "active"
end

local function view(store: Scope, row: Object): Object
    local envelope = type(row.envelope_bytes) == "string" and json.decode(row.envelope_bytes) or nil
    return {owner_node = store.node, workspace_id = store.workspace, lease_id = row.lease_id, target = row.target,
        envelope = envelope, envelope_digest = row.envelope_digest, source_approval_id = row.source_approval_id,
        source_approval_proposal_digest = row.source_approval_proposal_digest,
        source_approval_owner_incarnation = row.source_approval_owner_incarnation,
        granted_by = row.granted_by, created_at = row.created_at, expires_at = row.expires_at,
        max_applies = row.max_applies, applies_used = row.applies_used, revision = row.revision,
        state = effective(row), revoked_by = row.revoked_by, revoked_at = row.revoked_at}
end

local function replay(store: Store, tx: sql.Transaction, actor: string, input: Mutation, measured: string): Result?
    local key = id(input.idempotency_key)
    if not key then return failure("INVALID", "idempotency_key is required") end
    local row, err = one(tx, "SELECT actor_id, operation, request_digest, lease_id, result_json FROM bee_governance_lease_receipts WHERE owner_node = ? AND workspace_id = ? AND idempotency_key = ?",
        {store.node, store.workspace, key}, "lease receipt")
    if err or not row then return err end
    if row.actor_id ~= actor then return failure("DENIED", "idempotency key belongs to another actor") end
    if row.operation ~= input.operation or row.request_digest ~= measured then
        return failure("CONFLICT", "idempotency key was used by a different lease request")
    end
    local receipt_lease = id(row.lease_id)
    if not receipt_lease then return failure("INTERNAL", "lease receipt has no lease") end
    local current, current_error = load(tx, store, receipt_lease)
    if current_error or not current then return current_error or failure("INTERNAL", "lease receipt has no lease") end
    local reply = view(store, current)
    if type(row.result_json) == "string" then
        local saved = bounds.object(json.decode(row.result_json))
        if saved then
            reply.fenced_intents, reply.started_effects = saved.fenced_intents, saved.started_effects
        end
    end
    return transaction.success(reply, true)
end
local function save_receipt(store: Store, tx: sql.Transaction, actor: string, input: Mutation, measured: string, row: Object, result: Object?): Result?
    local total, total_error = one(tx, "SELECT COUNT(*) AS count FROM bee_governance_lease_receipts WHERE owner_node = ? AND workspace_id = ?",
        {store.node, store.workspace}, "lease receipt count")
    if total_error or not total then return total_error or failure("INTERNAL", "lease receipt count is missing") end
    local receipts = count(total.count, false)
    if not receipts then return failure("INTERNAL", "lease receipt count is corrupt") end
    if receipts >= MAX_RECEIPTS then return failure("CAPACITY_EXHAUSTED", "lease receipt capacity is exhausted") end
    local _, err = tx:execute("INSERT INTO bee_governance_lease_receipts (owner_node, workspace_id, idempotency_key, actor_id, operation, request_digest, lease_id, result_revision, result_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        {store.node, store.workspace, input.idempotency_key, actor, input.operation, measured, row.lease_id, row.revision,
            result and json.encode(result) or sql.NULL})
    if err then return storage(err, "record lease receipt") end
    return nil
end

local function decode(raw: unknown): (DecodedRequest?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "lease request must be an object" end
    local operation = value.operation
    if operation == "get" then
        local extra = unknown(value, {"operation", "lease_id"})
        local lease_id = id(value.lease_id)
        if extra or not lease_id then return nil, extra or "lease_id is required" end
        return {operation = operation, lease_id = lease_id}, nil
    end
    if operation == "list" then
        local extra = unknown(value, {"operation", "target", "history"})
        if extra then return nil, extra end
        local target = value.target == nil and nil or id(value.target)
        if value.target ~= nil and not target then return nil, "lease target is invalid" end
        local history: boolean? = nil
        if value.history ~= nil then
            local decoded = value.history
            if type(decoded) ~= "boolean" then return nil, "history is a boolean" end
            history = decoded
        end
        return {operation = operation, target = target, history = history}, nil
    end
    local key = id(value.idempotency_key)
    if not key then return nil, "idempotency_key is required" end
    if operation == "grant" then
        local extra = unknown(value, {"operation", "idempotency_key", "lease_id", "target", "envelope",
            "source_approval_id", "source_approval_proposal_digest", "source_approval_owner_incarnation",
            "granted_by", "ttl_seconds", "max_applies"})
        if extra then return nil, extra end
        local lease_id, target = id(value.lease_id), id(value.target)
        local approval, approval_digest = id(value.source_approval_id), hex_digest(value.source_approval_proposal_digest)
        local incarnation = count(value.source_approval_owner_incarnation, true)
        local granted_by = id(value.granted_by)
        local envelope = bounds.dense_list(value.envelope, lease_model.MAX_ENVELOPE, "lease envelope")
        local ttl = value.ttl_seconds == nil and nil or count(value.ttl_seconds, true)
        local max = value.max_applies == nil and nil or count(value.max_applies, true)
        if not lease_id or not target or not approval or not approval_digest or not incarnation or not granted_by
            or not envelope or #envelope == 0 then return nil, "lease grant identity is invalid" end
        if (value.ttl_seconds ~= nil and (not ttl or ttl > MAX_TTL_SECONDS))
            or (value.max_applies ~= nil and not max) then return nil, "lease bounds are invalid" end
        if not ttl and not max then return nil, "a lease requires an expiry, a use limit, or both" end
        return {operation = operation, idempotency_key = key, lease_id = lease_id, target = target,
            envelope = envelope, source_approval_id = approval, source_approval_proposal_digest = approval_digest,
            source_approval_owner_incarnation = incarnation, granted_by = granted_by,
            ttl_seconds = ttl, max_applies = max}, nil
    end
    local lease_id, expected = id(value.lease_id), count(value.expected_revision, true)
    if not lease_id or not expected then return nil, "lease_id and expected_revision are required" end
    if operation == "use" then
        local extra = unknown(value, {"operation", "idempotency_key", "lease_id", "expected_revision",
            "intent_id", "proposal_capabilities"})
        if extra then return nil, extra end
        local intent_id = id(value.intent_id)
        local proposed = bounds.dense_list(value.proposal_capabilities, lease_model.MAX_ENVELOPE, "proposed capabilities")
        if not intent_id or not proposed or #proposed == 0 then
            return nil, "lease use needs intent_id and proposal_capabilities"
        end
        return {operation = operation, idempotency_key = key, lease_id = lease_id, expected_revision = expected,
            intent_id = intent_id, proposal_capabilities = proposed}, nil
    end
    if operation == "revoke" then
        local extra = unknown(value, {"operation", "idempotency_key", "lease_id", "expected_revision", "revoked_by"})
        local revoked_by = id(value.revoked_by)
        if extra or not revoked_by then return nil, extra or "revoked_by is required" end
        return {operation = operation, idempotency_key = key, lease_id = lease_id,
            expected_revision = expected, revoked_by = revoked_by}, nil
    end
    return nil, "unsupported lease operation"
end

local function grant(store: Store, actor: string, input: GrantRequest): Result
    local measured, measure_error = request_digest(input)
    if not measured then return assert(measure_error) end
    local envelope_bytes = canonical.encode(input.envelope, MAX_ENVELOPE_BYTES)
    local envelope_digest = envelope_bytes and digest(envelope_bytes)
    if not envelope_bytes or not envelope_digest then return failure("INVALID", "lease envelope is too large or unmeasurable") end
    return transaction.write(store.db, "governance lease", function(tx: sql.Transaction): Result
        local already = replay(store, tx, actor, input, measured)
        if already then return already end
        local total, total_error = one(tx, "SELECT COUNT(*) AS count FROM bee_governance_leases WHERE owner_node = ? AND workspace_id = ? AND state = 'active' AND (expires_at IS NULL OR expires_at > " .. NOW .. ") AND (max_applies IS NULL OR applies_used < max_applies)",
            {store.node, store.workspace}, "lease count")
        if total_error or not total then return total_error or failure("INTERNAL", "lease count is missing") end
        local leases = count(total.count, false)
        if not leases then return failure("INTERNAL", "lease count is corrupt") end
        if leases >= MAX_LEASES then return failure("CAPACITY_EXHAUSTED", "lease capacity is exhausted") end
        local expires: string? = nil
        if input.ttl_seconds ~= nil then
            local row, err = one(tx, "SELECT strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '+' || ? || ' seconds') AS at",
                {input.ttl_seconds}, "lease expiry")
            if err or not row then return err or failure("INTERNAL", "compute lease expiry") end
            local at = row.at
            if type(at) ~= "string" then return failure("INTERNAL", "lease expiry is malformed") end
            expires = at
        end
        local _, insert_error = tx:execute("INSERT INTO bee_governance_leases (owner_node, workspace_id, lease_id, target, envelope_bytes, envelope_digest, source_approval_id, source_approval_proposal_digest, source_approval_owner_incarnation, granted_by, created_at, expires_at, max_applies, applies_used, revision, state) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, " .. NOW .. ", ?, ?, 0, 1, 'active')",
            {store.node, store.workspace, input.lease_id, input.target, envelope_bytes, envelope_digest,
                input.source_approval_id, input.source_approval_proposal_digest,
                input.source_approval_owner_incarnation, input.granted_by, expires or sql.NULL, input.max_applies or sql.NULL})
        if insert_error then
            local existing = one(tx, "SELECT lease_id FROM bee_governance_leases WHERE owner_node = ? AND workspace_id = ? AND source_approval_id = ?",
                {store.node, store.workspace, input.source_approval_id}, "lease by approval")
            if existing then return failure("CONFLICT", "approval already granted a lease") end
            return storage(insert_error, "grant lease")
        end
        local row, row_error = load(tx, store, input.lease_id)
        if row_error or not row then return row_error or failure("INTERNAL", "read granted lease") end
        local receipt_error = save_receipt(store, tx, actor, input, measured, row)
        if receipt_error then return receipt_error end
        return transaction.success(view(store, row), false)
    end)
end

-- reserve_in: check one lease and record the proof of the intent it
-- authorizes, inside the caller's transaction. Containment is checked here,
-- in the same transaction that counts the use, so no earlier lookup can go
-- stale. The approval identity the intent will carry is copied from the lease.
function M.reserve_in(tx: sql.Transaction, store: Scope, input: ReserveRequest): (Lease?, Result?)
    local row, row_error = load(tx, store, input.lease_id)
    if row_error or not row then return nil, row_error or failure("NOT_FOUND", "lease does not exist") end
    if input.expected_revision ~= row.revision then return nil, failure("CONFLICT", "expected_revision does not match lease") end
    local state = effective(row)
    if state ~= "active" then return nil, failure("DENIED", "lease is " .. state) end
    local envelope = capability_model.grants((json.decode(row.envelope_bytes)))
    local proposed = capability_model.grants(input.proposal_capabilities)
    if not envelope or not proposed or not lease_model.covers(envelope, proposed) then
        return nil, failure("DENIED", "proposal is outside the lease envelope")
    end
    local snapshot = canonical.encode(input.proposal_capabilities, MAX_ENVELOPE_BYTES)
    local snapshot_digest = snapshot and digest(snapshot)
    if not snapshot or not snapshot_digest then return nil, failure("INVALID", "proposed capabilities are too large or unmeasurable") end
    local next_revision = (row.revision) + 1
    local updated, err = tx:execute("UPDATE bee_governance_leases SET applies_used = applies_used + 1, revision = ? WHERE owner_node = ? AND workspace_id = ? AND lease_id = ? AND revision = ? AND state = 'active'",
        {next_revision, store.node, store.workspace, row.lease_id, row.revision})
    local update_error = cas(updated, err, "use lease")
    if update_error then return nil, update_error end
    local _, use_error = tx:execute("INSERT INTO bee_governance_lease_uses (owner_node, workspace_id, lease_id, intent_id, approval_id, approval_proposal_digest, proposal_snapshot_bytes, proposal_snapshot_digest, state, applied_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'reserved', " .. NOW .. ")",
        {store.node, store.workspace, row.lease_id, input.intent_id, row.source_approval_id,
            row.source_approval_proposal_digest, snapshot, snapshot_digest})
    if use_error then return nil, failure("CONFLICT", "an intent takes one lease authorization") end
    return load(tx, store, row.lease_id)
end

-- admit_in: the effect of a lease-authorized intent starts. It is refused
-- once the lease was revoked or expired, and refused when the recorded proof
-- names another approval than the intent carries. Admission and revocation
-- are both writes to this store, so exactly one of them lands first.
function M.admit_in(tx: sql.Transaction, store: Scope, intent_id: string, approval_id: unknown, approval_digest: unknown): Result?
    local use, use_error = one(tx, "SELECT * FROM bee_governance_lease_uses WHERE owner_node = ? AND workspace_id = ? AND intent_id = ?",
        {store.node, store.workspace, intent_id}, "lease use")
    if use_error then return use_error end
    if not use then return failure("CONFLICT", "the intent has no lease authorization") end
    if use.approval_id ~= approval_id or use.approval_proposal_digest ~= approval_digest then
        return failure("CONFLICT", "lease proof does not match the intent's authorization")
    end
    if use.state == "admitted" then return nil end
    if use.state == "fenced" then return failure("DENIED", "lease was revoked before the effect started") end
    local lease_id = id(use.lease_id)
    if not lease_id then return failure("INTERNAL", "lease use has no lease") end
    local lease, lease_error = load(tx, store, lease_id)
    if lease_error or not lease then return lease_error or failure("INTERNAL", "lease use has no lease") end
    local state = effective(lease)
    if lease.state == "revoked" or tonumber(lease.past_expiry) == 1 or lease.past_expiry == true then
        return failure("DENIED", "lease is " .. (lease.state == "revoked" and "revoked" or "expired") .. "; the effect is not admitted")
    end
    local updated, err = tx:execute("UPDATE bee_governance_lease_uses SET state = 'admitted', admitted_at = " .. NOW .. " WHERE owner_node = ? AND workspace_id = ? AND intent_id = ? AND state = 'reserved'",
        {store.node, store.workspace, intent_id})
    return cas(updated, err, "admit lease use")
end

local function use(store: Store, actor: string, input: UseRequest): Result
    local measured, measure_error = request_digest(input)
    if not measured then return assert(measure_error) end
    return transaction.write(store.db, "governance lease", function(tx: sql.Transaction): Result
        local already = replay(store, tx, actor, input, measured)
        if already then return already end
        local changed, reserve_error = M.reserve_in(tx, store, input)
        if reserve_error or not changed then return reserve_error or failure("INTERNAL", "read used lease") end
        local receipt_error = save_receipt(store, tx, actor, input, measured, changed)
        if receipt_error then return receipt_error end
        return transaction.success(view(store, changed), false)
    end)
end

local function revoke(store: Store, actor: string, input: RevokeRequest): Result
    local measured, measure_error = request_digest(input)
    if not measured then return assert(measure_error) end
    return transaction.write(store.db, "governance lease", function(tx: sql.Transaction): Result
        local already = replay(store, tx, actor, input, measured)
        if already then return already end
        local row, row_error = load(tx, store, input.lease_id)
        if row_error or not row then return row_error or failure("NOT_FOUND", "lease does not exist") end
        if input.expected_revision ~= row.revision then return failure("CONFLICT", "expected_revision does not match lease") end
        if row.state == "revoked" then return failure("CONFLICT", "lease is already revoked") end
        local next_revision = (row.revision) + 1
        local updated, err = tx:execute("UPDATE bee_governance_leases SET state = 'revoked', revoked_by = ?, revoked_at = " .. NOW .. ", revision = ? WHERE owner_node = ? AND workspace_id = ? AND lease_id = ? AND revision = ? AND state = 'active'",
            {input.revoked_by, next_revision, store.node, store.workspace, row.lease_id, row.revision})
        local update_error = cas(updated, err, "revoke lease")
        if update_error then return update_error end
        -- A reservation whose effect has not started is fenced; one whose
        -- effect was admitted first is reported as started.
        local fenced, fenced_error = tx:query("SELECT intent_id FROM bee_governance_lease_uses WHERE owner_node = ? AND workspace_id = ? AND lease_id = ? AND state = 'reserved' ORDER BY intent_id",
            {store.node, store.workspace, row.lease_id})
        if fenced_error or not fenced then return storage(fenced_error, "read reserved lease uses") end
        local _, fence_error = tx:execute("UPDATE bee_governance_lease_uses SET state = 'fenced' WHERE owner_node = ? AND workspace_id = ? AND lease_id = ? AND state = 'reserved'",
            {store.node, store.workspace, row.lease_id})
        if fence_error then return storage(fence_error, "fence lease uses") end
        local started, started_error = tx:query("SELECT intent_id FROM bee_governance_lease_uses WHERE owner_node = ? AND workspace_id = ? AND lease_id = ? AND state = 'admitted' ORDER BY intent_id",
            {store.node, store.workspace, row.lease_id})
        if started_error or not started then return storage(started_error, "read admitted lease uses") end
        local changed, changed_error = load(tx, store, row.lease_id)
        if changed_error or not changed then return changed_error or failure("INTERNAL", "read revoked lease") end
        local fenced_intents: {unknown} = {}
        for _, item in ipairs(fenced) do fenced_intents[#fenced_intents + 1] = item.intent_id end
        local started_effects: {unknown} = {}
        for _, item in ipairs(started) do started_effects[#started_effects + 1] = item.intent_id end
        local receipt_error = save_receipt(store, tx, actor, input, measured, changed,
            {fenced_intents = fenced_intents, started_effects = started_effects})
        if receipt_error then return receipt_error end
        local reply = view(store, changed)
        reply.fenced_intents, reply.started_effects = fenced_intents, started_effects
        return transaction.success(reply, false)
    end)
end

function M.get(store: Store, lease_raw: unknown): Result
    local lease_id = id(lease_raw)
    if not lease_id then return failure("INVALID", "lease_id is required") end
    return transaction.read(store.db, "governance lease", function(tx: sql.Transaction): Result
        local row, err = load(tx, store, lease_id)
        if err or not row then return err or failure("NOT_FOUND", "lease does not exist") end
        return transaction.success(view(store, row), false)
    end)
end

-- The leases for one target (or every lease of the workspace), newest first.
-- Each row carries its use records so a reader sees which intents it authorized.
-- A lease stays listed, and revocable, while it can still authorize or while
-- a reservation of it awaits admission: revocation may still fence that one.
local RESERVED = "EXISTS (SELECT 1 FROM bee_governance_lease_uses u WHERE u.owner_node = bee_governance_leases.owner_node AND u.workspace_id = bee_governance_leases.workspace_id AND u.lease_id = bee_governance_leases.lease_id AND u.state = 'reserved')"
local ACTIVE = "state = 'active' AND (((expires_at IS NULL OR expires_at > " .. NOW .. ") AND (max_applies IS NULL OR applies_used < max_applies)) OR " .. RESERVED .. ")"
local MAX_HISTORY = 64

-- list: the leases able to authorize something, newest first, so a full
-- history never crowds out an active lease. history adds the most recent
-- ended leases instead, bounded separately.
function M.list(store: Store, target: string?, history: boolean?): Result
    return transaction.read(store.db, "governance lease", function(tx: sql.Transaction): Result
        local filter = history and "NOT (" .. ACTIVE .. ")" or ACTIVE
        local limit = history and MAX_HISTORY or MAX_LEASES
        local statement = "SELECT *, (expires_at IS NOT NULL AND expires_at <= " .. NOW .. ") AS past_expiry FROM bee_governance_leases WHERE owner_node = ? AND workspace_id = ? AND " .. filter
        local params: {unknown} = {store.node, store.workspace}
        if target then statement = statement .. " AND target = ?"; params[#params + 1] = target end
        statement = statement .. " ORDER BY created_at DESC, lease_id LIMIT ?"
        params[#params + 1] = limit
        local rows, err = tx:query(statement, params)
        if err or not rows then return storage(err, "list leases") end
        local leases: {Object} = {}
        for _, row in ipairs(rows) do
            local item = view(store, row)
            local uses, use_error = tx:query("SELECT intent_id, state, proposal_snapshot_digest, applied_at FROM bee_governance_lease_uses WHERE owner_node = ? AND workspace_id = ? AND lease_id = ? ORDER BY applied_at, intent_id",
                {store.node, store.workspace, row.lease_id})
            if use_error or not uses then return storage(use_error, "list lease uses") end
            item.uses = uses
            leases[#leases + 1] = item
        end
        return transaction.success({leases = leases}, false)
    end)
end

-- The lease one approval granted, if any.
function M.by_approval(store: Store, approval_raw: unknown): Result
    local approval_id = id(approval_raw)
    if not approval_id then return failure("INVALID", "approval_id is required") end
    return transaction.read(store.db, "governance lease", function(tx: sql.Transaction): Result
        local row, err = one(tx, "SELECT *, (expires_at IS NOT NULL AND expires_at <= " .. NOW .. ") AS past_expiry FROM bee_governance_leases WHERE owner_node = ? AND workspace_id = ? AND source_approval_id = ?",
            {store.node, store.workspace, approval_id}, "lease by approval")
        if err then return err end
        if not row then return failure("NOT_FOUND", "no lease was granted from this approval") end
        return transaction.success(view(store, row), false)
    end)
end

-- The one lease currently able to authorize a proposal for this target.
function M.find_active(store: Store, target: string, proposed: {unknown}): Object?
    local listed = M.list(store, target)
    if not listed.ok then return nil end
    local value = bounds.object(listed.value)
    for _, raw in ipairs((value and value.leases or {})) do
        local lease = bounds.object(raw)
        if lease and lease.state == "active" and type(lease.envelope) == "table"
            and lease_model.covers(lease.envelope, proposed) then
            return lease
        end
    end
    return nil
end

-- Whether a lease already authorized this activation intent. Recovery uses it
-- to finish a lease-authorized intent locally instead of asking Approvals.
function M.authorized(store: Store, intent_raw: unknown): (Object?, string?)
    local intent_id = id(intent_raw)
    if not intent_id then return nil, "intent_id is required" end
    local result = transaction.read(store.db, "governance lease", function(tx: sql.Transaction): Result
        local row, err = one(tx, "SELECT lease_id, state, approval_id, approval_proposal_digest, proposal_snapshot_digest FROM bee_governance_lease_uses WHERE owner_node = ? AND workspace_id = ? AND intent_id = ?",
            {store.node, store.workspace, intent_id}, "lease use")
        if err then return err end
        return transaction.success(row or {}, false)
    end)
    if not result.ok then return nil, tostring(result.message) end
    local value = bounds.object(result.value)
    if value and next(value) == nil then return nil, nil end
    return value, nil
end

function M.call(store: Store, actor_raw: string, raw: unknown): Result
    if store.closed then return failure("CLOSED", "governance lease store is closed") end
    local actor = id(actor_raw)
    if not actor then return failure("INVALID", "lease actor is invalid") end
    local input, decode_error = decode(raw)
    if not input then return failure("INVALID", decode_error or "invalid lease request") end
    if input.operation == "get" then return M.get(store, input.lease_id)
    elseif input.operation == "list" then return M.list(store, input.target, input.history == true)
    elseif input.operation == "grant" then return grant(store, actor, input)
    elseif input.operation == "use" then return use(store, actor, input)
    elseif input.operation == "revoke" then return revoke(store, actor, input)
    end
    return failure("INVALID", "unsupported lease operation")
end

function M.close(store: Store): (boolean, string?)
    if store.closed then return true, nil end
    store.closed = true
    local released, err = store.db:release()
    if released ~= true or err then return false, "close governance lease database" end
    return true, nil
end

function M.open(resource: string, node_raw: string, workspace_raw: string): (Store?, string?)
    if type(resource) ~= "string" or resource == "" then return nil, "governance lease database is not linked" end
    local node, workspace = id(node_raw), id(workspace_raw)
    if not node or not workspace then return nil, "governance lease store identity is invalid" end
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
