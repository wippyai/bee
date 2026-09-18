-- MIT. The shared projection engine: a checkpoint folded from committed
-- records only, committed with its cursor under a revision compare-and-set.
-- A projection is derived and rebuildable; it is never a source of delivery
-- or lifecycle state, and each kind keeps its own revision and cursor. A
-- spec supplies the schema, kind, empty checkpoint and pure fold; the engine
-- owns reading, bounded folding and the revision fence.
local sql = require("sql")
local json = require("json")
local hash = require("hash")
local bounds = require("bounds")
local canonical = require("canonical")
local record = require("record")
local record_types = require("record_types")
local reader = require("reader")
local transaction = require("transaction")
local authority = require("authority")
local owner = require("owner")
local M = {}
type Result = transaction.Result
type Checkpoint = {[string]: unknown}
type Spec = {schema: string, kind: string, empty: () -> Checkpoint, fold: (Checkpoint, record_types.Record) -> Checkpoint}
type Stored = {through_sequence: integer, revision: integer, checkpoint: Checkpoint, digest: string}
M.BATCH = 64
M.MAX_ROUNDS = 8
local function failure(code: string, message: string): Result
    return transaction.failure(code, message)
end
local function storage(err: string): Result
    if err == "BUSY" then return transaction.storage_failure("thread database is busy") end
    return transaction.failure("INTERNAL", err)
end
function M.digest(spec: Spec, checkpoint: Checkpoint, through: integer): (string?, string?)
    local encoded, encode_error = canonical.encode({schema = spec.schema, through_sequence = through, checkpoint = checkpoint})
    if not encoded then return nil, encode_error end
    local digest, hash_error = hash.sha256(encoded)
    if hash_error or not digest then return nil, "digest checkpoint" end
    return digest, nil
end
local function decode_checkpoint(spec: Spec, text: string): (Checkpoint?, string?)
    local value: unknown, err = json.decode(text)
    if err or type(value) ~= "table" then return nil, "stored checkpoint is corrupt" end
    local checkpoint = value :: Checkpoint
    if checkpoint.schema ~= spec.schema then return nil, "stored checkpoint has another schema" end
    return checkpoint, nil
end
local function stored(spec: Spec, tx: sql.Transaction, thread_id: string): (Stored?, string?)
    local rows, err = tx:query("SELECT through_sequence, revision, checkpoint_json, checkpoint_digest FROM bee_thread_projections WHERE thread_id = ? AND kind = ?", {thread_id, spec.kind})
    if err or not rows then return nil, "read projection" end
    if #rows == 0 then return nil, nil end
    local row = rows[1]
    local through, revision = bounds.integer(row.through_sequence), bounds.integer(row.revision)
    if not through or not revision or type(row.checkpoint_json) ~= "string" or type(row.checkpoint_digest) ~= "string" then return nil, "projection row is corrupt" end
    local checkpoint, decode_error = decode_checkpoint(spec, row.checkpoint_json)
    if not checkpoint then return nil, decode_error end
    return {through_sequence = through, revision = revision, checkpoint = checkpoint, digest = row.checkpoint_digest}, nil
end
M.stored = stored
-- The durable owner identity, so a reader can fence a replacement owner. It
-- is empty until an owner has started; a reader treats a changed authority
-- as a reset, never as progress.
local function owner_identity(tx: sql.Transaction): (string, integer)
    local authority_id = owner.authority(tx) or ""
    local incarnation = owner.current(tx) or 0
    return authority_id, incarnation
end
local function view(spec: Spec, current: Stored?): {[string]: unknown}
    if not current then return {through_sequence = 0, revision = 0, checkpoint = spec.empty(), digest = nil} end
    return {through_sequence = current.through_sequence, revision = current.revision, checkpoint = current.checkpoint, digest = current.digest}
end
M.view = view
function M.thread_of(request: unknown): (string?, Result?)
    local object = bounds.object(request)
    if not object then return nil, failure("INVALID_ARGUMENT", "request must be an object") end
    local unknown_field = bounds.fields(object, {"thread_id", "idempotency_key"})
    if unknown_field then return nil, failure("INVALID_ARGUMENT", unknown_field) end
    local thread_id = bounds.id(object.thread_id)
    if not thread_id then return nil, failure("INVALID_ARGUMENT", "thread_id is not an identifier") end
    return thread_id, nil
