-- MIT. Read an uninstalled artifact's state and resource files. Native Hub
-- owns artifact verification and the read-only filesystem; Bee exposes reads.
local hub = require("hub")
local base64 = require("base64")
local bounds = require("bounds")
local inspection = require("inspection")
local requirements = require("requirements")
local M = {}
type Request = {component: string, version: string, resource: string?, path: string, offset: integer, limit: integer, expected_digest: string?,
    entry_offset: integer, entry_limit: integer, include_data: boolean}
type File = {name: string, type: string}
type Metadata = {[string]: unknown}
type Entry = {id: string, kind: string, meta: Metadata, data: unknown}
type Resource = {id: string, type: string, hash: string, size: integer, file_count: integer, meta: Metadata}
type StateResult = {operation: "state", component: string, version: string, digest: string,
    metadata: Metadata, entries: {inspection.Entry}, resources: {Resource}, next_offset: integer?, eof: boolean}
type FilesResult = {operation: "files", component: string, version: string, digest: string,
    files: {File}, next_offset: integer?}
type ContentResult = {operation: "read_file", component: string, version: string, digest: string,
    content_base64: string, offset: integer, size: integer, eof: boolean, next_offset: integer?}
type Result = StateResult | FilesResult | ContentResult
M.MAX_RESOURCES = 512

