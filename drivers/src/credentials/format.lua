-- SPDX-License-Identifier: MIT
-- The credential format a driver declares: where a login file and an API key
-- reach its CLI, and the files a login file needs beside it. Decoding grants
-- no resource access.
local bounds = require("bounds")
local M = {}
M.REVISION = "bee.credential-format@2"
type Initializer = {path: string, content: string, source_path: string?, on_missing_login: boolean?}
type File = {path: string, content_format: string, initialize: {Initializer}}
-- environments: the variables an API key or token reaches the CLI through.
type Format = {schema_revision: string, environments: {string}, file: File?}
M.MAX_INITIALIZATION_BYTES = 65536

function M.path(value: unknown): string?
    local path = bounds.text(value, 512)
    if not path then return nil end
    return bounds.subpath(path, nil, {nonempty = true, no_control = true})
end
function M.decode(value: unknown): (Format?, string?)
    local object = bounds.object(value)
    if not object or bounds.fields(object, {"schema_revision", "environments", "file"}) then return nil, "invalid credential format fields" end
    if object.schema_revision ~= M.REVISION then return nil, "unsupported credential format revision" end
    local environments: {string} = {}
    if object.environments ~= nil then
        local rows = bounds.array(object.environments, 8)
        if not rows then return nil, "credential environments must be a list of at most eight variables" end
        for _, raw in ipairs(rows) do
            local name = bounds.text(raw, 128)
            if not name or not name:match("^[A-Z_][A-Z0-9_]*$") then return nil, "invalid credential environment variable" end
            environments[#environments + 1] = name
        end
    end
    local file: File? = nil
    if object.file ~= nil then
        local entry = bounds.object(object.file)
        if not entry or bounds.fields(entry, {"path", "content_format", "initialize"}) then return nil, "invalid credential file format fields" end
        local path = M.path(entry.path)
        local content_format = bounds.member(entry.content_format, {"json", "opaque"})
        if not path or not content_format then return nil, "invalid credential file path or content format" end
        local initializers: {Initializer} = {}
        local items = entry.initialize
        if items ~= nil then
            local rows, rows_error = bounds.array(items, 4)
            if not rows then
                if type(items) ~= "table" then return nil, "credential initialization must contain at most four files" end
                return nil, "credential initialization must be a dense array: " .. tostring(rows_error)
            end
            local seen: {[string]: boolean} = {[path] = true}
            local bytes = 0
            for _, value in ipairs(rows) do
                local item = bounds.object(value)
                if not item or bounds.fields(item, {"path", "content", "source_path", "on_missing_login"}) then return nil, "invalid credential initialization fields" end
                local target, content = M.path(item.path), bounds.text(item.content, M.MAX_INITIALIZATION_BYTES)
                if not target then return nil, "invalid or duplicate credential initialization file" end
                if content == nil then return nil, "invalid or duplicate credential initialization file" end
                if seen[target] then return nil, "invalid or duplicate credential initialization file" end
                if item.on_missing_login ~= nil and type(item.on_missing_login) ~= "boolean" then return nil, "invalid credential initialization condition" end
                local source_path: string? = nil
                if item.source_path ~= nil then
                    source_path = M.path(item.source_path)
                    if not source_path then return nil, "invalid credential initialization source path" end
                end
                for existing in pairs(seen) do
                    if target:sub(1, #existing + 1) == existing .. "/" or existing:sub(1, #target + 1) == target .. "/" then
                        return nil, "credential files cannot also be parent directories"
                    end
                end
                bytes = bytes + #content
                if bytes > M.MAX_INITIALIZATION_BYTES then return nil, "credential initialization exceeds byte limit" end
                seen[target] = true
                local initializer: Initializer = {path = target, content = content, source_path = source_path}
                if item.on_missing_login == true then initializer.on_missing_login = true end
                initializers[#initializers + 1] = initializer
            end
        end
        file = {path = path, content_format = content_format, initialize = initializers}
    end
    if #environments == 0 and not file then return nil, "credential format has no destination" end
    return {schema_revision = M.REVISION, environments = environments, file = file}, nil
end
return M
