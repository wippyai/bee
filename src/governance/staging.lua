-- MIT. Node-local, service-owned mutable overlay and frozen copies.
-- It is deliberately not a registry writer, filesystem adapter, or executor.
local sql = require("sql")
local base64 = require("base64")
local hash = require("hash")
local bounds = require("bounds")
local database = require("database")
local shared = require("transaction")
local migrations = require("migrations")
local protocol = require("protocol")
local workspace = require("workspace")

local M = {}
type Result = shared.Result
type Store = {db: sql.DB, node: string, closed: boolean,
    call: (Store, string, protocol.Request) -> Result,
    read_frozen: (Store, string, string, string) -> Result,
    close: (Store) -> (boolean, string?)}
type WorkspaceRow = {actor: string, revision: integer}
type File = {path: string, content: string, content_base64: string, digest: string, bytes: integer}
type Snapshot = {digest: string, files_digest: string, file_count: integer, total_bytes: integer, revision: integer}
type FileSource = "workspace" | "snapshot"

local MAX_WORKSPACES = 64
local MAX_ACTOR_WORKSPACES = 8
-- Frozen revisions are the durable source history for iterative agent work.
-- Keep the budget explicit and bounded while allowing repair and later edits
-- to stay in one overlay.
local MAX_SNAPSHOTS = 16
local MAX_RECEIPTS = 512
local MAX_FILES = 256
local MAX_PATH_BYTES = 240
local MAX_FILE_BYTES = 4 * 1024 * 1024
local MAX_TOTAL_BYTES = 16 * 1024 * 1024
local MAX_BASE64_BYTES = 5592408
-- Files are encoded independently, so each can carry up to two padding bytes
-- before its four-byte base64 quantum. This is the tight aggregate ceiling
-- for the decoded byte and file-count limits, not the encoding of one blob.
local MAX_BASE64_TOTAL_BYTES = math.floor((MAX_TOTAL_BYTES + (2 * MAX_FILES) + 2) / 3) * 4
local MAX_REVISION = 9007199254740991

local function failure(code: string, message: string, value: unknown?): Result
    return shared.failure(code, message, value)
end
local function storage(err: unknown, action: string): Result
    if shared.busy(err) then return shared.storage_failure("governance database is busy") end
    return failure("INTERNAL", action)
end
local function integer(value: unknown): integer?
    if type(value) ~= "number" or value ~= math.floor(value) or value < 0 or value > 9007199254740991 then return nil end
    return math.floor(value)
end
local function one(tx: sql.Transaction, statement: string, params: {unknown}, label: string): ({[string]: unknown}?, Result?)
    local rows, err = tx:query(statement, params)
    if err or not rows then return nil, storage(err, "read " .. label) end
    if #rows > 1 then return nil, failure("INTERNAL", label .. " rows are corrupt") end
    return rows[1], nil
end
local function workspace_row(row: {[string]: unknown}?): (WorkspaceRow?, Result?)
    if not row then return nil, nil end
    local actor, revision = bounds.id(row.actor_id), integer(row.revision)
    if not actor or not revision or revision < 1 then return nil, failure("INTERNAL", "workspace row is corrupt") end
    return {actor = actor, revision = revision}, nil
end
local function load_workspace(store: Store, tx: sql.Transaction, id: string): (WorkspaceRow?, Result?)
    local row, err = one(tx, "SELECT actor_id, revision FROM bee_governance_workspaces WHERE owner_node = ? AND workspace_id = ?", {store.node, id}, "workspace")
    if err then return nil, err end
    return workspace_row(row)
end
local function owner(store: Store, tx: sql.Transaction, actor: string, id: string): (WorkspaceRow?, Result?)
    local current, err = load_workspace(store, tx, id)
    if err or not current then return current, err or failure("NOT_FOUND", "workspace does not exist") end
    if current.actor ~= actor then return nil, failure("DENIED", "workspace belongs to another actor") end
    return current, nil
end
local function value(store: Store, id: string, revision: integer, extra: {[string]: unknown}?): {[string]: unknown}
    local result: {[string]: unknown} = {owner_node = store.node, workspace_id = id, revision = revision}
    if extra then for key, item in pairs(extra) do result[key] = item end end
    return result
end
local function digest(content: string): (string?, Result?)
    local result, err = hash.sha256(content)
    if not result or err then return nil, failure("INTERNAL", "calculate workspace content digest") end
    return result, nil
