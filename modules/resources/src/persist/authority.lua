-- MIT. The resource authority: associations bind a workspace name to an
-- admitted root under a host ceiling; grants bind an authenticated subject,
-- an audience, an exact association revision and root digest, a scope and
-- an expiry; resolve re-checks all of it for the placement that asks.
-- Replacing an association or changing a root never retargets a grant.
local sql = require("sql")
local hash = require("hash")
local time = require("time")
local uuid = require("uuid")
local security = require("security")
local system = require("system")
local bounds = require("bounds")
local canonical = require("canonical")
local persist = require("persist")
local transaction = require("transaction")
local migrations = require("migrations")
local resources = require("resources")
local M = {}
M.LEDGER = {table = "bee_resource_schema_migrations", label = "resource"}
M.MANAGE = "bee.resources.manage"
M.GRANT = "bee.resources.grant"
M.RESOLVE = "bee.resources.resolve"
M.MAX_TTL_MS = 86400000
M.DEFAULT_TTL_MS = 3600000
M.MAX_LIST = 64
M.ACCESS = {"read", "write"}
M.PURPOSES = {"project", "output", "cache", "session"}
type Fault = {code: string, message: string}
type Reply = {ok: boolean, error: Fault?, value: unknown}
type Row = {[string]: unknown}
type TransactionResult = {ok: boolean, code: string?, message: string?, value: unknown, replayed: boolean, commit: boolean?}
local function fail(code: string, message: string): Reply
    return {ok = false, error = {code = code, message = message}, value = nil}
end
local function succeed(value: unknown): Reply
    return {ok = true, error = nil, value = value}
end
local function now_ms(): integer
    return math.floor(time.now():unix_nano() / 1000000)
end
local function stamp(ms: integer): string
    return time.unix(math.floor(ms / 1000), (ms % 1000) * 1000000):utc():format("2006-01-02T15:04:05.000Z07:00")
end
local function actor(): string?
    local current = security.actor()
    if not current then return nil end
    return bounds.id(current:id())
end
local function node(): string
    local id, err = system.node.id()
    if err or type(id) ~= "string" or id == "" then return "local" end
    return id
end
local function open(): (sql.DB?, Reply?)
    local resource, resource_error = resources.database()
    if not resource then return nil, fail("STORAGE", resource_error or "resource database") end
    local db, open_error = persist.open({resource = resource, ledger = M.LEDGER, migrations = migrations.all()})
    if not db then return nil, fail("STORAGE", open_error or "open resource store") end
    return db, nil
end
local function digest_of(value: unknown): (string?, string?)
    local encoded, encode_error = canonical.encode(value)
    if not encoded then return nil, encode_error end
    local sum, hash_error = hash.sha256(encoded)
    if hash_error or not sum then return nil, "digest failed" end
    return sum, nil
end
local function text(value: unknown): string?
    if type(value) ~= "string" then return nil end
    return value
end
local function integer(value: unknown): integer?
    if type(value) ~= "number" then return nil end
    return math.floor(value)
end
local function rank(access: string): integer
    if access == "write" then return 2 end
    return 1
end
local function association_view(row: Row): {[string]: unknown}
    return {workspace_id = row.workspace_id, name = row.name, association_id = row.association_id, revision = row.revision, root_ref = row.root_ref,
        root_digest = row.root_digest, subpath = row.subpath, allowed_access = row.allowed_access, owner_node = row.owner_node, created_at = row.created_at, updated_at = row.updated_at}
end
local function grant_view(row: Row): {[string]: unknown}
    return {grant_id = row.grant_id, workspace_id = row.workspace_id, name = row.name, association_id = row.association_id, association_revision = row.association_revision,
        issuer_owner = row.issuer_owner, subject = row.subject, audience = row.audience, root_ref = row.root_ref, root_digest = row.root_digest, subpath = row.subpath,
        access = row.access, purpose = row.purpose, attempt_id = row.attempt_id, expires_at = row.expires_at, authorization_epoch = row.authorization_epoch,
        revoked_at = row.revoked_at, created_at = row.created_at}
