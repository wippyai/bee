-- MIT. Credential authorization and transient materialization.
local sql = require("sql")
local hash = require("hash")
local time = require("time")
local uuid = require("uuid")
local security = require("security")
local system = require("system")
local env = require("env")
local fs = require("fs")
local json = require("json")
local bounds = require("bounds")
local canonical = require("canonical")
local credential_protocol = require("credential_protocol")
local store = require("store")
local transaction = require("transaction")
local sources = require("sources")
local formats = require("formats")
local funcs = require("funcs")
local configuration_admission = require("configuration_admission")
local M = {}
M.MANAGE = "bee.credentials.manage"
M.ISSUE = "bee.credentials.issue"
M.MATERIALIZE = "bee.credentials.materialize"
M.WRITE_BACK = "bee.credentials.write_back"
M.MAX_TTL_MS = 86400000
M.DEFAULT_TTL_MS = 3600000
M.MAX_SECRET_BYTES = credential_protocol.MAX_SECRET_BYTES
M.MAX_FILE_BYTES = credential_protocol.MAX_FILE_BYTES
M.MAX_LIST = 64
M.SOURCE_KINDS = {"env_variable", "fs_directory"}
type Row = {[string]: unknown}
type TransactionResult = {ok: boolean, code: string?, message: string?, value: unknown, replayed: boolean, commit: boolean?}
type AvailabilityRequest = {workspace_id: string, name: string}
type Availability = {workspace_id: string, name: string, definition_id: string, revision: integer, provider: string, source_kind: string, projection_kind: string, destination: string, format: unknown, present: boolean, optional: boolean}
type ProviderFileRequest = {source_path: string, path: string, optional: boolean}
local function fail(code: string, message: string): credential_protocol.Reply
    return {ok = false, error = {code = code, message = message}, value = nil}
end
local function succeed(value: unknown): credential_protocol.Reply
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
local function node(): (string?, string?)
    local id, err = system.node.id()
    if err then return nil, "node identity is unavailable" end
    local decoded = bounds.id(id)
    if not decoded then return nil, "node identity is invalid" end
    return decoded, nil
end
local function open(): (sql.DB?, credential_protocol.Reply?)
    local db, open_error = store.open()
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
local function canonical_format(value: formats.Format): (string?, string?)
    return canonical.encode(value)
end
local function stored_format(row: Row): (formats.Format?, string?)
    local encoded = text(row.format_json)
    if not encoded or encoded == "" then return nil, "credential format is not frozen" end
    local ok, parsed = pcall(json.decode, encoded)
    if not ok then return nil, "frozen credential format is invalid" end
    local decoded, decode_error = formats.decode(parsed)
    if not decoded then return nil, decode_error or "frozen credential format is invalid" end
    return decoded, nil
end
local function format_matches(row: Row, selected: formats.Format): boolean
    local frozen = stored_format(row)
    if not frozen then return false end
    local frozen_json = canonical_format(frozen)
    local selected_json = canonical_format(selected)
    return frozen_json ~= nil and selected_json ~= nil and frozen_json == selected_json
end
local function format_for(admitted: sources.SourceSet, provider: string, kind: string): (formats.Format?, string?, string?)
    local selected, selected_error = sources.format(admitted, provider)
    if not selected then return nil, selected_error or "credential format is unavailable", nil end
    local destination = sources.destination(selected, kind)
    if not destination then return nil, "credential format has no " .. kind .. " destination", nil end
    local encoded, encode_error = canonical_format(selected)
    if not encoded then return nil, encode_error or "credential format is invalid", nil end
    return selected, nil, encoded
end
local function integer(value: unknown): integer?
    return bounds.integer(value)