end
local function request_identity(input: protocol.Request): (string?, Result?)
    local path = input.path
    local content_digest: string? = nil
    if input.operation == "put" then
        if type(input.content) ~= "string" or #input.content > MAX_FILE_BYTES then return nil, failure("INVALID", "put content is missing or exceeds the workspace limit") end
        content_digest = digest(input.content)
        if not content_digest then return nil, failure("INTERNAL", "calculate workspace content digest") end
    end
    return content_digest, nil
end
local function matching_receipt(store: Store, tx: sql.Transaction, actor: string, input: protocol.Request, content_digest: string?): (Result?, Result?)
    local key, expected = input.idempotency_key, input.expected_revision
    if not key or expected == nil then return nil, failure("INVALID", "mutation lacks idempotency fields") end
    local row, err = one(tx, "SELECT actor_id, operation, expected_revision, path, content_sha256, result_revision, snapshot_digest, files_digest, file_count, total_bytes FROM bee_governance_receipts WHERE owner_node = ? AND workspace_id = ? AND idempotency_key = ?", {store.node, input.workspace_id, key}, "workspace receipt")
    if err or not row then return nil, err end
    local receipt_actor, operation = bounds.id(row.actor_id), row.operation
    local received_expected, revision = integer(row.expected_revision), integer(row.result_revision)
    local row_path, row_digest = row.path, row.content_sha256
    if not receipt_actor or type(operation) ~= "string" or received_expected == nil or not revision
        or (row_path ~= nil and type(row_path) ~= "string") or (row_digest ~= nil and type(row_digest) ~= "string") then
        return nil, failure("INTERNAL", "workspace receipt is corrupt")
    end
    if receipt_actor ~= actor then return nil, failure("DENIED", "workspace belongs to another actor") end
    if operation ~= input.operation or received_expected ~= expected or row_path ~= input.path or row_digest ~= content_digest then
        return nil, failure("CONFLICT", "idempotency_key was used by a different workspace request")
    end
    local extra: {[string]: unknown} = {}
    if operation == "freeze" then
        local snapshot_digest, files_digest = row.snapshot_digest, row.files_digest
        local count, total = integer(row.file_count), integer(row.total_bytes)
        if type(snapshot_digest) ~= "string" or type(files_digest) ~= "string" or not count or not total then
            return nil, failure("INTERNAL", "workspace freeze receipt is corrupt")
        end
        extra.digest, extra.files_digest, extra.file_count, extra.total_bytes = snapshot_digest, files_digest, count, total
    end
    return shared.success(value(store, input.workspace_id, revision, extra), true), nil
end
local function receipt_capacity(store: Store, tx: sql.Transaction, id: string): Result?
    local row, err = one(tx, "SELECT COUNT(*) AS count FROM bee_governance_receipts WHERE owner_node = ? AND workspace_id = ?", {store.node, id}, "workspace receipt count")
    if err or not row then return err or failure("INTERNAL", "read workspace receipt count") end
    local count = integer(row.count)
    if count == nil then return failure("INTERNAL", "workspace receipt count is corrupt") end
    if count >= MAX_RECEIPTS then return failure("CAPACITY_EXHAUSTED", "workspace receipt capacity is exhausted") end
    return nil
