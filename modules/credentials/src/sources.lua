-- MIT. Linked references of the credential broker: the store and the host's
-- source allowlist, the ceiling every definition stays under. Providers map
-- to their declared destinations; a file source may additionally name one
-- host-selected setup file. Its source path, retained destination and content
-- format are one admission decision.
local registry = require("registry")
local bounds = require("bounds")
local formats = require("formats")
local M = {}
M.DATABASE_REF = "bee.credentials:database_ref"
M.SOURCES_REF = "bee.credentials:sources_ref"
M.MATERIALIZER_REF = "bee.credentials:materializer_ref"
type Setup = {path: string, destination: string, content_format: string, initialize_empty: boolean}
type AuxiliaryFile = {source_prefix: string, destination_prefix: string, suffix: string, content_format: string}
type ProjectionKind = "environment" | "file"
type Source = {ref: string, workspace_id: string, audience: string, provider: string, projection_kinds: {ProjectionKind}, path: string?, setup: Setup?, auxiliary_files: {AuxiliaryFile}, write_back: boolean}
type SourceSet = {sources: {Source}, formats: {[string]: string}}
M.MAX_SOURCES = 64
M.MAX_FORMATS = 64
M.MAX_AUXILIARY_FILES = 8
local function reference(id: string, field: string, label: string): (string?, string?)
    local entry, err = registry.get(id)
    if err or not entry then return nil, label .. " reference unavailable" end
    local data = entry.data
    local ref = type(data) == "table" and data[field] or nil
    if type(ref) ~= "string" or ref == "" then return nil, label .. " reference is not linked" end
    return ref, nil
end
function M.database(): (string?, string?)
    return reference(M.DATABASE_REF, "resource_ref", "credential database")
end
function M.materializer(): (string?, string?)
    return reference(M.MATERIALIZER_REF, "binding_ref", "credential materializer")
