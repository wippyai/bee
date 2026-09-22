-- MIT. Durable destination-owned governance plan store.
-- It receives measured bytes and records local review/selection intent. It
-- never resolves, publishes, executes, activates, or contacts Approvals.
local sql = require("sql")
local hash = require("hash")
local bounds = require("bounds")
local canonical = require("canonical")
local database = require("database")
local transaction = require("transaction")
local migrations = require("migrations")
local protocol = require("plan_protocol")

local M = {}
local MAX_PLANS = 256
local MAX_RECEIPTS = 1024
local MAX_REVISION = 9007199254740991
local MAX_REQUEST_BYTES = 1441792

type Result = transaction.Result
type Blob = {bytes: string, digest: string}
type Identity = {operation: string, source_node: string, source_workspace: string, version: string}
type Mutation = {operation: string, source_node: string, source_workspace: string, version: string,
    expected_revision: integer, idempotency_key: string}
type StageRequest = {operation: string, source_node: string, source_workspace: string, version: string,
    expected_revision: integer, idempotency_key: string, candidate: Blob, artifact: Blob, preflight: Blob}
type ReviewRequest = {operation: string, source_node: string, source_workspace: string, version: string,
    expected_revision: integer, idempotency_key: string, review_status: "accepted" | "rejected", review_reason: string}
type ApprovalRequest = {operation: string, source_node: string, source_workspace: string, version: string,
    expected_revision: integer, idempotency_key: string, approval_id: string,
    approval_plan_digest: string, approval_proposal_digest: string, approval_owner_incarnation: integer}
type Store = {db: sql.DB, node: string, workspace: string, closed: boolean}
type Row = {source_node: string, source_workspace: string, version: string,
    candidate: Blob, artifact: Blob, preflight: Blob, revision: integer, status: string,
    plan_digest: string, review_status: string?, review_reason: string?, reviewer_id: string?, approval_id: string?,
    approval_plan_digest: string?, approval_proposal_digest: string?, approval_owner_incarnation: integer?,
    selected: boolean, selection_revision: integer?}

local function failure(code: string, message: string, value: unknown?): Result
    return transaction.failure(code, message, value)
end

local function storage(err: unknown, action: string): Result
    if transaction.busy(err) then return transaction.storage_failure("governance plan database is busy") end
    return failure("INTERNAL", action)
end

local function integer(value: unknown): integer?
    if type(value) ~= "number" or value ~= math.floor(value) or value < 0 or value > MAX_REVISION then return nil end
    return math.floor(value)
end

local function digest(value: string): string?
    local measured, err = hash.sha256(value)
    if err or not measured then return nil end
    return measured
end

local function checked_blob(value: Blob, label: string): Result?
    local actual = digest(value.bytes)
    if not actual or actual ~= value.digest then return failure("INVALID", label .. " digest does not match bytes") end
    return nil
end

local function plan_digest(store: Store, source_node: string, source_workspace: string, version: string, candidate: Blob, artifact: Blob, preflight: Blob): string?
    local encoded = canonical.encode({schema_revision = "bee.governance-plan@1", destination_node = store.node,
        destination_workspace = store.workspace, source_node = source_node, source_workspace = source_workspace,
        version = version, candidate_digest = candidate.digest, artifact_digest = artifact.digest,
        preflight_digest = preflight.digest})
    if not encoded then return nil end
    return digest(encoded)
end

local function request_digest(input: unknown): (string?, Result?)
    local encoded, err = canonical.encode(input, MAX_REQUEST_BYTES)
    if not encoded then return nil, failure("INVALID", "plan request cannot be measured") end
    local measured = digest(encoded)
    if not measured then return nil, failure("INTERNAL", "measure plan request") end
    return measured, nil
end

local function one(tx: sql.Transaction, statement: string, params: {unknown}, label: string): ({[string]: unknown}?, Result?)
    local rows, err = tx:query(statement, params)
    if err or not rows then return nil, storage(err, "read " .. label) end
    if #rows > 1 then return nil, failure("INTERNAL", label .. " rows are corrupt") end
    return rows[1], nil
