-- MIT. The credential broker: definitions reference host-admitted secret
-- sources and never hold bytes; projections bind an authenticated subject,
-- an audience, an attempt, exact profile, binding and policy digests, a
-- provider-fixed destination and an expiry; materialize re-checks all of it
-- for the authorized materializer and returns bytes once, to that caller,
-- in a reply nothing persists.
local sql = require("sql")
local hash = require("hash")
local time = require("time")
local uuid = require("uuid")
local security = require("security")
local system = require("system")
local env = require("env")
local bounds = require("bounds")
local canonical = require("canonical")
local persist = require("persist")
local migrations = require("migrations")
local sources = require("sources")
local M = {}
M.LEDGER = {table = "bee_credential_schema_migrations", label = "credential"}
M.MANAGE = "bee.credentials.manage"
M.ISSUE = "bee.credentials.issue"
M.MATERIALIZE = "bee.credentials.materialize"
M.MAX_TTL_MS = 86400000
M.DEFAULT_TTL_MS = 3600000
M.MAX_SECRET_BYTES = 8192
M.MAX_LIST = 64
M.PROVIDERS = {"claude", "codex"}
type Fault = {code: string, message: string}
type Reply = {ok: boolean, error: Fault?, value: unknown}
type Row = {[string]: unknown}
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
    local resource, resource_error = sources.database()
    if not resource then return nil, fail("STORAGE", resource_error or "credential database") end
    local db, open_error = persist.open({resource = resource, ledger = M.LEDGER, migrations = migrations.all()})
    if not db then return nil, fail("STORAGE", open_error or "open credential store") end
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
local function definition_of(db: sql.DB, workspace_id: string, name: string): (Row?, string?)
    local rows, err = db:query("SELECT * FROM bee_credential_definitions WHERE workspace_id = ? AND name = ?", {workspace_id, name})
    if err or not rows then return nil, "read definition" end
    if #rows == 0 then return nil, nil end
    return rows[1] :: Row, nil
end
local function projection_of(db: sql.DB, projection_id: string): (Row?, string?)
    local rows, err = db:query("SELECT * FROM bee_credential_projections WHERE projection_id = ?", {projection_id})
    if err or not rows then return nil, "read projection" end
    if #rows == 0 then return nil, nil end
    return rows[1] :: Row, nil
end
local function epoch_of(db: sql.DB, workspace_id: string): (integer?, string?)
    local rows, err = db:query("SELECT epoch FROM bee_credential_epochs WHERE workspace_id = ?", {workspace_id})
    if err or not rows then return nil, "read authorization epoch" end
    if #rows == 0 then return 0, nil end
    return integer(rows[1].epoch) or 0, nil
end
local function definition_view(row: Row): {[string]: unknown}
    return {workspace_id = row.workspace_id, name = row.name, definition_id = row.definition_id, revision = row.revision, provider = row.provider,
        source_kind = row.source_kind, source_ref = row.source_ref, projection_kind = row.projection_kind, destination = row.destination, digest = row.digest,
        owner_node = row.owner_node, created_at = row.created_at, updated_at = row.updated_at}
end
-- A projection as callers see it: bindings, never bytes.
local function projection_view(row: Row): {[string]: unknown}
    return {projection_id = row.projection_id, workspace_id = row.workspace_id, name = row.name, definition_id = row.definition_id, definition_revision = row.definition_revision,
        issuer_owner = row.issuer_owner, issuer_incarnation = row.issuer_incarnation, subject = row.subject, audience = row.audience, attempt_id = row.attempt_id,
        profile_id = row.profile_id, profile_digest = row.profile_digest, binding_digest = row.binding_digest, launch_policy_digest = row.launch_policy_digest,
        provider = row.provider, projection_kind = row.projection_kind, destination = row.destination, materializer = row.materializer,
        materialization_generation = row.materialization_generation, expires_at = row.expires_at, authorization_epoch = row.authorization_epoch,
        revoked_at = row.revoked_at, created_at = row.created_at}
