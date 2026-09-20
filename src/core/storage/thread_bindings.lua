-- MIT. Internal workspace-owned application/thread binding persistence.
--
-- A row names one logical application instance and the thread it is bound to.
-- The application is a participant in that thread.  The
-- workspace owner is the only caller of this helper; thread membership and
-- physical execution remain outside this store.
local workspace_store = require("workspace_store")

type WorkspaceStore = workspace_store.Store
type State = "pending" | "active" | "revoked"
type Binding = {
    instance_id: string,
    thread_id: string,
    definition_id: string,
    actor_id: string,
    role: "participant",
    binding_revision: integer,
    state: State,
    idempotency_key: string,
    definition_revision: string,
    initiating_owner_id: string,
    gateway_binding_id: string,
    gateway_approval_id: string,
    gateway_proposal_digest: string,
    access: "observe_post",
    join_expected_revision: integer,
    membership_revision: integer?,
    cleanup_pending: 0 | 1,
    cleanup_expected_revision: integer?,
}
type PrepareRequest = {
    instance_id: string,
    thread_id: string,
    definition_id: string,
    actor_id: string,
    role: "participant",
    idempotency_key: string,
    definition_revision: string,
    initiating_owner_id: string,
    gateway_binding_id: string,
    gateway_approval_id: string,
    gateway_proposal_digest: string,
    access: "observe_post",
    join_expected_revision: integer,
}
type ActivateRequest = {instance_id: string, expected_revision: integer, expected_state: "pending", membership_revision: integer}
type TransitionRequest = {instance_id: string, expected_revision: integer, expected_state: State}
type BeginRevokeRequest = {instance_id: string, expected_revision: integer, expected_state: State, cleanup_expected_revision: integer}
type RefreshRequest = {instance_id: string, expected_revision: integer, expected_state: State, refreshed_revision: integer}
type Store = {
    workspace: WorkspaceStore,
    prepare: (Store, unknown) -> (Binding?, string?),
    activate: (Store, unknown) -> (Binding?, string?),
    refresh_join: (Store, unknown) -> (Binding?, string?),
    begin_revoke: (Store, unknown) -> (Binding?, string?),
    refresh_cleanup: (Store, unknown) -> (Binding?, string?),
    finish_revoke: (Store, unknown) -> (Binding?, string?),
    get: (Store, unknown) -> (Binding?, string?),
    list: (Store) -> ({Binding}?, string?),
}

local M = {}
local MAX_INSTANCE_ID = 80
local MAX_THREAD_ID = 160
local MAX_DEFINITION_ID = 160
local MAX_DEFINITION_REVISION = 80
local MAX_ACTOR_ID = 160
local MAX_IDEMPOTENCY_KEY = 160
local MAX_OWNER_ID = 160
local MAX_GATEWAY_BINDING_ID = 160
local MAX_GATEWAY_APPROVAL_ID = 160
local MAX_REVISION = 9007199254740990
local MAX_BINDINGS = 256

local function text(value: unknown, maximum: integer): string?
    if type(value) ~= "string" or #value == 0 or #value > maximum or value:find("[^ -~]") then return nil end
    return value
end

local function revision(value: unknown): integer?
    if type(value) ~= "number" or value ~= value or value ~= math.floor(value)
        or value < 1 or value > MAX_REVISION then return nil end
    return math.floor(value)
end

local function object(value: unknown): {[string]: unknown}?
    if type(value) ~= "table" then return nil end
    for key in pairs(value) do
        if type(key) ~= "string" then return nil end
    end
    return value :: {[string]: unknown}
end

local function fields(value: {[string]: unknown}, allowed: {string}): boolean
    local permitted: {[string]: boolean} = {}
    for _, name in ipairs(allowed) do permitted[name] = true end
    for key in pairs(value) do
        if not permitted[key] then return false end
    end
    return true
end

local function role(value: unknown): "participant"?
    if value == "participant" then return "participant" end
    return nil
end

local function state(value: unknown): State?
    if value == "pending" or value == "active" or value == "revoked" then return value end
    return nil
