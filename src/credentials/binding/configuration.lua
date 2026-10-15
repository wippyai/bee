-- MIT. Credential availability and provider configuration setup.
local sql = require("sql")
local hash = require("hash")
local time = require("time")
local uuid = require("uuid")
local security = require("security")
local env = require("env")
local fs = require("fs")
local json = require("json")
local bounds = require("bounds")
local canonical = require("canonical")
local credential_protocol = require("credential_protocol")
local store = require("store")
local sources = require("sources")
local formats = require("formats")
local funcs = require("funcs")
local configuration_admission = require("configuration_admission")
local identity = require("identity")
local M = {}
M.MANAGE = "bee.credentials.manage"
M.MATERIALIZE = "bee.credentials.materialize"
M.MAX_FILE_BYTES = credential_protocol.MAX_FILE_BYTES
type Row = {[string]: unknown}
type AvailabilityRequest = {workspace_id: string, name: string}
type Availability = {workspace_id: string, name: string, definition_id: string, revision: integer, provider: string, source_kind: string, projection_kind: string, destination: string, format: unknown, present: boolean, optional: boolean}
local function fail(code: string, message: string): credential_protocol.Reply
    return {ok = false, error = {code = code, message = message}, value = nil}
end
local function succeed(value: unknown): credential_protocol.Reply
    return {ok = true, error = nil, value = value}
end
local actor = identity.actor

local function open(): (sql.DB?, credential_protocol.Reply?)
    local db, open_error = store.open()
    if not db then return nil, fail("STORAGE", open_error or "open credential store") end
    return db, nil
end
local digest_of = canonical.digest

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
local function configuration_io(workspace: string, provider: string, base_path: string): (configuration_admission.IO?, sql.DB?, sources.Setup?, credential_protocol.Reply?)
    local admitted, source_error = sources.host_sources()
    if not admitted then return nil, nil, nil, fail("UNAVAILABLE", source_error or "Configuration sources are unavailable.") end
    local selected_ref: string? = nil
    local selected_setup: sources.Setup? = nil
    for _, source in ipairs(admitted.sources) do
        if source.provider == provider and (source.workspace_id == "*" or source.workspace_id == workspace) and source.setup and source.setup.destination == base_path then
            if selected_ref and (selected_ref ~= source.ref or (selected_setup and selected_setup.path ~= source.setup.path)) then return nil, nil, nil, fail("CONFLICT", "Configuration setup names more than one source file.") end
            selected_ref, selected_setup = source.ref, source.setup
        end
    end
    if not selected_ref or not selected_setup then return nil, nil, nil, fail("FORBIDDEN", "This profile does not tell Bee where to find its configuration file. Ask the profile author to add a setup file, then choose Setup in Agents.") end
    local source_ref, setup = selected_ref, selected_setup
    local volume = fs.get(source_ref)
    if not volume then return nil, nil, nil, fail("UNAVAILABLE", "Configuration source folder is unavailable.") end
    local db, db_error = store.open()
    if not db then return nil, nil, nil, fail("STORAGE", db_error or "Configuration approval store is unavailable.") end
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
        finish = function(base: configuration_admission.Base?, approval: string, receipt: {[string]: unknown}): string?
            return store.finish_configuration(db, workspace, source_ref, setup.path, base and base.digest, approval, receipt)
        end,
        receipt = function(approval: string): ({[string]: unknown}?, string?) return store.configuration_receipt(db, approval) end,
        call = function(target: string, value: {[string]: unknown}): (unknown, string?) return funcs.call(target, value) end,
        wait = function() time.sleep("100ms") end,
    }
    return io, db, setup, nil
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
    local io, db, setup, problem = configuration_io(workspace, provider, base_path)
    if not io or not db or not setup then return problem or fail("UNAVAILABLE", "Configuration setup source is unavailable.") end
    if operation == "status" then
        local status, status_error = configuration_admission.status(io)
        db:release()
        if not status then return fail("UNAVAILABLE", status_error or "Configuration setup status is unavailable.") end
        return succeed(status)
    end
    local base, admission_error = configuration_admission.ensure(io, workspace, provider, attempt, base_path)
    db:release()
    if not base then return fail("DENIED", admission_error or "Configuration setup did not approve the file.") end
    if operation == "materialize" then return succeed({content = base.content, digest = base.digest, source_path = setup.path}) end
    return succeed({needs_setup = false, path = base.path})
