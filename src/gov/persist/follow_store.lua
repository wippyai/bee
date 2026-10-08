-- MIT. Destination-owned consent and immutable publication progress.
local sql = require("sql")
local json = require("json")
local hash = require("hash")
local bounds = require("bounds")
local canonical = require("canonical")
local transaction = require("transaction")
local semver = require("semver")
local version = require("version")
local M = {}
type Store = {db: sql.DB, node: string, workspace: string, closed: boolean}
type Identity = {source_node: string, source_workspace: string, component: string}
type Mode = "off" | "following" | "paused" | "pinned"
type Row = {source_node: string, source_workspace: string, component: string, mode: Mode,
    revision: integer, cursor: integer, version: string, artifact_digest: string, content_digest: string?,
    pending: version.Descriptor?, intent_id: string?, last_outcome: string?, last_message: string?}
type Result = transaction.Result
local function valid_identity(identity: Identity): boolean
    return bounds.id(identity.source_node) ~= nil and bounds.id(identity.source_workspace) ~= nil
        and bounds.id(identity.component) ~= nil
end
local function mode(raw: unknown): Mode?
    if raw == "off" or raw == "following" or raw == "paused" or raw == "pinned" then return raw end
    return nil
end
local function sha(raw: unknown): string?
    if type(raw) == "string" and #raw == 64 and raw:match("^[0-9a-f]+$") then return raw end
    return nil
end
local function empty(identity: Identity): Row
    return {source_node = identity.source_node, source_workspace = identity.source_workspace,
        component = identity.component, mode = "off", revision = 0, cursor = 0, version = "", artifact_digest = ""}
end
local function decode(raw: unknown): Row?
    local value = bounds.object(raw)
    if not value then return nil end
    local source_node, source_workspace, component = bounds.id(value.source_node), bounds.id(value.source_workspace), bounds.id(value.component)
    local selected_mode, revision, cursor = mode(value.mode), bounds.count(value.revision), bounds.count(value.cursor)
    local release, artifact_digest = bounds.id(value.version), sha(value.artifact_digest)
    if not source_node or not source_workspace or not component or not selected_mode or not revision or not cursor
        or not release or not artifact_digest then return nil end
    local pending = value.pending and version.decode(value.pending) or nil
    if value.pending ~= nil and not pending then return nil end
    local intent_id = bounds.id(value.intent_id)
    if pending and not intent_id then return nil end
    if value.content_digest ~= nil and not sha(value.content_digest) then return nil end
    return {source_node = source_node, source_workspace = source_workspace, component = component,
        mode = selected_mode, revision = revision, cursor = cursor, version = release, artifact_digest = artifact_digest,
        content_digest = sha(value.content_digest), pending = pending, intent_id = intent_id,
        last_outcome = bounds.id(value.last_outcome), last_message = bounds.text(value.last_message, 8192)}
end
local function read(tx: sql.Transaction, store: Store, identity: Identity): (Row?, Result?)
    local rows, err = tx:query([[SELECT state_json FROM bee_governance_follow WHERE owner_node = ? AND workspace_id = ? AND source_node = ? AND source_workspace = ? AND component = ?]],
        {store.node, store.workspace, identity.source_node, identity.source_workspace, identity.component})
    if not rows or err then return nil, transaction.sql_failure(err, "read following") end
    if #rows == 0 then return empty(identity), nil end
    local encoded = rows[1].state_json
    if type(encoded) ~= "string" then return nil, transaction.failure("INTERNAL", "following state is corrupt") end
    local raw, decode_error = json.decode(encoded)
    local row = not decode_error and decode(raw) or nil
    if not row or row.source_node ~= identity.source_node or row.source_workspace ~= identity.source_workspace
        or row.component ~= identity.component then return nil, transaction.failure("INTERNAL", "following identity is corrupt") end
    return row, nil
