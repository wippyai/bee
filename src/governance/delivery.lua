-- MIT. One immutable application version carried as opaque bee.sync content.
-- Publication is source-owned and destination-independent. Receiving these
-- bytes grants no review, selection, approval, installation or overlay authority.
local json = require("json")
local hash = require("hash")
local bounds = require("bounds")
local canonical = require("canonical")
local artifact = require("artifact")
local version = require("version")

local M = {}
M.SCHEMA = "bee.governance-application-version@2"
M.KEY_SCHEMA = "bee.governance-application-version-key@2"
M.SLOT_SCHEMA = "bee.governance-application-version-slot@1"
M.FEED = "governance.application_versions"
M.CONTENT_KIND = M.SCHEMA
M.MAX_BYTES = 393216

type Blob = {bytes: string, digest: string}
type Envelope = {schema_revision: string, source_node: string,
    source_workspace: string, component: string, version: string, artifact: Blob}
type Delivery = {value: Envelope, bytes: string, digest: string,
    manifest: {[string]: unknown}, key: string, slot: string}

local function sha(value: unknown): string?
    if type(value) ~= "string" or #value ~= 64 or not value:match("^[0-9a-f]+$") then return nil end
    return value
end

local function blob(raw: unknown): (Blob?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "artifact must be an object" end
    local extra = bounds.fields(value, {"bytes", "digest"})
    if extra then return nil, "artifact: " .. extra end
    if type(value.bytes) ~= "string" or #value.bytes == 0 or #value.bytes > artifact.MAX_BYTES then
        return nil, "artifact bytes exceed bound"
    end
    local digest = sha(value.digest)
    if not digest then return nil, "artifact digest is malformed" end
    local bytes: string = value.bytes :: string
    local measured, measure_error = hash.sha256(bytes)
    if not measured or measure_error or measured ~= digest then return nil, "artifact digest does not match bytes" end
    local _, decode_error = artifact.decode(bytes, digest)
    if decode_error then return nil, "artifact: " .. tostring(decode_error) end
    return {bytes = bytes, digest = digest}, nil
end

local function decode_envelope(raw: unknown): (Envelope?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "application version must be an object" end
    local extra = bounds.fields(value, {"schema_revision", "source_node", "source_workspace",
        "component", "version", "artifact"})
    if extra then return nil, "application version: " .. extra end
    local source_node = bounds.id(value.source_node)
    local source_workspace = bounds.id(value.source_workspace)
    local component = bounds.text(value.component, 160)
    local selected_version = bounds.id(value.version)
    local artifact_blob, artifact_error = blob(value.artifact)
    if value.schema_revision ~= M.SCHEMA or not source_node or not source_workspace
        or not component or component == "" or not selected_version or not artifact_blob then
        return nil, artifact_error or "application version identity is malformed"
    end
    return {schema_revision = M.SCHEMA, source_node = source_node,
        source_workspace = source_workspace, component = component,
        version = selected_version, artifact = artifact_blob}, nil
end

local function key(value: Envelope): (string?, string?)
    local material, encode_error = canonical.encode({schema_revision = M.KEY_SCHEMA,
        source_node = value.source_node, component = value.component, version = value.version,
        artifact_digest = value.artifact.digest})
    if not material then return nil, encode_error or "cannot encode application version key" end
    local measured, measure_error = hash.sha256(material)
    if not measured then return nil, tostring(measure_error) end
    return measured, nil
end

local function slot(value: Envelope): (string?, string?)
    local material, encode_error = canonical.encode({schema_revision = M.SLOT_SCHEMA,
        source_node = value.source_node, component = value.component, version = value.version})
    if not material then return nil, encode_error or "cannot encode application version slot" end
    local measured, measure_error = hash.sha256(material)
    if not measured then return nil, tostring(measure_error) end
    return measured, nil
end

local function finish(value: Envelope, bytes: string, digest: string): (Delivery?, string?)
    local version_key, key_error = key(value)
    if not version_key then return nil, key_error end
    local version_slot, slot_error = slot(value)
    if not version_slot then return nil, slot_error end
    local manifest: {[string]: unknown} = {schema_revision = M.SCHEMA,
        source_workspace = value.source_workspace, component = value.component,
        artifact_digest = value.artifact.digest}
    return {value = value, bytes = bytes, digest = digest, manifest = manifest,
        key = version_key, slot = version_slot}, nil
end

function M.create(raw: unknown): (Delivery?, string?)
    local value, value_error = decode_envelope(raw)
    if not value then return nil, value_error end
    local bytes, encode_error = canonical.encode(value, M.MAX_BYTES)
    if not bytes or #bytes > M.MAX_BYTES then return nil, encode_error or "application version exceeds bound" end
    local digest, digest_error = hash.sha256(bytes)
    if not digest then return nil, tostring(digest_error) end
    return finish(value, bytes, digest)
end

function M.decode(bytes_raw: unknown, digest_raw: unknown): (Delivery?, string?)
    if type(bytes_raw) ~= "string" or #bytes_raw == 0 or #bytes_raw > M.MAX_BYTES then
        return nil, "application version bytes exceed bound"
    end
    local digest = sha(digest_raw)
    if not digest then return nil, "application version digest is malformed" end
    local bytes: string = bytes_raw :: string
    local measured, measure_error = hash.sha256(bytes)
    if not measured or measure_error or measured ~= digest then return nil, "application version digest does not match bytes" end
    local decoded, decode_error = json.decode(bytes)
    if decode_error then return nil, "application version bytes are not JSON" end
    local value, value_error = decode_envelope(decoded)
    if not value then return nil, value_error end
    local canonical_bytes, encode_error = canonical.encode(value, M.MAX_BYTES)
    if not canonical_bytes or canonical_bytes ~= bytes then return nil, encode_error or "application version bytes are not canonical" end
    return finish(value, bytes, digest)
end

function M.descriptor(delivery: Delivery): (version.Descriptor?, string?)
    return version.create(delivery.value.source_node, M.FEED, delivery.key,
        delivery.value.component, delivery.value.version, delivery.digest,
        M.CONTENT_KIND, #delivery.bytes, delivery.manifest)
end

function M.verify_descriptor(raw: unknown, delivery: Delivery): (version.Descriptor?, string?)
    local descriptor, descriptor_error = version.decode(raw)
    if not descriptor then return nil, descriptor_error end
    local expected_manifest = canonical.encode(delivery.manifest)
    local actual_manifest = canonical.encode(descriptor.manifest)
    if descriptor.owner_id ~= delivery.value.source_node or descriptor.feed ~= M.FEED
        or descriptor.key ~= delivery.key or descriptor.object_id ~= delivery.value.component
        or descriptor.version_id ~= delivery.value.version or descriptor.content_kind ~= M.CONTENT_KIND
        or descriptor.content_digest ~= delivery.digest or descriptor.total_bytes ~= #delivery.bytes
        or not expected_manifest or expected_manifest ~= actual_manifest then
        return nil, "sync descriptor does not identify this application version"
    end
    return descriptor, nil
end

return M
