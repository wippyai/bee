-- MIT. Immutable transfer description for a frozen authoring snapshot.
-- It describes bytes to replicate; it never authorizes installation or overlay
-- activation on a receiving Bee.
local canonical = require("canonical")
local hash = require("hash")
local json = require("json")
local workspace = require("workspace")

local M = {}
M.SCHEMA = "bee.governance-candidate@1"
M.MAX_BYTES = 131072

type File = {path: string, content: string}
type MeasuredFile = {path: string, bytes: integer, digest: string}
type Candidate = {schema_revision: string, source_node: string, destination_node: string,
    source_workspace: string, destination_workspace: string, revision: integer,
    snapshot_digest: string, files_digest: string, file_count: integer, total_bytes: integer,
    files: {MeasuredFile}, digest: string}

local function identity(value: unknown): string?
    if type(value) ~= "string" or #value == 0 or #value > 160 or value:find("%c") then return nil end
    return value
end

local function digest(value: unknown): (string?, string?)
    local encoded, encode_error = canonical.encode(value, M.MAX_BYTES)
    if not encoded then return nil, encode_error or "cannot encode candidate" end
    local measured, measure_error = hash.sha256(encoded)
    if not measured then return nil, tostring(measure_error) end
    return measured, nil
end

local function measured_files(snapshot: workspace.Snapshot): {MeasuredFile}
    local result: {MeasuredFile} = {}
    for index, file in ipairs(snapshot.files) do
        result[index] = {path = file.path, bytes = file.bytes, digest = file.digest}
    end
    return result
end

local function normalize(raw: unknown): (Candidate?, string?)
    if type(raw) ~= "table" then return nil, "candidate must be an object" end
    local value = raw :: {[string]: unknown}
    local allowed: {[string]: boolean} = {schema_revision = true, source_node = true, destination_node = true,
        source_workspace = true, destination_workspace = true, revision = true, snapshot_digest = true,
        files_digest = true, file_count = true, total_bytes = true, files = true, digest = true}
    for name in pairs(value) do if type(name) ~= "string" or not allowed[name] then return nil, "candidate has an unknown field" end end
    if value.schema_revision ~= M.SCHEMA or not identity(value.source_node) or not identity(value.destination_node)
        or not identity(value.source_workspace) or not identity(value.destination_workspace)
        or type(value.revision) ~= "number" or value.revision ~= math.floor(value.revision) or value.revision < 0
        or type(value.snapshot_digest) ~= "string" or not value.snapshot_digest:match("^[0-9a-f]+$") or #value.snapshot_digest ~= 64
        or type(value.files_digest) ~= "string" or not value.files_digest:match("^[0-9a-f]+$") or #value.files_digest ~= 64
        or type(value.file_count) ~= "number" or value.file_count ~= math.floor(value.file_count) or value.file_count < 0 or value.file_count > 256
        or type(value.total_bytes) ~= "number" or value.total_bytes ~= math.floor(value.total_bytes) or value.total_bytes < 0 or value.total_bytes > 16777216
        or type(value.files) ~= "table" or type(value.digest) ~= "string" or not value.digest:match("^[0-9a-f]+$") or #value.digest ~= 64 then
        return nil, "candidate is malformed"
    end
    local files: {MeasuredFile} = {}
    local total = 0
    for key in pairs(value.files :: table) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 then return nil, "candidate files must be a dense list" end
        total = total + 1
    end
    if total ~= value.file_count then return nil, "candidate file count does not match manifest" end
    local previous = ""
    for index = 1, total do
        local raw_file = (value.files :: table)[index]
        if type(raw_file) ~= "table" then return nil, "candidate file is malformed" end
        local file = raw_file :: {[string]: unknown}
        for name in pairs(file) do if name ~= "path" and name ~= "bytes" and name ~= "digest" then return nil, "candidate file has an unknown field" end end
        if type(file.path) ~= "string" or file.path == "" or #file.path > 240 or file.path <= previous
            or type(file.bytes) ~= "number" or file.bytes ~= math.floor(file.bytes) or file.bytes < 0 or file.bytes > 4194304
            or type(file.digest) ~= "string" or #file.digest ~= 64 or not file.digest:match("^[0-9a-f]+$") then
            return nil, "candidate file is malformed"
        end
        previous = file.path
        files[index] = {path = file.path, bytes = math.floor(file.bytes), digest = file.digest}
    end
    local result: Candidate = {schema_revision = M.SCHEMA, source_node = value.source_node :: string,
        destination_node = value.destination_node :: string, source_workspace = value.source_workspace :: string,
        destination_workspace = value.destination_workspace :: string, revision = math.floor(value.revision :: number),
        snapshot_digest = value.snapshot_digest :: string, files_digest = value.files_digest :: string,
        file_count = math.floor(value.file_count :: number), total_bytes = math.floor(value.total_bytes :: number),
        files = files, digest = value.digest :: string}
    local measured, measure_error = digest({schema_revision = result.schema_revision, source_node = result.source_node,
        destination_node = result.destination_node, source_workspace = result.source_workspace,
        destination_workspace = result.destination_workspace, revision = result.revision,
        snapshot_digest = result.snapshot_digest, files_digest = result.files_digest, file_count = result.file_count,
        total_bytes = result.total_bytes, files = result.files})
    if not measured or measured ~= result.digest then return nil, measure_error or "candidate manifest digest does not match" end
    return result, nil