end
local function write(tx: sql.Transaction, store: Store, row: Row): Result
    row.revision = row.revision + 1
    local encoded = canonical.encode(row)
    if not encoded then return transaction.failure("INTERNAL", "encode following state") end
    local _, err = tx:execute([[INSERT INTO bee_governance_follow (owner_node, workspace_id, source_node, source_workspace, component, state_json) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(owner_node, workspace_id, source_node, source_workspace, component) DO UPDATE SET state_json = excluded.state_json]],
        {store.node, store.workspace, row.source_node, row.source_workspace, row.component, encoded})
    if err then return transaction.sql_failure(err, "persist following") end
    return transaction.success(row, false)
end
local function mutate(store: Store, identity: Identity, body: (sql.Transaction, Row) -> Result): Result
    if store.closed or not valid_identity(identity) then return transaction.failure("INVALID", "following identity is invalid") end
    return transaction.write(store.db, "following", function(tx: sql.Transaction): Result
        local row, err = read(tx, store, identity)
        if not row then return assert(err) end
        return body(tx, row)
    end)
end
function M.get(store: Store, identity: Identity): Result
    if store.closed or not valid_identity(identity) then return transaction.failure("INVALID", "following identity is invalid") end
    return transaction.read(store.db, "following", function(tx: sql.Transaction): Result
        local row, err = read(tx, store, identity)
        if not row then return assert(err) end
        return transaction.success(row, false)
    end)
end
function M.consent(store: Store, identity: Identity, raw_mode: unknown, raw_version: unknown, raw_digest: unknown, content_digest: string?): Result
    local selected_mode, release, artifact_digest = mode(raw_mode), bounds.id(raw_version), sha(raw_digest)
    if not selected_mode or not release or not artifact_digest or (content_digest ~= nil and not sha(content_digest)) then
        return transaction.failure("INVALID", "following consent is invalid")
    end
    if selected_mode == "following" and semver.compare_application(release, release) == nil then
        return transaction.failure("INVALID_VERSION", "Following requires an ordered application version")
    end
    return mutate(store, identity, function(tx: sql.Transaction, row: Row): Result
        if row.revision == 0 then row.version, row.artifact_digest, row.content_digest = release, artifact_digest, content_digest end
        row.mode = selected_mode
        return write(tx, store, row)
    end)
end
function M.reserve(store: Store, identity: Identity, raw: unknown, raw_cursor: unknown?): Result
    local descriptor = version.decode(raw)
    local cursor = raw_cursor == nil and 0 or bounds.count(raw_cursor)
    local manifest = descriptor and descriptor.manifest or nil
    local artifact_digest = manifest and sha(manifest.artifact_digest) or nil
    if not descriptor or not cursor or not artifact_digest or descriptor.owner_id ~= identity.source_node
        or descriptor.object_id ~= identity.component or manifest.source_workspace ~= identity.source_workspace then
        return transaction.failure("INVALID", "publication does not match following identity")
    end
    local admitted = descriptor
    return mutate(store, identity, function(tx: sql.Transaction, row: Row): Result
        if row.mode ~= "following" then return transaction.failure("PAUSED", "Following is off, paused or pinned") end
        if row.pending then return transaction.failure("BUSY", "A source update is in progress") end
        local order = semver.compare_application(admitted.version_id, row.version)
        local code: string? = nil
        if order == nil then code = "INVALID_VERSION"
        elseif order < 0 then code = "ROLLBACK"
        elseif order == 0 and (artifact_digest ~= row.artifact_digest
            or (row.content_digest ~= nil and row.content_digest ~= admitted.content_digest)) then code = "EQUIVOCATION" end
        row.cursor = math.max(row.cursor, cursor)
        if code then
            row.last_outcome, row.last_message = code, "Source update refused: " .. code
            local saved = write(tx, store, row)
            if not saved.ok then return saved end
            local refused = transaction.failure(code, assert(row.last_message), row)
            refused.commit = true
            return refused
        end
        if order == 0 then
            if cursor > 0 then return write(tx, store, row) end
            return transaction.success(row, true)
        end
        local bytes = canonical.encode({node = store.node, workspace = store.workspace, identity = identity, descriptor = admitted.digest})
        local intent_id = bytes and hash.sha256(bytes) or nil
        if not intent_id then return transaction.failure("INTERNAL", "measure follow activation identity") end
        row.version, row.artifact_digest, row.content_digest = admitted.version_id, artifact_digest, admitted.content_digest
        row.pending, row.intent_id = admitted, intent_id
        row.last_outcome, row.last_message = "staging", "Checking " .. admitted.version_id
        return write(tx, store, row)
    end)