end
-- define: a workspace manager names a credential from a host-admitted
-- source; the digest covers configuration and source identity, never
-- bytes; redefining moves to the next revision and existing projections
-- stop resolving.
function M.define(value: unknown): Reply
    local object = bounds.object(value)
    if not object then return fail("INVALID", "request must be an object") end
    local unknown_field = bounds.fields(object, {"workspace_id", "name", "provider", "source"})
    if unknown_field then return fail("INVALID", unknown_field) end
    local workspace_id, name = bounds.id(object.workspace_id), bounds.id(object.name)
    if not workspace_id then return fail("INVALID", "workspace_id is not an identifier") end
    if not name then return fail("INVALID", "name is not an identifier") end
    local provider = bounds.member(object.provider, M.PROVIDERS)
    if not provider then return fail("INVALID", "provider must be claude or codex") end
    local source = bounds.object(object.source)
    if not source then return fail("INVALID", "source must be an object") end
    local source_field = bounds.fields(source, {"kind", "ref"})
    if source_field then return fail("INVALID", "source: " .. source_field) end
    if source.kind ~= "env_variable" then return fail("INVALID", "source.kind must be env_variable") end
    local source_ref = bounds.id(source.ref)
    if not source_ref then return fail("INVALID", "source.ref is not an identifier") end
    local caller = actor()
    if not caller then return fail("UNAUTHENTICATED", "no actor") end
    if not security.can(M.MANAGE, workspace_id) then return fail("DENIED", "caller does not manage workspace " .. workspace_id) end
    local admitted, admitted_error = sources.host_sources()
    if not admitted then return fail("STORAGE", admitted_error or "host sources") end
    if not sources.admits(admitted, source_ref, workspace_id, provider, "environment") then
        return fail("FORBIDDEN", "source " .. source_ref .. " is not admitted for " .. provider .. " environment projections in workspace " .. workspace_id)
    end
    local variable, variable_error = sources.variable(source_ref)
    if not variable then return fail("INVALID", variable_error or "source") end
    local destination = sources.DESTINATIONS[provider]
    local digest, digest_error = digest_of({provider = provider, source_kind = "env_variable", source_ref = source_ref, variable = variable, projection_kind = "environment", destination = destination})
    if not digest then return fail("INVALID", digest_error or "definition is not measurable") end
    local db, open_failure = open()
    if not db then return open_failure :: Reply end
    local existing, existing_error = definition_of(db, workspace_id, name)
    if existing_error then
        db:release()
        return fail("STORAGE", existing_error)
    end
    local definition_id, id_error = uuid.v7()
    if id_error or not definition_id then
        db:release()
        return fail("STORAGE", "definition id")
    end
    local at = stamp(now_ms())
    if existing then
        local revision = (integer(existing.revision) or 0) + 1
        local _, update_error = db:execute("UPDATE bee_credential_definitions SET definition_id = ?, revision = ?, provider = ?, source_kind = 'env_variable', source_ref = ?, projection_kind = 'environment', destination = ?, digest = ?, owner_node = ?, updated_at = ? WHERE workspace_id = ? AND name = ?",
            {definition_id, revision, provider, source_ref, destination, digest, node(), at, workspace_id, name})
        if update_error then
            db:release()
            return fail("STORAGE", "replace definition")
        end
    else
        local _, insert_error = db:execute("INSERT INTO bee_credential_definitions (workspace_id, name, definition_id, revision, provider, source_kind, source_ref, projection_kind, destination, digest, owner_node, created_at, updated_at) VALUES (?, ?, ?, 1, ?, 'env_variable', ?, 'environment', ?, ?, ?, ?, ?)",
            {workspace_id, name, definition_id, provider, source_ref, destination, digest, node(), at, at})
        if insert_error then
            db:release()
            return fail("STORAGE", "record definition")
        end
    end
    local stored = definition_of(db, workspace_id, name)
    db:release()
    if not stored then return fail("STORAGE", "read definition") end
    return succeed(definition_view(stored))