end

local function digest(value: unknown): string?
    if type(value) ~= "string" or #value ~= 64 or not value:match("^[0-9a-f]+$") then return nil end
    return value
end

local function nullable_revision(value: unknown): integer?
    if value == nil then return nil end
    return revision(value)
end

local function prepare_input(value: unknown): (PrepareRequest?, string?)
    local input = object(value)
    if not input or not fields(input, {"instance_id", "thread_id", "definition_id", "actor_id", "role", "idempotency_key",
        "definition_revision", "initiating_owner_id", "gateway_binding_id", "gateway_approval_id",
        "gateway_proposal_digest", "access", "join_expected_revision"}) then
        return nil, "invalid application thread binding prepare"
    end
    local instance_id = text(input.instance_id, MAX_INSTANCE_ID)
    local thread_id = text(input.thread_id, MAX_THREAD_ID)
    local definition_id = text(input.definition_id, MAX_DEFINITION_ID)
    local actor_id = text(input.actor_id, MAX_ACTOR_ID)
    local binding_role = role(input.role)
    local idempotency_key = text(input.idempotency_key, MAX_IDEMPOTENCY_KEY)
    local definition_revision = text(input.definition_revision, MAX_DEFINITION_REVISION)
    local initiating_owner_id = text(input.initiating_owner_id, MAX_OWNER_ID)
    local gateway_binding_id = text(input.gateway_binding_id, MAX_GATEWAY_BINDING_ID)
    local gateway_approval_id = text(input.gateway_approval_id, MAX_GATEWAY_APPROVAL_ID)
    local gateway_proposal_digest = digest(input.gateway_proposal_digest)
    local join_expected_revision = revision(input.join_expected_revision)
    if not instance_id or not thread_id or not definition_id or not actor_id or not binding_role or not idempotency_key
        or not definition_revision or not initiating_owner_id or not gateway_binding_id or not gateway_approval_id
        or not gateway_proposal_digest or input.access ~= "observe_post" or not join_expected_revision then
        return nil, "invalid application thread binding identity"
    end
    return {instance_id = instance_id, thread_id = thread_id, definition_id = definition_id,
        actor_id = actor_id, role = binding_role, idempotency_key = idempotency_key,
        definition_revision = definition_revision, initiating_owner_id = initiating_owner_id,
        gateway_binding_id = gateway_binding_id, gateway_approval_id = gateway_approval_id,
        gateway_proposal_digest = gateway_proposal_digest, access = "observe_post",
        join_expected_revision = join_expected_revision}, nil
end

local function activate_input(value: unknown): (ActivateRequest?, string?)
    local input = object(value)
    if not input or not fields(input, {"instance_id", "expected_revision", "expected_state", "membership_revision"}) then
        return nil, "invalid application thread binding activation"
    end
    local instance_id = text(input.instance_id, MAX_INSTANCE_ID)
    local expected_revision = revision(input.expected_revision)
    local membership_revision = revision(input.membership_revision)
    if not instance_id or not expected_revision or input.expected_state ~= "pending" or not membership_revision then
        return nil, "invalid application thread binding transition"
    end
    return {instance_id = instance_id, expected_revision = expected_revision, expected_state = "pending",
        membership_revision = membership_revision}, nil
end

local function transition_input(value: unknown, operation: string): (TransitionRequest?, string?)
    local input = object(value)
    if not input or not fields(input, {"instance_id", "expected_revision", "expected_state"}) then
        return nil, "invalid application thread binding " .. operation
    end
    local instance_id = text(input.instance_id, MAX_INSTANCE_ID)
    local expected_revision = revision(input.expected_revision)
    local expected_state = state(input.expected_state)
    if not instance_id or not expected_revision or not expected_state then
        return nil, "invalid application thread binding transition"
    end
    return {instance_id = instance_id, expected_revision = expected_revision, expected_state = expected_state}, nil
end

