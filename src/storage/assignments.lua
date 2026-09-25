-- MIT. Internal workspace-owned display assignment persistence.
--
-- This is a storage slice, not an application transfer API.  The host must
-- authenticate display admission and complete the physical revoke/mount work.
-- `prepare` is persisted before revoke; `commit` is called only after revoke.
local workspace_store = require("workspace_store")

type WorkspaceStore = workspace_store.Store
type Assignment = {view_id: string, instance_id: string, display_id: string, revision: integer}
type IntentPhase = "prepared" | "committed" | "failed"
type Intent = {request_id: string, view_id: string, instance_id: string, source_display_id: string,
    target_display_id: string, expected_revision: integer, phase: IntentPhase, error: string?}
type Result = {assignment: Assignment, intent: Intent?}
type Store = {
    workspace: WorkspaceStore,
    claim: (Store, unknown) -> (Assignment?, string?),
    get: (Store, unknown) -> (Result?, string?),
    receipt: (Store, unknown) -> (Intent?, string?),
    prepare: (Store, unknown) -> (Intent?, string?),
    commit: (Store, unknown) -> (Result?, string?),
    fail: (Store, unknown) -> (Intent?, string?),
    retire: (Store, unknown) -> (boolean, string?),
    reconcile: (Store) -> ({Result}?, string?),
}

local M = {}
local MAX_ID = 80
local MAX_DISPLAY_ID = 160
local MAX_REQUEST_ID = 80
local MAX_ERROR = 1024
local MAX_REVISION = 9007199254740990
local MAX_ASSIGNMENTS = 16 -- Matches the bounded host live inventory.

local function text(value: unknown, maximum: integer): string?
    if type(value) ~= "string" or #value == 0 or #value > maximum or value:find("[^ -~]") then return nil end
    return value
end

local function revision(value: unknown): integer?
    if type(value) ~= "number" or value ~= math.floor(value) or value < 1 or value > MAX_REVISION then return nil end
    return math.floor(value)
end

local function key(value: unknown): {view_id: string, instance_id: string}?
    if type(value) ~= "table" then return nil end
    local view_id, instance_id = text(value.view_id, MAX_ID), text(value.instance_id, MAX_ID)
    if not view_id or not instance_id then return nil end
    return {view_id = view_id, instance_id = instance_id}
end

local function claim_input(value: unknown): {view_id: string, instance_id: string, display_id: string}?
    local decoded = key(value)
    if not decoded or type(value) ~= "table" then return nil end
    local display_id = text(value.display_id, MAX_DISPLAY_ID)
    if not display_id then return nil end
    return {view_id = decoded.view_id, instance_id = decoded.instance_id, display_id = display_id}
end

local function prepare_input(value: unknown): {request_id: string, view_id: string, instance_id: string,
    source_display_id: string, target_display_id: string, expected_revision: integer}?
    local decoded = key(value)
    if not decoded or type(value) ~= "table" then return nil end
    local request_id = text(value.request_id, MAX_REQUEST_ID)
    local source = text(value.source_display_id, MAX_DISPLAY_ID)
    local target = text(value.target_display_id, MAX_DISPLAY_ID)
    local expected = revision(value.expected_revision)
    if not request_id or not source or not target or source == target or not expected then return nil end
    return {request_id = request_id, view_id = decoded.view_id, instance_id = decoded.instance_id,
        source_display_id = source, target_display_id = target, expected_revision = expected}
end

local function finish_input(value: unknown): {request_id: string, view_id: string, instance_id: string, error: string?}?
    local decoded = key(value)
    if not decoded or type(value) ~= "table" then return nil end
    local request_id = text(value.request_id, MAX_REQUEST_ID)
    if not request_id then return nil end
    local error: string? = nil
    if value.error ~= nil then
        if type(value.error) ~= "string" or #value.error > MAX_ERROR then return nil end
        error = value.error
    end
    return {request_id = request_id, view_id = decoded.view_id, instance_id = decoded.instance_id, error = error}
end

local function integer(value: unknown): integer?
    if type(value) ~= "number" or value ~= math.floor(value) then return nil end
    return math.floor(value)
end

local function assignment(row: {[string]: unknown}): Assignment?
    local view_id, instance_id = text(row.view_id, MAX_ID), text(row.instance_id, MAX_ID)
    local display_id, current = text(row.display_id, MAX_DISPLAY_ID), revision(row.revision)
    if not view_id or not instance_id or not display_id or not current then return nil end
    return {view_id = view_id, instance_id = instance_id, display_id = display_id, revision = current}
end

