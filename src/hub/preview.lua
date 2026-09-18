-- MIT. Read an uninstalled artifact's state and resource files. Native Hub
-- owns artifact verification and the read-only filesystem; Bee exposes reads.
local hub = require("hub")
local base64 = require("base64")
local bounds = require("bounds")
local inspect = require("inspect")
local M = {}
type Request = {component: string, version: string, resource: string?, path: string, offset: integer, limit: integer, expected_digest: string?}
type File = {name: string, type: string}
type Result = {component: string, version: string, digest: string, metadata: unknown?, entries: {unknown}?, resources: {unknown}?,
    files: {File}?, next_offset: integer?, content_base64: string?, offset: integer?, size: number?, eof: boolean?}

function M.decode(operation: string, raw: unknown): (Request?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "package read must be an object" end
    local allowed = {"component", "version", "expected_digest"}
    if operation == "files" or operation == "read_file" then
        for _, field in ipairs({"resource", "path", "offset", "limit"}) do allowed[#allowed + 1] = field end
    elseif operation ~= "state" then return nil, "unknown package read" end
    local extra = bounds.fields(value, allowed)
    if extra then return nil, extra end
    local selected, invalid = inspect.decode({component = value.component, version = value.version})
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
            if path:sub(1, 1) == "/" or path:find("\\", 1, true) or path:find("//", 1, true) then return nil, "package path must be relative" end
            for part in path:gmatch("[^/]+") do
                if part == "." or part == ".." then return nil, "package path must be relative" end
            end
        end
    end
    local offset: integer = 0
    if value.offset ~= nil then
        local supplied = bounds.count(value.offset)
        if supplied == nil then return nil, "invalid read offset" end
        offset = supplied
    end
    local limit: integer = operation == "files" and 100 or 65536
    if value.limit ~= nil then
        local supplied = bounds.integer(value.limit)
        if not supplied or supplied < 1 or supplied > (operation == "files" and 1000 or 1048576) then return nil, "invalid read limit" end
        limit = supplied
    end
    return {component = selected.component, version = selected.version, resource = resource, path = path,
        offset = offset, limit = limit, expected_digest = expected}, nil
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
    local digest = package.digest:gsub("^sha256:", "")
    if request.expected_digest and request.expected_digest ~= digest then return finish(nil, "artifact changed; reopen its state") end
    local result: Result = {component = request.component, version = package.version, digest = digest}
    if operation == "state" then
        local entries, entries_error = package:entries({include_data = true})
        if not entries then return finish(nil, tostring(entries_error)) end
        local metadata, metadata_error = package:metadata()
        if not metadata then return finish(nil, tostring(metadata_error)) end
        local resources, resources_error = package:resources()
        if not resources then return finish(nil, tostring(resources_error)) end
        result.entries, result.metadata, result.resources = entries, metadata, resources
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
                if #files >= request.limit then result.next_offset = request.offset + #files; break end
                local name, kind = bounds.line(row.name, 1024), bounds.member(row.type, {"file", "directory"})
                if not name or not kind then return finish(nil, "invalid package directory entry") end
                files[#files + 1] = {name = name, type = kind}
            end
        end
        result.files = files
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
        result.content_base64, result.offset, result.size, result.eof = "", request.offset, size, true
        return finish(result, nil)
    end
    local position, seek_error = file:seek("set", request.offset)
    if position == nil then file:close(); return finish(nil, tostring(seek_error)) end
    local content, read_error = file:read(math.min(request.limit, size - request.offset))
    local closed, close_error = file:close()
    if type(content) ~= "string" then return finish(nil, tostring(read_error)) end
    if not closed then return finish(nil, tostring(close_error)) end
    result.content_base64 = base64.encode(content)
    result.offset, result.size, result.eof = request.offset, size, request.offset + #content >= size
    if not result.eof then result.next_offset = request.offset + #content end
    return finish(result, nil)
end
return M