local function begin_revoke_input(value: unknown): (BeginRevokeRequest?, string?)
    local input = object(value)
    if not input or not fields(input, {"instance_id", "expected_revision", "expected_state", "cleanup_expected_revision"}) then
        return nil, "invalid application thread binding revocation"
    end
    local instance_id = text(input.instance_id, MAX_INSTANCE_ID)
    local expected_revision = revision(input.expected_revision)
    local cleanup_expected_revision = revision(input.cleanup_expected_revision)
    if not instance_id or not expected_revision or (input.expected_state ~= "pending" and input.expected_state ~= "active")
        or not cleanup_expected_revision then
        return nil, "invalid application thread binding transition"
    end
    local expected_state: "pending" | "active" = input.expected_state == "pending" and "pending" or "active"
    return {instance_id = instance_id, expected_revision = expected_revision, expected_state = expected_state,
        cleanup_expected_revision = cleanup_expected_revision}, nil
end

local function refresh_input(value: unknown, operation: string, expected_state: State, field: string): (RefreshRequest?, string?)
    local input = object(value)
    if not input or not fields(input, {"instance_id", "expected_revision", "expected_state", field}) then
        return nil, "invalid application thread binding " .. operation
    end
    local instance_id = text(input.instance_id, MAX_INSTANCE_ID)
    local expected_revision = revision(input.expected_revision)
    local refreshed_revision = revision(input[field])
    if not instance_id or not expected_revision or input.expected_state ~= expected_state or not refreshed_revision then
        return nil, "invalid application thread binding transition"
    end
    return {instance_id = instance_id, expected_revision = expected_revision, expected_state = expected_state,
        refreshed_revision = refreshed_revision}, nil
end

local function instance_key(value: unknown): string?
    if type(value) == "string" then return text(value, MAX_INSTANCE_ID) end
    local input = object(value)
    if not input or not fields(input, {"instance_id"}) then return nil end
    return text(input.instance_id, MAX_INSTANCE_ID)
end

local function integer(value: unknown): integer?
    if type(value) ~= "number" or value ~= value or value ~= math.floor(value) then return nil end
    return math.floor(value)
end

local function decode(row: {[string]: unknown}): Binding?
    local instance_id = text(row.instance_id, MAX_INSTANCE_ID)
    local thread_id = text(row.thread_id, MAX_THREAD_ID)
    local definition_id = text(row.definition_id, MAX_DEFINITION_ID)
    local actor_id = text(row.actor_id, MAX_ACTOR_ID)
    local binding_role = role(row.role)
    local binding_revision = revision(row.binding_revision)
    local binding_state = state(row.state)
    local idempotency_key = text(row.idempotency_key, MAX_IDEMPOTENCY_KEY)
    local definition_revision = text(row.definition_revision, MAX_DEFINITION_REVISION)
    local initiating_owner_id = text(row.initiating_owner_id, MAX_OWNER_ID)
    local gateway_binding_id = text(row.gateway_binding_id, MAX_GATEWAY_BINDING_ID)
    local gateway_approval_id = text(row.gateway_approval_id, MAX_GATEWAY_APPROVAL_ID)
    local gateway_proposal_digest = digest(row.gateway_proposal_digest)
    local join_expected_revision = revision(row.join_expected_revision)
    local membership_revision = nullable_revision(row.membership_revision)
    local cleanup_pending = integer(row.cleanup_pending)
    local cleanup_expected_revision = nullable_revision(row.cleanup_expected_revision)
    if not instance_id or not thread_id or not definition_id or not actor_id or not binding_role
        or not binding_revision or not binding_state or not idempotency_key or not definition_revision
        or not initiating_owner_id or not gateway_binding_id or not gateway_approval_id or not gateway_proposal_digest
        or row.access ~= "observe_post" or not join_expected_revision or (cleanup_pending ~= 0 and cleanup_pending ~= 1)
        or (row.membership_revision ~= nil and not membership_revision)
        or (row.cleanup_expected_revision ~= nil and not cleanup_expected_revision) then return nil end
    if binding_state == "pending" and (membership_revision ~= nil or cleanup_pending ~= 0 or cleanup_expected_revision ~= nil) then return nil end
    if binding_state == "active" and (membership_revision == nil or cleanup_pending ~= 0 or cleanup_expected_revision ~= nil) then return nil end
    if binding_state == "revoked" and ((cleanup_pending == 0 and cleanup_expected_revision ~= nil)
        or (cleanup_pending == 1 and cleanup_expected_revision == nil)) then return nil end
    local cleanup_state: 0 | 1 = cleanup_pending == 0 and 0 or 1
    return {instance_id = instance_id, thread_id = thread_id, definition_id = definition_id,
        actor_id = actor_id, role = binding_role, binding_revision = binding_revision,
        state = binding_state, idempotency_key = idempotency_key, definition_revision = definition_revision,
        initiating_owner_id = initiating_owner_id, gateway_binding_id = gateway_binding_id,
        gateway_approval_id = gateway_approval_id, gateway_proposal_digest = gateway_proposal_digest,
        access = "observe_post", join_expected_revision = join_expected_revision,
        membership_revision = membership_revision, cleanup_pending = cleanup_state,
        cleanup_expected_revision = cleanup_expected_revision}
