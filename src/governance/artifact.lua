-- MIT. An exact, measured registry closure for a later owner-local apply.
--
-- This module only copies and measures supplied values.  It never reads the
-- registry, resolves a package, grants a capability, publishes an entry, or
-- applies an overlay.  The bytes are the immutable handoff between a resolver
-- and the owner that will perform those separately authorized operations.
local canonical = require("canonical")
local hash = require("hash")
local json = require("json")

local M = {}

M.SCHEMA = "bee.governance-artifact@1"
M.MAX_ENTRIES = 512
M.MAX_ID_BYTES = 160
M.MAX_DEPTH = 16
M.MAX_BYTES = 262144
M.MAX_VALUES = 8192

type Entry = {[string]: unknown}
type Artifact = {schema_revision: string, entries: {Entry}, bytes: string, digest: string}

local function object(value: unknown): Entry?
    if type(value) ~= "table" then return nil end
    for key in pairs(value) do
        if type(key) ~= "string" then return nil end
    end
    return value :: Entry
end

local function fields(value: Entry, allowed: {string}): string?
    local known: {[string]: boolean} = {}
    for _, name in ipairs(allowed) do known[name] = true end
    for name in pairs(value) do
        if not known[name] then return "unknown field " .. name end
    end
    return nil
end

local function digest_hex(value: unknown): string?
    if type(value) ~= "string" or #value ~= 64 or not value:match("^[0-9a-f]+$") then return nil end
    return value
end

local function identifier(value: unknown): string?
    -- Registry IDs have a namespace and local name.  The character set is
    -- deliberately narrower than bounds.id so malformed registry identities
    -- cannot be smuggled through as an opaque string.
    if type(value) ~= "string" or #value == 0 or #value > M.MAX_ID_BYTES then return nil end
    if value:find("%c") or not value:match("^[A-Za-z0-9][A-Za-z0-9_.-]*:[A-Za-z0-9][A-Za-z0-9_.-]*$") then return nil end
    return value
end

local function kind(value: unknown): string?
    if type(value) ~= "string" or #value == 0 or #value > M.MAX_ID_BYTES then return nil end
    if value:find("%c") or not value:match("^[A-Za-z0-9][A-Za-z0-9_.-]*$") then return nil end
    return value
end

-- Make an independent bounded copy before measuring.  canonical.encode also
-- validates these shapes, but doing this first prevents a caller from
-- changing a nested definition after create() returned and catches cycles
-- without relying on a serializer's recursion behavior.
type Meter = {bytes: integer, values: integer}