end
type Issue = {workspace_id: string, name: string, audience: string, attempt_id: string, profile_id: string, profile_digest: string, binding_digest: string, launch_policy_digest: string, idempotency_key: string, ttl: integer}
local function decode_issue(value: unknown): (Issue?, string?)
    local object = bounds.object(value)
    if not object then return nil, "request must be an object" end
    local unknown_field = bounds.fields(object, {"workspace_id", "name", "audience", "attempt_id", "profile_id", "profile_digest", "binding_digest", "launch_policy_digest", "idempotency_key", "ttl_ms"})
    if unknown_field then return nil, unknown_field end
    local workspace_id, name, audience = bounds.id(object.workspace_id), bounds.id(object.name), bounds.id(object.audience)
    local attempt_id, profile_id, key = bounds.id(object.attempt_id), bounds.id(object.profile_id), bounds.id(object.idempotency_key)
    local profile_digest, binding_digest, policy_digest = bounds.id(object.profile_digest), bounds.id(object.binding_digest), bounds.id(object.launch_policy_digest)
    if not workspace_id then return nil, "workspace_id is not an identifier" end
    if not name then return nil, "name is not an identifier" end
    if not audience then return nil, "audience is not an identifier" end
    if not attempt_id then return nil, "attempt_id is not an identifier" end
    if not profile_id then return nil, "profile_id is not an identifier" end
    if not key then return nil, "idempotency_key is not an identifier" end
    if not profile_digest or not binding_digest or not policy_digest then return nil, "profile_digest, binding_digest and launch_policy_digest are required" end
    local ttl = M.DEFAULT_TTL_MS
    if object.ttl_ms ~= nil then
        local declared = bounds.integer(object.ttl_ms)
        if not declared or declared < 1 or declared > M.MAX_TTL_MS then return nil, "ttl_ms must be between 1 and " .. tostring(M.MAX_TTL_MS) end
        ttl = declared
    end
    return {workspace_id = workspace_id, name = name, audience = audience, attempt_id = attempt_id, profile_id = profile_id, profile_digest = profile_digest,
        binding_digest = binding_digest, launch_policy_digest = policy_digest, idempotency_key = key, ttl = ttl}, nil