end
local function epoch_of(db: sql.DB, workspace_id: string): (integer?, string?)
    local rows, err = db:query("SELECT epoch FROM bee_resource_epochs WHERE workspace_id = ?", {workspace_id})
    if err or not rows then return nil, "read authorization epoch" end
    if #rows == 0 then return 0, nil end
    return integer(rows[1].epoch) or 0, nil
end
local function association_of(db: sql.DB, workspace_id: string, name: string): (Row?, string?)
    local rows, err = db:query("SELECT * FROM bee_resource_associations WHERE workspace_id = ? AND name = ?", {workspace_id, name})
    if err or not rows then return nil, "read association" end
    if #rows == 0 then return nil, nil end
    return rows[1] :: Row, nil
end
local function association_in(tx: sql.Transaction, workspace_id: string, name: string): (Row?, string?)
    local rows, err = tx:query("SELECT * FROM bee_resource_associations WHERE workspace_id = ? AND name = ?", {workspace_id, name})
    if err or not rows then return nil, "read association" end
    if #rows == 0 then return nil, nil end
    return rows[1] :: Row, nil
end
local function grant_of(db: sql.DB, grant_id: string): (Row?, string?)
    local rows, err = db:query("SELECT * FROM bee_resource_grants WHERE grant_id = ?", {grant_id})
    if err or not rows then return nil, "read grant" end
    if #rows == 0 then return nil, nil end
    return rows[1] :: Row, nil
end
-- associate: a workspace manager binds a name to an admitted root; a
-- second association under the same name replaces it at the next revision
-- and existing grants no longer resolve.
function M.associate(value: unknown): Reply
    local object = bounds.object(value)
    if not object then return fail("INVALID", "request must be an object") end
    local unknown_field = bounds.fields(object, {"workspace_id", "name", "root_ref", "subpath", "allowed_access", "expected_revision"})
    if unknown_field then return fail("INVALID", unknown_field) end
    local workspace_id, name, root_ref = bounds.id(object.workspace_id), bounds.id(object.name), bounds.id(object.root_ref)
    if not workspace_id then return fail("INVALID", "workspace_id is not an identifier") end
    if not name then return fail("INVALID", "name is not an identifier") end
    if not root_ref then return fail("INVALID", "root_ref is not an identifier") end
    local subpath, subpath_error = bounds.subpath(object.subpath == nil and "" or object.subpath)
    if not subpath then return fail("INVALID", subpath_error or "invalid subpath") end
    local allowed = bounds.member(object.allowed_access == nil and "read" or object.allowed_access, M.ACCESS)
    if not allowed then return fail("INVALID", "allowed_access must be read or write") end
    local expected_revision: integer? = nil
    if object.expected_revision ~= nil then
        expected_revision = bounds.count(object.expected_revision)
        if expected_revision == nil then return fail("INVALID", "expected_revision must be a nonnegative integer") end
    end
    local caller = actor()
    if not caller then return fail("UNAUTHENTICATED", "no actor") end
    if not security.can(M.MANAGE, workspace_id) then return fail("DENIED", "caller does not manage workspace " .. workspace_id) end
    local roots, roots_error = resources.host_roots()
    if not roots then return fail("STORAGE", roots_error or "host roots") end
    local ceiling = roots[root_ref]
    if not ceiling then return fail("FORBIDDEN", "root " .. root_ref .. " is not admitted on this host") end
    if rank(allowed) > rank(ceiling) then return fail("FORBIDDEN", "root " .. root_ref .. " is admitted " .. ceiling .. " only") end
    local root, root_error = resources.root(root_ref)
    if not root then return fail("INVALID", root_error or "root") end
    local root_digest, digest_error = digest_of(root)
    if not root_digest then return fail("INVALID", digest_error or "root is not measurable") end
    local db, open_failure = open()
    if not db then return open_failure :: Reply end
    local result: TransactionResult = transaction.write(db, "associate", function(tx: sql.Transaction): TransactionResult
        local existing, existing_error = association_in(tx, workspace_id, name)
        if existing_error then return transaction.failure("STORAGE", existing_error) :: TransactionResult end
        local current_revision = 0
        if existing then
            current_revision = integer(existing.revision)
            if not current_revision then return transaction.failure("STORAGE", "association revision is corrupt") :: TransactionResult end
        end
        if expected_revision ~= nil and expected_revision ~= current_revision then
            return transaction.failure("CONFLICT", "expected_revision does not match the association") :: TransactionResult
        end
        if existing and existing.root_ref == root_ref and existing.root_digest == root_digest
            and existing.subpath == subpath and existing.allowed_access == allowed then
            return transaction.success(association_view(existing), true) :: TransactionResult
        end
        local at = stamp(now_ms())
        local revision = current_revision + 1
        local association_id, id_error = uuid.v7()
        if id_error or not association_id then return transaction.failure("STORAGE", "association id") :: TransactionResult end
        if existing then
            local _, update_error = tx:execute("UPDATE bee_resource_associations SET association_id = ?, revision = ?, root_ref = ?, root_digest = ?, subpath = ?, allowed_access = ?, owner_node = ?, updated_at = ? WHERE workspace_id = ? AND name = ?",
                {association_id, revision, root_ref, root_digest, subpath, allowed, node(), at, workspace_id, name})
            if update_error then return transaction.failure("STORAGE", "replace association") :: TransactionResult end
        else
            local _, insert_error = tx:execute("INSERT INTO bee_resource_associations (workspace_id, name, association_id, revision, root_ref, root_digest, subpath, allowed_access, owner_node, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(workspace_id, name) DO NOTHING",
                {workspace_id, name, association_id, revision, root_ref, root_digest, subpath, allowed, node(), at, at})
            if insert_error then return transaction.failure("STORAGE", "record association") :: TransactionResult end
        end
        local stored, stored_error = association_in(tx, workspace_id, name)
        if stored_error or not stored then return transaction.failure("STORAGE", stored_error or "read association") :: TransactionResult end
        if not existing and stored.association_id ~= association_id then
            if expected_revision == 0 then return transaction.failure("CONFLICT", "association was created concurrently") :: TransactionResult end
            return transaction.failure("STORAGE", "association changed during creation") :: TransactionResult
        end
        return transaction.success(association_view(stored), false) :: TransactionResult
    end) :: TransactionResult
    db:release()
    if not result.ok then return fail(result.code or "STORAGE", result.message or "associate failed") end
    return succeed(result.value)