end

function M.encode(raw: unknown): (string?, string?)
    local value, value_error = normalize(raw)
    if not value then return nil, value_error end
    local bytes, encode_error = canonical.encode(value, M.MAX_BYTES)
    if not bytes or #bytes > M.MAX_BYTES then return nil, encode_error or "candidate bytes exceed bound" end
    return bytes, nil
end

function M.decode(bytes_raw: unknown, digest_raw: unknown): (Candidate?, string?)
    if type(bytes_raw) ~= "string" or #bytes_raw == 0 or #bytes_raw > M.MAX_BYTES then return nil, "candidate bytes exceed bound" end
    if type(digest_raw) ~= "string" or #digest_raw ~= 64 or not digest_raw:match("^[0-9a-f]+$") then return nil, "candidate byte digest is malformed" end
    local bytes: string = bytes_raw :: string
    local measured, measure_error = hash.sha256(bytes)
    if not measured or measure_error or measured ~= digest_raw then return nil, "candidate byte digest does not match" end
    local decoded, decode_error = json.decode(bytes)
    if decode_error then return nil, "candidate bytes are not JSON" end
    local value, value_error = normalize(decoded)
    if not value then return nil, value_error end
    local canonical_bytes, encode_error = canonical.encode(value, M.MAX_BYTES)
    if not canonical_bytes or canonical_bytes ~= bytes then return nil, encode_error or "candidate bytes are not canonical" end
    return value, nil
end

-- The destination is part of the immutable identity.  A sender cannot reuse a
-- candidate selected for Bee B as a request to modify Bee C.
function M.create(source_node_raw: unknown, destination_node_raw: unknown,
    destination_workspace_raw: unknown, snapshot: workspace.Snapshot): (Candidate?, string?)
    local source_node, destination_node = identity(source_node_raw), identity(destination_node_raw)
    local destination_workspace = identity(destination_workspace_raw)
    if not source_node or not destination_node or not destination_workspace then
        return nil, "candidate identities are invalid"
    end
    local verified, verify_error = workspace.freeze({workspace_id = snapshot.workspace_id,
        revision = snapshot.revision, files = snapshot.files})
    if not verified or verify_error or verified.digest ~= snapshot.digest
        or verified.files_digest ~= snapshot.files_digest or verified.file_count ~= snapshot.file_count
        or verified.total_bytes ~= snapshot.total_bytes then
        return nil, "source snapshot is not an exact frozen overlay"
    end
    local candidate: Candidate = {schema_revision = M.SCHEMA,
        source_node = source_node, destination_node = destination_node,
        source_workspace = snapshot.workspace_id, destination_workspace = destination_workspace,
        revision = snapshot.revision, snapshot_digest = snapshot.digest,
        files_digest = snapshot.files_digest, file_count = snapshot.file_count,
        total_bytes = snapshot.total_bytes, files = measured_files(snapshot), digest = ""}
    local measured, measure_error = digest({schema_revision = candidate.schema_revision,
        source_node = candidate.source_node, destination_node = candidate.destination_node,
        source_workspace = candidate.source_workspace, destination_workspace = candidate.destination_workspace,
        revision = candidate.revision, snapshot_digest = candidate.snapshot_digest,
        files_digest = candidate.files_digest, file_count = candidate.file_count,
        total_bytes = candidate.total_bytes, files = candidate.files})
    if not measured then return nil, measure_error end
    candidate.digest = measured
    return candidate, nil
end

-- A receiver must measure supplied bytes again.  The manifest has no executable
-- meaning and does not make its contents a registry entry or an approved change.
function M.verify(candidate: Candidate, files: {File}): (boolean, string?)
    local normalized, normalize_error = normalize(candidate)
    if not normalized then return false, normalize_error end
    candidate = normalized
    local rebuilt, rebuild_error = workspace.freeze({workspace_id = candidate.source_workspace,
        revision = candidate.revision, files = files})
    if not rebuilt then return false, rebuild_error or "candidate content is invalid" end
    if rebuilt.digest ~= candidate.snapshot_digest or rebuilt.files_digest ~= candidate.files_digest
        or rebuilt.file_count ~= candidate.file_count or rebuilt.total_bytes ~= candidate.total_bytes then
        return false, "candidate content does not match its frozen snapshot"
    end
    local measured = measured_files(rebuilt)
    if #candidate.files ~= #measured then return false, "candidate file manifest does not match its frozen snapshot" end
    for index, file in ipairs(measured) do
        local recorded = candidate.files[index]
        if type(recorded) ~= "table" or recorded.path ~= file.path or recorded.bytes ~= file.bytes
            or recorded.digest ~= file.digest then
            return false, "candidate file manifest does not match its frozen snapshot"
        end
    end
    local expected, digest_error = M.create(candidate.source_node, candidate.destination_node,
        candidate.destination_workspace, rebuilt)
    if not expected then return false, digest_error end
    if expected.digest ~= candidate.digest then return false, "candidate manifest digest does not match" end
    return true, nil
end

return M