end
-- issue_projection: the authenticated subject binds a credential to one
-- attempt, profile, binding and policy for one audience; the same key
-- replays the same projection. No bytes move here.
function M.issue_projection(value: unknown): Reply
    local request, decode_error = decode_issue(value)
    if not request then return fail("INVALID", decode_error or "invalid request") end
    local subject = actor()
    if not subject then return fail("UNAUTHENTICATED", "no actor") end
    if not security.can(M.ISSUE, request.workspace_id) then return fail("DENIED", "caller may not take credential projections in workspace " .. request.workspace_id) end
    local db, open_failure = open()
    if not db then return open_failure :: Reply end
    local replay, replay_error = db:query("SELECT * FROM bee_credential_projections WHERE subject = ? AND idempotency_key = ?", {subject, request.idempotency_key})
    if replay_error or not replay then
        db:release()
        return fail("STORAGE", "read projections")
    end
    if #replay == 1 then
        local view = projection_view(replay[1] :: Row)
        db:release()
        if view.attempt_id ~= request.attempt_id or view.name ~= request.name then return fail("CONFLICT", "idempotency key reused with a different request") end
        return succeed(view)
    end
    local definition, definition_error = definition_of(db, request.workspace_id, request.name)
    if definition_error then
        db:release()
        return fail("STORAGE", definition_error)
    end
    if not definition then
        db:release()
        return fail("NOT_FOUND", "no credential " .. request.name .. " in workspace " .. request.workspace_id)
    end
    local admitted, admitted_error = sources.host_sources()
    if not admitted then
        db:release()
        return fail("STORAGE", admitted_error or "host sources")
    end
    if not sources.admits(admitted, text(definition.source_ref) or "", request.workspace_id, text(definition.provider) or "", "environment", request.audience) then
        db:release()
        return fail("FORBIDDEN", "the host does not admit audience " .. request.audience .. " for credential " .. request.name)
    end
    local epoch, epoch_error = epoch_of(db, request.workspace_id)
    if not epoch then
        db:release()
        return fail("STORAGE", epoch_error or "epoch")
    end
    local projection_id, id_error = uuid.v7()
    if id_error or not projection_id then
        db:release()
        return fail("STORAGE", "projection id")
    end
    local created = now_ms()
    local _, insert_error = db:execute([[INSERT INTO bee_credential_projections (projection_id, workspace_id, name, definition_id, definition_revision, issuer_owner, issuer_incarnation,
        subject, audience, attempt_id, profile_id, profile_digest, binding_digest, launch_policy_digest, provider, projection_kind, destination, materializer, idempotency_key,
        materialization_generation, expires_at, authorization_epoch, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?)]],
        {projection_id, request.workspace_id, request.name, definition.definition_id, definition.revision, node(), 1, subject, request.audience, request.attempt_id,
            request.profile_id, request.profile_digest, request.binding_digest, request.launch_policy_digest, definition.provider, definition.projection_kind, definition.destination,
            sources.MATERIALIZER, request.idempotency_key, stamp(created + request.ttl), epoch, stamp(created)})
    if insert_error then
        db:release()
        return fail("STORAGE", "record projection")
    end
    local stored = projection_of(db, projection_id)
    db:release()
    if not stored then return fail("STORAGE", "read projection") end
    return succeed(projection_view(stored))
end
-- The checks every use of a projection repeats; nil means it holds.
local function holds(db: sql.DB, projection: Row, subject: string, audience: string, attempt_id: string): Reply?
    if projection.revoked_at ~= nil then return fail("REVOKED", "projection was revoked at " .. tostring(projection.revoked_at)) end
    if tostring(projection.expires_at) <= stamp(now_ms()) then return fail("EXPIRED", "projection expired at " .. tostring(projection.expires_at)) end
    if projection.subject ~= subject or projection.audience ~= audience then return fail("DENIED", "projection binds another subject or audience") end
    if projection.attempt_id ~= attempt_id then return fail("DENIED", "projection is scoped to another attempt") end
    local workspace_id = text(projection.workspace_id) or ""
    local epoch, epoch_error = epoch_of(db, workspace_id)
    if not epoch then return fail("STORAGE", epoch_error or "epoch") end
    if (integer(projection.authorization_epoch) or 0) < epoch then return fail("REVOKED", "workspace authorization epoch advanced past the projection") end
    local definition, definition_error = definition_of(db, workspace_id, text(projection.name) or "")
    if definition_error then return fail("STORAGE", definition_error) end
    if not definition or definition.definition_id ~= projection.definition_id or definition.revision ~= projection.definition_revision then
        return fail("CONFLICT", "credential definition was replaced; the projection needs re-issue")
    end
    local admitted, admitted_error = sources.host_sources()
    if not admitted then return fail("STORAGE", admitted_error or "host sources") end
    if not sources.admits(admitted, text(definition.source_ref) or "", workspace_id, text(definition.provider) or "", "environment", audience) then
        return fail("FORBIDDEN", "the host no longer admits this source for audience " .. audience)
    end
    return nil