local function intent(row: {[string]: unknown}): Intent?
    local prepared = prepare_input(row)
    local phase: IntentPhase? = nil
    if row.phase == "prepared" or row.phase == "committed" or row.phase == "failed" then phase = row.phase end
    local error: string? = nil
    if row.error ~= nil then
        if type(row.error) ~= "string" or #row.error > MAX_ERROR then return nil end
        error = row.error
    end
    if not prepared or not phase then return nil end
    return {request_id = prepared.request_id, view_id = prepared.view_id, instance_id = prepared.instance_id,
        source_display_id = prepared.source_display_id, target_display_id = prepared.target_display_id,
        expected_revision = prepared.expected_revision, phase = phase, error = error}
end

local function same_prepare(left: Intent, right: {request_id: string, view_id: string, instance_id: string,
    source_display_id: string, target_display_id: string, expected_revision: integer}): boolean
    return left.request_id == right.request_id and left.view_id == right.view_id and left.instance_id == right.instance_id
        and left.source_display_id == right.source_display_id and left.target_display_id == right.target_display_id
        and left.expected_revision == right.expected_revision
end

local function query_assignment(store: Store, view_id: string, instance_id: string): (Assignment?, string?)
    local rows, err = store.workspace.db:query("SELECT view_id, instance_id, display_id, revision FROM workspace_display_assignments WHERE workspace_id = ? AND view_id = ? AND instance_id = ? LIMIT 2", {store.workspace.workspace_id, view_id, instance_id})
    if err or not rows then return nil, "read display assignment: " .. tostring(err) end
    if #rows == 0 then return nil, nil end
    if #rows ~= 1 then return nil, "display assignment is corrupt" end
    local decoded = assignment(rows[1])
    if not decoded then return nil, "display assignment is corrupt" end
    return decoded, nil
end

local function query_prepared(store: Store, view_id: string, instance_id: string): (Intent?, string?)
    local rows, err = store.workspace.db:query("SELECT request_id, view_id, instance_id, source_display_id, target_display_id, expected_revision, phase, error FROM workspace_display_transfer_receipts WHERE workspace_id = ? AND view_id = ? AND instance_id = ? AND phase = 'prepared' LIMIT 2", {store.workspace.workspace_id, view_id, instance_id})
    if err or not rows then return nil, "read display transfer intent: " .. tostring(err) end
    if #rows == 0 then return nil, nil end
    if #rows ~= 1 then return nil, "display transfer intent is corrupt" end
    local decoded = intent(rows[1])
    if not decoded then return nil, "display transfer intent is corrupt" end
    return decoded, nil
end

-- Receipt lookup is deliberately exact and bounded.  The host uses it before
-- applying current admission checks so a completed retry remains replayable
-- after the source or destination has detached.  It is not enumeration of the
-- durable receipt history.
local function receipt_id(value: unknown): string?
    return text(value, MAX_REQUEST_ID)
end

function M.open(workspace: WorkspaceStore): (Store?, string?)
    if type(workspace) ~= "table" or workspace.db == nil then return nil, "workspace assignment store requires workspace storage" end
    return {workspace = workspace, claim = M.claim, get = M.get, receipt = M.receipt, prepare = M.prepare, commit = M.commit, fail = M.fail, retire = M.retire, reconcile = M.reconcile}, nil
end

