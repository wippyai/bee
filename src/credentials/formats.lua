-- SPDX-License-Identifier: MIT
-- Login layout is host-selected data; this decoder grants no resource access.
local bounds = require("bounds")
local M = {}
type Initializer = {path: string, content: string}
type File = {path: string, content_format: string, initialize: {Initializer}}
type Format = {schema_revision: string, environment_destination: string?, file: File?}

function M.path(value: unknown): string?
    local path = bounds.text(value, 512)
    if not path or path == "" or path:sub(1, 1) == "/" or path:find("[%c\\]") then return nil end
    for segment in (path .. "/"):gmatch("(.-)/") do
        if segment == "" or segment == "." or segment == ".." then return nil end
    end
    return path
end
function M.decode(value: unknown): (Format?, string?)
    local object = bounds.object(value)
    if not object or bounds.fields(object, {"schema_revision", "environment_destination", "file"}) then return nil, "invalid credential format fields" end
    if object.schema_revision ~= "bee.credential-format@1" then return nil, "unsupported credential format revision" end
    local environment: string? = nil
    if object.environment_destination ~= nil then
        environment = bounds.text(object.environment_destination, 128)
        if not environment or not environment:match("^[A-Z_][A-Z0-9_]*$") then return nil, "invalid credential environment destination" end
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
            if type(items) ~= "table" or #items > 4 then return nil, "credential initialization must contain at most four files" end
            local seen: {[string]: boolean} = {[path] = true}
            local bytes = 0
            local count = 0
            for key in pairs(items :: {[unknown]: unknown}) do
                if type(key) ~= "number" or key < 1 or key > #items or key % 1 ~= 0 then return nil, "credential initialization must be an array" end
                count = count + 1
            end
            if count ~= #items then return nil, "credential initialization must be a dense array" end
            for _, value in ipairs(items :: {unknown}) do
                local item = bounds.object(value)
                if not item or bounds.fields(item, {"path", "content"}) then return nil, "invalid credential initialization fields" end
                local target, content = M.path(item.path), bounds.text(item.content, 4096)
                if not target or content == nil or seen[target] then return nil, "invalid or duplicate credential initialization file" end
                for existing in pairs(seen) do
                    if target:sub(1, #existing + 1) == existing .. "/" or existing:sub(1, #target + 1) == target .. "/" then
                        return nil, "credential files cannot also be parent directories"
                    end
                end
                bytes = bytes + #content
                if bytes > 8192 then return nil, "credential initialization exceeds byte limit" end
                seen[target] = true
                initializers[#initializers + 1] = {path = target, content = content}
            end
        end
        file = {path = path, content_format = content_format, initialize = initializers}
    end
    if not environment and not file then return nil, "credential format has no destination" end
    return {schema_revision = "bee.credential-format@1", environment_destination = environment, file = file}, nil
end
return M
