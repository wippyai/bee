-- MIT. Host-owned saved launch profiles. The profile store is a typed facade
-- over bee.sync; callers never select its database or owner identity.
local security = require("security")
local ctx = require("ctx")
local system = require("system")
local registry = require("registry")
local sql = require("sql")
local hash = require("hash")
local canonical = require("canonical")
local bounds = require("bounds")
local sync = require("sync")
local transaction = require("transaction")
local protocol = require("protocol")

local M = {}
type Result = transaction.Result
type Request = protocol.Request
type Profile = protocol.Profile
type Stored = {profile_id: string, revision: integer, profile: Profile?, tombstone: boolean}

local DATABASE_REF = "bee.harness.profiles:database_ref"
local FEED_PREFIX = "harness.profiles:"
local EVENT_TYPE = "harness.profile.changed"
local READ = "bee.harness.profiles.read"
local WRITE = "bee.harness.profiles.write"

local function failure(code: string, message: string, value: unknown?): Result
    return transaction.failure(code, message, value)
end

local function clean(result: Result): Result
    -- The generic sync envelope contains owner/feed authority. Never pass it
    -- through this public, profile-shaped boundary on an error path.
    if result.ok then return result end
    return failure(result.code or "INTERNAL", result.message or "profile operation failed")
end

local function identity(node: string, actor: string, workspace: string, key: string): (string?, string?)
    local encoded, encode_error = canonical.encode({node = node, actor = actor, workspace_id = workspace, idempotency_key = key})
    if not encoded then return nil, tostring(encode_error or "profile identity is not measurable") end
    local value, hash_error = hash.sha256(encoded)
    if not value or hash_error then return nil, tostring(hash_error or "profile identity cannot be measured") end
    return value, nil
end

local function feed(workspace: string): (string?, string?)
    local digest, hash_error = hash.sha256(workspace)
    if not digest or hash_error then return nil, tostring(hash_error or "workspace feed cannot be measured") end
    return FEED_PREFIX .. digest, nil
end

local function authority(input: Request): (string?, string?, Result?)
    local actor_object = security.actor()
    if not actor_object then return nil, nil, failure("UNAUTHENTICATED", "profile operation requires an actor") end
    local actor = bounds.id(actor_object:id())
    if not actor then return nil, nil, failure("UNAUTHENTICATED", "profile actor identity is invalid") end
    local action = (input.operation == "get" or input.operation == "list") and READ or WRITE
    -- This check deliberately precedes registry access and database opening.
    -- Metadata is derived here from host-inherited context, never from the request.
    local workspace = bounds.id(ctx.get("bee.workspace_id"))
    if not security.can(action, input.workspace_id, {workspace_id = workspace or ""}) then
        return nil, nil, failure("DENIED", "profile operation is not authorized")
    end
    local node, node_error = system.node.id()
    if node_error or not node or node == "" then
        return nil, nil, failure("UNAVAILABLE", "native node identity is unavailable")
    end
    local owner = bounds.id(node)
    if not owner then return nil, nil, failure("UNAVAILABLE", "native node identity is invalid") end
    return owner, actor, nil
end

local function database_resource(): (string?, string?)
    local entry = registry.get(DATABASE_REF)
    local data = entry and bounds.object(entry.data) or nil
    local resource = data and bounds.id(data.resource_ref) or nil
    if not resource then return nil, "profile database reference is not linked" end
    return resource, nil
end

local function open(node: string): (sync.Store?, string?)
    local resource, resource_error = database_resource()
    if not resource then return nil, resource_error end
    return sync.open({resource = resource, owner = node, event_capacity = 128, receipt_capacity = 1024})
end