end

local function select_sql(): string
    return "SELECT instance_id, thread_id, definition_id, actor_id, role, binding_revision, state, idempotency_key, " ..
        "definition_revision, initiating_owner_id, gateway_binding_id, gateway_approval_id, gateway_proposal_digest, " ..
        "access, join_expected_revision, membership_revision, cleanup_pending, cleanup_expected_revision " ..
        "FROM workspace_application_thread_bindings"
end

local function same_identity(existing: Binding, requested: PrepareRequest): boolean
    return existing.instance_id == requested.instance_id and existing.thread_id == requested.thread_id
        and existing.definition_id == requested.definition_id and existing.actor_id == requested.actor_id
        and existing.role == requested.role and existing.idempotency_key == requested.idempotency_key
        and existing.definition_revision == requested.definition_revision
        and existing.initiating_owner_id == requested.initiating_owner_id
        and existing.gateway_binding_id == requested.gateway_binding_id
        and existing.gateway_approval_id == requested.gateway_approval_id
        and existing.gateway_proposal_digest == requested.gateway_proposal_digest
        and existing.access == requested.access
end

local function changed(existing: Binding, binding_revision: integer, binding_state: State,
    membership_revision: integer?, join_expected_revision: integer, cleanup_pending: 0 | 1,
    cleanup_expected_revision: integer?): Binding
    return {instance_id = existing.instance_id, thread_id = existing.thread_id, definition_id = existing.definition_id,
        actor_id = existing.actor_id, role = existing.role, binding_revision = binding_revision, state = binding_state,
        idempotency_key = existing.idempotency_key, definition_revision = existing.definition_revision,
        initiating_owner_id = existing.initiating_owner_id, gateway_binding_id = existing.gateway_binding_id,
        gateway_approval_id = existing.gateway_approval_id, gateway_proposal_digest = existing.gateway_proposal_digest,
        access = existing.access, join_expected_revision = join_expected_revision,
        membership_revision = membership_revision, cleanup_pending = cleanup_pending,
        cleanup_expected_revision = cleanup_expected_revision}
end

local function rollback(tx: sql.Transaction)
    tx:rollback()
end

function M.open(workspace: WorkspaceStore): (Store?, string?)
    if type(workspace) ~= "table" or workspace.db == nil then
        return nil, "application thread binding store requires workspace storage"
    end
    return {workspace = workspace, prepare = M.prepare, activate = M.activate,
        refresh_join = M.refresh_join, begin_revoke = M.begin_revoke,
        refresh_cleanup = M.refresh_cleanup, finish_revoke = M.finish_revoke,
        get = M.get, list = M.list}, nil
end