function M.claim(store: Store, value: unknown): (Assignment?, string?)
    local request = claim_input(value)
    if not request then return nil, "invalid display assignment claim" end
    local tx, begin_err = store.workspace.db:begin()
    if not tx then return nil, "begin display assignment claim: " .. tostring(begin_err) end
    local existing_rows, existing_err = tx:query("SELECT view_id, instance_id, display_id, revision FROM workspace_display_assignments WHERE workspace_id = ? AND view_id = ? AND instance_id = ? LIMIT 2", {store.workspace.workspace_id, request.view_id, request.instance_id})
    if existing_err or not existing_rows then tx:rollback(); return nil, "read display assignment claim: " .. tostring(existing_err) end
    if #existing_rows > 1 then tx:rollback(); return nil, "display assignment is corrupt" end
    if #existing_rows == 1 then
        local existing = assignment(existing_rows[1])
        if not existing then tx:rollback(); return nil, "display assignment is corrupt" end
        local pending_rows, pending_err = tx:query("SELECT request_id FROM workspace_display_transfer_receipts WHERE workspace_id = ? AND view_id = ? AND instance_id = ? AND phase = 'prepared' LIMIT 2", {store.workspace.workspace_id, request.view_id, request.instance_id})
        if pending_err or not pending_rows then tx:rollback(); return nil, "read prepared display transfer: " .. tostring(pending_err) end
        if #pending_rows ~= 0 then tx:rollback(); return nil, "display assignment has a prepared transfer" end
        local _, commit_err = tx:commit()
        if commit_err then tx:rollback(); return nil, "commit display assignment claim: " .. tostring(commit_err) end
        if existing.display_id ~= request.display_id then return nil, "display assignment belongs to another display" end
        return existing, nil
    end
    local rows, count_err = tx:query("SELECT COUNT(*) AS count FROM workspace_display_assignments WHERE workspace_id = ?", {store.workspace.workspace_id})
    if count_err or not rows or #rows ~= 1 or integer(rows[1].count) == nil then tx:rollback(); return nil, "count display assignments" end
    if integer(rows[1].count) >= MAX_ASSIGNMENTS then tx:rollback(); return nil, "workspace live assignment capacity reached" end
    local _, insert_err = tx:execute("INSERT INTO workspace_display_assignments (workspace_id, view_id, instance_id, display_id, revision) VALUES (?, ?, ?, ?, 1)", {store.workspace.workspace_id, request.view_id, request.instance_id, request.display_id})
    if insert_err then tx:rollback(); return nil, "claim display assignment: " .. tostring(insert_err) end
    local _, commit_err = tx:commit()
    if commit_err then tx:rollback(); return nil, "commit display assignment claim: " .. tostring(commit_err) end
    return {view_id = request.view_id, instance_id = request.instance_id, display_id = request.display_id, revision = 1}, nil
end

function M.get(store: Store, value: unknown): (Result?, string?)
    local request = key(value)
    if not request then return nil, "invalid display assignment key" end
    local current, assignment_err = query_assignment(store, request.view_id, request.instance_id)
    if assignment_err then return nil, assignment_err end
    if not current then return nil, nil end
    local pending, pending_err = query_prepared(store, request.view_id, request.instance_id)
    if pending_err then return nil, pending_err end
    return {assignment = current, intent = pending}, nil
end

function M.receipt(store: Store, value: unknown): (Intent?, string?)
    local request_id = receipt_id(value)
    if not request_id then return nil, "invalid display transfer receipt key" end
    local rows, query_err = store.workspace.db:query(
        "SELECT request_id, view_id, instance_id, source_display_id, target_display_id, expected_revision, phase, error " ..
        "FROM workspace_display_transfer_receipts WHERE workspace_id = ? AND request_id = ? LIMIT 2", {store.workspace.workspace_id, request_id})
    if query_err or not rows then return nil, "read display transfer receipt: " .. tostring(query_err) end
    if #rows == 0 then return nil, nil end
    if #rows ~= 1 then return nil, "display transfer receipt is corrupt" end
    local decoded = intent(rows[1])
    if not decoded then return nil, "display transfer receipt is corrupt" end
    return decoded, nil
end