-- Historical read compatibility only. Older projections stored one named
-- setting beside the shared options map. Translate that value in memory and
-- leave the projection, event and revision untouched; all new writes pass
-- through protocol.profile and therefore use the canonical shape.
local function historical_profile(value: unknown): (Profile?, string?)
    local object = bounds.object(value)
    if not object then return nil, "stored profile is not an object" end
    local legacy = object.config_profile
    if legacy == nil then return protocol.profile(value) end
    local options = bounds.object(object.options == nil and {} or object.options)
    if not options then return nil, "stored profile options are not an object" end
    local selected = options.config_profile
    if selected ~= nil and (type(selected) ~= type(legacy) or selected ~= legacy) then
        return nil, "stored profile has conflicting legacy and canonical option values"
    end
    local canonical: {[string]: unknown} = {}
    for key, item in pairs(object) do
        if key ~= "config_profile" then canonical[key] = item end
    end
    local copied_options: {[string]: unknown} = {}
    for key, item in pairs(options) do copied_options[key] = item end
    copied_options.config_profile = legacy
    canonical.options = copied_options
    return protocol.profile(canonical)
end

local function projection(value: unknown): (Stored?, Result?)
    local object = bounds.object(value)
    if not object then return nil, failure("INTERNAL", "profile projection is malformed") end
    local profile_id = bounds.id(object.key)
    local revision = bounds.count(object.revision)
    if not profile_id or not revision then return nil, failure("INTERNAL", "profile projection identity is malformed") end
    if type(object.tombstone) ~= "boolean" then return nil, failure("INTERNAL", "profile projection tombstone is malformed") end
    if object.tombstone then
        if object.value ~= nil then return nil, failure("INTERNAL", "profile tombstone contains a value") end
        return {profile_id = profile_id, revision = revision, profile = nil, tombstone = true}, nil
    end
    local profile, profile_error = historical_profile(object.value)
    if not profile then return nil, failure("INTERNAL", profile_error or "stored profile is malformed") end
    return {profile_id = profile_id, revision = revision, profile = profile, tombstone = false}, nil
end

local function reply(input: Request, profile_id: string, revision: integer, profile: Profile?, tombstone: boolean): {[string]: unknown}
    local value: {[string]: unknown} = {workspace_id = input.workspace_id, profile_id = profile_id, revision = revision, tombstone = tombstone}
    if not tombstone then value.profile = profile end
    return value
end

local function append(store: sync.Store, tx: sql.Transaction, input: Request, node: string, actor: string, feed_name: string,
    profile_id: string, profile: Profile?, tombstone: boolean): Result
    local event_id, identity_error = identity(node, actor, input.workspace_id, input.idempotency_key)
    if not event_id then return failure("INTERNAL", identity_error or "profile event identity failed") end
    return store:append_in(tx, {
        feed = feed_name, event_id = event_id, idempotency_key = event_id, event_type = EVENT_TYPE,
        projection_key = profile_id, projection_value = profile,
        payload = {schema_revision = protocol.SCHEMA, workspace_id = input.workspace_id,
            profile_id = profile_id, actor_id = actor, operation = input.operation, profile = profile,
            tombstone = tombstone}, tombstone = tombstone, expected_revision = input.expected_revision,
    })
end

local function get(store: sync.Store, tx: sql.Transaction, input: Request, feed_name: string): Result
    local result = store:projection_in(tx, feed_name, input.profile_id)
    if not result.ok then return clean(result) end
    if result.value == nil then return failure("NOT_FOUND", "profile does not exist") end
    local item, item_error = projection(result.value)
    if not item then return item_error or failure("INTERNAL", "decode profile") end
    return transaction.success(reply(input, item.profile_id, item.revision, item.profile, item.tombstone), false)
end