function M.prepare(store: Store, value: unknown): (Binding?, string?)
    local request, input_error = prepare_input(value)
    if not request then return nil, input_error end
    local tx, begin_error = store.workspace.db:begin()
    if not tx then return nil, "begin application thread binding prepare: " .. tostring(begin_error) end

    local rows, query_error = tx:query(select_sql() .. " WHERE instance_id = ? LIMIT 2", {request.instance_id})
    if query_error or not rows then
        rollback(tx)
        return nil, "read application thread binding: " .. tostring(query_error)
    end
    if #rows > 1 then
        rollback(tx)
        return nil, "application thread binding is corrupt"
    end
    if #rows == 1 then
        local existing = decode(rows[1])
        if not existing then
            rollback(tx)
            return nil, "application thread binding is corrupt"
        end
        local _, commit_error = tx:commit()
        if commit_error then
            rollback(tx)
            return nil, "commit application thread binding replay: " .. tostring(commit_error)
        end
        if same_identity(existing, request) then return existing, nil end
        return nil, "application thread binding conflicts with immutable identity"
    end

    local key_rows, key_error = tx:query(select_sql() .. " WHERE idempotency_key = ? LIMIT 2", {request.idempotency_key})
    if key_error or not key_rows then
        rollback(tx)
        return nil, "read application thread binding idempotency key: " .. tostring(key_error)
    end
    if #key_rows > 1 then
        rollback(tx)
        return nil, "application thread binding is corrupt"
    end
    if #key_rows == 1 then
        rollback(tx)
        return nil, "application thread binding idempotency key conflicts with another instance"
    end

    local count_rows, count_error = tx:query(
        "SELECT COUNT(*) AS count FROM workspace_application_thread_bindings WHERE state IN ('pending', 'active')")
    if count_error or not count_rows or #count_rows ~= 1 or integer(count_rows[1].count) == nil then
        rollback(tx)
        return nil, "count active application thread bindings: " .. tostring(count_error)
    end
    if integer(count_rows[1].count) >= MAX_BINDINGS then
        rollback(tx)
        return nil, "application thread binding capacity reached"
    end

    local _, insert_error = tx:execute(
        "INSERT INTO workspace_application_thread_bindings " ..
        "(instance_id, thread_id, definition_id, actor_id, role, binding_revision, state, idempotency_key, " ..
        "definition_revision, initiating_owner_id, gateway_binding_id, gateway_approval_id, gateway_proposal_digest, " ..
        "access, join_expected_revision, membership_revision, cleanup_pending, cleanup_expected_revision) " ..
        "VALUES (?, ?, ?, ?, ?, 1, 'pending', ?, ?, ?, ?, ?, ?, ?, ?, NULL, 0, NULL)",
        {request.instance_id, request.thread_id, request.definition_id, request.actor_id, request.role,
            request.idempotency_key, request.definition_revision, request.initiating_owner_id,
            request.gateway_binding_id, request.gateway_approval_id, request.gateway_proposal_digest,
            request.access, request.join_expected_revision})
    if insert_error then
        rollback(tx)
        return nil, "prepare application thread binding: " .. tostring(insert_error)
    end
    local _, commit_error = tx:commit()
    if commit_error then
        rollback(tx)
        return nil, "commit application thread binding prepare: " .. tostring(commit_error)
    end
    return {instance_id = request.instance_id, thread_id = request.thread_id, definition_id = request.definition_id,
        actor_id = request.actor_id, role = request.role, binding_revision = 1, state = "pending",
        idempotency_key = request.idempotency_key, definition_revision = request.definition_revision,
        initiating_owner_id = request.initiating_owner_id, gateway_binding_id = request.gateway_binding_id,
        gateway_approval_id = request.gateway_approval_id, gateway_proposal_digest = request.gateway_proposal_digest,
        access = request.access, join_expected_revision = request.join_expected_revision,
        membership_revision = nil, cleanup_pending = 0, cleanup_expected_revision = nil}, nil
end