local function package_metadata(raw: unknown): (Metadata?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "invalid package metadata" end
    return value, nil
end

local function package_entries(raw: unknown): ({Entry}?, string?)
    local rows, rows_error = bounds.dense_list(raw, requirements.MAX_PACKAGE_ENTRIES, "package entries")
    if not rows then return nil, rows_error end
    local entries: {Entry} = {}
    for index, raw_entry in ipairs(rows) do
        local item = bounds.object(raw_entry)
        local id = item and bounds.id(item.id) or nil
        local kind = item and bounds.id(item.kind) or nil
        local meta = item and bounds.object(item.meta) or nil
        if not item or bounds.fields(item, {"id", "kind", "meta", "data"}) or not id or not kind or not meta then
            return nil, "package entry " .. tostring(index) .. " is malformed"
        end
        entries[index] = {id = id, kind = kind, meta = meta, data = item.data}
    end
    return entries, nil
end

local function package_resources(raw: unknown): ({Resource}?, string?)
    local rows, rows_error = bounds.dense_list(raw, M.MAX_RESOURCES, "package resources")
    if not rows then return nil, rows_error end
    local resources: {Resource} = {}
    for index, raw_resource in ipairs(rows) do
        local item = bounds.object(raw_resource)
        local id = item and bounds.id(item.id) or nil
        local kind = item and bounds.line(item.type, 80) or nil
        local hash = item and bounds.text(item.hash, 128) or nil
        local size = item and bounds.count(item.size) or nil
        local file_count = item and bounds.count(item.file_count) or nil
        local meta = item and bounds.object(item.meta) or nil
        if not item or bounds.fields(item, {"id", "type", "hash", "size", "file_count", "meta"})
            or not id or not kind or kind == "" or not hash or not size or not file_count or not meta then
            return nil, "package resource " .. tostring(index) .. " is malformed"
        end
        resources[index] = {id = id, type = kind, hash = hash, size = size, file_count = file_count, meta = meta}
    end
    return resources, nil
end

function M.decode(operation: string, raw: unknown): (Request?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "package read must be an object" end
    local allowed = {"component", "version", "expected_digest"}
    if operation == "files" or operation == "read_file" then
        for _, field in ipairs({"resource", "path", "offset", "limit"}) do allowed[#allowed + 1] = field end
    elseif operation == "state" then
        for _, field in ipairs({"entry_offset", "entry_limit", "include_data"}) do allowed[#allowed + 1] = field end
    else return nil, "unknown package read" end
    local extra = bounds.fields(value, allowed)
    if extra then return nil, extra end
    local selected, invalid = inspection.decode({component = value.component, version = value.version})
    if not selected then return nil, invalid end
    local expected: string? = nil
    if value.expected_digest ~= nil then
        local digest = bounds.line(value.expected_digest, 64)
        if not digest or #digest ~= 64 or not digest:match("^[0-9a-f]+$") then return nil, "invalid artifact digest" end
        expected = digest
    end
    local resource: string? = nil
    local path = "."
    if operation ~= "state" then
        resource = bounds.id(value.resource)
        if not resource then return nil, "select a package filesystem resource" end
        if value.path ~= nil then
            local supplied = bounds.line(value.path, 1024)
            if not supplied then return nil, "invalid package path" end
            path = supplied
        end
        if path ~= "." then
            local relative = bounds.subpath(path, 1024)
            if not relative then return nil, "package path must be relative" end
            path = relative
        end
    end
    local entry_offset: integer = 0
    if value.entry_offset ~= nil then
        if operation ~= "state" then return nil, "entry paging is only valid on state" end
        local supplied = bounds.count(value.entry_offset)
        if supplied == nil then return nil, "entry_offset must be a nonnegative integer" end
        entry_offset = supplied
    end
    local entry_limit: integer = inspection.MAX_ENTRIES_PER_PAGE
    if value.entry_limit ~= nil then
        if operation ~= "state" then return nil, "entry paging is only valid on state" end
        local supplied = bounds.integer(value.entry_limit)
        if not supplied or supplied < 1 or supplied > inspection.MAX_ENTRIES_PER_PAGE then
            return nil, "entry_limit must be between 1 and " .. tostring(inspection.MAX_ENTRIES_PER_PAGE)
        end
        entry_limit = supplied
    end
    local include_data = false
    if value.include_data ~= nil then
        if operation ~= "state" then return nil, "entry paging is only valid on state" end
        if type(value.include_data) ~= "boolean" then return nil, "include_data must be a boolean" end
        include_data = value.include_data
    end
    local offset: integer = 0
    if value.offset ~= nil then
        local supplied = bounds.count(value.offset)
        if supplied == nil then return nil, "invalid read offset" end
        offset = supplied
    end
    local limit: integer = operation == "files" and 100 or 16384
    if value.limit ~= nil then
        local supplied = bounds.integer(value.limit)
        if not supplied or supplied < 1 or supplied > (operation == "files" and 1000 or 16384) then return nil, "invalid read limit" end
        limit = supplied
    end
    return {component = selected.component, version = selected.version, resource = resource, path = path,
        offset = offset, limit = limit, expected_digest = expected,
        entry_offset = entry_offset, entry_limit = entry_limit, include_data = include_data}, nil
end

function M.read(operation: string, raw: unknown): (Result?, string?)
    local request, request_error = M.decode(operation, raw)
    if not request then return nil, request_error end
    local package, open_error = hub.versions.open(request.component, request.version, {timeout = 30})
    if not package then return nil, tostring(open_error) end
    local function finish(result: Result?, problem: string?): (Result?, string?)
        local closed, close_error = package:close()
        if not closed then return nil, problem or tostring(close_error) end
        return result, problem
    end
    local version = bounds.line(package.version, 128)
    local raw_digest = bounds.line(package.digest, 71)
    local digest = raw_digest and raw_digest:gsub("^sha256:", "") or nil
    if not version then return finish(nil, "opened package identity is malformed") end
    if version ~= request.version then return finish(nil, "opened package identity is malformed") end
    if not digest then return finish(nil, "opened package identity is malformed") end
    if #digest ~= 64 or not digest:match("^[0-9a-f]+$") then return finish(nil, "opened package identity is malformed") end
    if request.expected_digest and request.expected_digest ~= digest then return finish(nil, "artifact changed; reopen its state") end
    if operation == "state" then
        local entries, entries_error = package:entries({include_data = true})
        if not entries then return finish(nil, tostring(entries_error)) end
        local metadata, metadata_error = package:metadata()
        if not metadata then return finish(nil, tostring(metadata_error)) end
        local resources, resources_error = package:resources()
        if not resources then return finish(nil, tostring(resources_error)) end
        local decoded_metadata, metadata_decode_error = package_metadata(metadata)
        local decoded_entries, entries_decode_error = package_entries(entries)
        local decoded_resources, resources_decode_error = package_resources(resources)
        if not decoded_metadata or not decoded_entries or not decoded_resources then
            return finish(nil, metadata_decode_error or entries_decode_error or resources_decode_error or "package state is malformed")
        end
        local summarized: {inspection.Entry} = {}
        for _, entry in ipairs(decoded_entries) do
            summarized[#summarized + 1] = {id = entry.id, kind = entry.kind, meta = entry.meta, data = entry.data}
        end
        local page = inspection.page(summarized, request.entry_offset, request.entry_limit, request.include_data)
        local result: StateResult = {operation = "state", component = request.component, version = version,
            digest = digest, entries = page.entries, metadata = decoded_metadata, resources = decoded_resources,
            next_offset = page.next_offset, eof = page.eof}
        return finish(result, nil)
    end
    local resource = request.resource
    if not resource then return finish(nil, "package resource is required") end
    -- This is the native FS returned by hub.Package:fs, not fs.get or a host
    -- directory. Its lifetime belongs to the package handle closed below.
    local filesystem, fs_error = package:fs(resource)
    if not filesystem then return finish(nil, tostring(fs_error)) end
    if operation == "files" then
        local iterator, iterator_state = filesystem:readdir(request.path)
        if not iterator then return finish(nil, tostring(iterator_state)) end
        local files: {File} = {}
        local index = 0
        for row in iterator, iterator_state do
            index = index + 1
            if index > request.offset then
                if #files >= request.limit then break end
                local name, kind = bounds.line(row.name, 1024), bounds.member(row.type, {"file", "directory"})
                if not name or not kind then return finish(nil, "invalid package directory entry") end
                files[#files + 1] = {name = name, type = kind}
            end
        end
        local next_offset = index > request.offset + #files and request.offset + #files or nil
        local result: FilesResult = {operation = "files", component = request.component, version = version,
            digest = digest, files = files, next_offset = next_offset}
        return finish(result, nil)
    end
    local file, file_error = filesystem:open(request.path, "r")
    if not file then return finish(nil, tostring(file_error)) end
    local info, info_error = file:stat()
    if not info then file:close(); return finish(nil, tostring(info_error)) end
    local size = bounds.count(info.size)
    if size == nil then file:close(); return finish(nil, "invalid package file size") end
    if request.offset >= size then
        file:close()
        local result: ContentResult = {operation = "read_file", component = request.component, version = version,
            digest = digest, content_base64 = "", offset = request.offset, size = size, eof = true, next_offset = nil}
        return finish(result, nil)
    end
    local position, seek_error = file:seek("set", request.offset)
    if position == nil then file:close(); return finish(nil, tostring(seek_error)) end
    local content, read_error = file:read(math.min(request.limit, size - request.offset))
    local closed, close_error = file:close()
    if type(content) ~= "string" then return finish(nil, tostring(read_error)) end
    if not closed then return finish(nil, tostring(close_error)) end
    local eof = request.offset + #content >= size
    local result: ContentResult = {operation = "read_file", component = request.component, version = version,
        digest = digest, content_base64 = base64.encode(content), offset = request.offset, size = size,
        eof = eof, next_offset = not eof and request.offset + #content or nil}
    return finish(result, nil)
end
return M