function M.prepare(store: Store, value: unknown): (Intent?, string?)
    local request = prepare_input(value)
    if not request then return nil, "invalid display transfer prepare" end
    local tx, begin_err = store.workspace.db:begin()
    if not tx then return nil, "begin display transfer prepare: " .. tostring(begin_err) end
    local receipts, receipt_err = tx:query("SELECT request_id, view_id, instance_id, source_display_id, target_display_id, expected_revision, phase, error FROM workspace_display_transfer_receipts WHERE workspace_id = ? AND request_id = ? LIMIT 2", {store.workspace.workspace_id, request.request_id})
    if receipt_err or not receipts then tx:rollback(); return nil, "read display transfer receipt: " .. tostring(receipt_err) end
    if #receipts > 1 then tx:rollback(); return nil, "display transfer receipt is corrupt" end
    if #receipts == 1 then
        local existing = intent(receipts[1])
        if not existing then tx:rollback(); return nil, "display transfer receipt is corrupt" end
        local _, commit_err = tx:commit()
        if commit_err then tx:rollback(); return nil, "commit display transfer replay: " .. tostring(commit_err) end
        if same_prepare(existing, request) then return existing, nil end
        return nil, "display transfer request conflicts with its durable receipt"
    end
    local pending, pending_err = tx:query("SELECT request_id FROM workspace_display_transfer_receipts WHERE workspace_id = ? AND view_id = ? AND instance_id = ? AND phase = 'prepared' LIMIT 2", {store.workspace.workspace_id, request.view_id, request.instance_id})
    if pending_err or not pending then tx:rollback(); return nil, "read prepared display transfer: " .. tostring(pending_err) end
    if #pending ~= 0 then tx:rollback(); return nil, "display transfer is already prepared" end
    local current_rows, assignment_err = tx:query("SELECT display_id, revision FROM workspace_display_assignments WHERE workspace_id = ? AND view_id = ? AND instance_id = ? LIMIT 2", {store.workspace.workspace_id, request.view_id, request.instance_id})
    if assignment_err or not current_rows then tx:rollback(); return nil, "read display assignment before prepare: " .. tostring(assignment_err) end
    if #current_rows ~= 1 or text(current_rows[1].display_id, MAX_DISPLAY_ID) ~= request.source_display_id or revision(current_rows[1].revision) ~= request.expected_revision then tx:rollback(); return nil, "display assignment source or revision changed" end
    if request.expected_revision >= MAX_REVISION then tx:rollback(); return nil, "display assignment revision exhausted" end
    local _, insert_err = tx:execute("INSERT INTO workspace_display_transfer_receipts (workspace_id, request_id, view_id, instance_id, source_display_id, target_display_id, expected_revision, phase, error, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, 'prepared', NULL, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))", {store.workspace.workspace_id, request.request_id, request.view_id, request.instance_id, request.source_display_id, request.target_display_id, request.expected_revision})
    if insert_err then tx:rollback(); return nil, "prepare display transfer: " .. tostring(insert_err) end
    local _, commit_err = tx:commit()
    if commit_err then tx:rollback(); return nil, "commit display transfer prepare: " .. tostring(commit_err) end
    return {request_id = request.request_id, view_id = request.view_id, instance_id = request.instance_id, source_display_id = request.source_display_id, target_display_id = request.target_display_id, expected_revision = request.expected_revision, phase = "prepared", error = nil}, nil
end

function M.commit(store: Store, value: unknown): (Result?, string?)
    local request = finish_input(value)
    if not request then return nil, "invalid display transfer commit" end
    local tx, begin_err = store.workspace.db:begin()
    if not tx then return nil, "begin display transfer commit: " .. tostring(begin_err) end
    local rows, receipt_err = tx:query("SELECT request_id, view_id, instance_id, source_display_id, target_display_id, expected_revision, phase, error FROM workspace_display_transfer_receipts WHERE workspace_id = ? AND request_id = ? LIMIT 2", {store.workspace.workspace_id, request.request_id})
    if receipt_err or not rows or #rows ~= 1 then tx:rollback(); return nil, "display transfer receipt is missing" end
    local receipt = intent(rows[1])
    if not receipt or receipt.view_id ~= request.view_id or receipt.instance_id ~= request.instance_id then tx:rollback(); return nil, "display transfer commit conflicts with durable receipt" end
    if receipt.phase == "failed" then tx:rollback(); return nil, "display transfer already failed" end
    local next_revision = receipt.expected_revision + 1
    if receipt.phase == "prepared" then
        local updated, update_err = tx:execute("UPDATE workspace_display_assignments SET display_id = ?, revision = ? WHERE workspace_id = ? AND view_id = ? AND instance_id = ? AND display_id = ? AND revision = ?", {receipt.target_display_id, next_revision, store.workspace.workspace_id, receipt.view_id, receipt.instance_id, receipt.source_display_id, receipt.expected_revision})
        if update_err or not updated or integer(updated.rows_affected) ~= 1 then tx:rollback(); return nil, "display assignment changed before commit" end
        local _, settle_err = tx:execute("UPDATE workspace_display_transfer_receipts SET phase = 'committed', error = NULL, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE workspace_id = ? AND request_id = ? AND phase = 'prepared'", {store.workspace.workspace_id, receipt.request_id})
        if settle_err then tx:rollback(); return nil, "commit display transfer receipt: " .. tostring(settle_err) end
    end
    local _, commit_err = tx:commit()
    if commit_err then tx:rollback(); return nil, "commit display transfer: " .. tostring(commit_err) end
    return {assignment = {view_id = receipt.view_id, instance_id = receipt.instance_id, display_id = receipt.target_display_id, revision = next_revision}, intent = {request_id = receipt.request_id, view_id = receipt.view_id, instance_id = receipt.instance_id, source_display_id = receipt.source_display_id, target_display_id = receipt.target_display_id, expected_revision = receipt.expected_revision, phase = "committed", error = nil}}, nil
end