function M.activate(store: Store, value: unknown): (Binding?, string?)
    local request, input_error = activate_input(value)
    if not request then return nil, input_error end
    local expected_revision: integer = request.expected_revision
    local expected_state: "pending" = request.expected_state
    if expected_revision >= MAX_REVISION then return nil, "application thread binding revision exhausted" end

    local tx, begin_error = store.workspace.db:begin()
    if not tx then return nil, "begin application thread binding activation: " .. tostring(begin_error) end
    local rows, query_error = tx:query(select_sql() .. " WHERE instance_id = ? LIMIT 2", {request.instance_id})
    if query_error or not rows then
        rollback(tx)
        return nil, "read application thread binding for activation: " .. tostring(query_error)
    end
    if #rows ~= 1 then
        rollback(tx)
        return nil, #rows == 0 and "application thread binding is missing" or "application thread binding is corrupt"
    end
    local existing = decode(rows[1])
    if not existing then
        rollback(tx)
        return nil, "application thread binding is corrupt"
    end
    if existing.binding_revision ~= expected_revision or existing.state ~= expected_state then
        rollback(tx)
        return nil, "application thread binding revision or state changed"
    end

    local result, update_error = tx:execute(
        "UPDATE workspace_application_thread_bindings SET binding_revision = ?, state = 'active', membership_revision = ? " ..
        "WHERE instance_id = ? AND binding_revision = ? AND state = ?",
        {expected_revision + 1, request.membership_revision, request.instance_id, expected_revision, expected_state})
    if update_error or not result or integer(result.rows_affected) ~= 1 then
        rollback(tx)
        return nil, "application thread binding activation was stale"
    end
    local _, commit_error = tx:commit()
    if commit_error then
        rollback(tx)
        return nil, "commit application thread binding activation: " .. tostring(commit_error)
    end
    return changed(existing, expected_revision + 1, "active", request.membership_revision,
        existing.join_expected_revision, 0, nil), nil
end

-- A membership owner may report a revision conflict after a failed join.  The
-- coordinator must first retry the recorded revision; this CAS is only the
-- explicit refresh after that owner has observed a conflict.
function M.refresh_join(store: Store, value: unknown): (Binding?, string?)
    local request, input_error = refresh_input(value, "join revision refresh", "pending", "join_expected_revision")
    if not request then return nil, input_error end
    local expected_revision: integer = request.expected_revision
    local refreshed_revision: integer = request.refreshed_revision
    local instance_id: string = request.instance_id
    if expected_revision >= MAX_REVISION then return nil, "application thread binding revision exhausted" end

    local tx, begin_error = store.workspace.db:begin()
    if not tx then return nil, "begin application thread binding join revision refresh: " .. tostring(begin_error) end
    local rows, query_error = tx:query(select_sql() .. " WHERE instance_id = ? LIMIT 2", {instance_id})
    if query_error or not rows then
        rollback(tx)
        return nil, "read application thread binding for join revision refresh: " .. tostring(query_error)
    end
    if #rows ~= 1 then
        rollback(tx)
        return nil, #rows == 0 and "application thread binding is missing" or "application thread binding is corrupt"
    end
    local existing = decode(rows[1])
    if not existing then
        rollback(tx)
        return nil, "application thread binding is corrupt"
    end
    if existing.binding_revision ~= expected_revision or existing.state ~= "pending" then
        rollback(tx)
        return nil, "application thread binding revision or state changed"
    end

    local result, update_error = tx:execute(
        "UPDATE workspace_application_thread_bindings SET binding_revision = ?, join_expected_revision = ? " ..
        "WHERE instance_id = ? AND binding_revision = ? AND state = 'pending'",
        {expected_revision + 1, refreshed_revision, instance_id, expected_revision})
    if update_error or not result or integer(result.rows_affected) ~= 1 then
        rollback(tx)
        return nil, "application thread binding join revision refresh was stale"
    end
    local _, commit_error = tx:commit()
    if commit_error then
        rollback(tx)
        return nil, "commit application thread binding join revision refresh: " .. tostring(commit_error)
    end
    return changed(existing, expected_revision + 1, "pending", existing.membership_revision,
        refreshed_revision, 0, nil), nil
end