end
-- Host sources: env.variable entries a workspace may define credentials
-- from, with the provider, the projection kinds and the audience (the
-- placement owner a projection may name) each admits. "*" admits every
-- workspace or every audience.
local function decode_source(value: unknown, index: integer): (Source?, string?)
    local label = "host credential sources[" .. tostring(index) .. "]"
    local declared = bounds.object(value)
    if not declared then return nil, label .. " must be an object" end
    local unknown_field = bounds.fields(declared, {"ref", "workspace_id", "audience", "provider", "projection_kinds", "path", "setup_path", "setup_destination", "setup_content_format", "setup_initialize_empty", "auxiliary_files", "write_back"})
    if unknown_field then return nil, label .. ": " .. unknown_field end
    local ref, workspace_id = bounds.id(declared.ref), bounds.id(declared.workspace_id)
    local audience, provider = bounds.id(declared.audience), bounds.id(declared.provider)
    if not ref or not workspace_id or not audience or not provider then return nil, label .. " has an invalid identity" end
    local raw_kinds, kinds_error = bounds.array(declared.projection_kinds, 2)
    if not raw_kinds or #raw_kinds == 0 then return nil, label .. " projection_kinds must contain one or two values: " .. tostring(kinds_error) end
    local kinds: {ProjectionKind} = {}
    local seen_kinds: {[string]: boolean} = {}
    for kind_index, raw in ipairs(raw_kinds) do
        local kind: ProjectionKind?
        if raw == "environment" then kind = "environment" elseif raw == "file" then kind = "file" end
        if not kind or seen_kinds[kind] then return nil, label .. " projection_kinds[" .. tostring(kind_index) .. "] is invalid or duplicated" end
        seen_kinds[kind] = true
        kinds[kind_index] = kind
    end
    local path: string? = nil
    if declared.path ~= nil then
        path = formats.path(declared.path)
        if not path then return nil, label .. " path is invalid" end
    end
    local setup: Setup? = nil
    if declared.setup_path ~= nil then
        local setup_path = formats.path(declared.setup_path)
        local setup_destination = declared.setup_destination == nil and setup_path or formats.path(declared.setup_destination)
        local setup_format: string? = "json"
        if declared.setup_content_format ~= nil then setup_format = bounds.member(declared.setup_content_format, {"json", "opaque"}) end
        if not setup_path or not setup_destination then return nil, label .. " setup path or destination is invalid" end
        if not setup_format then return nil, label .. " setup content format is invalid" end
        local initialize_empty = false
        if declared.setup_initialize_empty ~= nil then
            if type(declared.setup_initialize_empty) ~= "boolean" then return nil, label .. " setup empty-base flag is invalid" end
            initialize_empty = declared.setup_initialize_empty
        end
        setup = {path = setup_path, destination = setup_destination, content_format = setup_format, initialize_empty = initialize_empty}
    elseif declared.setup_destination ~= nil or declared.setup_content_format ~= nil or declared.setup_initialize_empty ~= nil then
        return nil, label .. " setup metadata requires setup_path"
    end
    local auxiliary_files: {AuxiliaryFile} = {}
    if declared.auxiliary_files ~= nil then
        local items, array_error = bounds.array(declared.auxiliary_files, M.MAX_AUXILIARY_FILES)
        if not items then return nil, label .. " auxiliary_files must be a bounded dense array: " .. tostring(array_error) end
        for file_index, raw in ipairs(items) do
            local item = bounds.object(raw)
            if not item then return nil, label .. " auxiliary_files[" .. tostring(file_index) .. "] must be an object" end
            local item_field = bounds.fields(item, {"source_prefix", "destination_prefix", "suffix", "content_format"})
            if item_field then return nil, label .. " auxiliary_files[" .. tostring(file_index) .. "]: " .. item_field end
            local source_prefix = bounds.text(item.source_prefix, 256)
            local destination_prefix = bounds.text(item.destination_prefix, 256)
            local suffix = bounds.text(item.suffix, 64)
            local content_format = bounds.member(item.content_format, {"json", "opaque"})
            if not source_prefix or source_prefix:sub(-1) ~= "/" or not formats.path(source_prefix .. "bee-file")
                or not destination_prefix or destination_prefix:sub(-1) ~= "/" or not formats.path(destination_prefix .. "bee-file")
                or not suffix or not suffix:match("^%.[A-Za-z0-9._-]+$") or suffix:find("..", 1, true) ~= nil
                or not content_format then return nil, label .. " auxiliary_files[" .. tostring(file_index) .. "] is invalid" end
            auxiliary_files[file_index] = {source_prefix = source_prefix, destination_prefix = destination_prefix,
                suffix = suffix, content_format = content_format}
        end
    end
    local write_back = false
    if declared.write_back ~= nil then
        if type(declared.write_back) ~= "boolean" then return nil, label .. " write_back must be a boolean" end
        write_back = declared.write_back
    end
    local file_allowed = seen_kinds.file == true
    if write_back and not file_allowed then return nil, label .. " write_back requires a file projection" end
    if not file_allowed and (path ~= nil or setup ~= nil or #auxiliary_files > 0) then return nil, label .. " file metadata requires a file projection" end
    return {ref = ref, workspace_id = workspace_id, audience = audience, provider = provider,
        projection_kinds = kinds, path = path, setup = setup, auxiliary_files = auxiliary_files, write_back = write_back}, nil
end
function M.host_sources(): (SourceSet?, string?)
    local sources_entry, sources_error = reference(M.SOURCES_REF, "resource_ref", "host sources")
    if not sources_entry then return nil, sources_error end
    local entry, err = registry.get(sources_entry)
    if err or not entry then return nil, "host sources unavailable" end
    local data = bounds.object(entry.data)
    if not data then return nil, "host credential declaration must be an object" end
    local unknown_field = bounds.fields(data, {"sources", "formats"})
    if unknown_field then return nil, "host credential declaration: " .. unknown_field end
    local source_rows, source_error = bounds.array(data.sources, M.MAX_SOURCES)
    if not source_rows then return nil, "host credential sources must be a bounded dense array: " .. tostring(source_error) end
    local format_declarations = bounds.object(data.formats)
    if not format_declarations then return nil, "host credential formats must be an object" end
    local sources: SourceSet = {sources = {}, formats = {}}
    local format_count = 0
    for provider, raw_ref in pairs(format_declarations) do
        local selected_provider, ref = bounds.id(provider), bounds.id(raw_ref)
        if not selected_provider or not ref then return nil, "host credential format entries must be identifiers" end
        format_count = format_count + 1
        if format_count > M.MAX_FORMATS then return nil, "host credential formats exceed " .. tostring(M.MAX_FORMATS) .. " entries" end
        sources.formats[selected_provider] = ref
    end
    for index, raw in ipairs(source_rows) do
        local source, source_error = decode_source(raw, index)
        if not source then return nil, source_error end
        sources.sources[index] = source
    end
    return sources, nil
end
local function matching_sources(sources: SourceSet, ref: string, workspace_id: string, provider: string,
    audience: string?, kind: string?): {Source}
    local matches: {Source} = {}
    for _, source in ipairs(sources.sources) do
        if source.ref == ref and source.provider == provider and (source.workspace_id == "*" or source.workspace_id == workspace_id)
            and (audience == nil or source.audience == "*" or source.audience == audience) then
            local admits_kind = kind == nil
            for _, admitted in ipairs(source.projection_kinds) do
                if admitted == kind then admits_kind = true end
            end
            if admits_kind then matches[#matches + 1] = source end
        end
    end
    return matches
end
-- An auxiliary config file is read only when its exact safe path is requested
-- by a driver and the host admits its prefix and suffix for this source.
function M.auxiliary_rules(sources: SourceSet, ref: string, workspace_id: string, provider: string, audience: string?): ({AuxiliaryFile}?, string?)
    local selected: {AuxiliaryFile}? = nil
    for _, source in ipairs(matching_sources(sources, ref, workspace_id, provider, audience, "file")) do
        local same = selected == nil or #selected == #source.auxiliary_files
        if same and selected ~= nil then
            for index, rule in ipairs(source.auxiliary_files) do
                local prior = selected[index]
                if not prior or prior.source_prefix ~= rule.source_prefix or prior.destination_prefix ~= rule.destination_prefix
                    or prior.suffix ~= rule.suffix or prior.content_format ~= rule.content_format then
                    same = false
                    break
                end
            end
        end
        if not same then return nil, "host auxiliary credential file declarations are ambiguous" end
        if selected == nil then selected = source.auxiliary_files end
    end
    if selected == nil then return nil, "host file source is not admitted" end
    return selected, nil
end
function M.additional_file(ref: string, workspace_id: string, provider: string, audience: string,
    source_path: string, destination: string): (string?, string?)
    if not formats.path(source_path) or not formats.path(destination) then return nil, "auxiliary provider path is invalid" end
    local sources, sources_error = M.host_sources()
    if not sources then return nil, sources_error or "host sources unavailable" end
    local rules, rules_error = M.auxiliary_rules(sources, ref, workspace_id, provider, audience)
    if not rules then return nil, rules_error or "host auxiliary file rule unavailable" end
    local selected: string? = nil
    for _, rule in ipairs(rules) do
        if source_path:sub(1, #rule.source_prefix) == rule.source_prefix and source_path:sub(-#rule.suffix) == rule.suffix then
            local leaf = source_path:sub(#rule.source_prefix + 1)
            local name = leaf:sub(1, #leaf - #rule.suffix)
            if leaf:find("/", 1, true) == nil and name:match("^[A-Za-z0-9_][A-Za-z0-9_-]*$")
                and destination == rule.destination_prefix .. leaf then
                if selected ~= nil and selected ~= rule.content_format then
                    return nil, "host auxiliary credential file declarations are ambiguous"
                end
                selected = rule.content_format
            end
        end
    end
    if not selected then return nil, "host does not admit this auxiliary provider file" end
    return selected, nil
end
-- An optional provider setup file is a host-selected path paired with a file
-- source. It is metadata only; the file policy still authorizes fs.get/read.
-- Ambiguous declarations refuse rather than choosing one path.
function M.setup(sources: SourceSet, ref: string, workspace_id: string, provider: string, audience: string?): (Setup?, string?)
    local selected: Setup? = nil
    local selected_set = false
    local matches = matching_sources(sources, ref, workspace_id, provider, audience, "file")
    for _, source in ipairs(matches) do
        if not selected_set then
            selected = source.setup
            selected_set = true
        else
            local candidate = source.setup
            local same = (selected == nil and candidate == nil) or (selected ~= nil and candidate ~= nil
                and selected.path == candidate.path and selected.destination == candidate.destination
                and selected.content_format == candidate.content_format and selected.initialize_empty == candidate.initialize_empty)
            if not same then return nil, "host credential setup files are ambiguous" end
        end
    end
    if #matches == 0 then return nil, "host file source is not admitted" end
    return selected, nil
end
-- Token write-back is a separate host admission bit; file readability alone
-- never permits returning child changes to the machine login source.
function M.token_write_back(sources: SourceSet, ref: string, workspace_id: string, provider: string, audience: string?): (boolean?, string?)
    local selected: boolean? = nil
    for _, source in ipairs(matching_sources(sources, ref, workspace_id, provider, audience, "file")) do
        if selected ~= nil and selected ~= source.write_back then return nil, "host token write-back declarations are ambiguous" end
        selected = source.write_back
    end
    if selected == nil then return nil, "host file source is not admitted" end
    return selected, nil
end
-- Whether the host admits a source for a workspace, provider and kind, and
-- when an audience is named, for that audience too.
function M.admits(sources: SourceSet, ref: string, workspace_id: string, provider: string, kind: string, audience: string?): boolean
    return #matching_sources(sources, ref, workspace_id, provider, audience, kind) > 0
end
-- Paths belong to host admission, never to a definition request. Ambiguous
-- host rows refuse rather than selecting whichever happens to come first.
local function basename(path: string): string
    return path:match("[^/]+$") or path
end
function M.format(sources: SourceSet, provider: string): (formats.Format?, string?)
    local ref = sources.formats[provider]
    if not ref then return nil, "host credential format is not declared for " .. provider end
    local entry, err = registry.get(ref)
    if err or not entry then return nil, "credential format " .. ref .. " is unavailable" end
    local decoded, decode_error = formats.decode(entry.data)
    if not decoded then return nil, decode_error or "credential format is invalid" end
    return decoded, nil
end
function M.destination(format: formats.Format, kind: string): string?
    if kind == "environment" and format.environment_destination then
        return format.environment_destination
    end
    if kind == "file" and format.file then
        return basename(format.file.path)
    end
    return nil
end
function M.file_path(sources: SourceSet, ref: string, workspace_id: string, provider: string, audience: string?, format: formats.Format?): (string?, string?)
    local selected: string? = nil
    for _, source in ipairs(matching_sources(sources, ref, workspace_id, provider, audience, "file")) do
        local path = source.path
        if not path then
            local selected_format = format
            if not selected_format then
                local format_error
                selected_format, format_error = M.format(sources, provider)
                if not selected_format then return nil, format_error or "credential format unavailable" end
            end
            path = M.destination(selected_format, "file")
        end
        if not path then return nil, "credential format has no file destination" end
        if selected ~= nil and selected ~= path then return nil, "host credential paths are ambiguous" end
        selected = path
    end
    if not selected then return nil, "host file source is not admitted" end
    return selected, nil
end
function M.providers(sources: SourceSet): {string}
    local providers: {string} = {}
    local seen: {[string]: boolean} = {}
    for _, source in ipairs(sources.sources) do
        if not seen[source.provider] then
            seen[source.provider] = true
            providers[#providers + 1] = source.provider
        end
    end
    table.sort(providers)
    return providers
end
-- The env.variable entry behind a source, as configuration only.
function M.variable(ref: string): ({[string]: unknown}?, string?)
    local entry, err = registry.get(ref)
    if err or not entry then return nil, "source " .. ref .. " is not in the registry" end
    if entry.kind ~= "env.variable" then return nil, "source " .. ref .. " is not an env.variable" end
    local data = type(entry.data) == "table" and entry.data :: {[string]: unknown} or {}
    return {kind = entry.kind, storage = data.storage, variable = data.variable, readonly = data.readonly}, nil
end
-- The fs.directory entry behind a login file source, as configuration only.
function M.directory(ref: string): ({[string]: unknown}?, string?)
    local entry, err = registry.get(ref)
    if err or not entry then return nil, "source " .. ref .. " is not in the registry" end
    if entry.kind ~= "fs.directory" then return nil, "source " .. ref .. " is not an fs.directory" end
    local data = type(entry.data) == "table" and entry.data :: {[string]: unknown} or {}
    local directory = type(data.directory) == "string" and data.directory or nil
    if not directory or directory == "" then return nil, "source " .. ref .. " has no directory" end
    return {kind = entry.kind, directory = directory, mode = data.mode, readonly = data.readonly}, nil
end
return M