local function list(store: sync.Store, tx: sql.Transaction, input: Request, feed_name: string): Result
    -- sync treats nil as the first page; an explicit empty key is not a
    -- projection key and must not cross that generic boundary.
    local after_key: string? = input.after_key ~= "" and input.after_key or nil
    local result = store:snapshot_in(tx, feed_name, input.limit, after_key, input.expected_cursor)
    if not result.ok then
        if result.code == "RESET_REQUIRED" then
            local raw = bounds.object(result.value)
            local cursor = raw and bounds.count(raw.cursor) or nil
            return failure("RESET_REQUIRED", result.message or "profile cursor is stale", {
                workspace_id = input.workspace_id, cursor = cursor, reset_required = true,
            })
        end
        return clean(result)
    end
    local raw = bounds.object(result.value)
    if not raw then return failure("INTERNAL", "profile snapshot is malformed") end
    local cursor = bounds.count(raw.cursor)
    local complete = raw.complete
    local items = raw.items
    if not cursor or type(complete) ~= "boolean" or type(items) ~= "table" then
        return failure("INTERNAL", "profile snapshot envelope is malformed")
    end
    local decoded: {{[string]: unknown}} = {}
    for _, value in ipairs(items :: {unknown}) do
        local item, item_error = projection(value)
        if not item then return item_error or failure("INTERNAL", "decode profile snapshot") end
        decoded[#decoded + 1] = reply(input, item.profile_id, item.revision, item.profile, item.tombstone)
    end
    local next_key: string? = nil
    if not complete then
        next_key = bounds.id(raw.next_key)
        if not next_key then return failure("INTERNAL", "profile snapshot continuation is malformed") end
    end
    return transaction.success({workspace_id = input.workspace_id, items = decoded, cursor = cursor,
        next_key = next_key, complete = complete}, false)
end

local function put(store: sync.Store, tx: sql.Transaction, input: Request, node: string, actor: string, feed_name: string): Result
    local profile = input.profile
    if not profile then return failure("INVALID_ARGUMENT", "put profile is required") end
    local result = append(store, tx, input, node, actor, feed_name, input.profile_id, profile, false)
    if not result.ok then return clean(result) end
    local value = bounds.object(result.value)
    local revision = value and bounds.count(value.revision) or nil
    if not revision then return failure("INTERNAL", "profile append omitted revision") end
    return transaction.success(reply(input, input.profile_id, revision, profile, false), result.replayed)
end

local function remove(store: sync.Store, tx: sql.Transaction, input: Request, node: string, actor: string, feed_name: string): Result
    -- Keep this read and append in the same transaction. For an existing row,
    -- append_in checks receipts before CAS, allowing an old remove to replay
    -- after a later edit. A fresh remove of a tombstone is refused before it
    -- could append another tombstone.
    local current_result = store:projection_in(tx, feed_name, input.profile_id)
    if not current_result.ok then return clean(current_result) end
    if current_result.value == nil then return failure("NOT_FOUND", "profile does not exist") end
    local current, current_error = projection(current_result.value)
    if not current then return current_error or failure("INTERNAL", "decode profile") end
    if current.tombstone and input.expected_revision == current.revision then
        return failure("CONFLICT", "profile is already removed")
    end
    local result = append(store, tx, input, node, actor, feed_name, input.profile_id, nil, true)
    if not result.ok then return clean(result) end
    local value = bounds.object(result.value)
    local revision = value and bounds.count(value.revision) or nil
    if not revision then return failure("INTERNAL", "profile removal omitted revision") end
    return transaction.success(reply(input, input.profile_id, revision, nil, true), result.replayed)
end

function M.call(raw: unknown): Result
    local input, invalid = protocol.decode(raw)
    if not input then return failure("INVALID_ARGUMENT", invalid or "invalid profile request") end
    local node, actor, denied = authority(input)
    if not node or not actor then return denied or failure("DENIED", "profile operation refused") end
    local feed_name, feed_error = feed(input.workspace_id)
    if not feed_name then return failure("INTERNAL", feed_error or "profile feed failed") end
    local owner: string = node
    local caller: string = actor
    local selected_feed: string = feed_name
    local store, open_error = open(owner)
    if not store then return failure("UNAVAILABLE", open_error or "profile store unavailable") end
    local result: Result
    if input.operation == "get" then
        result = transaction.read(store.db, "profiles", function(tx: sql.Transaction): Result return get(store, tx, input, selected_feed) end)
    elseif input.operation == "list" then
        result = transaction.read(store.db, "profiles", function(tx: sql.Transaction): Result return list(store, tx, input, selected_feed) end)
    elseif input.operation == "put" then
        result = transaction.write(store.db, "profiles", function(tx: sql.Transaction): Result return put(store, tx, input, owner, caller, selected_feed) end)
    else
        result = transaction.write(store.db, "profiles", function(tx: sql.Transaction): Result return remove(store, tx, input, owner, caller, selected_feed) end)
    end
    store:close()
    return result
end

return M