end

local function plan_query(source_node: string, source_workspace: string, version: string): (string, {unknown})
    return "SELECT p.*, CASE WHEN s.version IS NULL THEN 0 ELSE 1 END AS selected, s.plan_revision AS selection_revision FROM bee_governance_plans p LEFT JOIN bee_governance_plan_slots s ON s.owner_node = p.owner_node AND s.workspace_id = p.workspace_id AND s.source_node = p.source_node AND s.source_workspace = p.source_workspace AND s.version = p.version WHERE p.owner_node = ? AND p.workspace_id = ? AND p.source_node = ? AND p.source_workspace = ? AND p.version = ?", {source_node, source_workspace, version}
end

local function decode_row(raw: {[string]: unknown}): (Row?, Result?)
    local source_node, source_workspace, version = bounds.id(raw.source_node), bounds.id(raw.source_workspace), bounds.id(raw.version)
    local revision = integer(raw.revision)
    if not source_node or not source_workspace or not version or not revision or revision < 1 then return nil, failure("INTERNAL", "governance plan identity is corrupt") end
    local function row_blob(bytes: unknown, measured: unknown, limit: integer, label: string): (Blob?, Result?)
        if type(bytes) ~= "string" or #bytes == 0 or #bytes > limit or type(measured) ~= "string" or #measured ~= 64 or not measured:match("^[0-9a-f]+$") then
            return nil, failure("INTERNAL", label .. " is corrupt")
        end
        local actual = digest(bytes)
        if not actual or actual ~= measured then return nil, failure("INTERNAL", label .. " digest is corrupt") end
        local result: Blob = {bytes = bytes, digest = measured :: string}
        return result, nil
    end
    local candidate, candidate_error = row_blob(raw.candidate_bytes, raw.candidate_digest, protocol.MAX_CANDIDATE_BYTES :: integer, "candidate")
    if not candidate then return nil, candidate_error end
    local artifact, artifact_error = row_blob(raw.artifact_bytes, raw.artifact_digest, protocol.MAX_ARTIFACT_BYTES :: integer, "artifact")
    if not artifact then return nil, artifact_error end
    local preflight, preflight_error = row_blob(raw.preflight_bytes, raw.preflight_digest, protocol.MAX_PREFLIGHT_BYTES :: integer, "preflight")
    if not preflight then return nil, preflight_error end
    local plan_digest_value = bounds.text(raw.plan_digest, 64)
    if not plan_digest_value or #plan_digest_value ~= 64 or not plan_digest_value:match("^[0-9a-f]+$") then return nil, failure("INTERNAL", "governance plan digest is corrupt") end
    local approval_plan_digest: string? = nil
    if raw.approval_digest ~= nil then
        approval_plan_digest = bounds.text(raw.approval_digest, 64)
        if not approval_plan_digest or #approval_plan_digest ~= 64 or not approval_plan_digest:match("^[0-9a-f]+$") then
            return nil, failure("INTERNAL", "governance approval plan digest is corrupt")
        end
    end
    local approval_proposal_digest: string? = nil
    if raw.approval_proposal_digest ~= nil then
        approval_proposal_digest = bounds.text(raw.approval_proposal_digest, 64)
        if not approval_proposal_digest or #approval_proposal_digest ~= 64 or not approval_proposal_digest:match("^[0-9a-f]+$") then
            return nil, failure("INTERNAL", "governance approval proposal digest is corrupt")
        end
    end
    local status = raw.status
    if status ~= "staged" and status ~= "reviewed" and status ~= "rejected" and status ~= "approval_bound" then return nil, failure("INTERNAL", "governance plan status is corrupt") end
    local selected = raw.selected == 1 or raw.selected == true
    local selection_revision: integer? = nil
    if selected then
        selection_revision = integer(raw.selection_revision)
        if not selection_revision or selection_revision < 1 then return nil, failure("INTERNAL", "governance selection revision is corrupt") end
    elseif raw.selection_revision ~= nil then return nil, failure("INTERNAL", "unselected governance plan has a selection revision") end
    local review_status: string? = nil
    if raw.review_status ~= nil then
        if raw.review_status ~= "accepted" and raw.review_status ~= "rejected" then return nil, failure("INTERNAL", "governance review status is corrupt") end
        review_status = raw.review_status :: string
    end
    local approval_owner_incarnation = integer(raw.approval_owner_incarnation)
    if status == "approval_bound" and (not approval_plan_digest or not approval_proposal_digest
        or not approval_owner_incarnation or approval_owner_incarnation < 1) then
        return nil, failure("INTERNAL", "bound governance approval identity is incomplete")
    end
    local verified_plan_digest = plan_digest_value :: string
    return {source_node = source_node, source_workspace = source_workspace, version = version,
        candidate = candidate :: Blob, artifact = artifact :: Blob, preflight = preflight :: Blob,
        plan_digest = verified_plan_digest, revision = revision, status = status :: string, review_status = review_status,
        review_reason = raw.review_reason :: string?, reviewer_id = raw.reviewer_id :: string?,
        approval_id = raw.approval_id :: string?, approval_plan_digest = approval_plan_digest,
        approval_proposal_digest = approval_proposal_digest,
        approval_owner_incarnation = approval_owner_incarnation, selected = selected,
        selection_revision = selection_revision}, nil