end
-- read: the stored checkpoint under the caller's membership, with the head
-- sequence so a reader can tell how far behind the projection is. The engine
-- returns the raw checkpoint; a projection's own read method may derive
-- caller-specific fields from it without persisting them.
function M.read(spec: Spec, db: sql.DB, actor: string, request: unknown): Result
    local thread_id, invalid = M.thread_of(request)
    if not thread_id then return invalid or failure("INVALID_ARGUMENT", "invalid request") end
    return transaction.read(db, function(tx: sql.Transaction): Result
        local head, member, denied = authority.membership(tx, thread_id, actor)
        if not head or not member then return denied or failure("DENIED", "caller is not a member of the thread") end
        local current, err = stored(spec, tx, thread_id)
        if err then return storage(err) end
        local result = view(spec, current)
        result.head_sequence = head.head_sequence
        result.owner_authority, result.owner_incarnation = owner_identity(tx)
        return transaction.success(result, false)
    end)
end
local function round(spec: Spec, db: sql.DB, actor: string, thread_id: string): (Result, boolean)
    local base: Stored? = nil
    local batch: {record_types.Record} = {}
    local head_sequence = 0
    local read_result = transaction.read(db, function(tx: sql.Transaction): Result
        local head, member, denied = authority.membership(tx, thread_id, actor)
        if not head or not member then return denied or failure("DENIED", "caller is not a member of the thread") end
        head_sequence = head.head_sequence
        local current, err = stored(spec, tx, thread_id)
        if err then return storage(err) end
        base = current
        local from = 0
        if current then from = current.through_sequence end
        local rows, rows_err = reader.page(tx, thread_id, from, math.floor(math.min(from + M.BATCH, head.head_sequence)), M.BATCH, nil, nil)
        if not rows then return storage(rows_err or "read thread records") end
        for index = 1, math.min(#rows, M.BATCH) do
            local decoded, decode_error = record.decode_json(rows[index].record_json)
            if not decoded then return failure("INTERNAL", decode_error or "stored record is corrupt") end
            batch[index] = decoded
        end
        return transaction.success(nil, false)
    end)
    if not read_result.ok then return read_result, false end
    local current = base
    if #batch == 0 then
        local result = view(spec, current)
        result.head_sequence = head_sequence
        return transaction.read(db, function(tx: sql.Transaction): Result
            result.owner_authority, result.owner_incarnation = owner_identity(tx)
            return transaction.success(result, false)
        end), false
    end
    local checkpoint = spec.empty()
    local revision = 0
    local through = 0
    if current then
        checkpoint = current.checkpoint
        revision = current.revision
        through = current.through_sequence
    end
    for _, entry in ipairs(batch) do
        checkpoint = spec.fold(checkpoint, entry)
        through = entry.sequence
    end
    local digest, digest_error = M.digest(spec, checkpoint, through)
    if not digest then return failure("INTERNAL", digest_error or "digest checkpoint"), false end
    local encoded, encode_error = canonical.encode(checkpoint)
    if not encoded then return failure("INTERNAL", encode_error or "encode checkpoint"), false end
    local write_result = transaction.write(db, function(tx: sql.Transaction): Result
        local latest, err = stored(spec, tx, thread_id)
        if err then return storage(err) end
        local latest_revision = 0
        if latest then latest_revision = latest.revision end
        if latest_revision ~= revision then return failure("CONFLICT", "the projection moved; fold again") end
        local write_err = transaction.write_projection(tx, thread_id, spec.kind, through, revision + 1, encoded, digest, transaction.now())
        if write_err then return storage(write_err) end
        return transaction.success({through_sequence = through, revision = revision + 1, checkpoint = checkpoint, digest = digest, head_sequence = head_sequence}, false)
    end)
    if not write_result.ok and write_result.code == "CONFLICT" then return write_result, true end
    return write_result, write_result.ok and through < head_sequence
end
function M.update(spec: Spec, db: sql.DB, actor: string, request: unknown): Result
    local thread_id, invalid = M.thread_of(request)
    if not thread_id then return invalid or failure("INVALID_ARGUMENT", "invalid request") end
    local last: Result = failure("INTERNAL", "projection did not run")
    for _ = 1, M.MAX_ROUNDS do
        local result, continue_folding = round(spec, db, actor, thread_id)
        last = result
        if not continue_folding then return result end
    end
    return last
end
function M.rebuild(spec: Spec, db: sql.DB, actor: string, request: unknown): Result
    local thread_id, invalid = M.thread_of(request)
    if not thread_id then return invalid or failure("INVALID_ARGUMENT", "invalid request") end
    local dropped = transaction.write(db, function(tx: sql.Transaction): Result
        local head, member, denied = authority.membership(tx, thread_id, actor)
        if not head or not member then return denied or failure("DENIED", "caller is not a member of the thread") end
        if head.owner_actor ~= actor then return failure("DENIED", "only the owner rebuilds a projection") end
        local err = transaction.drop_projection(tx, thread_id, spec.kind)
        if err then return storage(err) end
        return transaction.success(nil, false)
    end)
    if not dropped.ok then return dropped end
    return M.update(spec, db, actor, request)
end
return M