function M.fail(store: Store, value: unknown): (Intent?, string?)
    local request = finish_input(value)
    if not request then return nil, "invalid display transfer failure" end
    local tx, begin_err = store.workspace.db:begin()
    if not tx then return nil, "begin display transfer failure: " .. tostring(begin_err) end
    local rows, receipt_err = tx:query("SELECT request_id, view_id, instance_id, source_display_id, target_display_id, expected_revision, phase, error FROM workspace_display_transfer_receipts WHERE workspace_id = ? AND request_id = ? LIMIT 2", {store.workspace.workspace_id, request.request_id})
    if receipt_err or not rows or #rows ~= 1 then tx:rollback(); return nil, "display transfer receipt is missing" end
    local receipt = intent(rows[1])
    if not receipt or receipt.view_id ~= request.view_id or receipt.instance_id ~= request.instance_id then tx:rollback(); return nil, "display transfer failure conflicts with durable receipt" end
    if receipt.phase == "committed" then tx:rollback(); return nil, "display transfer already committed" end
    if receipt.phase == "prepared" then
        local _, update_err = tx:execute("UPDATE workspace_display_transfer_receipts SET phase = 'failed', error = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE workspace_id = ? AND request_id = ? AND phase = 'prepared'", {request.error or "transfer failed", store.workspace.workspace_id, receipt.request_id})
        if update_err then tx:rollback(); return nil, "fail display transfer receipt: " .. tostring(update_err) end
        receipt.phase, receipt.error = "failed", request.error or "transfer failed"
    end
    local _, commit_err = tx:commit()
    if commit_err then tx:rollback(); return nil, "commit display transfer failure: " .. tostring(commit_err) end
    return receipt, nil
end

-- A host may retire only an exact dead application identity after it has
-- reconciled inventory. Receipts intentionally remain available for audit and
-- retry outcomes; a prepared operation must be settled first.
function M.retire(store: Store, value: unknown): (boolean, string?)
    local request = key(value)
    if not request then return false, "invalid display assignment retirement" end
    local tx, begin_err = store.workspace.db:begin()
    if not tx then return false, "begin display assignment retirement: " .. tostring(begin_err) end
    local pending, pending_err = tx:query("SELECT request_id FROM workspace_display_transfer_receipts WHERE workspace_id = ? AND view_id = ? AND instance_id = ? AND phase = 'prepared' LIMIT 2", {store.workspace.workspace_id, request.view_id, request.instance_id})
    if pending_err or not pending then tx:rollback(); return false, "read prepared display transfer: " .. tostring(pending_err) end
    if #pending ~= 0 then tx:rollback(); return false, "cannot retire display assignment with a prepared transfer" end
    local deleted, delete_err = tx:execute("DELETE FROM workspace_display_assignments WHERE workspace_id = ? AND view_id = ? AND instance_id = ?", {store.workspace.workspace_id, request.view_id, request.instance_id})
    if delete_err or not deleted then tx:rollback(); return false, "retire display assignment: " .. tostring(delete_err) end
    if integer(deleted.rows_affected) ~= 1 then tx:rollback(); return false, "display assignment is missing" end
    local _, commit_err = tx:commit()
    if commit_err then tx:rollback(); return false, "commit display assignment retirement: " .. tostring(commit_err) end
    return true, nil
end

-- Startup reconciliation is bounded by the host's 16-live-view ceiling. It
-- returns each assignment and its unresolved fence without enumerating the
-- durable receipt history.
function M.reconcile(store: Store): ({Result}?, string?)
    local rows, query_err = store.workspace.db:query(
        "SELECT a.view_id, a.instance_id, a.display_id, a.revision, " ..
        "r.request_id, r.source_display_id, r.target_display_id, r.expected_revision, r.phase, r.error " ..
        "FROM workspace_display_assignments AS a " ..
        "LEFT JOIN workspace_display_transfer_receipts AS r ON r.workspace_id = a.workspace_id AND r.view_id = a.view_id " ..
        "AND r.instance_id = a.instance_id AND r.phase = 'prepared' " ..
        "WHERE a.workspace_id = ? ORDER BY a.view_id, a.instance_id LIMIT 17", {store.workspace.workspace_id})
    if query_err or not rows then return nil, "reconcile display assignments: " .. tostring(query_err) end
    if #rows > MAX_ASSIGNMENTS then return nil, "workspace live assignment capacity exceeded" end
    local results: {Result} = {}
    for _, row in ipairs(rows) do
        local current = assignment(row)
        if not current then return nil, "display assignment is corrupt" end
        local pending: Intent? = nil
        if row.request_id ~= nil then
            pending = intent(row)
            if not pending or pending.phase ~= "prepared" then return nil, "display transfer intent is corrupt" end
        end
        results[#results + 1] = {assignment = current, intent = pending}
    end
    return results, nil
end

return M