end
local function record_receipt(store: Store, tx: sql.Transaction, actor: string, input: protocol.Request, content_digest: string?, revision: integer, snapshot: Snapshot?): Result?
    local key, expected = input.idempotency_key, input.expected_revision
    if not key or expected == nil then return failure("INTERNAL", "mutation receipt is incomplete") end
    local inserted: unknown
    local err: unknown
    if snapshot then
        inserted, err = tx:execute("INSERT INTO bee_governance_receipts (owner_node, workspace_id, idempotency_key, actor_id, operation, expected_revision, result_revision, snapshot_digest, files_digest, file_count, total_bytes) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            {store.node, input.workspace_id, key, actor, input.operation, expected, revision,
            snapshot.digest, snapshot.files_digest, snapshot.file_count, snapshot.total_bytes})
    elseif input.operation == "put" then
        local path = bounds.text(input.path, MAX_PATH_BYTES)
        if not path or not content_digest then return failure("INTERNAL", "put receipt is incomplete") end
        inserted, err = tx:execute("INSERT INTO bee_governance_receipts (owner_node, workspace_id, idempotency_key, actor_id, operation, expected_revision, path, content_sha256, result_revision) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            {store.node, input.workspace_id, key, actor, input.operation, expected, path, content_digest, revision})
    elseif input.operation == "remove" then
        local path = bounds.text(input.path, MAX_PATH_BYTES)
        if not path then return failure("INTERNAL", "remove receipt is incomplete") end
        inserted, err = tx:execute("INSERT INTO bee_governance_receipts (owner_node, workspace_id, idempotency_key, actor_id, operation, expected_revision, path, result_revision) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            {store.node, input.workspace_id, key, actor, input.operation, expected, path, revision})
    else
        inserted, err = tx:execute("INSERT INTO bee_governance_receipts (owner_node, workspace_id, idempotency_key, actor_id, operation, expected_revision, result_revision) VALUES (?, ?, ?, ?, ?, ?, ?)",
            {store.node, input.workspace_id, key, actor, input.operation, expected, revision})
    end
    if not inserted or err then return storage(err, "record workspace receipt") end
    return nil
end
local function decode_file(row: {[string]: unknown}): (File?, Result?)
    local path_value = bounds.text(row.path, MAX_PATH_BYTES)
    if not path_value or #path_value == 0 then return nil, failure("INTERNAL", "workspace file row is corrupt") end
    local encoded_value = bounds.text(row.content_base64, MAX_BASE64_BYTES)
    if not encoded_value then return nil, failure("INTERNAL", "workspace file row is corrupt") end
    local digest_value = bounds.text(row.content_sha256, 64)
    if not digest_value or #digest_value ~= 64 then return nil, failure("INTERNAL", "workspace file row is corrupt") end
    local bytes_value = integer(row.bytes)
    if bytes_value == nil or bytes_value > MAX_FILE_BYTES then
        return nil, failure("INTERNAL", "workspace file row is corrupt")
    end
    local path: string, encoded: string, stored_digest: string, bytes: integer = path_value, encoded_value, digest_value, bytes_value
    local content, decode_error = base64.decode(encoded)
    if not content or decode_error or #content ~= bytes then return nil, failure("INTERNAL", "workspace file content is corrupt") end
    local normalized, encode_error = base64.encode(content)
    if encode_error or normalized ~= encoded then return nil, failure("INTERNAL", "workspace file encoding is corrupt") end
    local actual, digest_error = hash.sha256(content)
    if digest_error or actual ~= stored_digest then return nil, failure("INTERNAL", "workspace file digest is corrupt") end
    return {path = path, content = content, content_base64 = encoded, digest = stored_digest, bytes = bytes}, nil
end
-- The selector is an internal closed variant, never a request field.  Keeping
-- the table names here makes snapshot reads use the copied rows only.
local function files(store: Store, tx: sql.Transaction, id: string, source: FileSource, snapshot_digest: string?): ({File}?, Result?)
    -- Check bounded metadata before bringing any base64 bodies into Lua.  A
    -- corrupt SQLite file must not turn a manifest read into an unbounded
    -- allocation merely because its declared byte count was small.
    local totals: {{[string]: unknown}}?
    local totals_err: unknown
    if source == "workspace" then
        totals, totals_err = tx:query("SELECT COUNT(*) AS count, COALESCE(SUM(bytes), 0) AS total_bytes, COALESCE(SUM(length(CAST(content_base64 AS BLOB))), 0) AS encoded_total FROM bee_governance_workspace_files WHERE owner_node = ? AND workspace_id = ?", {store.node, id})
    else
        if not snapshot_digest then return nil, failure("INTERNAL", "snapshot file selector is incomplete") end
        totals, totals_err = tx:query("SELECT COUNT(*) AS count, COALESCE(SUM(bytes), 0) AS total_bytes, COALESCE(SUM(length(CAST(content_base64 AS BLOB))), 0) AS encoded_total FROM bee_governance_snapshot_files WHERE owner_node = ? AND workspace_id = ? AND snapshot_digest = ?", {store.node, id, snapshot_digest})
    end
    if totals_err or not totals or #totals ~= 1 then return nil, storage(totals_err, "measure workspace files") end
    local count = integer(totals[1].count)
    local total_bytes = integer(totals[1].total_bytes)
    local encoded_total = integer(totals[1].encoded_total)
    if count == nil or total_bytes == nil or encoded_total == nil or count > MAX_FILES
        or total_bytes > MAX_TOTAL_BYTES or encoded_total > MAX_BASE64_TOTAL_BYTES then
        return nil, failure("INTERNAL", "workspace file rows exceed capacity")
    end
    local shape_rows: {{[string]: unknown}}?
    local shape_err: unknown
    if source == "workspace" then
        shape_rows, shape_err = tx:query("SELECT path, content_sha256, bytes, length(CAST(content_base64 AS BLOB)) AS encoded_bytes FROM bee_governance_workspace_files WHERE owner_node = ? AND workspace_id = ? ORDER BY path LIMIT 257", {store.node, id})
    else
        shape_rows, shape_err = tx:query("SELECT path, content_sha256, bytes, length(CAST(content_base64 AS BLOB)) AS encoded_bytes FROM bee_governance_snapshot_files WHERE owner_node = ? AND workspace_id = ? AND snapshot_digest = ? ORDER BY path LIMIT 257", {store.node, id, snapshot_digest})
    end
    if shape_err or not shape_rows then return nil, storage(shape_err, "list workspace file metadata") end
    if #shape_rows > MAX_FILES then return nil, failure("INTERNAL", "workspace file rows exceed capacity") end
    for _, row in ipairs(shape_rows) do
        local path = bounds.text(row.path, MAX_PATH_BYTES)
        if not path or #path == 0 then return nil, failure("INTERNAL", "workspace file row is corrupt") end
        local stored_digest = bounds.text(row.content_sha256, 64)
        if not stored_digest or #stored_digest ~= 64 then return nil, failure("INTERNAL", "workspace file row is corrupt") end
        local raw_bytes = integer(row.bytes)
        if raw_bytes == nil or raw_bytes > MAX_FILE_BYTES then return nil, failure("INTERNAL", "workspace file row is corrupt") end
        local raw_encoded_bytes = integer(row.encoded_bytes)
        if raw_encoded_bytes == nil or raw_encoded_bytes > MAX_BASE64_BYTES then return nil, failure("INTERNAL", "workspace file row is corrupt") end
    end
    local rows: {{[string]: unknown}}?
    local err: unknown
    if source == "workspace" then
        rows, err = tx:query("SELECT path, content_base64, content_sha256, bytes FROM bee_governance_workspace_files WHERE owner_node = ? AND workspace_id = ? ORDER BY path LIMIT 257", {store.node, id})
    else
        rows, err = tx:query("SELECT path, content_base64, content_sha256, bytes FROM bee_governance_snapshot_files WHERE owner_node = ? AND workspace_id = ? AND snapshot_digest = ? ORDER BY path LIMIT 257", {store.node, id, snapshot_digest})
    end
    if err or not rows then return nil, storage(err, "read workspace file content") end
    if #rows ~= #shape_rows then return nil, failure("INTERNAL", "workspace file rows changed during read") end
    local result: {File} = {}
    for index, row in ipairs(rows) do
        local decoded, decode_error = decode_file(row)
        if not decoded then return nil, decode_error end
        result[index] = decoded
    end
    return result, nil
end
local function snapshot_row(row: {[string]: unknown}?): (Snapshot?, Result?)
    if not row then return nil, nil end
    local digest_value = bounds.text(row.digest, 64)
    if not digest_value or #digest_value ~= 64 then return nil, failure("INTERNAL", "workspace snapshot is corrupt") end
    local files_digest_value = bounds.text(row.files_digest, 64)
    if not files_digest_value or #files_digest_value ~= 64 then return nil, failure("INTERNAL", "workspace snapshot is corrupt") end
    local revision_value = integer(row.revision)
    if revision_value == nil or revision_value < 1 then return nil, failure("INTERNAL", "workspace snapshot is corrupt") end
    local count_value = integer(row.file_count)
    if count_value == nil or count_value > MAX_FILES then return nil, failure("INTERNAL", "workspace snapshot is corrupt") end
    local total_value = integer(row.total_bytes)
    if total_value == nil or total_value > MAX_TOTAL_BYTES then return nil, failure("INTERNAL", "workspace snapshot is corrupt") end
    local digest: string = digest_value
    local files_digest: string = files_digest_value
    local revision: integer = revision_value
    local count: integer = count_value
    local total: integer = total_value
    return {digest = digest, files_digest = files_digest, revision = revision, file_count = count, total_bytes = total}, nil
end
local function load_snapshot(store: Store, tx: sql.Transaction, id: string, raw_digest: string?): (Snapshot?, Result?)
    local requested = bounds.text(raw_digest, 64)
    if not requested or #requested ~= 64 then return nil, failure("INVALID", "snapshot_digest is invalid") end
    local row, row_error = one(tx, "SELECT digest, revision, files_digest, file_count, total_bytes FROM bee_governance_snapshots WHERE owner_node = ? AND workspace_id = ? AND digest = ?", {store.node, id, requested}, "workspace snapshot")
    if row_error then return nil, row_error end
    local snapshot, decode_error = snapshot_row(row)
    if decode_error then return nil, decode_error end
    if not snapshot then return nil, failure("NOT_FOUND", "workspace snapshot does not exist") end
    return snapshot, nil
end
local function measure_snapshot(id: string, snapshot: Snapshot, stored: {File}): (Snapshot?, Result?)
    local input: {workspace_id: string, revision: integer, files: {{path: string, content: string}}} =
        {workspace_id = id, revision = snapshot.revision, files = {}}
    for index, file in ipairs(stored) do input.files[index] = {path = file.path, content = file.content} end
    local frozen, freeze_error = workspace.freeze(input)
    if not frozen then return nil, failure("INTERNAL", freeze_error or "cannot verify workspace snapshot") end
    if frozen.digest ~= snapshot.digest or frozen.files_digest ~= snapshot.files_digest
        or frozen.file_count ~= snapshot.file_count or frozen.total_bytes ~= snapshot.total_bytes
        or frozen.revision ~= snapshot.revision then
        return nil, failure("INTERNAL", "workspace snapshot content is corrupt")
    end
    return snapshot, nil
end
local function load_verified_snapshot(store: Store, tx: sql.Transaction, id: string, raw_digest: string?): (Snapshot?, {File}?, Result?)
    local snapshot, snapshot_error = load_snapshot(store, tx, id, raw_digest)
    if not snapshot then return nil, nil, snapshot_error or failure("NOT_FOUND", "workspace snapshot does not exist") end
    local stored, files_error = files(store, tx, id, "snapshot", snapshot.digest)
    if not stored then return nil, nil, files_error or failure("INTERNAL", "read workspace snapshot files") end
    local measured, measure_error = measure_snapshot(id, snapshot, stored)
    if not measured then return nil, nil, measure_error or failure("INTERNAL", "verify workspace snapshot") end
    return measured, stored, nil
end
-- The database constraints prevent oversized individual records.  This pass
-- additionally checks the *proposed whole tree* before a mutation is allowed
-- to commit, including file/ancestor collisions that SQL cannot express.
local function validate_files(store: Store, tx: sql.Transaction, id: string, revision: integer): Result?
    local stored, files_error = files(store, tx, id, "workspace", nil)
    if not stored then return files_error or failure("INTERNAL", "read workspace files") end
    local input: {workspace_id: string, revision: integer, files: {{path: string, content: string}}} =
        {workspace_id = id, revision = revision, files = {}}
    for index, file in ipairs(stored) do input.files[index] = {path = file.path, content = file.content} end
    local _, freeze_error = workspace.freeze(input)
    if freeze_error then return failure("INVALID", freeze_error) end
    return nil
end
local function create(store: Store, tx: sql.Transaction, actor: string, input: protocol.Request, content_digest: string?): Result
    if input.expected_revision ~= 0 then return failure("INVALID", "create requires expected_revision zero") end
    local existing, existing_error = load_workspace(store, tx, input.workspace_id)
    if existing_error then return existing_error end
    if existing then
        if existing.actor ~= actor then return failure("DENIED", "workspace belongs to another actor") end
        local replay, replay_error = matching_receipt(store, tx, actor, input, content_digest)
        return replay or replay_error or failure("CONFLICT", "workspace already exists")
    end
    local actor_count_row, actor_count_error = one(tx,
        "SELECT COUNT(*) AS count FROM bee_governance_workspaces WHERE owner_node = ? AND actor_id = ?",
        {store.node, actor}, "author workspace count")
    if actor_count_error or not actor_count_row then return actor_count_error or failure("INTERNAL", "read author workspace count") end
    local actor_count = integer(actor_count_row.count)
    if actor_count == nil then return failure("INTERNAL", "author workspace count is corrupt") end
    if actor_count >= MAX_ACTOR_WORKSPACES then
        return failure("CAPACITY_EXHAUSTED", "author workspace capacity is exhausted")
    end
    local count_row, count_error = one(tx, "SELECT COUNT(*) AS count FROM bee_governance_workspaces WHERE owner_node = ?", {store.node}, "workspace count")
    if count_error or not count_row then return count_error or failure("INTERNAL", "read workspace count") end
    local count = integer(count_row.count)
    if count == nil then return failure("INTERNAL", "workspace count is corrupt") end
    if count >= MAX_WORKSPACES then return failure("CAPACITY_EXHAUSTED", "node workspace capacity is exhausted") end
    local _, insert_error = tx:execute("INSERT INTO bee_governance_workspaces (owner_node, workspace_id, actor_id, revision) VALUES (?, ?, ?, 1)", {store.node, input.workspace_id, actor})
    if insert_error then return storage(insert_error, "create workspace") end
    local receipt_error = record_receipt(store, tx, actor, input, content_digest, 1, nil)
    if receipt_error then return receipt_error end
    return shared.success(value(store, input.workspace_id, 1), false)
end
local function mutation(store: Store, tx: sql.Transaction, actor: string, input: protocol.Request, content_digest: string?): Result
    local current, owner_error = owner(store, tx, actor, input.workspace_id)
    if not current then return owner_error or failure("NOT_FOUND", "workspace does not exist") end
    local replay, replay_error = matching_receipt(store, tx, actor, input, content_digest)
    if replay then return replay end
    if replay_error then return replay_error end
    local capacity_error = receipt_capacity(store, tx, input.workspace_id)
    if capacity_error then return capacity_error end
    if input.expected_revision ~= current.revision then return failure("CONFLICT", "expected_revision does not match workspace") end
    if current.revision >= MAX_REVISION then return failure("CAPACITY_EXHAUSTED", "workspace revision capacity is exhausted") end
    local path = bounds.text(input.path, MAX_PATH_BYTES)
    if not path or #path == 0 then return failure("INVALID", "workspace path is missing") end
    if input.operation == "put" then
        if type(input.content) ~= "string" or not content_digest then return failure("INVALID", "put content is missing") end
        local encoded, encode_error = base64.encode(input.content)
        if encode_error or not encoded then return failure("INTERNAL", "encode workspace content") end
        local _, put_error = tx:execute("INSERT INTO bee_governance_workspace_files (owner_node, workspace_id, path, content_base64, content_sha256, bytes) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(owner_node, workspace_id, path) DO UPDATE SET content_base64 = excluded.content_base64, content_sha256 = excluded.content_sha256, bytes = excluded.bytes", {store.node, input.workspace_id, path, encoded, content_digest, #input.content})
        if put_error then return storage(put_error, "write workspace file") end
    else
        local removed, remove_error = tx:execute("DELETE FROM bee_governance_workspace_files WHERE owner_node = ? AND workspace_id = ? AND path = ?", {store.node, input.workspace_id, path})
        if remove_error then return storage(remove_error, "remove workspace file") end
        if not removed or integer(removed.rows_affected) ~= 1 then return failure("NOT_FOUND", "workspace file does not exist") end
    end
    local revision = current.revision + 1
    local validation_error = validate_files(store, tx, input.workspace_id, revision)
    if validation_error then return validation_error end
    local advanced, revision_error = tx:execute("UPDATE bee_governance_workspaces SET revision = ? WHERE owner_node = ? AND workspace_id = ? AND actor_id = ? AND revision = ?", {revision, store.node, input.workspace_id, actor, current.revision})
    if revision_error then return storage(revision_error, "advance workspace revision") end
    if not advanced or integer(advanced.rows_affected) ~= 1 then
        return failure("CONFLICT", "workspace changed during mutation")
    end
    local receipt_error = record_receipt(store, tx, actor, input, content_digest, revision, nil)
    if receipt_error then return receipt_error end
    return shared.success(value(store, input.workspace_id, revision), false)
end
local function freeze(store: Store, tx: sql.Transaction, actor: string, input: protocol.Request, content_digest: string?): Result
    local current, owner_error = owner(store, tx, actor, input.workspace_id)
    if not current then return owner_error or failure("NOT_FOUND", "workspace does not exist") end
    local replay, replay_error = matching_receipt(store, tx, actor, input, content_digest)
    if replay then return replay end
    if replay_error then return replay_error end
    local capacity_error = receipt_capacity(store, tx, input.workspace_id)
    if capacity_error then return capacity_error end
    if input.expected_revision ~= current.revision then return failure("CONFLICT", "expected_revision does not match workspace") end
    local stored, files_error = files(store, tx, input.workspace_id, "workspace", nil)
    if not stored then return files_error or failure("INTERNAL", "read workspace files") end
    local freeze_input: {workspace_id: string, revision: integer, files: {{path: string, content: string}}} = {workspace_id = input.workspace_id, revision = current.revision, files = {}}
    for index, file in ipairs(stored) do freeze_input.files[index] = {path = file.path, content = file.content} end
    local snapshot, freeze_error = workspace.freeze(freeze_input)
    if not snapshot then return failure("INVALID", freeze_error or "workspace cannot be frozen") end
    local existing, existing_error = one(tx, "SELECT revision, files_digest, file_count, total_bytes FROM bee_governance_snapshots WHERE owner_node = ? AND workspace_id = ? AND digest = ?", {store.node, input.workspace_id, snapshot.digest}, "workspace snapshot")
    if existing_error then return existing_error end
    local snapshot_value: Snapshot = {digest = snapshot.digest, files_digest = snapshot.files_digest, file_count = snapshot.file_count, total_bytes = snapshot.total_bytes, revision = snapshot.revision}
    if existing then
        local revision, count, total = integer(existing.revision), integer(existing.file_count), integer(existing.total_bytes)
        if not revision or not count or not total or existing.files_digest ~= snapshot.files_digest or revision ~= snapshot.revision
            or count ~= snapshot.file_count or total ~= snapshot.total_bytes then
            return failure("INTERNAL", "workspace snapshot is corrupt")
        end
    else
        local count_row, count_error = one(tx, "SELECT COUNT(*) AS count FROM bee_governance_snapshots WHERE owner_node = ? AND workspace_id = ?", {store.node, input.workspace_id}, "workspace snapshot count")
        if count_error or not count_row then return count_error or failure("INTERNAL", "read workspace snapshot count") end
        local count = integer(count_row.count)
        if count == nil then return failure("INTERNAL", "workspace snapshot count is corrupt") end
        if count >= MAX_SNAPSHOTS then return failure("CAPACITY_EXHAUSTED", "workspace snapshot capacity is exhausted") end
        local _, insert_error = tx:execute("INSERT INTO bee_governance_snapshots (owner_node, workspace_id, digest, revision, files_digest, file_count, total_bytes) VALUES (?, ?, ?, ?, ?, ?, ?)", {store.node, input.workspace_id, snapshot.digest, snapshot.revision, snapshot.files_digest, snapshot.file_count, snapshot.total_bytes})
        if insert_error then return storage(insert_error, "create workspace snapshot") end
        for _, file in ipairs(stored) do
            local _, copy_error = tx:execute("INSERT INTO bee_governance_snapshot_files (owner_node, workspace_id, snapshot_digest, path, content_base64, content_sha256, bytes) VALUES (?, ?, ?, ?, ?, ?, ?)", {store.node, input.workspace_id, snapshot.digest, file.path, file.content_base64, file.digest, file.bytes})
            if copy_error then return storage(copy_error, "copy workspace snapshot file") end
        end
    end
    local receipt_error = record_receipt(store, tx, actor, input, content_digest, current.revision, snapshot_value)
    if receipt_error then return receipt_error end
    return shared.success(value(store, input.workspace_id, current.revision, {digest = snapshot.digest, files_digest = snapshot.files_digest, file_count = snapshot.file_count, total_bytes = snapshot.total_bytes}), false)
end
local function list(store: Store, tx: sql.Transaction, actor: string, input: protocol.Request): Result
    local current, owner_error = owner(store, tx, actor, input.workspace_id)
    if not current then return owner_error or failure("NOT_FOUND", "workspace does not exist") end
    local revision = current.revision
    local snapshot: Snapshot? = nil
    local stored: {File}?
    local files_error: Result?
    if input.snapshot_digest then
        snapshot, stored, files_error = load_verified_snapshot(store, tx, input.workspace_id, input.snapshot_digest)
        if not snapshot or not stored then return files_error or failure("INTERNAL", "read workspace snapshot") end
        revision = snapshot.revision
    else
        stored, files_error = files(store, tx, input.workspace_id, "workspace", nil)
        if not stored then return files_error or failure("INTERNAL", "read workspace files") end
    end
    local manifest: {{path: string, bytes: integer, digest: string}} = {}
    for index, file in ipairs(stored) do manifest[index] = {path = file.path, bytes = file.bytes, digest = file.digest} end
    local extra: {[string]: unknown} = {files = manifest}
    if snapshot then
        extra.snapshot_digest, extra.digest = snapshot.digest, snapshot.digest
        extra.files_digest, extra.file_count, extra.total_bytes = snapshot.files_digest, snapshot.file_count, snapshot.total_bytes
    end
    return shared.success(value(store, input.workspace_id, revision, extra), false)
end
local function read(store: Store, tx: sql.Transaction, actor: string, input: protocol.Request): Result
    local current, owner_error = owner(store, tx, actor, input.workspace_id)
    if not current then return owner_error or failure("NOT_FOUND", "workspace does not exist") end
    local path = bounds.text(input.path, MAX_PATH_BYTES)
    if not path or #path == 0 then return failure("INVALID", "workspace path is missing") end
    if input.snapshot_digest then
        local snapshot, stored, snapshot_error = load_verified_snapshot(store, tx, input.workspace_id, input.snapshot_digest)
        if not snapshot or not stored then return snapshot_error or failure("INTERNAL", "read workspace snapshot") end
        for _, file in ipairs(stored) do
            if file.path == path then
                return shared.success(value(store, input.workspace_id, snapshot.revision, {path = file.path,
                    content_base64 = file.content_base64, bytes = file.bytes, digest = file.digest,
                    snapshot_digest = snapshot.digest, files_digest = snapshot.files_digest,
                    file_count = snapshot.file_count, total_bytes = snapshot.total_bytes}), false)
            end
        end
        return failure("NOT_FOUND", "workspace snapshot file does not exist")
    end
    local row, row_error = one(tx, "SELECT path, content_base64, content_sha256, bytes FROM bee_governance_workspace_files WHERE owner_node = ? AND workspace_id = ? AND path = ?", {store.node, input.workspace_id, path}, "workspace file")
    if row_error then return row_error end
    if not row then return failure("NOT_FOUND", "workspace file does not exist") end
    local file, decode_error = decode_file(row)
    if not file then return decode_error or failure("INTERNAL", "workspace file is corrupt") end
    return shared.success(value(store, input.workspace_id, current.revision, {path = file.path, content_base64 = file.content_base64, bytes = file.bytes, digest = file.digest}), false)
end

-- Host services may read one exact immutable file after selecting the source
-- workspace themselves. This does not expose mutable authoring state and does
-- not impersonate the actor that owns the workspace.
function M.read_frozen(store: Store, workspace_raw: string, path_raw: string, digest_raw: string): Result
    if store.closed then return failure("CLOSED", "workspace store is closed") end
    local workspace_id = bounds.id(workspace_raw)
    local path = bounds.text(path_raw, MAX_PATH_BYTES)
    local snapshot_digest = bounds.id(digest_raw)
    if not workspace_id or not path or #path == 0 or not snapshot_digest
        or #snapshot_digest ~= 64 or not snapshot_digest:match("^[0-9a-f]+$") then
        return failure("INVALID", "frozen overlay file identity is invalid")
    end
    local selected_workspace: string = workspace_id :: string
    local selected_digest: string = snapshot_digest :: string
    return shared.read(store.db, "governance", function(tx: sql.Transaction): Result
        local current, workspace_error = load_workspace(store, tx, selected_workspace)
        if not current then return workspace_error or failure("NOT_FOUND", "workspace does not exist") end
        local snapshot, stored, snapshot_error = load_verified_snapshot(store, tx, selected_workspace, selected_digest)
        if not snapshot or not stored then return snapshot_error or failure("INTERNAL", "read workspace snapshot") end
        for _, file in ipairs(stored) do
            if file.path == path then
                return shared.success(value(store, selected_workspace, snapshot.revision, {path = file.path,
                    content_base64 = file.content_base64, bytes = file.bytes, digest = file.digest,
                    snapshot_digest = snapshot.digest, files_digest = snapshot.files_digest,
                    file_count = snapshot.file_count, total_bytes = snapshot.total_bytes}), false)
            end
        end
        return failure("NOT_FOUND", "workspace snapshot file does not exist")
    end)
end
function M.call(store: Store, actor_raw: string, input: protocol.Request): Result
    if store.closed then return failure("CLOSED", "workspace store is closed") end
    local actor = bounds.id(actor_raw)
    if not actor then return failure("INVALID", "workspace actor is invalid") end
    if input.operation == "list" or input.operation == "read" then
        return shared.read(store.db, "governance", function(tx: sql.Transaction): Result
            if input.operation == "list" then return list(store, tx, actor, input) end
            return read(store, tx, actor, input)
        end)
    end
    return shared.write(store.db, "governance", function(tx: sql.Transaction): Result
        local content_digest, digest_error = request_identity(input)
        if digest_error then return digest_error end
        if input.operation == "create" then return create(store, tx, actor, input, content_digest) end
        if input.operation == "put" or input.operation == "remove" then return mutation(store, tx, actor, input, content_digest) end
        if input.operation == "freeze" then return freeze(store, tx, actor, input, content_digest) end
        return failure("INVALID", "unknown workspace operation")
    end)
end
function M.close(store: Store): (boolean, string?)
    if store.closed then return true, nil end
    store.closed = true
    local released, err = store.db:release()
    if released ~= true or err then return false, "close governance database" end
    return true, nil
end
function M.open(resource: string, node_raw: string): (Store?, string?)
    if type(resource) ~= "string" or resource == "" then return nil, "governance database is not linked" end
    local node = bounds.id(node_raw)
    if not node then return nil, "governance node identity is invalid" end
    local db, err = database.open({resource = resource,
        ledger = {table = "bee_governance_migrations", label = "governance"}, migrations = migrations.all()})
    if not db then return nil, err end
    return {db = db, node = node, closed = false, call = M.call,
        read_frozen = M.read_frozen, close = M.close}, nil
end
return M
