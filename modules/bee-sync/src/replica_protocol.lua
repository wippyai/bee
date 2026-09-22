-- MIT. Strict public request decoder for the destination-owned replica cache.
-- Transport identity is supplied by Hive; source_owner selects the exact local
-- policy resource and is never inferred from registry metadata.
local bounds = require("bounds")
local version = require("version")
local M = {}

M.MAX_CONTENT_BYTES = 16777216
M.MAX_ENCODED_CHUNK_BYTES = 43692
type Object = {[string]: unknown}
type Request = {
    action: string,
    source_owner: string,
    feed: string?,
    version_key: string?,
    descriptor_digest: string?,
    descriptor: version.Descriptor?,
    source_cursor: integer?,
    offset: integer?,
    content_base64: string?,
}

local function object(value: unknown): Object?
    if type(value) ~= "table" then return nil end
    for key in pairs(value) do if type(key) ~= "string" then return nil end end
    return value :: Object
end

local function exact(value: Object, allowed: {string}): string?
    local names: {[string]: boolean} = {}
    for _, name in ipairs(allowed) do names[name] = true end
    for name in pairs(value) do
        if not names[name] then return "unknown replica request field " .. name end
    end
    return nil
end

local function digest(value: unknown): string?
    if type(value) ~= "string" or #value ~= 64 or not value:match("^[0-9a-f]+$") then return nil end
    return value
end

local function selected_key(value: Object, action: string): (Request?, string?)
    local unexpected = exact(value, {"action", "source_owner", "feed", "version_key", "descriptor_digest"})
    if unexpected then return nil, unexpected end
    local owner, feed, key = bounds.id(value.source_owner), bounds.id(value.feed), bounds.id(value.version_key)
    local measured = digest(value.descriptor_digest)
    if not owner or not feed or not key or not measured then return nil, "replica identity is invalid" end
    return {action = action, source_owner = owner, feed = feed, version_key = key,
        descriptor_digest = measured}, nil
end

function M.decode(raw: unknown): (Request?, string?)
    local value = object(raw)
    if not value then return nil, "replica request must be an object" end
    if value.action == "begin" then
        local unexpected = exact(value, {"action", "descriptor", "source_cursor"})
        if unexpected then return nil, unexpected end
        local descriptor, descriptor_error = version.decode(value.descriptor)
        local cursor = bounds.count(value.source_cursor, 9007199254740991)
        if not descriptor or cursor == nil then return nil, descriptor_error or "source_cursor is invalid" end
        return {action = "begin", source_owner = descriptor.owner_id, descriptor = descriptor,
            source_cursor = cursor}, nil
    end
    if value.action == "put" then
        local unexpected = exact(value, {"action", "source_owner", "feed", "version_key", "descriptor_digest", "offset", "content_base64"})
        if unexpected then return nil, unexpected end
        local owner, feed, key = bounds.id(value.source_owner), bounds.id(value.feed), bounds.id(value.version_key)
        local measured = digest(value.descriptor_digest)
        local offset = bounds.count(value.offset, M.MAX_CONTENT_BYTES)
        if not owner or not feed or not key or not measured or offset == nil
            or type(value.content_base64) ~= "string" or #value.content_base64 > M.MAX_ENCODED_CHUNK_BYTES then
            return nil, "replica chunk request is invalid"
        end
        return {action = "put", source_owner = owner, feed = feed, version_key = key,
            descriptor_digest = measured, offset = offset, content_base64 = value.content_base64}, nil
    end
    if value.action == "finish" or value.action == "status" then
        local action: string = value.action :: string
        return selected_key(value, action)
    end
    return nil, "replica action is unsupported"
end

return M
