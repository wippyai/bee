-- MIT. Credential definition, projection issue, revocation and listing.
local sql = require("sql")
local uuid = require("uuid")
local security = require("security")
local env = require("env")
local bounds = require("bounds")
local clock = require("clock")
local credential_protocol = require("credential_protocol")
local store = require("store")
local transaction = require("transaction")
local sources = require("sources")
local formats = require("formats")
local identity = require("identity")
local part_configuration = require("part_configuration")
local views = require("views")
local M = {}
M.MANAGE = part_configuration.MANAGE
M.MAX_FILE_BYTES = part_configuration.MAX_FILE_BYTES
type Row = part_configuration.Row
type TransactionResult = part_configuration.TransactionResult
local milliseconds = part_configuration.milliseconds
local definition_view = views.definition_view
local projection_view = views.projection_view
local fail = part_configuration.fail
local succeed = part_configuration.succeed
local actor = part_configuration.actor
local open = part_configuration.open
local digest_of = part_configuration.digest_of
local text = part_configuration.text
local format_matches = part_configuration.format_matches
local format_for = part_configuration.format_for
local integer = part_configuration.integer
local file_binding = part_configuration.file_binding
M.availability = part_configuration.availability
M.configuration_setup = part_configuration.configuration_setup
M.configuration_effects = part_configuration.configuration_effects
M.ISSUE = "bee.credentials.issue"
M.MAX_TTL_MS = 86400000
M.DEFAULT_TTL_MS = 3600000
M.MAX_SECRET_BYTES = credential_protocol.MAX_SECRET_BYTES
M.MAX_LIST = 64
M.SOURCE_KINDS = {"env_variable", "fs_directory"}
local node = identity.node

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
        local at = clock.stamp(milliseconds())
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
    local created = milliseconds()
    local insert_error = store.insert_projection(db, {projection_id = projection_id,
        workspace_id = request.workspace_id, name = request.name, definition_id = definition.definition_id,
        definition_revision = definition.revision, issuer_owner = owner_node, subject = subject,
        audience = request.audience, attempt_id = request.attempt_id, profile_id = request.profile_id,
        profile_digest = request.profile_digest, binding_digest = request.binding_digest,
        launch_policy_digest = request.launch_policy_digest, provider = definition.provider,
        projection_kind = definition.projection_kind, destination = definition.destination,
        format_json = format_json, materializer = materializer, idempotency_key = request.idempotency_key,
        expires_at = clock.stamp(created + request.ttl), lease_ms = request.ttl, authorization_epoch = epoch, created_at = clock.stamp(created)})
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
        local update_error = store.revoke(db, projection_id, clock.stamp(milliseconds()))
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
    local projections, projections_error = store.active_projections(db, workspace_id, clock.stamp(milliseconds()), M.MAX_LIST)
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
return M
