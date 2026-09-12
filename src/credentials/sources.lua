-- MIT. Linked references of the credential broker: the store and the host's
-- source allowlist, the ceiling every definition stays under. Providers map
-- to the single environment destination each admits in phase 1.
local registry = require("registry")
local M = {}
M.DATABASE_REF = "bee.credentials:database_ref"
M.SOURCES_REF = "bee.credentials:sources_ref"
M.MATERIALIZER = "bee.placement.native:binding"
-- The destination a provider adapter admits for an environment projection.
M.DESTINATIONS = {claude = "ANTHROPIC_API_KEY", codex = "OPENAI_API_KEY"}
-- The relative file destination a provider adapter admits for a login file projection.
M.FILE_DESTINATIONS = {claude = ".credentials.json", codex = "auth.json"}
type Source = {ref: string, workspace_id: string, audience: string, provider: string, projection_kinds: {string}, path: string?}
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
-- Host sources: env.variable entries a workspace may define credentials
-- from, with the provider, the projection kinds and the audience (the
-- placement owner a projection may name) each admits. "*" admits every
-- workspace or every audience.
function M.host_sources(): ({Source}?, string?)
    local sources_entry, sources_error = reference(M.SOURCES_REF, "resource_ref", "host sources")
    if not sources_entry then return nil, sources_error end
    local entry, err = registry.get(sources_entry)
    if err or not entry then return nil, "host sources unavailable" end
    local data = entry.data
    local sources: {Source} = {}
    local list = type(data) == "table" and data.sources or nil
    if type(list) ~= "table" then return sources, nil end
    for _, item in ipairs(list :: {unknown}) do
        if type(item) == "table" then
            local declared = item :: {[string]: unknown}
            local path: string? = nil
            if declared.path ~= nil then
                if type(declared.path) ~= "string" or #declared.path == 0 or #declared.path > 512
                    or declared.path:find("[%z\r\n\\]") or declared.path:sub(1, 1) == "/" then
                    return nil, "host credential path is invalid"
                end
                for segment in (declared.path .. "/"):gmatch("(.-)/") do
                    if segment == "" or segment == "." or segment == ".." then return nil, "host credential path is invalid" end
                end
                path = declared.path :: string
            end
            local kinds: {string} = {}
            if type(declared.projection_kinds) == "table" then
                for _, kind in ipairs(declared.projection_kinds :: {unknown}) do
                    if kind == "environment" or kind == "file" then kinds[#kinds + 1] = kind end
                end
            end
            if type(declared.ref) == "string" and type(declared.workspace_id) == "string" and type(declared.audience) == "string"
                and (M.DESTINATIONS[declared.provider] or M.FILE_DESTINATIONS[declared.provider]) then
                sources[#sources + 1] = {ref = declared.ref :: string, workspace_id = declared.workspace_id :: string, audience = declared.audience :: string,
                    provider = declared.provider :: string, projection_kinds = kinds, path = path}
            end
        end
    end
    return sources, nil
end
-- Whether the host admits a source for a workspace, provider and kind, and
-- when an audience is named, for that audience too.
function M.admits(sources: {Source}, ref: string, workspace_id: string, provider: string, kind: string, audience: string?): boolean
    for _, source in ipairs(sources) do
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
function M.file_path(sources: {Source}, ref: string, workspace_id: string, provider: string, audience: string?): (string?, string?)
    local selected: string? = nil
    for _, source in ipairs(sources) do
        if source.ref == ref and source.provider == provider and (source.workspace_id == "*" or source.workspace_id == workspace_id)
            and (audience == nil or source.audience == "*" or source.audience == audience) then
            for _, kind in ipairs(source.projection_kinds) do
                if kind == "file" then
                    local path = source.path or M.FILE_DESTINATIONS[provider]
                    if not path then return nil, "unsupported credential provider" end
                    if selected ~= nil and selected ~= path then return nil, "host credential paths are ambiguous" end
                    selected = path
                end
            end
        end
    end
    if not selected then return nil, "host file source is not admitted" end
    return selected, nil
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