end

local function view(store: Store, row: Row, include_bytes: boolean): {[string]: unknown}
    local result: {[string]: unknown} = {owner_node = store.node, workspace_id = store.workspace,
        source_node = row.source_node, source_workspace = row.source_workspace, version = row.version,
        plan_digest = row.plan_digest,
        candidate_digest = row.candidate.digest, artifact_digest = row.artifact.digest,
        preflight_digest = row.preflight.digest, revision = row.revision, status = row.status,
        review_status = row.review_status, review_reason = row.review_reason, reviewer_id = row.reviewer_id,
        approval_id = row.approval_id, approval_plan_digest = row.approval_plan_digest,
        approval_proposal_digest = row.approval_proposal_digest,
        approval_owner_incarnation = row.approval_owner_incarnation, selected = row.selected,
        selection_revision = row.selection_revision}
    if include_bytes then
        result.candidate_bytes, result.artifact_bytes, result.preflight_bytes = row.candidate.bytes, row.artifact.bytes, row.preflight.bytes
    end
    return result
end

local function find(tx: sql.Transaction, store: Store, source_node: string, source_workspace: string, version: string): (Row?, Result?)
    local statement, tail = plan_query(source_node, source_workspace, version)
    local params = {store.node, store.workspace}
    for _, value in ipairs(tail) do params[#params + 1] = value end
    local rows, err = tx:query(statement, params)
    if err or not rows then return nil, storage(err, "read governance plan") end
    if #rows == 0 then return nil, nil end
    if #rows > 1 then return nil, failure("INTERNAL", "governance plan identity is duplicated") end
    local row, row_error = decode_row(rows[1])
    if not row then return nil, row_error end
    local expected = plan_digest(store, row.source_node, row.source_workspace, row.version, row.candidate, row.artifact, row.preflight)
    if not expected or expected ~= row.plan_digest then return nil, failure("INTERNAL", "governance plan digest is corrupt") end
    return row, nil
end

local function receipt(store: Store, tx: sql.Transaction, actor: string, input: Mutation, measured: string): (Result?, Result?)
    local rows, err = tx:query("SELECT actor_id, operation, request_digest, source_node, source_workspace, version, result_revision FROM bee_governance_plan_receipts WHERE owner_node = ? AND workspace_id = ? AND idempotency_key = ?", {store.node, store.workspace, input.idempotency_key})
    if err or not rows then return nil, storage(err, "read governance plan receipt") end
    if #rows == 0 then return nil, nil end
    local row = rows[1]
    if row.actor_id ~= actor then return nil, failure("DENIED", "idempotency key belongs to another actor") end
    if row.operation ~= input.operation or row.request_digest ~= measured or row.version ~= input.version or row.source_node ~= input.source_node or row.source_workspace ~= input.source_workspace then
        return nil, failure("CONFLICT", "idempotency key was used by a different governance plan request")
    end
    local plan, plan_error = find(tx, store, row.source_node :: string, row.source_workspace :: string, row.version :: string)
    if plan_error then return nil, plan_error end
    if not plan then return nil, failure("INTERNAL", "governance plan receipt has no plan") end
    return transaction.success(view(store, plan, false), true), nil
end

local function insert_receipt(store: Store, tx: sql.Transaction, actor: string, input: Mutation, measured: string, row: Row): Result?
    local counts, count_error = tx:query("SELECT COUNT(*) AS count FROM bee_governance_plan_receipts WHERE owner_node = ? AND workspace_id = ?", {store.node, store.workspace})
    if count_error or not counts or #counts ~= 1 then return storage(count_error, "read governance plan receipt count") end
    local count = integer(counts[1].count)
    if count == nil then return failure("INTERNAL", "governance plan receipt count is corrupt") end
    if count >= MAX_RECEIPTS then return failure("CAPACITY_EXHAUSTED", "governance plan receipt capacity is exhausted") end
    local _, err = tx:execute("INSERT INTO bee_governance_plan_receipts (owner_node, workspace_id, idempotency_key, actor_id, operation, request_digest, source_node, source_workspace, version, result_revision) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", {store.node, store.workspace, input.idempotency_key, actor, input.operation, measured, row.source_node, row.source_workspace, row.version, row.revision})
    if err then return storage(err, "record governance plan receipt") end
    return nil
end

local function load_by_version(tx: sql.Transaction, store: Store, input: Identity): (Row?, Result?)
    local row, err = find(tx, store, input.source_node :: string, input.source_workspace :: string, input.version :: string)
    if err then return nil, err end
    if not row then return nil, failure("NOT_FOUND", "governance plan does not exist") end
    return row, nil
end

function M.stage(store: Store, actor_raw: string, input: StageRequest): Result
    if store.closed then return failure("CLOSED", "governance plan store is closed") end
    local actor = bounds.id(actor_raw)
    if not actor then return failure("INVALID", "plan actor is invalid") end
    local measured, measure_error = request_digest(input)
    if not measured then return measure_error :: Result end
    return transaction.write(store.db, "governance plan", function(tx: sql.Transaction): Result
        local replay, replay_error = receipt(store, tx, actor, input, measured :: string)
        if replay then return replay end
        if replay_error then return replay_error end
        local candidate_error = checked_blob(input.candidate :: Blob, "candidate")
        if candidate_error then return candidate_error end
        local artifact_error = checked_blob(input.artifact :: Blob, "artifact")
        if artifact_error then return artifact_error end
        local preflight_error = checked_blob(input.preflight :: Blob, "preflight")
        if preflight_error then return preflight_error end
        local measured_plan = plan_digest(store, input.source_node :: string, input.source_workspace :: string, input.version :: string, input.candidate :: Blob, input.artifact :: Blob, input.preflight :: Blob)
        if not measured_plan then return failure("INTERNAL", "measure governance plan") end
        local existing, existing_error = find(tx, store, input.source_node :: string, input.source_workspace :: string, input.version :: string)
        if existing_error then return existing_error end
        if existing then
            if existing.source_workspace ~= input.source_workspace or existing.candidate.digest ~= input.candidate.digest
                or existing.artifact.digest ~= input.artifact.digest or existing.preflight.digest ~= input.preflight.digest
                or existing.candidate.bytes ~= input.candidate.bytes or existing.artifact.bytes ~= input.artifact.bytes or existing.preflight.bytes ~= input.preflight.bytes
                or existing.plan_digest ~= measured_plan then
                return failure("CONFLICT", "version already contains different governance plan bytes")
            end
            local receipt_error = insert_receipt(store, tx, actor, input, measured :: string, existing)
            if receipt_error then return receipt_error end
            return transaction.success(view(store, existing, false), false)
        end
        local count_row, count_error = one(tx, "SELECT COUNT(*) AS count FROM bee_governance_plans WHERE owner_node = ? AND workspace_id = ?", {store.node, store.workspace}, "governance plan count")
        if count_error or not count_row then return count_error or failure("INTERNAL", "read governance plan count") end
        local count = integer(count_row.count)
        if count == nil then return failure("INTERNAL", "governance plan count is corrupt") end
        if count >= MAX_PLANS then return failure("CAPACITY_EXHAUSTED", "governance plan capacity is exhausted") end
        local now = "strftime('%Y-%m-%dT%H:%M:%fZ', 'now')"
        local _, insert_error = tx:execute("INSERT INTO bee_governance_plans (owner_node, workspace_id, source_node, source_workspace, version, candidate_bytes, candidate_digest, artifact_bytes, artifact_digest, preflight_bytes, preflight_digest, plan_digest, revision, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, 'staged', " .. now .. ", " .. now .. ")", {store.node, store.workspace, input.source_node, input.source_workspace, input.version, input.candidate.bytes, input.candidate.digest, input.artifact.bytes, input.artifact.digest, input.preflight.bytes, input.preflight.digest, measured_plan})
        if insert_error then return storage(insert_error, "stage governance plan") end
        local row, row_error = find(tx, store, input.source_node :: string, input.source_workspace :: string, input.version :: string)
        if row_error or not row then return row_error or failure("INTERNAL", "read staged governance plan") end
        local receipt_error = insert_receipt(store, tx, actor, input, measured :: string, row)
        if receipt_error then return receipt_error end
        return transaction.success(view(store, row, false), false)
    end)
end

local function transition(store: Store, actor: string, input: Mutation, change: (sql.Transaction, Row) -> Result): Result
    local measured, measure_error = request_digest(input)
    if not measured then return measure_error :: Result end
    return transaction.write(store.db, "governance plan", function(tx: sql.Transaction): Result
        local replay, replay_error = receipt(store, tx, actor, input, measured :: string)
        if replay then return replay end
        if replay_error then return replay_error end
        local row, row_error = load_by_version(tx, store, input)
        if not row then return row_error or failure("NOT_FOUND", "governance plan does not exist") end
        if input.expected_revision ~= row.revision then return failure("CONFLICT", "expected_revision does not match governance plan") end
        local changed = change(tx, row)
        if not changed.ok then return changed end
        return changed
    end)
end

function M.record_review(store: Store, actor_raw: string, input: ReviewRequest): Result
    if store.closed then return failure("CLOSED", "governance plan store is closed") end
    local actor = bounds.id(actor_raw)
    if not actor then return failure("INVALID", "plan actor is invalid") end
    return transition(store, actor, input, function(tx: sql.Transaction, row: Row): Result
        if row.status ~= "staged" then return failure("CONFLICT", "governance plan cannot be reviewed in its current status") end
        local next_revision: integer = (row.revision :: integer) + 1
        local _, err = tx:execute("UPDATE bee_governance_plans SET revision = ?, status = ?, review_status = ?, review_reason = ?, reviewer_id = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE owner_node = ? AND workspace_id = ? AND source_node = ? AND source_workspace = ? AND version = ? AND revision = ?", {next_revision, input.review_status == "accepted" and "reviewed" or "rejected", input.review_status, input.review_reason, actor, store.node, store.workspace, row.source_node, row.source_workspace, row.version, row.revision})
        if err then return storage(err, "record governance review") end
        if not _ or integer(_.rows_affected) ~= 1 then return failure("CONFLICT", "governance plan changed during review") end
        local changed, changed_error = find(tx, store, row.source_node, row.source_workspace, row.version)
        if changed_error or not changed then return changed_error or failure("INTERNAL", "read reviewed governance plan") end
        local measured = request_digest(input)
        if not measured then return failure("INTERNAL", "measure review receipt") end
        local receipt_error = insert_receipt(store, tx, actor, input, measured :: string, changed)
        if receipt_error then return receipt_error end
        return transaction.success(view(store, changed, false), false)
    end)
end

function M.bind_approval(store: Store, actor_raw: string, input: ApprovalRequest): Result
    if store.closed then return failure("CLOSED", "governance plan store is closed") end
    local actor = bounds.id(actor_raw)
    if not actor then return failure("INVALID", "plan actor is invalid") end
    return transition(store, actor, input, function(tx: sql.Transaction, row: Row): Result
        if not row.selected then return failure("CONFLICT", "governance plan must be selected before approval binding") end
        if row.status ~= "reviewed" and row.status ~= "approval_bound" then return failure("CONFLICT", "governance plan requires an accepted review") end
        if input.approval_plan_digest ~= row.plan_digest then return failure("CONFLICT", "approval is not bound to the exact plan digest") end
        if row.status == "approval_bound" and (row.approval_id ~= input.approval_id
            or row.approval_plan_digest ~= input.approval_plan_digest
            or row.approval_proposal_digest ~= input.approval_proposal_digest
            or row.approval_owner_incarnation ~= input.approval_owner_incarnation) then
            return failure("CONFLICT", "governance plan is bound to another approval")
        end
        local next_revision: integer = (row.revision :: integer) + 1
        local _, err = tx:execute("UPDATE bee_governance_plans SET revision = ?, status = 'approval_bound', approval_id = ?, approval_digest = ?, approval_proposal_digest = ?, approval_owner_incarnation = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE owner_node = ? AND workspace_id = ? AND source_node = ? AND source_workspace = ? AND version = ? AND revision = ?", {next_revision, input.approval_id, input.approval_plan_digest, input.approval_proposal_digest, input.approval_owner_incarnation, store.node, store.workspace, row.source_node, row.source_workspace, row.version, row.revision})
        if err then return storage(err, "bind governance approval") end
        if not _ or integer(_.rows_affected) ~= 1 then return failure("CONFLICT", "governance plan changed during approval binding") end
        local changed, changed_error = find(tx, store, row.source_node, row.source_workspace, row.version)
        if changed_error or not changed then return changed_error or failure("INTERNAL", "read bound governance plan") end
        local measured = request_digest(input)
        if not measured then return failure("INTERNAL", "measure approval receipt") end
        local receipt_error = insert_receipt(store, tx, actor, input, measured :: string, changed)
        if receipt_error then return receipt_error end
        return transaction.success(view(store, changed, false), false)
    end)
end

function M.select(store: Store, actor_raw: string, input: Mutation): Result
    if store.closed then return failure("CLOSED", "governance plan store is closed") end
    local actor = bounds.id(actor_raw)
    if not actor then return failure("INVALID", "plan actor is invalid") end
    return transition(store, actor, input, function(tx: sql.Transaction, row: Row): Result
        if row.status ~= "reviewed" and row.status ~= "approval_bound" then return failure("CONFLICT", "governance plan is not eligible for selection") end
        local next_revision: integer = (row.revision :: integer) + 1
        local _, plan_error = tx:execute("UPDATE bee_governance_plans SET revision = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE owner_node = ? AND workspace_id = ? AND source_node = ? AND source_workspace = ? AND version = ? AND revision = ?", {next_revision, store.node, store.workspace, row.source_node, row.source_workspace, row.version, row.revision})
        if plan_error then return storage(plan_error, "select governance plan") end
        local _, selection_error = tx:execute("INSERT INTO bee_governance_plan_slots (owner_node, workspace_id, source_node, source_workspace, version, plan_revision, selected_by, selected_at) VALUES (?, ?, ?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now')) ON CONFLICT(owner_node, workspace_id, source_node, source_workspace) DO UPDATE SET version = excluded.version, plan_revision = excluded.plan_revision, selected_by = excluded.selected_by, selected_at = excluded.selected_at", {store.node, store.workspace, row.source_node, row.source_workspace, row.version, next_revision, actor})
        if selection_error then return storage(selection_error, "record selected governance plan") end
        local changed, changed_error = find(tx, store, row.source_node, row.source_workspace, row.version)
        if changed_error or not changed then return changed_error or failure("INTERNAL", "read selected governance plan") end
        local measured = request_digest(input)
        if not measured then return failure("INTERNAL", "measure selection receipt") end
        local receipt_error = insert_receipt(store, tx, actor, input, measured :: string, changed)
        if receipt_error then return receipt_error end
        return transaction.success(view(store, changed, false), false)
    end)
end

function M.get(store: Store, input: Identity): Result
    if store.closed then return failure("CLOSED", "governance plan store is closed") end
    return transaction.read(store.db, "governance plan", function(tx: sql.Transaction): Result
        local row, err = load_by_version(tx, store, input)
        if not row then return err or failure("NOT_FOUND", "governance plan does not exist") end
        return transaction.success(view(store, row, true), false)
    end)
end

function M.list(store: Store): Result
    if store.closed then return failure("CLOSED", "governance plan store is closed") end
    return transaction.read(store.db, "governance plans", function(tx: sql.Transaction): Result
        local rows, err = tx:query("SELECT p.*, CASE WHEN s.version IS NULL THEN 0 ELSE 1 END AS selected, s.plan_revision AS selection_revision FROM bee_governance_plans p LEFT JOIN bee_governance_plan_slots s ON s.owner_node = p.owner_node AND s.workspace_id = p.workspace_id AND s.source_node = p.source_node AND s.source_workspace = p.source_workspace AND s.version = p.version WHERE p.owner_node = ? AND p.workspace_id = ? ORDER BY p.source_node, p.source_workspace, p.version LIMIT ?", {store.node, store.workspace, MAX_PLANS + 1})
        if err or not rows then return storage(err, "list governance plans") end
        if #rows > MAX_PLANS then return failure("INTERNAL", "governance plan rows exceed capacity") end
        local result: {unknown} = {}
        for index, raw in ipairs(rows) do
            local row, row_error = decode_row(raw)
            if not row then return row_error or failure("INTERNAL", "decode governance plan") end
            result[index] = view(store, row, false)
        end
        return transaction.success({owner_node = store.node, workspace_id = store.workspace, plans = result}, false)
    end)
end

function M.call(store: Store, actor: string, raw: unknown): Result
    local input, decode_error = protocol.decode(raw)
    if not input then return failure("INVALID", decode_error or "invalid governance plan request") end
    if input.operation == "stage" then return M.stage(store, actor, input :: StageRequest) end
    if input.operation == "record_review" then return M.record_review(store, actor, input :: ReviewRequest) end
    if input.operation == "bind_approval" then return M.bind_approval(store, actor, input :: ApprovalRequest) end
    if input.operation == "select" then return M.select(store, actor, input :: Mutation) end
    if input.operation == "get" then return M.get(store, input :: Identity) end
    return M.list(store)
end

function M.close(store: Store): (boolean, string?)
    if store.closed then return true, nil end
    store.closed = true
    local released, err = store.db:release()
    if released ~= true or err then return false, "close governance plan database" end
    return true, nil
end

function M.open(resource: string, node_raw: string, workspace_raw: string): (Store?, string?)
    if type(resource) ~= "string" or resource == "" then return nil, "governance plan database is not linked" end
    local node, workspace = bounds.id(node_raw), bounds.id(workspace_raw)
    if not node or not workspace then return nil, "governance plan store identity is invalid" end
    local db, err = database.open({resource = resource,
        ledger = {table = "bee_governance_migrations", label = "governance"}, migrations = migrations.all()})
    if not db then return nil, err end
    return {db = db, node = node, workspace = workspace, closed = false}, nil
end

return M