end
-- grant: the authenticated actor is the subject; the audience is the
-- placement owner the grant is for; the association and root are pinned
-- at their current revision and digest. An idempotency key replays the
-- same grant for the same request and conflicts on a different one.
function M.grant(value: unknown): Reply
    local object = bounds.object(value)
    if not object then return fail("INVALID", "request must be an object") end
    local unknown_field = bounds.fields(object, {"workspace_id", "name", "access", "purpose", "audience", "attempt_id", "ttl_ms", "idempotency_key"})
    if unknown_field then return fail("INVALID", unknown_field) end
    local idempotency_key: string? = nil
    if object.idempotency_key ~= nil then
        idempotency_key = bounds.id(object.idempotency_key)
        if not idempotency_key then return fail("INVALID", "idempotency_key is not an identifier") end
    end
    local workspace_id, name = bounds.id(object.workspace_id), bounds.id(object.name)
    if not workspace_id then return fail("INVALID", "workspace_id is not an identifier") end
    if not name then return fail("INVALID", "name is not an identifier") end
    local access = bounds.member(object.access, M.ACCESS)
    if not access then return fail("INVALID", "access must be read or write") end
    local purpose = bounds.member(object.purpose, M.PURPOSES)
    if not purpose then return fail("INVALID", "purpose is not one the authority knows") end
    local audience = bounds.id(object.audience)
    if not audience then return fail("INVALID", "audience is not an identifier") end
    local attempt_id: string? = nil
    if object.attempt_id ~= nil then
        attempt_id = bounds.id(object.attempt_id)
        if not attempt_id then return fail("INVALID", "attempt_id is not an identifier") end
    end
    local ttl = M.DEFAULT_TTL_MS
    if object.ttl_ms ~= nil then
        local declared = bounds.integer(object.ttl_ms)
        if not declared or declared < 1 or declared > M.MAX_TTL_MS then return fail("INVALID", "ttl_ms must be between 1 and " .. tostring(M.MAX_TTL_MS)) end
        ttl = declared
    end
    local subject = actor()
    if not subject then return fail("UNAUTHENTICATED", "no actor") end
    if not security.can(M.GRANT, workspace_id) then return fail("DENIED", "caller may not take grants in workspace " .. workspace_id) end
    local request_digest, request_digest_error = digest_of({workspace_id = workspace_id, name = name, access = access, purpose = purpose, audience = audience, attempt_id = attempt_id})
    if not request_digest then return fail("INVALID", request_digest_error or "request is not measurable") end
    local db, open_failure = open()
    if not db then return open_failure :: Reply end
    if idempotency_key then
        local replay, replay_error = db:query("SELECT * FROM bee_resource_grants WHERE subject = ? AND idempotency_key = ?", {subject, idempotency_key})
        if replay_error or not replay then
            db:release()
            return fail("STORAGE", "read grants")
        end
        if #replay == 1 then
            local stored = replay[1] :: Row
            db:release()
            if stored.request_digest ~= request_digest then return fail("CONFLICT", "idempotency key reused with a different request") end
            return succeed(grant_view(stored))
        end
    end
    local association, association_error = association_of(db, workspace_id, name)
    if association_error then
        db:release()
        return fail("STORAGE", association_error)
    end
    if not association then
        db:release()
        return fail("NOT_FOUND", "no association " .. name .. " in workspace " .. workspace_id)
    end
    local root, root_error = resources.root(text(association.root_ref) or "")
    if not root then
        db:release()
        return fail("CONFLICT", root_error or "root is gone")
    end
    local root_digest = digest_of(root)
    if root_digest ~= association.root_digest then
        db:release()
        return fail("CONFLICT", "root definition changed; the association needs replacement")
    end
    if rank(access) > rank(text(association.allowed_access) or "read") then
        db:release()
        return fail("FORBIDDEN", "association " .. name .. " allows " .. tostring(association.allowed_access) .. " only")
    end
    local epoch, epoch_error = epoch_of(db, workspace_id)
    if not epoch then
        db:release()
        return fail("STORAGE", epoch_error or "epoch")
    end
    local grant_id, id_error = uuid.v7()
    if id_error or not grant_id then
        db:release()
        return fail("STORAGE", "grant id")
    end
    local created = now_ms()
    local _, insert_error = db:execute([[INSERT INTO bee_resource_grants (grant_id, workspace_id, name, association_id, association_revision, issuer_owner, subject, audience,
        root_ref, root_digest, subpath, access, purpose, attempt_id, expires_at, authorization_epoch, idempotency_key, request_digest, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]],
        {grant_id, workspace_id, name, association.association_id, association.revision, node(), subject, audience, association.root_ref, association.root_digest,
            association.subpath, access, purpose, attempt_id, stamp(created + ttl), epoch, idempotency_key, request_digest, stamp(created)})
    if insert_error then
        db:release()
        return fail("STORAGE", "record grant")
    end
    local stored = grant_of(db, grant_id)
    db:release()
    if not stored then return fail("STORAGE", "read grant") end
    return succeed(grant_view(stored))
end
-- revoke: the subject or a manager ends a grant; revoke_all advances the
-- workspace's authorization epoch so every earlier grant stops resolving.
function M.revoke(value: unknown): Reply
    local object = bounds.object(value)
    if not object then return fail("INVALID", "request must be an object") end
    local unknown_field = bounds.fields(object, {"grant_id"})
    if unknown_field then return fail("INVALID", unknown_field) end
    local grant_id = bounds.id(object.grant_id)
    if not grant_id then return fail("INVALID", "grant_id is not an identifier") end
    local caller = actor()
    if not caller then return fail("UNAUTHENTICATED", "no actor") end
    local db, open_failure = open()
    if not db then return open_failure :: Reply end
    local grant, grant_error = grant_of(db, grant_id)
    if grant_error then
        db:release()
        return fail("STORAGE", grant_error)
    end
    if not grant then
        db:release()
        return fail("NOT_FOUND", "grant does not exist")
    end
    local workspace_id = text(grant.workspace_id) or ""
    if grant.subject ~= caller and not security.can(M.MANAGE, workspace_id) then
        db:release()
        return fail("DENIED", "only the subject or a workspace manager revokes a grant")
    end
    if grant.revoked_at == nil then
        local _, update_error = db:execute("UPDATE bee_resource_grants SET revoked_at = ? WHERE grant_id = ?", {stamp(now_ms()), grant_id})
        if update_error then
            db:release()
            return fail("STORAGE", "revoke grant")
        end
    end
    local stored = grant_of(db, grant_id)
    db:release()
    if not stored then return fail("STORAGE", "read grant") end
    return succeed(grant_view(stored))
end
function M.revoke_all(value: unknown): Reply
    local object = bounds.object(value)
    if not object then return fail("INVALID", "request must be an object") end
    local unknown_field = bounds.fields(object, {"workspace_id"})
    if unknown_field then return fail("INVALID", unknown_field) end
    local workspace_id = bounds.id(object.workspace_id)
    if not workspace_id then return fail("INVALID", "workspace_id is not an identifier") end
    if not actor() then return fail("UNAUTHENTICATED", "no actor") end
    if not security.can(M.MANAGE, workspace_id) then return fail("DENIED", "caller does not manage workspace " .. workspace_id) end
    local db, open_failure = open()
    if not db then return open_failure :: Reply end
    local epoch, epoch_error = epoch_of(db, workspace_id)
    if not epoch then
        db:release()
        return fail("STORAGE", epoch_error or "epoch")
    end
    local _, upsert_error = db:execute("INSERT INTO bee_resource_epochs (workspace_id, epoch) VALUES (?, ?) ON CONFLICT(workspace_id) DO UPDATE SET epoch = excluded.epoch", {workspace_id, epoch + 1})
    db:release()
    if upsert_error then return fail("STORAGE", "advance authorization epoch") end
    return succeed({workspace_id = workspace_id, authorization_epoch = epoch + 1})
end
-- resolve: a placement asks with the subject and audience it admitted
-- itself; every binding of the grant is re-checked against the present.
function M.resolve(value: unknown): Reply
    local object = bounds.object(value)
    if not object then return fail("INVALID", "request must be an object") end
    local unknown_field = bounds.fields(object, {"grant_id", "subject", "audience", "attempt_id"})
    if unknown_field then return fail("INVALID", unknown_field) end
    local grant_id, subject, audience = bounds.id(object.grant_id), bounds.id(object.subject), bounds.id(object.audience)
    if not grant_id then return fail("INVALID", "grant_id is not an identifier") end
    if not subject then return fail("INVALID", "subject is not an identifier") end
    if not audience then return fail("INVALID", "audience is not an identifier") end
    local attempt_id: string? = nil
    if object.attempt_id ~= nil then
        attempt_id = bounds.id(object.attempt_id)
        if not attempt_id then return fail("INVALID", "attempt_id is not an identifier") end
    end
    if not actor() then return fail("UNAUTHENTICATED", "no actor") end
    local db, open_failure = open()
    if not db then return open_failure :: Reply end
    local grant, grant_error = grant_of(db, grant_id)
    if grant_error then
        db:release()
        return fail("STORAGE", grant_error)
    end
    if not grant then
        db:release()
        return fail("NOT_FOUND", "grant does not exist")
    end
    local workspace_id = text(grant.workspace_id) or ""
    if not security.can(M.RESOLVE, workspace_id) then
        db:release()
        return fail("DENIED", "caller is not a placement admitted to resolve in workspace " .. workspace_id)
    end
    if grant.revoked_at ~= nil then
        db:release()
        return fail("REVOKED", "grant was revoked at " .. tostring(grant.revoked_at))
    end
    if tostring(grant.expires_at) <= stamp(now_ms()) then
        db:release()
        return fail("EXPIRED", "grant expired at " .. tostring(grant.expires_at))
    end
    if grant.subject ~= subject or grant.audience ~= audience then
        db:release()
        return fail("DENIED", "grant binds another subject or audience")
    end
    if grant.attempt_id ~= nil and grant.attempt_id ~= attempt_id then
        db:release()
        return fail("DENIED", "grant is scoped to another attempt")
    end
    local epoch, epoch_error = epoch_of(db, workspace_id)
    if not epoch then
        db:release()
        return fail("STORAGE", epoch_error or "epoch")
    end
    if (integer(grant.authorization_epoch) or 0) < epoch then
        db:release()
        return fail("REVOKED", "workspace authorization epoch advanced past the grant")
    end
    local association, association_error = association_of(db, workspace_id, text(grant.name) or "")
    db:release()
    if association_error then return fail("STORAGE", association_error) end
    if not association or association.association_id ~= grant.association_id or association.revision ~= grant.association_revision then
        return fail("CONFLICT", "association was replaced; the grant needs re-admission")
    end
    local root, root_error = resources.root(text(grant.root_ref) or "")
    if not root then return fail("CONFLICT", root_error or "root is gone") end
    local root_digest = digest_of(root)
    if root_digest ~= grant.root_digest then return fail("CONFLICT", "root definition changed; the grant needs re-admission") end
    if association.owner_node ~= node() then return fail("RESOURCE_NOT_LOCAL", "resource belongs to node " .. tostring(association.owner_node)) end
    local directory = (root.data :: {[string]: unknown}).directory
    return succeed({grant_id = grant_id, workspace_id = workspace_id, name = grant.name, root_ref = grant.root_ref, root_digest = grant.root_digest, directory = directory,
        subpath = grant.subpath, access = grant.access, purpose = grant.purpose, association_id = grant.association_id, association_revision = grant.association_revision,
        expires_at = grant.expires_at, authorization_epoch = grant.authorization_epoch})
end
-- list: a manager's view of a workspace's associations and live grants.
function M.list(value: unknown): Reply
    local object = bounds.object(value)
    if not object then return fail("INVALID", "request must be an object") end
    local unknown_field = bounds.fields(object, {"workspace_id"})
    if unknown_field then return fail("INVALID", unknown_field) end
    local workspace_id = bounds.id(object.workspace_id)
    if not workspace_id then return fail("INVALID", "workspace_id is not an identifier") end
    if not actor() then return fail("UNAUTHENTICATED", "no actor") end
    if not security.can(M.MANAGE, workspace_id) then return fail("DENIED", "caller does not manage workspace " .. workspace_id) end
    local db, open_failure = open()
    if not db then return open_failure :: Reply end
    local associations, associations_error = db:query("SELECT * FROM bee_resource_associations WHERE workspace_id = ? ORDER BY name LIMIT ?", {workspace_id, M.MAX_LIST})
    local grants, grants_error = db:query("SELECT * FROM bee_resource_grants WHERE workspace_id = ? AND revoked_at IS NULL AND expires_at > ? ORDER BY created_at LIMIT ?", {workspace_id, stamp(now_ms()), M.MAX_LIST})
    db:release()
    if associations_error or not associations or grants_error or not grants then return fail("STORAGE", "read workspace resources") end
    local association_views: {{[string]: unknown}} = {}
    for index, row in ipairs(associations) do association_views[index] = association_view(row :: Row) end
    local grant_views: {{[string]: unknown}} = {}
    for index, row in ipairs(grants) do grant_views[index] = grant_view(row :: Row) end
    return succeed({workspace_id = workspace_id, associations = association_views, grants = grant_views})
end
-- The workspace extension methods: what one workspace holds here and which
-- of its resources match a name prefix, for a caller the workspace catalog
-- lets read that workspace.
M.READ_WORKSPACE = "bee.workspace.manager.read"
M.MAX_DESCRIBED = 50
local function described(row: Row): {[string]: unknown}
    local subpath = text(row.subpath) or ""
    local place = tostring(row.root_ref) .. (subpath ~= "" and ("/" .. subpath) or "")
    return {label = tostring(row.name), detail = place .. " · " .. tostring(row.allowed_access)}
end
local function readable(object: {[string]: unknown}): (string?, Reply?)
    local workspace_id = bounds.id(object.workspace_id)
    if not workspace_id then return nil, fail("INVALID", "workspace_id is not an identifier") end
    if not actor() then return nil, fail("UNAUTHENTICATED", "no actor") end
    if not security.can(M.READ_WORKSPACE, workspace_id) then return nil, fail("DENIED", "caller may not read workspace " .. workspace_id) end
    return workspace_id, nil
end
function M.describe(value: unknown): Reply
    local object = bounds.object(value)
    if not object then return fail("INVALID", "request must be an object") end
    local unknown_field = bounds.fields(object, {"workspace_id"})
    if unknown_field then return fail("INVALID", unknown_field) end
    local workspace_id, refused = readable(object)
    if not workspace_id then return refused :: Reply end
    local db, open_failure = open()
    if not db then return open_failure :: Reply end
    local rows, rows_error = db:query("SELECT name, root_ref, subpath, allowed_access FROM bee_resource_associations WHERE workspace_id = ? ORDER BY name LIMIT ?",
        {workspace_id, M.MAX_DESCRIBED})
    local counted, count_error = db:query("SELECT COUNT(*) AS total FROM bee_resource_associations WHERE workspace_id = ?", {workspace_id})
    db:release()
    if rows_error or not rows or count_error or not counted then return fail("STORAGE", "read workspace resources") end
    local items: {{[string]: unknown}} = {}
    for index, row in ipairs(rows) do items[index] = described(row :: Row) end
    return succeed({title = "Resources", items = items, total = integer((counted[1] :: Row).total) or #items})
end
function M.search(value: unknown): Reply
    local object = bounds.object(value)
    if not object then return fail("INVALID", "request must be an object") end
    local unknown_field = bounds.fields(object, {"workspace_id", "text", "limit"})
    if unknown_field then return fail("INVALID", unknown_field) end
    local prefix = bounds.line(object.text, 240)
    if not prefix then return fail("INVALID", "text must be one nonempty line") end
    local limit = M.MAX_DESCRIBED
    if object.limit ~= nil then
        local number = bounds.integer(object.limit)
        if not number or number < 1 or number > M.MAX_DESCRIBED then return fail("INVALID", "limit must be between 1 and " .. tostring(M.MAX_DESCRIBED)) end
        limit = number
    end
    local workspace_id, refused = readable(object)
    if not workspace_id then return refused :: Reply end
    local db, open_failure = open()
    if not db then return open_failure :: Reply end
    -- Names are identifiers without control bytes, so the successor of the
    -- prefix's last byte bounds the range of names that start with it.
    local upper = prefix:sub(1, #prefix - 1) .. string.char(prefix:byte(#prefix) + 1)
    local rows, rows_error = db:query("SELECT name, root_ref, subpath, allowed_access FROM bee_resource_associations " ..
        "WHERE workspace_id = ? AND name >= ? AND name < ? ORDER BY name LIMIT ?", {workspace_id, prefix, upper, limit})
    db:release()
    if rows_error or not rows then return fail("STORAGE", "search workspace resources") end
    local hits: {{[string]: unknown}} = {}
    for index, row in ipairs(rows) do hits[index] = described(row :: Row) end
    return succeed({title = "Resources", hits = hits})
end
function M.capabilities(): Reply
    return succeed({resource_authority = "granted", max_ttl_ms = M.MAX_TTL_MS, default_ttl_ms = M.DEFAULT_TTL_MS, nonlocal = "refused", transfer = false, node = node()})
end
return M