end
function M.configuration_effects(): string?
    local raw, err = funcs.call("bee.approvals.binding:effect_queue", {destination = "credentials.configuration", limit = 64})
    local reply = bounds.object(raw)
    local page = reply and reply.ok == true and bounds.object(reply.value)
    local effects = page and bounds.array(page.effects, 64)
    if err or not effects then return "Configuration setup effects could not be read: " .. tostring(err or (reply and reply.error)) end
    for _, item in ipairs(effects) do
        local view = bounds.object(item)
        local proposal = view and bounds.object(view.proposal)
        local payload = proposal and bounds.object(proposal.payload)
        local workspace = payload and bounds.id(payload.workspace_id)
        local provider = payload and bounds.id(payload.provider)
        local path = payload and formats.path(payload.base_path)
        if not view or not workspace or workspace ~= view.workspace_id or not provider or not path then return "Configuration setup effect has invalid source metadata." end
        local io, db, _, problem = configuration_io(workspace, provider, path)
        if not io or not db then return problem and problem.error and problem.error.message or "Configuration setup source is unavailable." end
        local consume_error = configuration_admission.consume(io, view)
        db:release()
        if consume_error then return consume_error end
    end
    local cursor = 0
    while true do
        local events_raw, events_error = funcs.call("bee.approvals.binding:events", {destination = "credentials.configuration", cursor = cursor, limit = 64})
        local events_reply = bounds.object(events_raw)
        local events_page = events_reply and events_reply.ok == true and bounds.object(events_reply.value)
        local events = events_page and bounds.array(events_page.events, 64)
        local next_cursor = events_page and bounds.count(events_page.cursor)
        if events_error or not events or not next_cursor then return "Configuration setup events could not be read." end
        local acknowledgments: {string} = {}
        local db, open_error = store.open()
        if not db then return open_error or "Configuration setup receipts are unavailable." end
        for _, item in ipairs(events) do
            local event = bounds.object(item)
            local id = event and bounds.id(event.event_id)
            local body = event and bounds.object(event.body)
            local approval = body and bounds.id(body.approval_id)
            if id and approval and event.acknowledged_at == nil then
                local receipt, receipt_error = store.configuration_receipt(db, approval)
                if receipt_error then db:release(); return receipt_error end
                if receipt then
                    local effect_raw, effect_error = funcs.call("bee.approvals.binding:effect", {operation = "read", approval_id = approval, proposal_digest = receipt.proposal_digest})
                    local effect_reply = bounds.object(effect_raw)
                    local effect_view = effect_reply and effect_reply.ok == true and bounds.object(effect_reply.value)
                    if effect_error or not effect_view then db:release(); return "Configuration setup effect receipt could not be inspected." end
                    if effect_view.effect_completed_at ~= nil then acknowledgments[#acknowledgments + 1] = id end
                end
            end
        end
        db:release()
        if #acknowledgments > 0 then
            local acknowledged, acknowledge_error = funcs.call("bee.approvals.binding:events", {destination = "credentials.configuration", acknowledge = acknowledgments})
            local result = bounds.object(acknowledged)
            if acknowledge_error or not result or result.ok ~= true then return "Configuration setup events could not be acknowledged." end
        end
        if #events < 64 then break end
        cursor = next_cursor
    end
    return nil
end

M.fail = fail
M.succeed = succeed
M.actor = actor
M.open = open
M.digest_of = digest_of
M.text = text
M.canonical_format = canonical_format
M.stored_format = stored_format
M.format_matches = format_matches
M.format_for = format_for
M.integer = integer
M.read_source_file = read_source_file
M.file_binding = file_binding
M.decode_availability = decode_availability
M.availability_view = availability_view
M.configuration_io = configuration_io
return M