function M.begin_revoke(store: Store, value: unknown): (Binding?, string?)
    local request, input_error = begin_revoke_input(value)
    if not request then return nil, input_error end
    local expected_revision: integer = request.expected_revision
    local expected_state: State = request.expected_state
    if expected_revision >= MAX_REVISION then return nil, "application thread binding revision exhausted" end

    local tx, begin_error = store.workspace.db:begin()
    if not tx then return nil, "begin application thread binding revocation: " .. tostring(begin_error) end
    local rows, query_error = tx:query(select_sql() .. " WHERE instance_id = ? LIMIT 2", {request.instance_id})
    if query_error or not rows then
        rollback(tx)
        return nil, "read application thread binding for revocation: " .. tostring(query_error)
    end
    if #rows ~= 1 then
        rollback(tx)
        return nil, #rows == 0 and "application thread binding is missing" or "application thread binding is corrupt"
    end
    local existing = decode(rows[1])
    if not existing then
        rollback(tx)
        return nil, "application thread binding is corrupt"
    end
    if existing.binding_revision ~= expected_revision or existing.state ~= expected_state then
        rollback(tx)
        return nil, "application thread binding revision or state changed"
    end

    local result, update_error = tx:execute(
        "UPDATE workspace_application_thread_bindings SET binding_revision = ?, state = 'revoked', cleanup_pending = 1, cleanup_expected_revision = ? " ..
        "WHERE instance_id = ? AND binding_revision = ? AND state = ?",
        {expected_revision + 1, request.cleanup_expected_revision, request.instance_id, expected_revision, expected_state})
    if update_error or not result or integer(result.rows_affected) ~= 1 then
        rollback(tx)
        return nil, "application thread binding revocation was stale"
    end
    local _, commit_error = tx:commit()
    if commit_error then
        rollback(tx)
        return nil, "commit application thread binding revocation: " .. tostring(commit_error)
    end
    return changed(existing, expected_revision + 1, "revoked", existing.membership_revision,
        existing.join_expected_revision, 1, request.cleanup_expected_revision), nil
end

-- The membership owner may report a cleanup revision conflict after the
-- durable revoke fence.  Keep the cleanup tombstone visible while its
-- expected external revision is refreshed through this CAS.
function M.refresh_cleanup(store: Store, value: unknown): (Binding?, string?)
    local request, input_error = refresh_input(value, "cleanup revision refresh", "revoked", "cleanup_expected_revision")
    if not request then return nil, input_error end
    local expected_revision: integer = request.expected_revision
    local refreshed_revision: integer = request.refreshed_revision
    local instance_id: string = request.instance_id
    if expected_revision >= MAX_REVISION then return nil, "application thread binding revision exhausted" end

    local tx, begin_error = store.workspace.db:begin()
    if not tx then return nil, "begin application thread binding cleanup revision refresh: " .. tostring(begin_error) end
    local rows, query_error = tx:query(select_sql() .. " WHERE instance_id = ? LIMIT 2", {instance_id})
    if query_error or not rows then
        rollback(tx)
        return nil, "read application thread binding for cleanup revision refresh: " .. tostring(query_error)
    end
    if #rows ~= 1 then
        rollback(tx)
        return nil, #rows == 0 and "application thread binding is missing" or "application thread binding is corrupt"
    end
    local existing = decode(rows[1])
    if not existing then
        rollback(tx)
        return nil, "application thread binding is corrupt"
    end
    if existing.binding_revision ~= expected_revision or existing.state ~= "revoked"
        or existing.cleanup_pending ~= 1 then
        rollback(tx)
        return nil, "application thread binding revision or state changed"
    end

    local result, update_error = tx:execute(
        "UPDATE workspace_application_thread_bindings SET binding_revision = ?, cleanup_expected_revision = ? " ..
        "WHERE instance_id = ? AND binding_revision = ? AND state = 'revoked' AND cleanup_pending = 1",
        {expected_revision + 1, refreshed_revision, instance_id, expected_revision})
    if update_error or not result or integer(result.rows_affected) ~= 1 then
        rollback(tx)
        return nil, "application thread binding cleanup revision refresh was stale"
    end
    local _, commit_error = tx:commit()
    if commit_error then
        rollback(tx)
        return nil, "commit application thread binding cleanup revision refresh: " .. tostring(commit_error)
    end
    return changed(existing, expected_revision + 1, "revoked", existing.membership_revision,
        existing.join_expected_revision, 1, refreshed_revision), nil
