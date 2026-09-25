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
type Setup = {path: string, destination: string, content_format: string}
type Source = {ref: string, workspace_id: string, audience: string, provider: string, projection_kinds: {string}, path: string?, setup: Setup?}
type SourceSet = {sources: {Source}, formats: {[string]: string}}
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
function M.host_sources(): (SourceSet?, string?)
    local sources_entry, sources_error = reference(M.SOURCES_REF, "resource_ref", "host sources")
    if not sources_entry then return nil, sources_error end
    local entry, err = registry.get(sources_entry)
    if err or not entry then return nil, "host sources unavailable" end
    local data = entry.data
    local sources: SourceSet = {sources = {}, formats = {}}
    local list = type(data) == "table" and data.sources or nil
    local declared_formats = type(data) == "table" and data.formats or nil
    if declared_formats ~= nil then
        if type(declared_formats) ~= "table" then return nil, "host credential formats are invalid" end
        local format_count = 0
        for provider, ref in pairs(declared_formats :: {[unknown]: unknown}) do
            if type(provider) ~= "string" or not bounds.id(provider) or type(ref) ~= "string" or not bounds.id(ref) then
                return nil, "host credential formats are invalid"
            end
            format_count = format_count + 1
            if format_count > 64 then return nil, "host credential formats exceed the limit" end
            sources.formats[provider] = ref
        end
    end
    if type(list) ~= "table" then return sources, nil end
    for _, item in ipairs(list :: {unknown}) do
        if type(item) == "table" then
            local declared = item :: {[string]: unknown}
            local path: string? = nil
            if declared.path ~= nil then
                path = formats.path(declared.path)
                if not path then return nil, "host credential path is invalid" end
            end
            local setup: Setup? = nil
            if declared.setup_path ~= nil then
                local setup_path = formats.path(declared.setup_path)
                local setup_destination = declared.setup_destination == nil and setup_path or formats.path(declared.setup_destination)
                local setup_format = declared.setup_content_format == nil and "json" or bounds.member(declared.setup_content_format, {"json", "opaque"})
                if not setup_path or not setup_destination then return nil, "host credential setup path or destination is invalid" end
                if not setup_format then return nil, "host credential setup content format is invalid" end
                setup = {path = setup_path, destination = setup_destination, content_format = setup_format}
            elseif declared.setup_destination ~= nil or declared.setup_content_format ~= nil then
                return nil, "host credential setup destination and format require setup_path"
            end
            local kinds: {string} = {}
            if type(declared.projection_kinds) == "table" then
                for _, kind in ipairs(declared.projection_kinds :: {unknown}) do
                    if kind == "environment" or kind == "file" then kinds[#kinds + 1] = kind end
                end
            end
            local provider = bounds.id(declared.provider)
            local ref = bounds.id(declared.ref)
            local workspace_id = bounds.id(declared.workspace_id)
            local audience = bounds.id(declared.audience)
            if ref and workspace_id and audience and provider then
                sources.sources[#sources.sources + 1] = {ref = ref, workspace_id = workspace_id, audience = audience,
                    provider = provider, projection_kinds = kinds, path = path, setup = setup}
            end
        end
    end
    return sources, nil
end
-- An optional provider setup file is a host-selected path paired with a file
-- source. It is metadata only; the file policy still authorizes fs.get/read.
-- Ambiguous declarations refuse rather than choosing one path.
function M.setup(sources: SourceSet, ref: string, workspace_id: string, provider: string, audience: string?): (Setup?, string?)
    local selected: Setup? = nil
    local matched = false
    local selected_set = false
    for _, source in ipairs(sources.sources) do
        if source.ref == ref and source.provider == provider and (source.workspace_id == "*" or source.workspace_id == workspace_id)
            and (audience == nil or source.audience == "*" or source.audience == audience) then
            for _, kind in ipairs(source.projection_kinds) do
                if kind == "file" then
                    matched = true
                    if not selected_set then
                        selected = source.setup
                        selected_set = true
                    else
                        local candidate = source.setup
                        local same = (selected == nil and candidate == nil) or (selected ~= nil and candidate ~= nil
                            and selected.path == candidate.path and selected.destination == candidate.destination
                            and selected.content_format == candidate.content_format)
                        if not same then return nil, "host credential setup files are ambiguous" end
                    end
                end
            end
        end
    end
    if not matched then return nil, "host file source is not admitted" end
    return selected, nil
end
-- Whether the host admits a source for a workspace, provider and kind, and
-- when an audience is named, for that audience too.
function M.admits(sources: SourceSet, ref: string, workspace_id: string, provider: string, kind: string, audience: string?): boolean
    for _, source in ipairs(sources.sources) do
        if source.ref == ref and source.provider == provider and (source.workspace_id == "*" or source.workspace_id == workspace_id)
            and (audience == nil or source.audience == "*" or source.audience == audience) then
            for _, admitted in ipairs(source.projection_kinds) do
                if admitted == kind then return true end
            end
        end
    end
    return false
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
    for _, source in ipairs(sources.sources) do
        if source.ref == ref and source.provider == provider and (source.workspace_id == "*" or source.workspace_id == workspace_id)
            and (audience == nil or source.audience == "*" or source.audience == audience) then
            for _, kind in ipairs(source.projection_kinds) do
                if kind == "file" then
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
            end
        end
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