end
local function read_source_file(volume: fs.FS, path: string, content_format: string, bound: integer, label: string): (string?, string?, string?)
    local file, open_error = volume:open("/" .. path, "r")
    if not file then
        if open_error and open_error:kind() == errors.NOT_FOUND then return nil, "MISSING", nil end
        return nil, "UNAVAILABLE", "source " .. label .. ": " .. tostring(open_error or "unavailable")
    end
    local chunks: {string} = {}
    local size: integer = 0
    while true do
        local remaining = bound + 1 - size
        if remaining <= 0 then break end
        local chunk, read_error = file:read(math.min(4096, remaining))
        if read_error and tostring(read_error) == "EOF" then break end
        if read_error then
            file:close()
            return nil, "UNAVAILABLE", "source " .. label .. " could not be read"
        end
        if chunk == nil or chunk == "" then break end
        if type(chunk) ~= "string" then
            file:close()
            return nil, "UNAVAILABLE", "source " .. label .. " yielded invalid bytes"
        end
        chunks[#chunks + 1] = chunk
        size = size + #chunk
    end
    file:close()
    local content = table.concat(chunks)
    if #content == 0 then return nil, "UNAVAILABLE", "source " .. label .. " is empty" end
    if #content > bound then return nil, "INVALID", "source " .. label .. " exceeds " .. tostring(bound) .. " bytes" end
    if content_format == "json" then
        local ok, parsed = pcall(json.decode, content)
        if not ok or type(parsed) ~= "table" then return nil, "INVALID", "source " .. label .. " is not valid JSON" end
    end
    return content, "PRESENT", nil
end
local function append_setup(format: formats.Format, destination: string, content: string, source_path: string): (formats.Format?, string?)
    local file = format.file
    if not file then return nil, "credential setup requires a file format" end
    file.initialize[#file.initialize + 1] = {path = destination, content = content, source_path = source_path, on_missing_login = true}
    local decoded, decode_error = formats.decode(format)
    if not decoded then return nil, decode_error or "credential setup format is invalid" end
    return decoded, nil
end
local function definition_view(row: Row): ({[string]: unknown}?, string?)
    local revision, optional = integer(row.revision), integer(row.optional)
    if not revision or revision < 1 or (optional ~= 0 and optional ~= 1) then return nil, "credential definition numeric fields are corrupt" end
    local format, format_error = stored_format(row)
    if not format then return nil, format_error or "credential definition format is corrupt" end
    return {workspace_id = row.workspace_id, name = row.name, definition_id = row.definition_id, revision = revision, provider = row.provider,
        source_kind = row.source_kind, source_ref = row.source_ref, projection_kind = row.projection_kind, destination = row.destination, optional = optional == 1, digest = row.digest,
        format = format, owner_node = row.owner_node, created_at = row.created_at, updated_at = row.updated_at}, nil
end
local function projection_view(row: Row): ({[string]: unknown}?, string?)
    local definition_revision, issuer_incarnation = integer(row.definition_revision), integer(row.issuer_incarnation)
    local generation, authorization_epoch = integer(row.materialization_generation), integer(row.authorization_epoch)
    if not definition_revision or definition_revision < 1 or not issuer_incarnation or issuer_incarnation < 1
        or not generation or generation < 0 or not authorization_epoch or authorization_epoch < 0 then
        return nil, "credential projection numeric fields are corrupt"
    end
    local format, format_error = stored_format(row)
    if not format then return nil, format_error or "credential projection format is corrupt" end
    return {projection_id = row.projection_id, workspace_id = row.workspace_id, name = row.name, definition_id = row.definition_id, definition_revision = definition_revision,
        issuer_owner = row.issuer_owner, issuer_incarnation = issuer_incarnation, subject = row.subject, audience = row.audience, attempt_id = row.attempt_id,
        profile_id = row.profile_id, profile_digest = row.profile_digest, binding_digest = row.binding_digest, launch_policy_digest = row.launch_policy_digest,
        provider = row.provider, projection_kind = row.projection_kind, destination = row.destination, materializer = row.materializer,
        materialization_generation = generation, expires_at = row.expires_at, authorization_epoch = authorization_epoch,
        format = format, revoked_at = row.revoked_at, created_at = row.created_at}, nil
end
function M.define(value: unknown): credential_protocol.Reply
    local object = bounds.object(value)
    if not object then return fail("INVALID", "request must be an object") end
    local unknown_field = bounds.fields(object, {"workspace_id", "name", "provider", "source", "projection_kind", "expected_revision", "optional"})
    if unknown_field then return fail("INVALID", unknown_field) end
    local workspace_id, name = bounds.id(object.workspace_id), bounds.id(object.name)
    if not workspace_id then return fail("INVALID", "workspace_id is not an identifier") end
    if not name then return fail("INVALID", "name is not an identifier") end
    local expected_revision: integer? = nil
    if object.expected_revision ~= nil then
        expected_revision = bounds.count(object.expected_revision)
        if expected_revision == nil then return fail("INVALID", "expected_revision must be a nonnegative integer") end
    end
    local optional = false
    if object.optional ~= nil then
        if type(object.optional) ~= "boolean" then return fail("INVALID", "optional must be a boolean") end
        optional = object.optional
    end
    local provider = bounds.id(object.provider)
    if not provider then return fail("INVALID", "provider is not an identifier") end
    local source = bounds.object(object.source)
    if not source then return fail("INVALID", "source must be an object") end
    local source_field = bounds.fields(source, {"kind", "ref"})
    if source_field then return fail("INVALID", "source: " .. source_field) end
    local source_kind = bounds.member(source.kind, M.SOURCE_KINDS)
    if not source_kind then return fail("INVALID", "source.kind must be env_variable or fs_directory") end
    local source_ref = bounds.id(source.ref)
    if not source_ref then return fail("INVALID", "source.ref is not an identifier") end
    local caller = actor()
    if not caller then return fail("UNAUTHENTICATED", "no actor") end
    if not security.can(M.MANAGE, workspace_id) then return fail("DENIED", "caller does not manage workspace " .. workspace_id) end
    local owner_node, node_error = node()
    if not owner_node then return fail("UNAVAILABLE", node_error or "node identity is unavailable") end
    local admitted, admitted_error = sources.host_sources()
    if not admitted then return fail("STORAGE", admitted_error or "host sources") end

    local projection_kind: string
    local destination: string?
    local digest_payload: {[string]: unknown}
    local selected_format: formats.Format?
    local format_json: string

    if source_kind == "env_variable" then
        projection_kind = "environment"
        if object.projection_kind ~= nil and object.projection_kind ~= "environment" then
            return fail("INVALID", "env_variable sources only support environment projections")
        end
        if not sources.admits(admitted, source_ref, workspace_id, provider, "environment") then
            return fail("FORBIDDEN", "source " .. source_ref .. " is not admitted for " .. provider .. " environment projections in workspace " .. workspace_id)
        end
        local selected, format_error, encoded = format_for(admitted, provider, "environment")
        if not selected then return fail("INVALID", format_error or "credential format is unavailable") end
        selected_format, format_json = selected, encoded
        local variable, variable_error = sources.variable(source_ref)
        if not variable then return fail("INVALID", variable_error or "source") end
        destination = sources.destination(selected_format, "environment")
        digest_payload = {provider = provider, source_kind = source_kind, source_ref = source_ref, variable = variable, projection_kind = projection_kind, destination = destination, optional = optional}
    else
        projection_kind = "file"
        if object.projection_kind ~= nil and object.projection_kind ~= "file" then
            return fail("INVALID", "login file sources only support file projections")
        end
        if not sources.admits(admitted, source_ref, workspace_id, provider, "file") then
            return fail("FORBIDDEN", "source " .. source_ref .. " is not admitted for " .. provider .. " file projections in workspace " .. workspace_id)
        end
        local selected, format_error, encoded = format_for(admitted, provider, "file")
        if not selected then return fail("INVALID", format_error or "credential format is unavailable") end
        selected_format, format_json = selected, encoded
        local directory, dir_error = sources.directory(source_ref)
        if not directory then return fail("INVALID", dir_error or "source") end
        destination = sources.destination(selected_format, "file")
        local path, path_error = sources.file_path(admitted, source_ref, workspace_id, provider, nil, selected_format)
        if not path then return fail("FORBIDDEN", path_error or "file source path unavailable") end
        local setup, setup_error = sources.setup(admitted, source_ref, workspace_id, provider, nil)
        if setup_error then return fail("FORBIDDEN", setup_error) end
        local auxiliary_files, auxiliary_error = sources.auxiliary_rules(admitted, source_ref, workspace_id, provider, nil)
        if not auxiliary_files then return fail("FORBIDDEN", auxiliary_error or "host auxiliary file declarations unavailable") end
        local write_back, write_back_error = sources.token_write_back(admitted, source_ref, workspace_id, provider, nil)
        if write_back_error or write_back == nil then return fail("FORBIDDEN", write_back_error or "file write-back admission unavailable") end
        digest_payload = {provider = provider, source_kind = source_kind, source_ref = source_ref, directory = directory,
            path = path, setup = setup, auxiliary_files = auxiliary_files, write_back = write_back,
            projection_kind = projection_kind, destination = destination, optional = optional}
    end

    if not destination then return fail("INVALID", "no destination for provider " .. provider) end
    local digest, digest_error = digest_of(digest_payload)
    if not digest then return fail("INVALID", digest_error or "definition is not measurable") end
    local db, open_failure = open()
    if not db then return open_failure end
    local result: TransactionResult = transaction.write(db, "credential definition", function(tx: sql.Transaction): TransactionResult
        local existing, existing_error = store.definition(tx, workspace_id, name)
        if existing_error then return transaction.failure("STORAGE", existing_error) end
        local current_revision = 0
        if existing then
            current_revision = integer(existing.revision)
            if not current_revision then return transaction.failure("STORAGE", "definition revision is corrupt") end
        end
        if expected_revision ~= nil and expected_revision ~= current_revision then
            return transaction.failure("CONFLICT", "expected_revision does not match the credential definition")
        end
        local definition_id, id_error = uuid.v7()
        if id_error or not definition_id then return transaction.failure("STORAGE", "definition id") end
        local at = stamp(now_ms())
        local save_error = store.save_definition(tx, {workspace_id = workspace_id, name = name,
            definition_id = definition_id, revision = current_revision + 1, provider = provider,
            source_kind = source_kind, source_ref = source_ref, projection_kind = projection_kind,
            destination = destination, optional = optional, digest = digest, format_json = format_json,
            owner_node = owner_node, at = at}, existing ~= nil)
        if save_error then return transaction.failure("STORAGE", save_error) end
        local stored, stored_error = store.definition(tx, workspace_id, name)
        if stored_error or not stored then return transaction.failure("STORAGE", stored_error or "read definition") end
        if stored.definition_id ~= definition_id then
            return transaction.failure("CONFLICT", "credential definition was created concurrently")
        end
        local view, view_error = definition_view(stored)
        if not view then return transaction.failure("STORAGE", view_error or "credential definition is corrupt") end
        return transaction.success(view, false)
    end)
    db:release()
    if not result.ok then return fail(result.code or "STORAGE", result.message or "define failed") end
    return succeed(result.value)
end
type Issue = {workspace_id: string, name: string, audience: string, attempt_id: string, profile_id: string, profile_digest: string, binding_digest: string, launch_policy_digest: string, idempotency_key: string, ttl: integer}
local function same_issue(row: Row, request: Issue): (boolean?, string?)
    if row.workspace_id ~= request.workspace_id or row.name ~= request.name or row.audience ~= request.audience
        or row.attempt_id ~= request.attempt_id or row.profile_id ~= request.profile_id
        or row.profile_digest ~= request.profile_digest or row.binding_digest ~= request.binding_digest
        or row.launch_policy_digest ~= request.launch_policy_digest then
        return false, nil
    end
    local lease = integer(row.lease_ms)
    if not lease or lease < 1 then return nil, "projection lease length is corrupt" end
    return lease == request.ttl, nil
end

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
function M.set_value(value: unknown): credential_protocol.Reply
    local request = bounds.object(value)
    if not request or bounds.fields(request, {"workspace_id", "name", "value"}) then return fail("INVALID", "credential value request is malformed") end
    local workspace, name = bounds.id(request.workspace_id), bounds.id(request.name)
    if not workspace or not name then return fail("INVALID", "credential identity is invalid") end
    if not actor() then return fail("UNAUTHENTICATED", "no actor") end
    if not security.can(M.MANAGE, workspace) then return fail("DENIED", "caller does not manage workspace " .. workspace) end
    local secret = bounds.text(request.value, M.MAX_SECRET_BYTES)
    if not secret or secret:find("[%z\r\n]") then return fail("INVALID", "credential value cannot be carried in an environment") end
    local db, open_failure = open()
    if not db then return open_failure or fail("STORAGE", "credential store unavailable") end
    local definition, read_error = store.definition(db, workspace, name)
    db:release()
    if read_error then return fail("STORAGE", "credential definition unavailable") end
    if not definition then return fail("NOT_FOUND", "credential definition does not exist") end
    local ref, provider = bounds.id(definition.source_ref), bounds.id(definition.provider)
    if definition.source_kind ~= "env_variable" or not ref or not provider or not sources.accepts_value(ref) then
        return fail("DENIED", "credential source does not accept person-entered values")
    end
    local admitted, admission_error = sources.host_sources()
    if not admitted then return fail("UNAVAILABLE", admission_error or "credential admission unavailable") end
    if not sources.admits(admitted, ref, workspace, provider, "environment") then return fail("DENIED", "credential source is no longer admitted") end
    local set, set_error = env.set(ref, secret)
    if not set or set_error then return fail("UNAVAILABLE", "credential value could not be set") end
    return succeed({workspace_id = workspace, name = name, present = secret ~= ""})
end
function M.issue_projection(value: unknown): credential_protocol.Reply
    local request, decode_error = decode_issue(value)
    if not request then return fail("INVALID", decode_error or "invalid request") end
    local subject = actor()
    if not subject then return fail("UNAUTHENTICATED", "no actor") end
    if not security.can(M.ISSUE, request.workspace_id) then return fail("DENIED", "caller may not take credential projections in workspace " .. request.workspace_id) end
    local owner_node, node_error = node()
    if not owner_node then return fail("UNAVAILABLE", node_error or "node identity is unavailable") end
    local admitted, admitted_error = sources.host_sources()
    if not admitted then return fail("STORAGE", admitted_error or "host sources") end
    local db, open_failure = open()
    if not db then return open_failure end
    local replay, replay_error = store.issue_replay(db, subject, request.idempotency_key)
    if replay_error or not replay then
        db:release()
        return fail("STORAGE", "read projections")
    end
    if #replay == 1 then
        local row = replay[1]
        local same, same_error = same_issue(row, request)
        db:release()
        if same_error then return fail("STORAGE", same_error) end
        if not same then return fail("CONFLICT", "idempotency key reused with a different request") end
        local view, view_error = projection_view(row)
        if not view then return fail("STORAGE", view_error or "credential projection is corrupt") end
        return succeed(view)
    end
    local definition, definition_error = store.definition(db, request.workspace_id, request.name)
    if definition_error then
        db:release()
        return fail("STORAGE", definition_error)
    end
    if not definition then
        db:release()
        return fail("NOT_FOUND", "no credential " .. request.name .. " in workspace " .. request.workspace_id)
    end
    local definition_provider = text(definition.provider) or ""
    local definition_kind = text(definition.projection_kind) or "environment"
    if not sources.admits(admitted, text(definition.source_ref) or "", request.workspace_id, definition_provider, definition_kind, request.audience) then
        db:release()
        return fail("FORBIDDEN", "the host does not admit audience " .. request.audience .. " for credential " .. request.name)
    end
    local selected_format, format_error, format_json = format_for(admitted, definition_provider, definition_kind)
    if not selected_format then
        db:release()
        return fail("CONFLICT", format_error or "credential format is unavailable")
    end
    if not format_matches(definition, selected_format) then
        db:release()
        return fail("CONFLICT", "credential format changed; redefine before issuing a projection")
    end
    if sources.destination(selected_format, definition_kind) ~= definition.destination then
        db:release()
        return fail("CONFLICT", "credential destination does not match its frozen format")
    end
    local materializer, materializer_error = sources.materializer()
    if not materializer then
        db:release()
        return fail("STORAGE", materializer_error or "credential materializer")
    end
    local epoch, epoch_error = store.epoch(db, request.workspace_id)
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
    local insert_error = store.insert_projection(db, {projection_id = projection_id,
        workspace_id = request.workspace_id, name = request.name, definition_id = definition.definition_id,
        definition_revision = definition.revision, issuer_owner = owner_node, subject = subject,
        audience = request.audience, attempt_id = request.attempt_id, profile_id = request.profile_id,
        profile_digest = request.profile_digest, binding_digest = request.binding_digest,
        launch_policy_digest = request.launch_policy_digest, provider = definition.provider,
        projection_kind = definition.projection_kind, destination = definition.destination,
        format_json = format_json, materializer = materializer, idempotency_key = request.idempotency_key,
        expires_at = stamp(created + request.ttl), lease_ms = request.ttl, authorization_epoch = epoch, created_at = stamp(created)})
    if insert_error then
        db:release()
        return fail("STORAGE", "record projection")
    end
    local stored = store.projection(db, projection_id)
    db:release()
    if not stored then return fail("STORAGE", "read projection") end
    local view, view_error = projection_view(stored)
    if not view then return fail("STORAGE", view_error or "credential projection is corrupt") end
    return succeed(view)
end
local function file_binding(admitted: sources.SourceSet, definition: Row, workspace_id: string, audience: string?): (string?, credential_protocol.Reply?, sources.Setup?, boolean?)
    local ref, provider = text(definition.source_ref) or "", text(definition.provider) or ""
    if not sources.admits(admitted, ref, workspace_id, provider, "file", audience) then
        return nil, fail("FORBIDDEN", "the host no longer admits this file source")
    end
    local selected_format, format_error = format_for(admitted, provider, "file")
    if not selected_format then return nil, fail("CONFLICT", format_error or "credential format is unavailable") end
    if not format_matches(definition, selected_format) then
        return nil, fail("CONFLICT", "credential format changed; redefine before use")
    end
    local path, path_error = sources.file_path(admitted, ref, workspace_id, provider, audience, selected_format)
    if not path then return nil, fail("FORBIDDEN", path_error or "file source unavailable") end
    local setup, setup_error = sources.setup(admitted, ref, workspace_id, provider, audience)
    if setup_error then return nil, fail("FORBIDDEN", setup_error) end
    local auxiliary_files, auxiliary_error = sources.auxiliary_rules(admitted, ref, workspace_id, provider, audience)
    if not auxiliary_files then return nil, fail("FORBIDDEN", auxiliary_error or "host auxiliary file declarations unavailable") end
    local write_back, write_back_error = sources.token_write_back(admitted, ref, workspace_id, provider, audience)
    if write_back_error or write_back == nil then return nil, fail("FORBIDDEN", write_back_error or "file write-back admission unavailable") end
    local directory, directory_error = sources.directory(ref)
    if not directory then return nil, fail("INVALID", directory_error or "file source unavailable") end
    local optional_value = integer(definition.optional)
    if optional_value ~= 0 and optional_value ~= 1 then return nil, fail("STORAGE", "credential optional flag is corrupt") end
    local digest_payload: {[string]: unknown} = {provider = provider, source_kind = "fs_directory", source_ref = ref, directory = directory,
        path = path, setup = setup, auxiliary_files = auxiliary_files, write_back = write_back,
        projection_kind = "file", destination = definition.destination, optional = optional_value == 1}
    local digest = digest_of(digest_payload)
    if not digest or digest ~= definition.digest then return nil, fail("CONFLICT", "credential source changed; redefine before use") end
    return path, nil, setup, write_back
end
local function binding_holds(admitted: sources.SourceSet, projection: Row, subject: string, audience: string, attempt_id: string,
    epoch: integer, definition: Row?): credential_protocol.Reply?
    if projection.revoked_at ~= nil then return fail("REVOKED", "projection was revoked at " .. tostring(projection.revoked_at)) end
    if tostring(projection.expires_at) <= stamp(now_ms()) then return fail("EXPIRED", "projection expired at " .. tostring(projection.expires_at)) end
    if projection.subject ~= subject or projection.audience ~= audience then return fail("DENIED", "projection binds another subject or audience") end
    if projection.attempt_id ~= attempt_id then return fail("DENIED", "projection is scoped to another attempt") end
    local workspace_id = text(projection.workspace_id) or ""
    local projection_epoch = integer(projection.authorization_epoch)
    if not projection_epoch or projection_epoch < 0 then return fail("STORAGE", "projection authorization epoch is corrupt") end
    if projection_epoch < epoch then return fail("REVOKED", "workspace authorization epoch advanced past the projection") end
    if not definition or definition.definition_id ~= projection.definition_id or definition.revision ~= projection.definition_revision then
        return fail("CONFLICT", "credential definition was replaced; the projection needs re-issue")
    end
    if not sources.admits(admitted, text(definition.source_ref) or "", workspace_id, text(definition.provider) or "", text(definition.projection_kind) or "environment", audience) then
        return fail("FORBIDDEN", "the host no longer admits this source for audience " .. audience)
    end
    local provider = text(definition.provider) or ""
    local kind = text(definition.projection_kind) or "environment"
    local selected_format, format_error = format_for(admitted, provider, kind)
    if not selected_format then return fail("CONFLICT", format_error or "credential format is unavailable") end
    if not format_matches(definition, selected_format) or not format_matches(projection, selected_format) then
        return fail("CONFLICT", "credential format changed; redefine and re-issue before use")
    end
    local selected_destination = sources.destination(selected_format, kind)
    if not selected_destination or definition.destination ~= selected_destination then
        return fail("CONFLICT", "credential destination does not match its frozen format")
    end
    if projection.provider ~= definition.provider or projection.projection_kind ~= definition.projection_kind
        or projection.destination ~= definition.destination then
        return fail("CONFLICT", "projection credential metadata does not match its definition")
    end
    if definition.projection_kind == "file" then
        local _, binding_error = file_binding(admitted, definition, workspace_id, audience)
        if binding_error then return binding_error end
    end
    return nil
end
local function holds(db: store.Reader, admitted: sources.SourceSet, projection: Row, subject: string, audience: string, attempt_id: string): credential_protocol.Reply?
    local workspace_id = text(projection.workspace_id) or ""
    local epoch, epoch_error = store.epoch(db, workspace_id)
    if not epoch then return fail("STORAGE", epoch_error or "epoch") end
    local definition, definition_error = store.definition(db, workspace_id, text(projection.name) or "")
    if definition_error then return fail("STORAGE", definition_error) end
    return binding_holds(admitted, projection, subject, audience, attempt_id, epoch, definition)
end
type UseRequest = {projection_id: string, subject: string, audience: string, attempt_id: string,
    generation_key: unknown?, provider_files: unknown?, generation: unknown?, source_digest: unknown?, value: unknown?}
local function decode_use(value: unknown, extra: {string}): (UseRequest?, string?)
    local object = bounds.object(value)
    if not object then return nil, "request must be an object" end
    local allowed: {string} = {"projection_id", "subject", "audience", "attempt_id"}
    for _, name in ipairs(extra) do allowed[#allowed + 1] = name end
    local unknown_field = bounds.fields(object, allowed)
    if unknown_field then return nil, unknown_field end
    for _, name in ipairs({"projection_id", "subject", "audience", "attempt_id"}) do
        if not bounds.id(object[name]) then return nil, name .. " is not an identifier" end
    end
    return {projection_id = assert(bounds.id(object.projection_id)), subject = assert(bounds.id(object.subject)),
        audience = assert(bounds.id(object.audience)), attempt_id = assert(bounds.id(object.attempt_id)),
        generation_key = object.generation_key, provider_files = object.provider_files,
        generation = object.generation, source_digest = object.source_digest, value = object.value}, nil
end
local function decode_provider_files(value: unknown): ({ProviderFileRequest}?, string?)
    if value == nil then return {}, nil end
    if type(value) ~= "table" then return nil, "provider_files must be a list" end
    local raw = value
    if #raw > 8 then return nil, "provider_files exceeds the limit" end
    local count = 0
    for key in pairs(raw) do
        if type(key) ~= "number" or key < 1 or key > #raw or math.floor(key) ~= key then return nil, "provider_files must be a dense list" end
        count = count + 1
    end
    if count ~= #raw then return nil, "provider_files must be a dense list" end
    local decoded: {ProviderFileRequest} = {}
    local sources_seen: {[string]: boolean} = {}
    local paths_seen: {[string]: boolean} = {}
    for index, item_value in ipairs(raw) do
        local item = bounds.object(item_value)
        if not item or bounds.fields(item, {"source_path", "path", "optional"}) then return nil, "provider_files contains an invalid item" end
        local source_path = bounds.text(item.source_path, 512)
        local path = bounds.text(item.path, 512)
        local optional = item.optional
        if not source_path or not formats.path(source_path) or not path or not formats.path(path)
            or type(optional) ~= "boolean" or sources_seen[source_path] or paths_seen[path] then
            return nil, "provider_files contains an invalid or duplicate path"
        end
        sources_seen[source_path] = true
        paths_seen[path] = true
        decoded[index] = {source_path = source_path, path = path, optional = optional}
    end
    return decoded, nil
end
local function decode_availability(value: unknown): (AvailabilityRequest?, string?)
    local object = bounds.object(value)
    if not object then return nil, "request must be an object" end
    local unknown_field = bounds.fields(object, {"workspace_id", "name"})
    if unknown_field then return nil, unknown_field end
    local workspace_id, name = bounds.id(object.workspace_id), bounds.id(object.name)
    if not workspace_id then return nil, "workspace_id is not an identifier" end
    if not name then return nil, "name is not an identifier" end
    return {workspace_id = workspace_id, name = name}, nil
end
local function availability_view(request: AvailabilityRequest, definition_id: string, revision: integer, provider: string,
    source_kind: string, projection_kind: string, destination: string, format: unknown, present: boolean, optional: boolean): Availability
    return {workspace_id = request.workspace_id, name = request.name, definition_id = definition_id, revision = revision,
        provider = provider, source_kind = source_kind, projection_kind = projection_kind, destination = destination, format = format, present = present, optional = optional}
end
function M.availability(value: unknown): credential_protocol.Reply
    local request, decode_error = decode_availability(value)
    if not request then return fail("INVALID", decode_error or "invalid request") end
    if not actor() then return fail("UNAUTHENTICATED", "no actor") end
    if not security.can(M.MANAGE, request.workspace_id) then
        return fail("DENIED", "caller does not manage workspace " .. request.workspace_id)
    end
    local admitted, admitted_error = sources.host_sources()
    if not admitted then return fail("STORAGE", admitted_error or "host sources") end
    local db, open_failure = open()
    if not db then return open_failure end
    local definition, definition_error = store.definition(db, request.workspace_id, request.name)
    if definition_error then
        db:release()
        return fail("STORAGE", definition_error)
    end
    if not definition then
        db:release()
        return fail("NOT_FOUND", "credential definition does not exist")
    end
    local provider = bounds.id(definition.provider)
    local source_kind = text(definition.source_kind)
    local projection_kind = text(definition.projection_kind)
    local source_ref = bounds.id(definition.source_ref)
    local definition_id = bounds.id(definition.definition_id)
    local revision = integer(definition.revision)
    local optional_value = integer(definition.optional)
    local destination = provider and text(definition.destination) or nil
    if not provider or source_kind ~= "fs_directory" or projection_kind ~= "file" or not source_ref
        or not definition_id or not revision or revision < 1 or (optional_value ~= 0 and optional_value ~= 1) or not destination then
        db:release()
        if projection_kind ~= "file" then return fail("INVALID", "availability only supports file projections") end
        return fail("INVALID", "credential definition has invalid file metadata")
    end
    if not sources.admits(admitted, source_ref, request.workspace_id, provider, "file") then
        db:release()
        return fail("FORBIDDEN", "the host no longer admits this source")
    end
    local selected_format, format_error = format_for(admitted, provider, "file")
    if not selected_format then
        db:release()
        return fail("CONFLICT", format_error or "credential format is unavailable")
    end
    if not format_matches(definition, selected_format) then
        db:release()
        return fail("CONFLICT", "credential format changed; redefine before use")
    end
    local selected_destination = sources.destination(selected_format, "file")
    if not selected_destination or destination ~= selected_destination then
        db:release()
        return fail("CONFLICT", "credential destination changed; redefine before use")
    end
    local directory, directory_error = sources.directory(source_ref)
    if not directory then
        db:release()
        return fail("INVALID", directory_error or "credential source is invalid")
    end
    -- Keep the source directory lookup as an explicit configuration check;
    -- the fs handle is still obtained from the source registry reference, so
    -- callers cannot substitute the directory metadata or a path.
    if type(directory.directory) ~= "string" or directory.directory == "" then
        db:release()
        return fail("INVALID", "credential source directory is invalid")
    end
    local path, binding_error = file_binding(admitted, definition, request.workspace_id, nil)
    if not path then db:release(); return binding_error or fail("INVALID", "file source unavailable") end
    local volume = fs.get(source_ref)
    if not volume then
        db:release()
        return fail("UNAVAILABLE", "credential source volume unavailable")
    end
    local info, stat_error = volume:stat("/" .. path)
    db:release()
    if info then
        if info.type ~= "file" or info.is_dir == true then return fail("INVALID", "provider login path is not a file") end
        return succeed(availability_view(request, definition_id, revision, provider, source_kind, projection_kind, destination, selected_format, true, optional_value == 1))
    end
    if stat_error and stat_error:kind() == errors.NOT_FOUND then
        return succeed(availability_view(request, definition_id, revision, provider, source_kind, projection_kind, destination, selected_format, false, optional_value == 1))
    end
    return fail("UNAVAILABLE", "provider login path could not be inspected: " .. tostring(stat_error or "unknown filesystem error"))
end
function M.check(value: unknown): credential_protocol.Reply
    local object, decode_error = decode_use(value, {})
    if not object then return fail("INVALID", decode_error or "invalid request") end
    if not actor() then return fail("UNAUTHENTICATED", "no actor") end
    local admitted, admitted_error = sources.host_sources()
    if not admitted then return fail("STORAGE", admitted_error or "host sources") end
    local db, open_failure = open()
    if not db then return open_failure end
    local projection, projection_error = store.projection(db, object.projection_id)
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
    local refused = holds(db, admitted, projection, object.subject, object.audience, object.attempt_id)
    -- A file projection may seed a retained home after placement prepare.
    -- Report only its source's existence; no login bytes are opened here.
    local source_present: boolean? = nil
    if not refused and projection.projection_kind == "file" then
        local definition, definition_error = store.definition(db, workspace_id, text(projection.name) or "")
        if definition_error then
            refused = fail("STORAGE", definition_error)
        elseif not definition then
            refused = fail("CONFLICT", "credential definition is gone")
        else
            local path, binding_error = file_binding(admitted, definition, workspace_id, object.audience)
            if not path then refused = binding_error or fail("INVALID", "file source is unavailable") end
            local source_ref = bounds.id(definition.source_ref)
            local volume = source_ref and fs.get(source_ref) or nil
            if not source_ref then refused = fail("STORAGE", "credential source reference is corrupt")
            elseif not volume then refused = fail("UNAVAILABLE", "credential source volume is unavailable") end
            if path and volume and not refused then
                local info, stat_error = volume:stat("/" .. path)
                if info then source_present = info.type == "file" and info.is_dir ~= true
                elseif stat_error and stat_error:kind() == errors.NOT_FOUND then source_present = false
                else refused = fail("UNAVAILABLE", "credential login path could not be inspected: " .. tostring(stat_error or "unknown filesystem error")) end
            end
        end
    end
    db:release()
    if refused then return refused end
    local result, view_error = projection_view(projection)
    if not result then
        return fail("STORAGE", view_error or "credential projection is corrupt")
    end
    result.source_present = source_present
    return succeed(result)
end
-- renew_attempt: the materializer supervising a live attempt extends the
-- projections it holds for that attempt by their recorded term once less than
-- half of the term remains. A revoked, expired or epoch-fenced projection
-- stays ended.
function M.renew_attempt(value: unknown): credential_protocol.Reply
    local object = bounds.object(value)
    if not object then return fail("INVALID", "request must be an object") end
    local unknown_field = bounds.fields(object, {"attempt_id", "subject", "audience"})
    if unknown_field then return fail("INVALID", unknown_field) end
    local attempt_id, subject, audience = bounds.id(object.attempt_id), bounds.id(object.subject), bounds.id(object.audience)
    if not attempt_id then return fail("INVALID", "attempt_id is not an identifier") end
    if not subject then return fail("INVALID", "subject is not an identifier") end
    if not audience then return fail("INVALID", "audience is not an identifier") end
    if not actor() then return fail("UNAUTHENTICATED", "no actor") end
    local db, open_failure = open()
    if not db then return open_failure end
    local now = now_ms()
    local rows, read_error = store.attempt_leases(db, attempt_id, subject, audience, stamp(now))
    if not rows then db:release(); return fail("STORAGE", read_error or "read attempt projections") end
    local renewed = 0
    for _, row in ipairs(rows) do
        local workspace_id = text(row.workspace_id) or ""
        if not security.can(M.MATERIALIZE, workspace_id) then db:release(); return fail("DENIED", "caller is not a materializer admitted in workspace " .. workspace_id) end
        local epoch, epoch_error = store.epoch(db, workspace_id)
        if not epoch then db:release(); return fail("STORAGE", epoch_error or "epoch") end
        local lease, projection_epoch = integer(row.lease_ms), integer(row.authorization_epoch)
        if not lease or lease < 1 or not projection_epoch then db:release(); return fail("STORAGE", "projection lease is corrupt") end
        if projection_epoch >= epoch and tostring(row.expires_at) <= stamp(now + lease // 2) then
            local extend_error = store.extend(db, tostring(row.projection_id), stamp(now + lease))
            if extend_error then db:release(); return fail("STORAGE", extend_error) end
            renewed = renewed + 1
        end
    end
    db:release()
    return succeed({attempt_id = attempt_id, renewed = renewed})
end
function M.materialize(value: unknown): credential_protocol.Reply
    local object, decode_error = decode_use(value, {"generation_key", "provider_files"})
    if not object then return fail("INVALID", decode_error or "invalid request") end
    local provider_files, provider_files_error = decode_provider_files(object.provider_files)
    if not provider_files then return fail("INVALID", provider_files_error or "provider_files is invalid") end
    local generation_key = bounds.id(object.generation_key)
    if not generation_key then return fail("INVALID", "generation_key is not an identifier") end
    local materializer = actor()
    if not materializer then return fail("UNAUTHENTICATED", "no actor") end
    local admitted, admitted_error = sources.host_sources()
    if not admitted then return fail("STORAGE", admitted_error or "host sources") end
    local db, open_failure = open()
    if not db then return open_failure end
    local projection_id = bounds.id(object.projection_id)
    local subject, audience, attempt_id = bounds.id(object.subject), bounds.id(object.audience), bounds.id(object.attempt_id)
    if not projection_id or not subject or not audience or not attempt_id then
        db:release()
        return fail("INVALID", "materialization identity is malformed")
    end
    local reserved: TransactionResult = transaction.write(db, "credential materialization", function(tx: sql.Transaction): TransactionResult
        local projection, projection_error = store.projection(tx, projection_id)
        if projection_error then return transaction.failure("STORAGE", projection_error) end
        if not projection then return transaction.failure("NOT_FOUND", "projection does not exist") end
        local workspace_id = bounds.id(projection.workspace_id)
        local name = bounds.id(projection.name)
        if not workspace_id or not name then return transaction.failure("STORAGE", "projection identity is corrupt") end
        if not security.can(M.MATERIALIZE, workspace_id) then
            return transaction.failure("DENIED", "caller is not a materializer admitted in workspace " .. workspace_id)
        end
        local refused = holds(tx, admitted, projection, subject, audience, attempt_id)
        if refused then return transaction.failure(refused.error and refused.error.code or "DENIED",
            refused.error and refused.error.message or "projection binding is invalid") end
        local definition, definition_error = store.definition(tx, workspace_id, name)
        if definition_error then return transaction.failure("STORAGE", definition_error) end
        if not definition then return transaction.failure("CONFLICT", "credential definition is gone") end
        local current_generation = bounds.count(projection.materialization_generation)
        if current_generation == nil then
            return transaction.failure("STORAGE", "materialization generation is corrupt")
        end
        if current_generation == bounds.MAX_SAFE_INTEGER then
            return transaction.failure("STORAGE", "materialization generation has reached its safe integer limit")
        end
        local used, used_error = store.generation_used(tx, projection_id, generation_key)
        if used_error or used == nil then return transaction.failure("STORAGE", "read materialization generation key") end
        if used then
            return transaction.failure("CONFLICT", "generation key " .. generation_key .. " was already used; a lost reply is not repaired by a second read")
        end
        local generation = current_generation + 1
        local reservation_error = store.reserve_generation(tx, projection_id, generation_key, generation, materializer, stamp(now_ms()))
        if reservation_error then return transaction.failure("STORAGE", reservation_error) end
        return transaction.success({projection = projection, definition = definition, generation = generation}, false)
    end)
    db:release()
    if not reserved.ok then return fail(reserved.code or "STORAGE", reserved.message or "reserve materialization generation") end
    local allocation = bounds.object(reserved.value)
    local projection = allocation and bounds.object(allocation.projection)
    local definition = allocation and bounds.object(allocation.definition)
    local generation = allocation and bounds.count(allocation.generation)
    if not projection or not definition or not generation or generation < 1 then
        return fail("STORAGE", "materialization reservation returned corrupt data")
    end
    local source_ref = text(definition.source_ref) or ""
    local proj_kind = text(projection.projection_kind) or "environment"
    local destination = text(projection.destination) or ""
    local provider = text(definition.provider) or ""
    local optional_value = integer(definition.optional)
    if optional_value ~= 0 and optional_value ~= 1 then
        return fail("STORAGE", "credential optional flag is corrupt")
    end
    local optional = optional_value == 1
    if #provider_files > 0 and proj_kind ~= "file" then
        return fail("INVALID", "provider_files is only valid for file projections")
    end
    local frozen_format, frozen_format_error = stored_format(definition)
    if not frozen_format then
        return fail("CONFLICT", frozen_format_error or "credential format is not frozen")
    end

    if proj_kind == "environment" then
        local secret, secret_error = env.get(source_ref)
        if secret_error or type(secret) ~= "string" or secret == "" then
            if optional and (not secret_error or secret_error:kind() == errors.NOT_FOUND) then
                return succeed({projection_id = projection.projection_id, destination = destination, projection_kind = "environment", encoding = "utf-8",
                    generation = generation, generation_key = generation_key, format = frozen_format, present = false, optional = true})
            end
            return fail("UNAVAILABLE", "source " .. source_ref .. " yields no value")
        end
        if #secret > M.MAX_SECRET_BYTES then return fail("INVALID", "source " .. source_ref .. " exceeds " .. tostring(M.MAX_SECRET_BYTES) .. " bytes") end
        if secret:find("\0", 1, true) or secret:find("[\r\n]") then return fail("INVALID", "source " .. source_ref .. " holds bytes an environment value cannot carry") end
        return succeed({projection_id = projection.projection_id, destination = destination, projection_kind = "environment", encoding = "utf-8",
            generation = generation, generation_key = generation_key, format = frozen_format, present = true, optional = optional, value = secret})
    elseif proj_kind == "file" then
        local file_object = frozen_format.file
        local content_format = file_object and file_object.content_format or nil
        local expected_dest = sources.destination(frozen_format, "file")
        if not expected_dest or destination ~= expected_dest or (content_format ~= "json" and content_format ~= "opaque") then
            return fail("CONFLICT", "projection destination does not match credential format")
        end
        if not content_format then
            return fail("CONFLICT", "projection content format is unavailable")
        end
        local path, binding_error, setup, write_back = file_binding(admitted, definition, text(projection.workspace_id) or "", text(projection.audience))
        if not path then return binding_error or fail("INVALID", "file source unavailable") end
        local volume = fs.get(source_ref)
        if not volume then return fail("UNAVAILABLE", "source root " .. source_ref .. " unavailable") end
        local resolved_format = frozen_format
        if setup then
            local setup_bound = setup.content_format == "json" and 4096 or 65536
            local setup_content, setup_status, setup_error = read_source_file(volume, setup.path, setup.content_format, setup_bound, "setup file")
            if setup_status == "PRESENT" and setup_content then
                local appended, append_error = append_setup(resolved_format, setup.destination, setup_content, setup.path)
                if not appended then return fail("CONFLICT", append_error or "credential setup format is invalid") end
                resolved_format = appended
            elseif setup_status == "MISSING" and setup.content_format == "opaque" and setup.initialize_empty then
                -- An absent opaque setup is a measured empty base. Returning
                -- its admitted destination lets placement authorize an empty
                -- first-use composition without reading another retained file.
                local appended, append_error = append_setup(resolved_format, setup.destination, "", setup.path)
                if not appended then return fail("CONFLICT", append_error or "credential setup format is invalid") end
                resolved_format = appended
            elseif setup_status ~= "MISSING" then
                return fail(setup_status or "UNAVAILABLE", setup_error or "source setup file unavailable")
            end
        end
        for _, requested in ipairs(provider_files) do
            local duplicate = false
            if setup then
                if requested.source_path == setup.path or requested.path == setup.destination then
                    if requested.source_path == setup.path and requested.path == setup.destination then duplicate = true
                    else return fail("CONFLICT", "provider configuration file overlaps an admitted setup file") end
                end
            end
            local file = resolved_format.file
            if not file then return fail("CONFLICT", "credential format has no file") end
            for _, existing in ipairs(file.initialize) do
                if existing.path == requested.path or existing.source_path == requested.source_path then
                    if existing.path == requested.path and existing.source_path == requested.source_path then
                        duplicate = true
                    else
                        return fail("CONFLICT", "provider configuration file overlaps an admitted setup file")
                    end
                end
            end
            if not duplicate then
                local auxiliary_format, auxiliary_error = sources.additional_file(source_ref, text(projection.workspace_id) or "",
                    provider, text(projection.audience) or "", requested.source_path, requested.path)
                if not auxiliary_format then return fail("FORBIDDEN", auxiliary_error or "provider configuration file is not admitted") end
                local extra_content, extra_status, extra_error = read_source_file(volume, requested.source_path, auxiliary_format, M.MAX_FILE_BYTES, "provider configuration file")
                if extra_status == "MISSING" and requested.optional then
                    -- Optional provider settings may not exist on a machine
                    -- that has only the provider's login file.
                elseif extra_status ~= "PRESENT" or extra_content == nil then
                    return fail(extra_status or "UNAVAILABLE", extra_error or "provider configuration file unavailable")
                else
                    local appended, append_error = append_setup(resolved_format, requested.path, extra_content, requested.source_path)
                    if not appended then return fail("CONFLICT", append_error or "provider configuration format is invalid") end
                    resolved_format = appended
                end
            end
        end
        local content, status, content_error = read_source_file(volume, path, content_format, M.MAX_FILE_BYTES, "login file")
        if status == "MISSING" then
            if optional then
                return succeed({projection_id = projection.projection_id, destination = destination, projection_kind = "file", encoding = content_format == "opaque" and "bytes" or "utf-8", format = resolved_format,
                    generation = generation, generation_key = generation_key, definition_id = definition.definition_id,
                    definition_revision = definition.revision, provider = provider, source_path = path, source_present = false,
                    write_back = write_back == true, present = false, optional = true})
            end
            return fail("UNAVAILABLE", "source login file unavailable")
        end
        if status ~= "PRESENT" or not content then return fail(status or "UNAVAILABLE", content_error or "source login file unavailable") end
        -- Login formats belong to the harness. Do not guess OS-keyring
        -- locations or reinterpret provider fields; only an actual admitted
        -- file can be projected. Its bytes remain outside persisted state.
        local source_digest, source_digest_error = hash.sha256(content)
        if not source_digest or source_digest_error then return fail("UNAVAILABLE", "login source could not be measured") end
        return succeed({projection_id = projection.projection_id, destination = destination, projection_kind = "file", encoding = content_format == "opaque" and "bytes" or "utf-8", format = resolved_format,
            generation = generation, generation_key = generation_key, definition_id = definition.definition_id,
            definition_revision = definition.revision, provider = provider, source_path = path, source_present = true, source_digest = source_digest,
            write_back = write_back == true,
            present = true, optional = optional, value = content})
    else
        db:release()
        return fail("INVALID", "unsupported projection kind " .. proj_kind)
    end
end
function M.write_back(value: unknown): credential_protocol.Reply
    local object, decode_error = decode_use(value, {"generation", "source_digest", "value"})
    if not object then return fail("INVALID", decode_error or "invalid request") end
    local generation = bounds.integer(object.generation)
    local source_digest = bounds.text(object.source_digest, 64)
    if not generation or generation < 1 or not source_digest or #source_digest ~= 64 or not source_digest:match("^[0-9a-f]+$")
        or type(object.value) ~= "string" then
        return fail("INVALID", "provider token write-back metadata is invalid")
    end
    local content = object.value
    if #content == 0 or #content > M.MAX_FILE_BYTES then return fail("INVALID", "provider token update exceeds the file bound") end
    local next_digest, next_digest_error = hash.sha256(content)
    if not next_digest or next_digest_error then return fail("UNAVAILABLE", "provider token update could not be measured") end
    if not actor() then return fail("UNAUTHENTICATED", "no actor") end
    local admitted, admitted_error = sources.host_sources()
    if not admitted then return fail("STORAGE", admitted_error or "host sources") end
    local db, open_failure = open()
    if not db then return open_failure end
    local projection, projection_error = store.projection(db, object.projection_id)
    if projection_error or not projection then
        db:release()
        return projection_error and fail("STORAGE", projection_error) or fail("NOT_FOUND", "projection does not exist")
    end
    local workspace_id = text(projection.workspace_id) or ""
    if not security.can(M.WRITE_BACK, workspace_id) then
        db:release()
        return fail("DENIED", "caller is not a token writer admitted in workspace " .. workspace_id)
    end
    local result: TransactionResult = transaction.write(db, "credential token write-back", function(tx: sql.Transaction): TransactionResult
        local current_projection, current_projection_error = store.projection(tx, object.projection_id)
        if current_projection_error or not current_projection then
            return transaction.failure(current_projection_error and "STORAGE" or "NOT_FOUND",
                current_projection_error or "projection does not exist")
        end
        local serialize_error = store.serialize_write_back(tx, current_projection.projection_id)
        if serialize_error then
            if transaction.busy(serialize_error) then return transaction.storage_failure("credential token write-back database is busy") end
            return transaction.failure("STORAGE", "serialize provider token write-back")
        end
        local refused = holds(tx, admitted, current_projection, object.subject, object.audience, object.attempt_id)
        if refused then return transaction.failure(refused.error and refused.error.code or "DENIED",
            refused.error and refused.error.message or "projection no longer holds") end
        if current_projection.projection_kind ~= "file" or integer(current_projection.materialization_generation) ~= generation then
            if integer(current_projection.materialization_generation) == nil then
                return transaction.failure("STORAGE", "materialization generation is corrupt")
            end
            return transaction.failure("DENIED", "write-back does not match the active file projection generation")
        end
        local definition, definition_error = store.definition(tx, workspace_id, text(current_projection.name) or "")
        if definition_error or not definition then
            return transaction.failure("CONFLICT", definition_error or "credential definition is gone")
        end
        local selected_format, format_error = format_for(admitted, text(definition.provider) or "", "file")
        if not selected_format or not selected_format.file then
            return transaction.failure("CONFLICT", format_error or "provider login format is unavailable")
        end
        local content_format = selected_format.file.content_format
        if content_format == "json" then
            local ok, parsed = pcall(json.decode, content)
            if not ok or type(parsed) ~= "table" then
                return transaction.failure("INVALID", "provider token update is not valid JSON")
            end
        end
        local path, binding_error, _, write_back = file_binding(admitted, definition, workspace_id, text(current_projection.audience))
        local source_ref = bounds.id(definition.source_ref)
        if not path or not source_ref then
            return transaction.failure(binding_error and binding_error.error and binding_error.error.code or "FORBIDDEN",
                binding_error and binding_error.error and binding_error.error.message or "provider login source is unavailable")
        end
        if write_back ~= true then
            return transaction.failure("DENIED", "host admission does not allow token write-back for this file")
        end
        local volume = fs.get(source_ref)
        if not volume then return transaction.failure("UNAVAILABLE", "provider login source volume unavailable") end
        local current, status, read_error = read_source_file(volume, path, content_format, M.MAX_FILE_BYTES, "login file")
        if status ~= "PRESENT" or not current then
            return transaction.failure("CONFLICT", read_error or "the original provider login is no longer present")
        end
        local current_digest, current_digest_error = hash.sha256(current)
        if not current_digest or current_digest_error then
            return transaction.failure("UNAVAILABLE", "provider login could not be measured")
        end
        if current_digest == next_digest then
            return transaction.success({generation = generation, written = false}, false)
        end
        if current_digest ~= source_digest then
            return transaction.failure("CONFLICT", "the provider login changed after projection")
        end
        local published, write_error = volume:writefile("/" .. path, content, {atomic = true})
        if not published then
            local details = bounds.object(write_error and write_error:details() or nil)
            if details and details.published == true then
                return transaction.refusal("UNCERTAIN", "provider token update was published but durability requires inspection", nil)
            end
            return transaction.failure("UNAVAILABLE", "provider token update was refused")
        end
        return transaction.success({generation = generation, written = true}, false)
    end)
    db:release()
    if not result.ok then return fail(result.code or "STORAGE", result.message or "provider token write-back failed") end
    return succeed(result.value)
end
function M.revoke(value: unknown): credential_protocol.Reply
    local object = bounds.object(value)
    if not object then return fail("INVALID", "request must be an object") end
    local unknown_field = bounds.fields(object, {"projection_id"})
    if unknown_field then return fail("INVALID", unknown_field) end
    local projection_id = bounds.id(object.projection_id)
    if not projection_id then return fail("INVALID", "projection_id is not an identifier") end
    local caller = actor()
    if not caller then return fail("UNAUTHENTICATED", "no actor") end
    local db, open_failure = open()
    if not db then return open_failure end
    local projection, projection_error = store.projection(db, projection_id)
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
        local update_error = store.revoke(db, projection_id, stamp(now_ms()))
        if update_error then
            db:release()
            return fail("STORAGE", "revoke projection")
        end
    end
    local stored = store.projection(db, projection_id)
    db:release()
    if not stored then return fail("STORAGE", "read projection") end
    local view, view_error = projection_view(stored)
    if not view then return fail("STORAGE", view_error or "credential projection is corrupt") end
    return succeed(view)
end
function M.revoke_all(value: unknown): credential_protocol.Reply
    local object = bounds.object(value)
    if not object then return fail("INVALID", "request must be an object") end
    local unknown_field = bounds.fields(object, {"workspace_id"})
    if unknown_field then return fail("INVALID", unknown_field) end
    local workspace_id = bounds.id(object.workspace_id)
    if not workspace_id then return fail("INVALID", "workspace_id is not an identifier") end
    if not actor() then return fail("UNAUTHENTICATED", "no actor") end
    if not security.can(M.MANAGE, workspace_id) then return fail("DENIED", "caller does not manage workspace " .. workspace_id) end
    local db, open_failure = open()
    if not db then return open_failure end
    local epoch, epoch_error = store.epoch(db, workspace_id)
    if not epoch then
        db:release()
        return fail("STORAGE", epoch_error or "epoch")
    end
    local upsert_error = store.set_epoch(db, workspace_id, epoch + 1)
    db:release()
    if upsert_error then return fail("STORAGE", "advance authorization epoch") end
    return succeed({workspace_id = workspace_id, authorization_epoch = epoch + 1})
end
function M.list(value: unknown): credential_protocol.Reply
    local object = bounds.object(value)
    if not object then return fail("INVALID", "request must be an object") end
    local unknown_field = bounds.fields(object, {"workspace_id"})
    if unknown_field then return fail("INVALID", unknown_field) end
    local workspace_id = bounds.id(object.workspace_id)
    if not workspace_id then return fail("INVALID", "workspace_id is not an identifier") end
    if not actor() then return fail("UNAUTHENTICATED", "no actor") end
    if not security.can(M.MANAGE, workspace_id) then return fail("DENIED", "caller does not manage workspace " .. workspace_id) end
    local db, open_failure = open()
    if not db then return open_failure end
    local definitions, definitions_error = store.definitions(db, workspace_id, M.MAX_LIST)
    local projections, projections_error = store.active_projections(db, workspace_id, stamp(now_ms()), M.MAX_LIST)
    db:release()
    if definitions_error or not definitions or projections_error or not projections then return fail("STORAGE", "read workspace credentials") end
    local definition_views: {{[string]: unknown}} = {}
    for index, row in ipairs(definitions) do
        local view, view_error = definition_view(row)
        if not view then return fail("STORAGE", view_error or "credential definition is corrupt") end
        definition_views[index] = view
    end
    local projection_views: {{[string]: unknown}} = {}
    for index, row in ipairs(projections) do
        local view, view_error = projection_view(row)
        if not view then return fail("STORAGE", view_error or "credential projection is corrupt") end
        projection_views[index] = view
    end
    return succeed({workspace_id = workspace_id, definitions = definition_views, projections = projection_views})
end
function M.capabilities(): credential_protocol.Reply
    local admitted, admitted_error = sources.host_sources()
    if not admitted then return fail("STORAGE", admitted_error or "host sources") end
    local local_node, node_error = node()
    if not local_node then return fail("UNAVAILABLE", node_error or "node identity is unavailable") end
    local providers = sources.providers(admitted)
    local destinations: {[string]: string} = {}
    local file_destinations: {[string]: string} = {}
    for _, provider in ipairs(providers) do
        local selected = sources.format(admitted, provider)
        if selected then
            local environment = sources.destination(selected, "environment")
            local file = sources.destination(selected, "file")
            if environment then destinations[provider] = environment end
            if file then file_destinations[provider] = file end
        end
    end
    return succeed({credential_broker = true, projection_kinds = {"environment", "file"}, providers = providers, destinations = destinations,
        file_destinations = file_destinations, file_projections = true, provider_revocation = false, refresh = false, write_back = true,
        rotation = "next_materialization", repeat_generation = "refused", max_secret_bytes = M.MAX_SECRET_BYTES, max_file_bytes = M.MAX_FILE_BYTES,
        max_ttl_ms = M.MAX_TTL_MS, revocation_enforcement = "stop_on_reconcile", node = local_node})
end
function M.configuration_setup(raw: unknown): credential_protocol.Reply
    local request = bounds.object(raw)
    if not request or bounds.fields(request, {"workspace_id", "provider", "base_path", "operation", "attempt_id"}) then return fail("INVALID", "Configuration setup request is invalid.") end
    local workspace, provider, base_path = bounds.id(request.workspace_id), bounds.id(request.provider), formats.path(request.base_path)
    local operation = bounds.member(request.operation, {"status", "admit", "materialize"})
    local attempt = bounds.id(request.attempt_id)
    if not workspace or not provider or not base_path or not operation then return fail("INVALID", "Configuration setup needs a workspace, provider and file.") end
    if operation == "materialize" and not attempt then return fail("INVALID", "Configuration setup needs the launch attempt.") end
    if operation == "admit" then attempt = uuid.v7() end
    if operation == "materialize" then
        if not security.can(M.MATERIALIZE, workspace) then return fail("DENIED", "Configuration setup is not authorized for this launch.") end
    elseif not security.can("bee.harness.setup", workspace) then return fail("DENIED", "Configuration setup is not authorized in this workspace.") end
    local admitted, source_error = sources.host_sources()
    if not admitted then return fail("UNAVAILABLE", source_error or "Configuration sources are unavailable.") end
    local selected_ref: string? = nil
    local selected_setup: sources.Setup? = nil
    for _, source in ipairs(admitted.sources) do
        if source.provider == provider and (source.workspace_id == "*" or source.workspace_id == workspace) and source.setup and source.setup.destination == base_path then
            if selected_ref and (selected_ref ~= source.ref or (selected_setup and selected_setup.path ~= source.setup.path)) then return fail("CONFLICT", "Configuration setup names more than one source file.") end
            selected_ref, selected_setup = source.ref, source.setup
        end
    end
    if not selected_ref or not selected_setup then return fail("FORBIDDEN", "Bee has no approved setup source for this configuration base. Open Agents and choose Setup for this profile.") end
    local source_ref, setup = selected_ref, selected_setup
    local volume = fs.get(source_ref)
    if not volume then return fail("UNAVAILABLE", "Configuration source folder is unavailable.") end
    local db, db_error = store.open()
    if not db then return fail("STORAGE", db_error or "Configuration approval store is unavailable.") end
    local io: configuration_admission.IO = {
        measure = function(): (configuration_admission.Base?, string?)
            local content, state, err = read_source_file(volume, setup.path, setup.content_format, M.MAX_FILE_BYTES, "configuration file")
            if state == "MISSING" and setup.initialize_empty then content = "" end
            if content == nil then return nil, err or "The configuration file is missing. Create it with your provider, then choose Setup in Agents." end
            local digest, hash_error = hash.sha256(content)
            if not digest then return nil, tostring(hash_error or "Configuration file could not be measured.") end
            local root, root_error = env.get("bee.env:machine_home")
            if type(root) ~= "string" or root_error then return nil, "Configuration source path is unavailable." end
            return {content = content, digest = digest, path = root .. "/" .. setup.path}, nil
        end,
        admitted = function(base: configuration_admission.Base): (boolean?, string?) return store.configuration_admitted(db, workspace, source_ref, setup.path, base.digest) end,
        admit = function(base: configuration_admission.Base, approval: string): string? return store.admit_configuration(db, workspace, source_ref, setup.path, base.digest, approval) end,
        call = function(target: string, value: {[string]: unknown}): (unknown, string?) return funcs.call(target, value) end,
        wait = function() time.sleep("100ms") end,
    }
    if operation == "status" then
        local status, status_error = configuration_admission.status(io)
        db:release()
        if not status then return fail("UNAVAILABLE", status_error or "Configuration setup status is unavailable.") end
        return succeed(status)
    end
    local base, admission_error = configuration_admission.ensure(io, workspace, provider, attempt)
    db:release()
    if not base then return fail("DENIED", admission_error or "Configuration setup did not approve the file.") end
    if operation == "materialize" then return succeed({content = base.content, digest = base.digest, source_path = setup.path}) end
    return succeed({needs_setup = false, path = base.path})
end
return M