end

function M.finish_revoke(store: Store, value: unknown): (Binding?, string?)
    local request, input_error = transition_input(value, "revocation completion")
    if not request then return nil, input_error end
    local expected_revision: integer = request.expected_revision
    if request.expected_state ~= "revoked" then
        return nil, "application thread binding revocation completion requires revoked state"
    end
    if expected_revision >= MAX_REVISION then return nil, "application thread binding revision exhausted" end

    local tx, begin_error = store.workspace.db:begin()
    if not tx then return nil, "begin application thread binding revocation completion: " .. tostring(begin_error) end
    local rows, query_error = tx:query(select_sql() .. " WHERE instance_id = ? LIMIT 2", {request.instance_id})
    if query_error or not rows then
        rollback(tx)
        return nil, "read application thread binding for revocation completion: " .. tostring(query_error)
    end
    if #rows ~= 1 then
        rollback(tx)
        return nil, #rows == 0 and "application thread binding is missing" or "application thread binding is corrupt"
    end
    local existing = decode(rows[1])
    if not existing then
        rollback(tx)
        return nil, "application thread binding is corrupt"
    end
    if existing.binding_revision ~= expected_revision or existing.state ~= "revoked" then
        rollback(tx)
        return nil, "application thread binding revision or state changed"
    end
    if existing.cleanup_pending ~= 1 or existing.cleanup_expected_revision == nil then
        rollback(tx)
        return nil, "application thread binding cleanup is not pending"
    end

    local result, update_error = tx:execute(
        "UPDATE workspace_application_thread_bindings SET binding_revision = ?, cleanup_pending = 0, cleanup_expected_revision = NULL " ..
        "WHERE instance_id = ? AND binding_revision = ? AND state = 'revoked' AND cleanup_pending = 1",
        {expected_revision + 1, request.instance_id, expected_revision})
    if update_error or not result or integer(result.rows_affected) ~= 1 then
        rollback(tx)
        return nil, "application thread binding revocation completion was stale"
    end
    local _, commit_error = tx:commit()
    if commit_error then
        rollback(tx)
        return nil, "commit application thread binding revocation completion: " .. tostring(commit_error)
    end
    return changed(existing, expected_revision + 1, "revoked", existing.membership_revision,
        existing.join_expected_revision, 0, nil), nil
end

function M.get(store: Store, value: unknown): (Binding?, string?)
    local instance_id = instance_key(value)
    if not instance_id then return nil, "invalid application thread binding key" end
    local rows, query_error = store.workspace.db:query(select_sql() .. " WHERE instance_id = ? LIMIT 2", {instance_id})
    if query_error or not rows then return nil, "read application thread binding: " .. tostring(query_error) end
    if #rows == 0 then return nil, nil end
    if #rows ~= 1 then return nil, "application thread binding is corrupt" end
    local result = decode(rows[1])
    if not result then return nil, "application thread binding is corrupt" end
    return result, nil
end

function M.list(store: Store): ({Binding}?, string?)
    local rows, query_error = store.workspace.db:query(
        select_sql() .. " WHERE state IN ('pending', 'active') OR (state = 'revoked' AND cleanup_pending = 1) " ..
        "ORDER BY instance_id LIMIT " .. tostring(MAX_BINDINGS + 1))
    if query_error or not rows then return nil, "list application thread bindings: " .. tostring(query_error) end
    if #rows > MAX_BINDINGS then return nil, "application thread binding capacity exceeded" end
    local result: {Binding} = {}
    for _, row in ipairs(rows) do
        local decoded = decode(row)
        if not decoded then return nil, "application thread binding is corrupt" end
        result[#result + 1] = decoded
    end
    return result, nil
end

return M
