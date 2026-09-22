-- MIT. Immutable version descriptors carried by a source-owned sync feed.
-- Descriptors announce available content only.  Selecting or activating a
-- version is deliberately outside bee.sync and belongs to the destination's
-- component owner.
local bounds = require("bounds")
local canonical = require("canonical")
local hash = require("hash")
local M = {}

M.SCHEMA = "bee.sync-version@1"
M.MAX_MANIFEST_BYTES = 16384
type Object = {[string]: unknown}
type Descriptor = {schema: string, owner_id: string, feed: string, key: string,
    object_id: string, version_id: string, content_digest: string, manifest_digest: string,
    content_kind: string, total_bytes: integer, manifest: Object, digest: string}

local function object(value: unknown): Object?
    if type(value) ~= "table" then return nil end
    for key in pairs(value) do if type(key) ~= "string" then return nil end end
    return value :: Object
end
local function fields(value: Object, allowed: {string}): string?
    local known: {[string]: boolean} = {}
    for _, name in ipairs(allowed) do known[name] = true end
    for name in pairs(value) do if not known[name] then return "unknown field " .. name end end
    return nil
end
local function digest(value: unknown): (string?, string?)
    local encoded, encode_error = canonical.encode(value)
    if not encoded then return nil, encode_error or "cannot encode version descriptor" end
    local measured, measure_error = hash.sha256(encoded)
    if not measured then return nil, tostring(measure_error) end
    return measured, nil
end
local function sha(value: unknown): string?
    if type(value) ~= "string" or #value ~= 64 or not value:match("^[0-9a-f]+$") then return nil end
    return value
end

-- Decode verifies the descriptor's self-measurement but does not trust it as
-- proof that bytes arrived. A receiver verifies content separately before its
-- local state can become available.
function M.decode(raw: unknown): (Descriptor?, string?)
    local value = object(raw)
    if not value then return nil, "version descriptor must be an object" end
    local unexpected = fields(value, {"schema", "owner_id", "feed", "key", "object_id", "version_id", "content_digest", "manifest_digest", "content_kind", "total_bytes", "manifest", "digest"})
    if unexpected then return nil, unexpected end
    if value.schema ~= M.SCHEMA then return nil, "unsupported version descriptor schema" end
    local owner, feed, key = bounds.id(value.owner_id), bounds.id(value.feed), bounds.id(value.key)
    local object_id, version_id, kind = bounds.id(value.object_id), bounds.id(value.version_id), bounds.id(value.content_kind)
    local content_digest, manifest_digest, recorded = sha(value.content_digest), sha(value.manifest_digest), sha(value.digest)
    local total = bounds.count(value.total_bytes, 16777216)
    local manifest = object(value.manifest)
    if not owner or not feed or not key or not object_id or not version_id or not kind
        or not content_digest or not manifest_digest or not recorded or total == nil or not manifest then
        return nil, "version descriptor has invalid fields"
    end
    local manifest_encoded, manifest_error = canonical.encode(manifest)
    if not manifest_encoded or manifest_error or #manifest_encoded > M.MAX_MANIFEST_BYTES then return nil, "version manifest exceeds bound" end
    local actual_manifest, manifest_hash_error = hash.sha256(manifest_encoded)
    if not actual_manifest or manifest_hash_error or actual_manifest ~= manifest_digest then return nil, "version manifest digest does not match" end
    local material = {schema = M.SCHEMA, owner_id = owner, feed = feed, key = key, object_id = object_id,
        version_id = version_id, content_digest = content_digest, manifest_digest = manifest_digest,
        content_kind = kind, total_bytes = total, manifest = manifest}
    local actual, measure_error = digest(material)
    if not actual or measure_error or actual ~= recorded then return nil, "version descriptor digest does not match" end
    return {schema = M.SCHEMA, owner_id = owner, feed = feed, key = key, object_id = object_id,
        version_id = version_id, content_digest = content_digest, manifest_digest = manifest_digest,
        content_kind = kind, total_bytes = total, manifest = manifest, digest = recorded}, nil
end

function M.create(owner: string, feed: string, key: string, object_id: string, version_id: string,
    content_digest: string, content_kind: string, total_bytes: integer, manifest: Object): (Descriptor?, string?)
    local manifest_encoded, manifest_error = canonical.encode(manifest)
    if not manifest_encoded or manifest_error then return nil, "invalid version manifest" end
    local manifest_digest, manifest_hash_error = hash.sha256(manifest_encoded)
    if not manifest_digest or manifest_hash_error then return nil, "measure version manifest" end
    local material = {schema = M.SCHEMA, owner_id = owner, feed = feed, key = key, object_id = object_id,
        version_id = version_id, content_digest = content_digest, manifest_digest = manifest_digest,
        content_kind = content_kind, total_bytes = total_bytes, manifest = manifest}
    local measured, measure_error = digest(material)
    if not measured then return nil, measure_error end
    material.digest = measured
    return M.decode(material)
end

-- Same identity must always mean the same immutable content.  This is used by
-- replica stores before accepting retries or a later full resnapshot.
function M.same(left: Descriptor, right: Descriptor): boolean
    return left.owner_id == right.owner_id and left.feed == right.feed and left.key == right.key
        and left.digest == right.digest and left.content_digest == right.content_digest
end
return M
