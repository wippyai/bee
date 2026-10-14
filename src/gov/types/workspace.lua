-- MIT. Trusted in-memory authoring input can be frozen for later review.
-- This helper has no filesystem, registry, process, or authorization access.
local canonical = require("canonical")
local hash = require("hash")
local M = {}

type File = {path: string, content: string}
type Input = {workspace_id: string, revision: integer, files: {File}}
type SnapshotFile = {path: string, content: string, bytes: integer, digest: string}
type MeasuredFile = {path: string, bytes: integer, digest: string}
type Snapshot = {schema_revision: string, workspace_id: string, revision: integer,
    files: {SnapshotFile}, file_count: integer, total_bytes: integer, files_digest: string, digest: string}

local MAX_FILES = 256
local MAX_PATH_BYTES = 240
local MAX_FILE_BYTES = 4 * 1024 * 1024
local MAX_TOTAL_BYTES = 16 * 1024 * 1024
-- Exported only so adapters can report the admission envelope. Freeze uses the
-- private constants, so a consumer cannot widen its own enforcement boundary.
M.MAX_FILES = MAX_FILES
M.MAX_PATH_BYTES = MAX_PATH_BYTES
M.MAX_FILE_BYTES = MAX_FILE_BYTES
M.MAX_TOTAL_BYTES = MAX_TOTAL_BYTES

local function identifier(value: string): boolean
    return #value > 0 and #value <= 160 and not value:find("%c")
end

-- A path is canonical because it has no representation-changing segment:
-- only nonempty relative components, separated by forward slashes, remain.
local function relative_path(value: string): boolean
    if #value == 0 or #value > MAX_PATH_BYTES or value:sub(1, 1) == "/"
        or value:find("\\", 1, true) or value:find(":", 1, true) or value:find("%c") then return false end
    for part in value:gmatch("[^/]+") do
        if part == "." or part == ".." then return false end
    end
    return not value:find("//", 1, true) and value:sub(-1) ~= "/"
end

-- Freeze is deliberately an internal typed boundary. A caller supplies content
-- already read through an authorized adapter; this never reads host paths.
function M.freeze(input: Input): (Snapshot?, string?)
    if not identifier(input.workspace_id) or input.revision < 0 or input.revision > 9007199254740991 then
        return nil, "invalid workspace identity or revision"
    end
    if #input.files > MAX_FILES then return nil, "workspace exceeds file count limit" end

    local files: {SnapshotFile} = {}
    local measured_files: {MeasuredFile} = {}
    local paths: {[string]: boolean} = {}
    local total = 0
    for _, file in ipairs(input.files) do
        if not relative_path(file.path) then return nil, "workspace has a noncanonical relative path" end
        if #file.content > MAX_FILE_BYTES then return nil, "workspace file exceeds byte limit" end
        total = total + #file.content
        if total > MAX_TOTAL_BYTES then return nil, "workspace exceeds total byte limit" end
        if paths[file.path] then return nil, "workspace has duplicate file paths" end
        paths[file.path] = true
        local file_digest, digest_error = hash.sha256(file.content)
        if not file_digest then return nil, tostring(digest_error) end
        files[#files + 1] = {path = file.path, content = file.content, bytes = #file.content, digest = file_digest}
        measured_files[#measured_files + 1] = {path = file.path, bytes = #file.content, digest = file_digest}
    end
    table.sort(files, function(left: SnapshotFile, right: SnapshotFile): boolean return left.path < right.path end)
    table.sort(measured_files, function(left: MeasuredFile, right: MeasuredFile): boolean return left.path < right.path end)
    for _, file in ipairs(files) do
        local offset = 1
        while true do
            local separator = file.path:find("/", offset, true)
            if not separator then break end
            if paths[file.path:sub(1, separator - 1)] then
                return nil, "workspace has a file-directory path collision"
            end
            offset = separator + 1
        end
    end
    -- Contents may be valid binary assets larger than canonical JSON's bound.
    -- Each bounded record is canonically encoded, then length-framed before the
    -- aggregate hash, avoiding both JSON's aggregate ceiling and ambiguity.
    local framed: {string} = {}
    for _, file in ipairs(measured_files) do
        local record, record_error = canonical.encode(file)
        if not record then return nil, record_error or "cannot encode file measurement" end
        framed[#framed + 1] = tostring(#record) .. ":" .. record
    end
    local files_digest, files_error = hash.sha256(table.concat(framed))
    if not files_digest then return nil, tostring(files_error) end
    local measured = {schema_revision = "bee.governance-workspace@1", workspace_id = input.workspace_id,
        revision = input.revision, files_digest = files_digest, file_count = #files, total_bytes = total}
    local encoded, encode_error = canonical.encode(measured)
    if not encoded then return nil, encode_error or "cannot encode workspace snapshot" end
    local digest, digest_error = hash.sha256(encoded)
    if not digest then return nil, tostring(digest_error) end
    return {schema_revision = "bee.governance-workspace@1", workspace_id = input.workspace_id, revision = input.revision,
        files = files, file_count = #files, total_bytes = total, files_digest = files_digest, digest = digest}, nil
end

return M