end
function M.finish(store: Store, identity: Identity, raw_intent: unknown, raw_outcome: unknown, raw_message: unknown): Result
    local intent_id, outcome, message = bounds.id(raw_intent), bounds.id(raw_outcome), bounds.text(raw_message, 8192)
    if not intent_id or not outcome or not message then return transaction.failure("INVALID", "following outcome is invalid") end
    return mutate(store, identity, function(tx: sql.Transaction, row: Row): Result
        if row.intent_id ~= intent_id then return transaction.failure("CONFLICT", "following activation changed") end
        row.last_outcome, row.last_message = outcome, message
        if outcome ~= "needs_you" and outcome ~= "activating" and outcome ~= "paused" then row.pending = nil end
        return write(tx, store, row)
    end)
end
function M.list(resource: string, node: string): Result
    local db, open_error = sql.get(resource)
    if not db then return transaction.sql_failure(open_error, "open following ledger") end
    local result = transaction.read(db, "following", function(tx: sql.Transaction): Result
        local rows, err = tx:query([[SELECT workspace_id, state_json FROM bee_governance_follow WHERE owner_node = ? ORDER BY workspace_id, source_node, source_workspace, component]], {node})
        if not rows or err then return transaction.sql_failure(err, "list following") end
        local items: {{workspace_id: string, state: Row}} = {}
        for _, raw in ipairs(rows) do
            local encoded, workspace = raw.state_json, bounds.id(raw.workspace_id)
            local parsed = type(encoded) == "string" and json.decode(encoded) or nil
            local row = decode(parsed)
            if not workspace or not row then return transaction.failure("INTERNAL", "following ledger is corrupt") end
            items[#items + 1] = {workspace_id = workspace, state = row}
        end
        return transaction.success({items = items}, false)
    end)
    return transaction.release(db, "following", result)
end
function M.disable(store: Store, source_workspace: string, raw_mode: unknown): Result
    local selected_mode = mode(raw_mode)
    if not selected_mode or not bounds.id(source_workspace) then return transaction.failure("INVALID", "Following pause is invalid") end
    return transaction.write(store.db, "following", function(tx: sql.Transaction): Result
        local rows, err = tx:query([[SELECT state_json FROM bee_governance_follow WHERE owner_node = ? AND workspace_id = ? AND source_workspace = ?]],
            {store.node, store.workspace, source_workspace})
        if not rows or err then return transaction.sql_failure(err, "read following consent") end
        for _, raw in ipairs(rows) do
            local encoded = raw.state_json
            local parsed = type(encoded) == "string" and json.decode(encoded) or nil
            local row = decode(parsed)
            if not row then return transaction.failure("INTERNAL", "Following consent is corrupt") end
            row.mode = selected_mode
            local result = write(tx, store, row)
            if not result.ok then return result end
        end
        return transaction.success({mode = selected_mode}, false)
    end)
end

function M.observe_installation(store: Store, identity: Identity, release: string, artifact_digest: string): Result
    if not bounds.id(release) or not sha(artifact_digest) then return transaction.failure("INVALID", "Observed application version is invalid") end
    return mutate(store, identity, function(tx: sql.Transaction, row: Row): Result
        if row.revision == 0 then return transaction.success(row, true) end
        local order = semver.compare_application(release, row.version)
        if order == nil then return transaction.failure("INVALID_VERSION", "Observed application has no semantic version ordering") end
        if order <= 0 then return transaction.success(row, true) end
        row.version, row.artifact_digest, row.content_digest = release, artifact_digest, nil
        return write(tx, store, row)
    end)
end
return M
