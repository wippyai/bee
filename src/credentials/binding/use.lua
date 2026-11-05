-- MIT. Credential projection use: check, attempt renewal, materialization and token write-back.
local sql = require("sql")
local hash = require("hash")
local security = require("security")
local env = require("env")
local fs = require("fs")
local json = require("json")
local bounds = require("bounds")
local clock = require("clock")
local credential_protocol = require("credential_protocol")
local store = require("store")
local transaction = require("transaction")
local sources = require("sources")
local formats = require("formats")
local part_configuration = require("part_configuration")
local views = require("views")
local M = {}
M.WRITE_BACK = "bee.credentials.write_back"
local MATERIALIZE = part_configuration.MATERIALIZE
local MAX_FILE_BYTES = part_configuration.MAX_FILE_BYTES
type Row = part_configuration.Row
type TransactionResult = part_configuration.TransactionResult
type ProviderFileRequest = {source_path: string, path: string, optional: boolean}
local milliseconds = part_configuration.milliseconds
local projection_view = views.projection_view
local fail = part_configuration.fail
local succeed = part_configuration.succeed
local actor = part_configuration.actor
local open = part_configuration.open
local text = part_configuration.text
local stored_format = part_configuration.stored_format
local format_matches = part_configuration.format_matches
local format_for = part_configuration.format_for
local integer = part_configuration.integer
local read_source_file = part_configuration.read_source_file
local file_binding = part_configuration.file_binding
local function append_setup(format: formats.Format, destination: string, content: string, source_path: string): (formats.Format?, string?)
    local file = format.file
    if not file then return nil, "credential setup requires a file format" end
    file.initialize[#file.initialize + 1] = {path = destination, content = content, source_path = source_path, on_missing_login = true}
    local decoded, decode_error = formats.decode(format)
    if not decoded then return nil, decode_error or "credential setup format is invalid" end
    return decoded, nil
end
local function binding_holds(admitted: sources.SourceSet, projection: Row, subject: string, audience: string, attempt_id: string,
    epoch: integer, definition: Row?): credential_protocol.Reply?
    if projection.revoked_at ~= nil then return fail("REVOKED", "projection was revoked at " .. tostring(projection.revoked_at)) end
    if tostring(projection.expires_at) <= clock.stamp(milliseconds()) then return fail("EXPIRED", "projection expired at " .. tostring(projection.expires_at)) end
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
    if not security.can(MATERIALIZE, workspace_id) then
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
    local now = milliseconds()
    local rows, read_error = store.attempt_leases(db, attempt_id, subject, audience, clock.stamp(now))
    if not rows then db:release(); return fail("STORAGE", read_error or "read attempt projections") end
    local renewed = 0
    for _, row in ipairs(rows) do
        local workspace_id = text(row.workspace_id) or ""
        if not security.can(MATERIALIZE, workspace_id) then db:release(); return fail("DENIED", "caller is not a materializer admitted in workspace " .. workspace_id) end
        local epoch, epoch_error = store.epoch(db, workspace_id)
        if not epoch then db:release(); return fail("STORAGE", epoch_error or "epoch") end
        local lease, projection_epoch = integer(row.lease_ms), integer(row.authorization_epoch)
        if not lease or lease < 1 or not projection_epoch then db:release(); return fail("STORAGE", "projection lease is corrupt") end
        if projection_epoch >= epoch and tostring(row.expires_at) <= clock.stamp(now + lease // 2) then
            local extend_error = store.extend(db, tostring(row.projection_id), clock.stamp(now + lease))
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
        if not security.can(MATERIALIZE, workspace_id) then
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
        local reservation_error = store.reserve_generation(tx, projection_id, generation_key, generation, materializer, clock.stamp(milliseconds()))
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
        if #secret > credential_protocol.MAX_SECRET_BYTES then return fail("INVALID", "source " .. source_ref .. " exceeds " .. tostring(credential_protocol.MAX_SECRET_BYTES) .. " bytes") end
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
                local extra_content, extra_status, extra_error = read_source_file(volume, requested.source_path, auxiliary_format, MAX_FILE_BYTES, "provider configuration file")
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
        local content, status, content_error = read_source_file(volume, path, content_format, MAX_FILE_BYTES, "login file")
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
    if #content == 0 or #content > MAX_FILE_BYTES then return fail("INVALID", "provider token update exceeds the file bound") end
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
        local current, status, read_error = read_source_file(volume, path, content_format, MAX_FILE_BYTES, "login file")
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
return M