end
local function decode_use(value: unknown, extra: {string}): ({[string]: unknown}?, string?)
    local object = bounds.object(value)
    if not object then return nil, "request must be an object" end
    local allowed: {string} = {"projection_id", "subject", "audience", "attempt_id"}
    for _, name in ipairs(extra) do allowed[#allowed + 1] = name end
    local unknown_field = bounds.fields(object, allowed)
    if unknown_field then return nil, unknown_field end
    for _, name in ipairs({"projection_id", "subject", "audience", "attempt_id"}) do
        if not bounds.id(object[name]) then return nil, name .. " is not an identifier" end
    end
    return object, nil
end
-- check: the bindings without bytes, for a placement preparing or
-- reconciling an attempt.
function M.check(value: unknown): Reply
    local object, decode_error = decode_use(value, {})
    if not object then return fail("INVALID", decode_error or "invalid request") end
    if not actor() then return fail("UNAUTHENTICATED", "no actor") end
    local db, open_failure = open()
    if not db then return open_failure :: Reply end
    local projection, projection_error = projection_of(db, object.projection_id :: string)
    if projection_error then
        db:release()
        return fail("STORAGE", projection_error)
    end
    if not projection then
        db:release()
        return fail("NOT_FOUND", "projection does not exist")
    end
    local workspace_id = text(projection.workspace_id) or ""
    if not security.can(M.MATERIALIZE, workspace_id) then
        db:release()
        return fail("DENIED", "caller is not a materializer admitted in workspace " .. workspace_id)
    end
    local refused = holds(db, projection, object.subject :: string, object.audience :: string, object.attempt_id :: string)
    db:release()
    if refused then return refused end
    return succeed(projection_view(projection))
end
-- materialize: the authorized materializer receives the bytes once, in a
-- reply nothing persists; each generation key is accepted once, so a lost
-- reply is never repaired by a silent second read. The source is read now,
-- so rotation at an unchanged reference reaches the next materialization.
function M.materialize(value: unknown): Reply
    local object, decode_error = decode_use(value, {"generation_key"})
    if not object then return fail("INVALID", decode_error or "invalid request") end
    local generation_key = bounds.id(object.generation_key)
    if not generation_key then return fail("INVALID", "generation_key is not an identifier") end
    if not actor() then return fail("UNAUTHENTICATED", "no actor") end
    local db, open_failure = open()
    if not db then return open_failure :: Reply end
    local projection, projection_error = projection_of(db, object.projection_id :: string)
    if projection_error then
        db:release()
        return fail("STORAGE", projection_error)
    end
    if not projection then
        db:release()
        return fail("NOT_FOUND", "projection does not exist")
    end
    local workspace_id = text(projection.workspace_id) or ""
    if not security.can(M.MATERIALIZE, workspace_id) then
        db:release()
        return fail("DENIED", "caller is not a materializer admitted in workspace " .. workspace_id)
    end
    local refused = holds(db, projection, object.subject :: string, object.audience :: string, object.attempt_id :: string)
    if refused then
        db:release()
        return refused
    end
    local definition = definition_of(db, workspace_id, text(projection.name) or "")
    if not definition then
        db:release()
        return fail("CONFLICT", "credential definition is gone")
    end
    local generation = (integer(projection.materialization_generation) or 0) + 1
    local _, key_error = db:execute("INSERT INTO bee_credential_generations (projection_id, generation_key, generation, materializer_actor, created_at) VALUES (?, ?, ?, ?, ?)",
        {projection.projection_id, generation_key, generation, actor(), stamp(now_ms())})
    if key_error then
        db:release()
        return fail("CONFLICT", "generation key " .. generation_key .. " was already used; a lost reply is not repaired by a second read")
    end
    local _, update_error = db:execute("UPDATE bee_credential_projections SET materialization_generation = ? WHERE projection_id = ?", {generation, projection.projection_id})
    if update_error then
        db:release()
        return fail("STORAGE", "record materialization")
    end
    local source_ref = text(definition.source_ref) or ""
    local secret, secret_error = env.get(source_ref)
    db:release()
    if secret_error or type(secret) ~= "string" or secret == "" then return fail("UNAVAILABLE", "source " .. source_ref .. " yields no value") end
    if #secret > M.MAX_SECRET_BYTES then return fail("INVALID", "source " .. source_ref .. " exceeds " .. tostring(M.MAX_SECRET_BYTES) .. " bytes") end
    if secret:find("\0", 1, true) or secret:find("[\r\n]") then return fail("INVALID", "source " .. source_ref .. " holds bytes an environment value cannot carry") end
    return succeed({projection_id = projection.projection_id, destination = projection.destination, projection_kind = projection.projection_kind, encoding = "utf-8",
        generation = generation, generation_key = generation_key, value = secret})
end
function M.revoke(value: unknown): Reply
    local object = bounds.object(value)
    if not object then return fail("INVALID", "request must be an object") end
    local unknown_field = bounds.fields(object, {"projection_id"})
    if unknown_field then return fail("INVALID", unknown_field) end
    local projection_id = bounds.id(object.projection_id)
    if not projection_id then return fail("INVALID", "projection_id is not an identifier") end
    local caller = actor()
    if not caller then return fail("UNAUTHENTICATED", "no actor") end
    local db, open_failure = open()
    if not db then return open_failure :: Reply end
    local projection, projection_error = projection_of(db, projection_id)
    if projection_error then
        db:release()
        return fail("STORAGE", projection_error)
    end
    if not projection then
        db:release()
        return fail("NOT_FOUND", "projection does not exist")
    end
    local workspace_id = text(projection.workspace_id) or ""
    if projection.subject ~= caller and not security.can(M.MANAGE, workspace_id) then
        db:release()
        return fail("DENIED", "only the subject or a workspace manager revokes a projection")
    end
    if projection.revoked_at == nil then
        local _, update_error = db:execute("UPDATE bee_credential_projections SET revoked_at = ? WHERE projection_id = ?", {stamp(now_ms()), projection_id})
        if update_error then
            db:release()
            return fail("STORAGE", "revoke projection")
        end
    end
    local stored = projection_of(db, projection_id)
    db:release()
    if not stored then return fail("STORAGE", "read projection") end
    return succeed(projection_view(stored))
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
    local _, upsert_error = db:execute("INSERT INTO bee_credential_epochs (workspace_id, epoch) VALUES (?, ?) ON CONFLICT(workspace_id) DO UPDATE SET epoch = excluded.epoch", {workspace_id, epoch + 1})
    db:release()
    if upsert_error then return fail("STORAGE", "advance authorization epoch") end
    return succeed({workspace_id = workspace_id, authorization_epoch = epoch + 1})
end
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
    local definitions, definitions_error = db:query("SELECT * FROM bee_credential_definitions WHERE workspace_id = ? ORDER BY name LIMIT ?", {workspace_id, M.MAX_LIST})
    local projections, projections_error = db:query("SELECT * FROM bee_credential_projections WHERE workspace_id = ? AND revoked_at IS NULL AND expires_at > ? ORDER BY created_at LIMIT ?", {workspace_id, stamp(now_ms()), M.MAX_LIST})
    db:release()
    if definitions_error or not definitions or projections_error or not projections then return fail("STORAGE", "read workspace credentials") end
    local definition_views: {{[string]: unknown}} = {}
    for index, row in ipairs(definitions) do definition_views[index] = definition_view(row :: Row) end
    local projection_views: {{[string]: unknown}} = {}
    for index, row in ipairs(projections) do projection_views[index] = projection_view(row :: Row) end
    return succeed({workspace_id = workspace_id, definitions = definition_views, projections = projection_views})
end
function M.capabilities(): Reply
    return succeed({credential_broker = true, projection_kinds = {"environment"}, providers = M.PROVIDERS, destinations = sources.DESTINATIONS, file_projections = false,
        provider_revocation = false, refresh = false, write_back = false, rotation = "next_materialization", repeat_generation = "refused",
        max_secret_bytes = M.MAX_SECRET_BYTES, max_ttl_ms = M.MAX_TTL_MS, revocation_enforcement = "stop_on_reconcile", node = node()})
end
return M