local function copy(value: unknown, depth: integer, active: {[table]: boolean}, meter: Meter): (unknown?, string?)
    if depth > M.MAX_DEPTH then return nil, "artifact value nests too deeply" end
    meter.values = meter.values + 1
    if meter.values > M.MAX_VALUES then return nil, "artifact contains too many values" end
    local value_type = type(value)
    if value_type == "string" then
        meter.bytes = meter.bytes + #value
        if meter.bytes > M.MAX_BYTES then return nil, "artifact values exceed bound" end
        return value, nil
    end
    if value == nil or value_type == "boolean" or value_type == "number" then
        return value, nil
    end
    if value_type ~= "table" then return nil, "artifact contains an unsupported value" end
    local source = value :: table
    if active[source] then return nil, "artifact contains a cyclic value" end
    active[source] = true
    local total = 0
    local strings: {string} = {}
    for key in pairs(source) do
        total = total + 1
        if type(key) == "string" then
            meter.bytes = meter.bytes + #key
            if meter.bytes > M.MAX_BYTES then
                active[source] = nil
                return nil, "artifact values exceed bound"
            end
            strings[#strings + 1] = key
        elseif type(key) ~= "number" or key ~= math.floor(key) or key < 1 then
            active[source] = nil
            return nil, "artifact table key is not encodable"
        end
    end
    if #strings > 0 and #strings ~= total then
        active[source] = nil
        return nil, "artifact table mixes list and object keys"
    end
    local result: {[unknown]: unknown} = {}
    if #strings == 0 and total > 0 then
        for index = 1, total do
            if source[index] == nil then
                active[source] = nil
                return nil, "artifact list is not dense"
            end
            local item, item_error = copy(source[index], depth + 1, active, meter)
            if item_error then active[source] = nil; return nil, item_error end
            result[index] = item
        end
    else
        for _, key in ipairs(strings) do
            local item, item_error = copy(source[key], depth + 1, active, meter)
            if item_error then active[source] = nil; return nil, item_error end
            result[key] = item
        end
    end
    active[source] = nil
    return result, nil
end

local function entries(value: unknown): ({Entry}?, string?)
    if type(value) ~= "table" then return nil, "artifact entries must be a list" end
    local source = value :: table
    local count = 0
    for key in pairs(source) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 then
            return nil, "artifact entries must be a dense list"
        end
        count = count + 1
    end
    if count == 0 or count > M.MAX_ENTRIES then return nil, "artifact entry count exceeds bound" end
    local copied: {Entry} = {}
    local seen: {[string]: boolean} = {}
    local meter: Meter = {bytes = 0, values = 0}
    for index = 1, count do
        if source[index] == nil then return nil, "artifact entries must be a dense list" end
        local raw, copy_error = copy(source[index], 1, {}, meter)
        if copy_error then return nil, "entries[" .. tostring(index) .. "]: " .. copy_error end
        local item = object(raw)
        if not item then return nil, "entries[" .. tostring(index) .. "] must be an object" end
        local extra = fields(item, {"id", "kind", "meta", "data"})
        if extra then return nil, "entries[" .. tostring(index) .. "]: " .. extra .. "; registry configuration belongs in data" end
        if not object(item.data) then return nil, "entries[" .. tostring(index) .. "] requires a registry data object" end
        if item.meta ~= nil and not object(item.meta) then return nil, "entries[" .. tostring(index) .. "] metadata must be an object" end
        local id = identifier(item.id)
        local entry_kind = kind(item.kind)
        if not id or not entry_kind then return nil, "entries[" .. tostring(index) .. "] has an invalid id or kind" end
        if seen[id] then return nil, "duplicate registry entry " .. id end
        seen[id] = true
        copied[index] = item
    end
    table.sort(copied, function(left: Entry, right: Entry): boolean return tostring(left.id) < tostring(right.id) end)
    return copied, nil
end

local function encode_entries(value: unknown): ({Entry}?, string?, string?)
    local copied, entries_error = entries(value)
    if not copied then return nil, nil, entries_error end
    local encoded, encode_error = canonical.encode({schema_revision = M.SCHEMA, entries = copied}, M.MAX_BYTES)
    if not encoded then return nil, nil, encode_error or "artifact cannot be encoded" end
    if #encoded > M.MAX_BYTES then return nil, nil, "artifact exceeds encoded bound" end
    return copied, encoded, nil
end

function M.encode(value: unknown): (string?, string?)
    local _, encoded, encode_error = encode_entries(value)
    return encoded, encode_error
end

function M.digest(value: unknown): (string?, string?)
    if type(value) ~= "string" or #value == 0 or #value > M.MAX_BYTES then return nil, "artifact bytes exceed bound" end
    local measured, measure_error = hash.sha256(value)
    if not measured then return nil, tostring(measure_error) end
    return measured, nil
end

function M.create(value: unknown): (Artifact?, string?)
    local copied, encoded, encode_error = encode_entries(value)
    if not copied or not encoded then return nil, encode_error end
    local measured, measure_error = M.digest(encoded)
    if not measured then return nil, measure_error end
    return {schema_revision = M.SCHEMA, entries = copied, bytes = encoded, digest = measured}, nil
end

-- Verify an exact byte handoff against the complete definitions supplied by a
-- resolver.  Re-encoding is intentional: a digest alone cannot prove that the
-- receiver retained all fields needed for a later overlay apply.
function M.verify_bytes(value: unknown, bytes_raw: unknown, digest_raw: unknown): (boolean, string?)
    if type(bytes_raw) ~= "string" or #bytes_raw == 0 or #bytes_raw > M.MAX_BYTES then
        return false, "artifact bytes exceed bound"
    end
    local recorded = digest_hex(digest_raw)
    if not recorded then return false, "artifact digest is malformed" end
    local _, expected_bytes, encode_error = encode_entries(value)
    if not expected_bytes then return false, encode_error end
    if expected_bytes ~= bytes_raw then return false, "artifact bytes do not match entries" end
    local measured, measure_error = M.digest(bytes_raw)
    if not measured then return false, measure_error end
    if measured ~= recorded then return false, "artifact digest does not match bytes" end
    return true, nil
end

-- Decode a byte-only handoff.  The JSON decoder is used only as a parser;
-- canonical re-encoding below is what rejects whitespace, reordered/list
-- ambiguity and extra envelope fields.  The returned entries are fresh
-- copies, so the receiver can retain them for a later checked apply.
function M.decode(bytes_raw: unknown, digest_raw: unknown): ({Entry}?, string?)
    if type(bytes_raw) ~= "string" or #bytes_raw == 0 or #bytes_raw > M.MAX_BYTES then
        return nil, "artifact bytes exceed bound"
    end
    local recorded = digest_hex(digest_raw)
    if not recorded then return nil, "artifact digest is malformed" end
    local measured, measure_error = M.digest(bytes_raw)
    if not measured then return nil, measure_error end
    if measured ~= recorded then return nil, "artifact digest does not match bytes" end
    local decoded, decode_error = json.decode(bytes_raw)
    if decode_error or type(decoded) ~= "table" then return nil, "artifact bytes are not a JSON object" end
    local envelope = object(decoded)
    if not envelope then return nil, "artifact envelope has invalid keys" end
    local unexpected = fields(envelope, {"schema_revision", "entries"})
    if unexpected then return nil, unexpected end
    if envelope.schema_revision ~= M.SCHEMA then return nil, "unsupported artifact schema" end
    local copied, canonical_bytes, encode_error = encode_entries(envelope.entries)
    if not copied or not canonical_bytes then return nil, encode_error end
    if canonical_bytes ~= bytes_raw then return nil, "artifact bytes are not canonical" end
    return copied, nil
end

-- Verify a created/transferred Artifact record.  The artifact-shaped call
-- keeps the normal receiver path explicit; byte-only receivers use decode.
function M.verify(value: unknown): (boolean, string?)
    local artifact = object(value)
    if not artifact then return false, "artifact must be an object" end
    local unexpected = fields(artifact, {"schema_revision", "entries", "bytes", "digest"})
    if unexpected then return false, unexpected end
    if artifact.schema_revision ~= M.SCHEMA then return false, "unsupported artifact schema" end
    return M.verify_bytes(artifact.entries, artifact.bytes, artifact.digest)
end

return M
