-- MIT. Source-owned immutable application publication. The artifact is made
-- durable before its descriptor enters the ordered Sync feed, so discovery
-- never points at missing bytes. Publication names no destination and grants
-- no destination review, selection, approval or activation authority.
local base64 = require("base64")
local bounds = require("bounds")
local delivery = require("delivery")
local replicas = require("replicas")
local sync = require("sync")
local transaction = require("transaction")

local M = {}
type Result = transaction.Result
type Object = {[string]: unknown}

local function failure(code: string, message: string): Result
    return transaction.failure(code, message)
end

local function put(store: replicas.Store, item: delivery.Delivery, descriptor: unknown): Result
    local begun = replicas.begin(store, descriptor, 0)
    if not begun.ok then return begun end
    local value = bounds.object(begun.value)
    if value and value.state == "available" then return begun end
    local decoded = descriptor :: {owner_id: string, feed: string, key: string, digest: string}
    local offset = value and bounds.count(value.received_bytes, #item.bytes) or 0
    if offset == nil then return failure("INTERNAL", "published replica progress is malformed") end
    while offset < #item.bytes do
        local ending = math.min(#item.bytes, offset + (replicas.MAX_CHUNK_BYTES :: integer))
        local encoded, encode_error = base64.encode(item.bytes:sub(offset + 1, ending))
        if not encoded then return failure("INTERNAL", tostring(encode_error or "encode published replica chunk")) end
        local written = replicas.put(store, {source_owner = decoded.owner_id, feed = decoded.feed,
            version_key = decoded.key, descriptor_digest = decoded.digest}, offset, encoded)
        if not written.ok then return written end
        offset = ending
    end
    return replicas.finish(store, {source_owner = decoded.owner_id, feed = decoded.feed,
        version_key = decoded.key, descriptor_digest = decoded.digest})
end

local function prepare(resource: string, source_node: unknown, raw: unknown): (delivery.Delivery?, unknown?, Result?)
    local node = bounds.id(source_node)
    local value = bounds.object(raw)
    if not node or not value then return nil, nil, failure("INVALID", "application publication is invalid") end
    local extra = bounds.fields(value, {"source_workspace", "component", "version", "artifact"})
    if extra then return nil, nil, failure("INVALID", "application publication: " .. extra) end
    local item, create_error = delivery.create({schema_revision = delivery.SCHEMA,
        source_node = node, source_workspace = value.source_workspace, component = value.component,
        version = value.version, artifact = value.artifact})
    if not item then return nil, nil, failure("INVALID", create_error or "create application version") end
    local descriptor, descriptor_error = delivery.descriptor(item)
    if not descriptor then return nil, nil, failure("INTERNAL", descriptor_error or "create application descriptor") end
    local replica_store, replica_error = replicas.open(resource)
    if not replica_store then return nil, nil, failure("UNAVAILABLE", replica_error or "open published replica store") end
    local stored = put(replica_store, item, descriptor)
    replicas.close(replica_store)
    if not stored.ok then return nil, nil, stored end
    return item, descriptor, nil
end

-- Make an authored immutable version locally available for the existing
-- stage/review/select/approve/apply workflow. No Sync feed entry is appended,
-- so preparing an edit cannot distribute it.
function M.prepare(resource: string, source_node: unknown, raw: unknown): Result
    local item, descriptor, prepare_error = prepare(resource, source_node, raw)
    if not item or not descriptor then return prepare_error :: Result end
    return transaction.success({descriptor = descriptor, version = item.value.version,
        component = item.value.component}, false)
end

function M.publish(resource: string, source_node: unknown, raw: unknown): Result
    local node = bounds.id(source_node)
    local item, descriptor, prepare_error = prepare(resource, source_node, raw)
    if not node or not item or not descriptor then return prepare_error :: Result end
    local feed_store, feed_error = sync.open({resource = resource, owner = node})
    if not feed_store then return failure("UNAVAILABLE", feed_error or "open application publication feed") end
    local published = sync.append(feed_store, {feed = delivery.FEED, event_id = descriptor.digest,
        idempotency_key = descriptor.digest, event_type = "application.version.published",
        payload = descriptor, projection_key = item.slot, projection_value = descriptor,
        expected_revision = 0})
    sync.close(feed_store)
    if not published.ok then return published end
    local receipt = bounds.object(published.value) or {}
    return transaction.success({descriptor = descriptor, sequence = receipt.sequence,
        version = item.value.version, component = item.value.component}, published.replayed)
end

return M
