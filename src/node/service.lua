-- MIT. Node-description owner. Native identity and caller authority never come
-- from the editable metadata. The sync store commits each projection and event.
local system = require("system")
local security = require("security")
local hash = require("hash")
local protocol = require("protocol")
local resources = require("resources")
local sync = require("sync")
local transaction = require("transaction")
local bounds = require("bounds")
local canonical = require("canonical")
local appearance = require("appearance")
local M = {}
M.FEED = "node.description"
M.KEY = "description"
type Result = transaction.Result

local function authority(action: string): (string?, string?, Result?)
    local node, err = system.node.id()
    if err or not node or node == "" then return nil, nil, transaction.failure("UNAVAILABLE", "native node identity is unavailable") end
    local actor = security.actor()
    if not actor or not security.can(action, node) then
        return nil, nil, transaction.failure("DENIED", "caller is not authorized for this node")
    end
    return node, actor:id(), nil
end

local function open(node: string): (sync.Store?, string?)
    local resource, err = resources.database()
    if not resource then return nil, err end
    return sync.open({resource = resource, owner = node})
end

function M.describe(request: unknown): Result
    local invalid = protocol.empty(request)
    if invalid then return transaction.failure("INVALID", invalid) end
    local node, actor, denied = authority("bee.node.read")
    if not node then return denied or transaction.failure("DENIED", "node read refused") end
    local store, err = open(node)
    if not store then return transaction.failure("UNAVAILABLE", err or "node store unavailable") end
    local result = store:projection(M.FEED, M.KEY)
    store:close()
    if not result.ok then return result end
    local revision = 0
    local metadata: protocol.Metadata = {display_name = node, description = "", labels = {}}
    if result.value ~= nil then
        local projection = bounds.object(result.value)
        if not projection then return transaction.failure("INTERNAL", "stored node projection is malformed") end
        local stored_revision = bounds.count(projection.revision)
        local stored, decode_error = protocol.metadata(projection.value)
        if not stored_revision or not stored or projection.tombstone == true then
            return transaction.failure("INTERNAL", decode_error or "stored node projection is malformed")
        end
        revision, metadata = stored_revision, stored
    end
    return transaction.success({schema_revision = protocol.SCHEMA, node_id = node, revision = revision, metadata = metadata}, false)
end

function M.update_metadata(request: unknown): Result
    local input, invalid = protocol.update(request)
    if not input then return transaction.failure("INVALID", invalid or "invalid metadata update") end
    local node, actor, denied = authority("bee.node.update")
    if not node or not actor then return denied or transaction.failure("DENIED", "node update refused") end
    local encoded, encode_error = canonical.encode({node = node, actor = actor, key = input.idempotency_key})
    if not encoded then return transaction.failure("INTERNAL", encode_error or "encode event identity") end
    local identity, hash_error = hash.sha256(encoded)
    if not identity or hash_error then return transaction.failure("INTERNAL", "calculate event identity") end
    local store, err = open(node)
    if not store then return transaction.failure("UNAVAILABLE", err or "node store unavailable") end
    local result = store:append({feed = M.FEED, event_id = identity, idempotency_key = identity,
        event_type = "node.description.updated", expected_revision = input.expected_revision,
        projection_key = M.KEY, projection_value = input.metadata,
        payload = {schema_revision = protocol.SCHEMA, node_id = node, actor_id = actor,
            operation_id = identity, metadata = input.metadata}})
    store:close()
    return result
end

function M.get_appearance(request: unknown): Result
    local invalid = protocol.empty(request)
    if invalid then return transaction.failure("INVALID", invalid) end
    local node, actor, denied = authority("bee.node.read")
    if not node then return denied or transaction.failure("DENIED", "node read refused") end
    local store, err = open(node)
    if not store then return transaction.failure("UNAVAILABLE", err or "node store unavailable") end
    local result = store:projection("node.appearance", "defaults")
    store:close()
    if not result.ok then return result end
    local preferences: appearance.Preferences = appearance.defaults()
    local revision = 0
    if result.value ~= nil then
        local projection = bounds.object(result.value)
        if not projection then return transaction.failure("INTERNAL", "stored appearance is malformed") end
        local stored_revision = bounds.count(projection.revision)
        local stored, decode_error = protocol.preferences(projection.value)
        if not stored_revision or not stored or projection.tombstone == true then
            return transaction.failure("INTERNAL", decode_error or "stored appearance is malformed")
        end
        revision, preferences = stored_revision, stored
    end
    return transaction.success({schema_revision = "bee.node-appearance@1", node_id = node,
        revision = revision, preferences = preferences}, false)
end

function M.update_appearance(request: unknown): Result
    local input, invalid = protocol.appearance_update(request)
    if not input then return transaction.failure("INVALID", invalid or "invalid appearance update") end
    local node, actor, denied = authority("bee.node.appearance.update")
    if not node or not actor then return denied or transaction.failure("DENIED", "node appearance update refused") end
    local encoded, encode_error = canonical.encode({node = node, actor = actor,
        operation = "node.appearance", key = input.idempotency_key})
    if not encoded then return transaction.failure("INTERNAL", encode_error or "encode event identity") end
    local identity, hash_error = hash.sha256(encoded)
    if not identity or hash_error then return transaction.failure("INTERNAL", "calculate event identity") end
    local store, err = open(node)
    if not store then return transaction.failure("UNAVAILABLE", err or "node store unavailable") end
    local result = store:append({feed = "node.appearance", event_id = identity, idempotency_key = identity,
        event_type = "node.appearance.updated", expected_revision = input.expected_revision,
        projection_key = "defaults", projection_value = input.preferences,
        payload = {schema_revision = "bee.node-appearance@1", node_id = node, actor_id = actor,
            operation_id = identity, preferences = input.preferences}})
    store:close()
    return result
end

function M.snapshot(request: unknown): Result
    local invalid = protocol.empty(request)
    if invalid then return transaction.failure("INVALID", invalid) end
    local node, actor, denied = authority("bee.node.read")
    if not node then return denied or transaction.failure("DENIED", "node read refused") end
    local store, err = open(node)
    if not store then return transaction.failure("UNAVAILABLE", err or "node store unavailable") end
    local result = store:snapshot(M.FEED, 1)
    store:close()
    return result
end

function M.read_after(request: unknown): Result
    local cursor, limit, invalid = protocol.page(request)
    if not cursor or not limit then return transaction.failure("INVALID", invalid or "invalid page") end
    local node, actor, denied = authority("bee.node.read")
    if not node then return denied or transaction.failure("DENIED", "node read refused") end
    local store, err = open(node)
    if not store then return transaction.failure("UNAVAILABLE", err or "node store unavailable") end
    local result = store:read_after(M.FEED, cursor, limit)
    store:close()
    return result
end
return M
