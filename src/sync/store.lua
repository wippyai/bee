-- MIT. Owner-local ordered feed and projection.  The owner is fixed when a
-- store opens; callers cannot choose another node's namespace in a request.
local sql = require("sql")
local json = require("json")
local time = require("time")
local bounds = require("bounds")
local canonical = require("canonical")
local database = require("database")
local shared = require("transaction")
local resources = require("resources")

local M = {}
type Result = {ok: boolean, code: string?, message: string?, value: unknown, replayed: boolean, commit: boolean?}
type Store = {db: sql.DB, owner: string, event_capacity: integer, receipt_capacity: integer, closed: boolean,
    append: (Store, unknown) -> Result,
    append_in: (Store, sql.Transaction, unknown) -> Result,
    projection: (Store, unknown, unknown) -> Result,
    projection_in: (Store, sql.Transaction, unknown, unknown) -> Result,
    read_after: (Store, unknown, unknown, unknown) -> Result,
    read_after_in: (Store, sql.Transaction, unknown, unknown, unknown) -> Result,
    snapshot: (Store, unknown, unknown, unknown?, unknown?) -> Result,
    snapshot_in: (Store, sql.Transaction, unknown, unknown, unknown?, unknown?) -> Result,
    close: (Store) -> (boolean, string?)}
type Input = {feed: string, event_id: string, idempotency_key: string, event_type: string, payload: unknown,
    projection_key: string, projection_value: unknown, tombstone: boolean, expected_revision: integer?, request_json: string}
type Feed = {head: integer, earliest: integer, event_capacity: integer, receipt_capacity: integer}
type Projection = {key: string, revision: integer, value: unknown, tombstone: boolean, sequence: integer, updated_at: string}

local function stamp(): string
    return time.now():utc():format("2006-01-02T15:04:05.000Z07:00")
end
local function failure(code: string, message: string, value: unknown?): Result
    return shared.failure(code, message, value)
end
local function storage(err: unknown, action: string): Result
    if shared.busy(err) then return shared.storage_failure("sync database is busy") end
    return failure("INTERNAL", action)
end
local function integer(value: unknown): integer?
    if type(value) ~= "number" or value ~= math.floor(value) then return nil end
    return math.floor(value)
end
local function object(value: unknown): {[string]: unknown}?
    if type(value) ~= "table" then return nil end
    for key in pairs(value) do if type(key) ~= "string" then return nil end end
    return value :: {[string]: unknown}
end
local function fields(value: {[string]: unknown}, allowed: {string}): string?
    local known: {[string]: boolean} = {}
    for _, key in ipairs(allowed) do known[key] = true end
    for key in pairs(value) do if not known[key] then return "unknown field " .. key end end
    return nil
end
local function decode_input(raw: unknown): (Input?, Result?)
    local value = object(raw)
    if not value then return nil, failure("INVALID_ARGUMENT", "append request must be an object") end
    local unexpected = fields(value, {"feed", "event_id", "idempotency_key", "event_type", "payload", "projection_key", "projection_value", "tombstone", "expected_revision"})
    if unexpected then return nil, failure("INVALID_ARGUMENT", unexpected) end
    local feed, event_id = bounds.id(value.feed), bounds.id(value.event_id)
    local key, event_type = bounds.id(value.idempotency_key), bounds.id(value.event_type)
    local projection_key = bounds.id(value.projection_key)
    if not feed then return nil, failure("INVALID_ARGUMENT", "feed is not an identifier") end
    if not event_id then return nil, failure("INVALID_ARGUMENT", "event_id is not an identifier") end
    if not key then return nil, failure("INVALID_ARGUMENT", "idempotency_key is not an identifier") end
    if not event_type then return nil, failure("INVALID_ARGUMENT", "event_type is not an identifier") end
    if not projection_key then return nil, failure("INVALID_ARGUMENT", "projection_key is not an identifier") end
    if value.payload == nil then return nil, failure("INVALID_ARGUMENT", "payload is required") end
    local tombstone = value.tombstone == true
    if value.tombstone ~= nil and type(value.tombstone) ~= "boolean" then return nil, failure("INVALID_ARGUMENT", "tombstone must be boolean") end
    if not tombstone and value.projection_value == nil then return nil, failure("INVALID_ARGUMENT", "projection_value is required unless tombstone") end
    if tombstone and value.projection_value ~= nil then return nil, failure("INVALID_ARGUMENT", "tombstone has no projection_value") end
    local expected: integer? = nil
    if value.expected_revision ~= nil then
        expected = bounds.count(value.expected_revision, 9007199254740991)
        if expected == nil then return nil, failure("INVALID_ARGUMENT", "expected_revision is not a nonnegative integer") end
    end
    local request_json, request_error = canonical.encode({feed = feed, event_id = event_id, idempotency_key = key,
        event_type = event_type, payload = value.payload, projection_key = projection_key,
        projection_value = value.projection_value, tombstone = tombstone, expected_revision = expected})
    if not request_json then return nil, failure("INVALID_ARGUMENT", "append request is not encodable: " .. tostring(request_error)) end
    return {feed = feed, event_id = event_id, idempotency_key = key, event_type = event_type, payload = value.payload,
        projection_key = projection_key, projection_value = value.projection_value, tombstone = tombstone,
        expected_revision = expected, request_json = request_json}, nil
end
local function query_one(tx: sql.Transaction, statement: string, params: {unknown}, label: string): ({[string]: unknown}?, Result?)
    local rows, query_error = tx:query(statement, params)
    if query_error or not rows then return nil, storage(query_error, "read " .. label) end
    if #rows > 1 then return nil, failure("INTERNAL", label .. " rows are corrupt") end
    return rows[1] :: {[string]: unknown}?, nil
end
local function feed_row(row: {[string]: unknown}?): (Feed?, Result?)
    if not row then return nil, nil end
    local head, earliest, events, receipts = integer(row.head_sequence), integer(row.earliest_sequence), integer(row.event_capacity), integer(row.receipt_capacity)
    if not head or not earliest or not events or not receipts or head < 0 or earliest < 1 or events < 1 or receipts < 1 then
        return nil, failure("INTERNAL", "sync feed is corrupt")
    end
    return {head = head, earliest = earliest, event_capacity = events, receipt_capacity = receipts}, nil
end
local function projection_row(row: {[string]: unknown}?): (Projection?, Result?)
    if not row then return nil, nil end
    local key, revision, sequence, changed = row.projection_key, integer(row.revision), integer(row.last_sequence), row.updated_at
    local marker = integer(row.tombstone)
    if type(key) ~= "string" or not revision or not sequence or type(changed) ~= "string" or (marker ~= 0 and marker ~= 1) then
        return nil, failure("INTERNAL", "sync projection is corrupt")
    end
    if marker == 1 then
        if row.value_json ~= nil then return nil, failure("INTERNAL", "sync tombstone is corrupt") end
        return {key = key, revision = revision, value = nil, tombstone = true, sequence = sequence, updated_at = changed}, nil
    end
    if type(row.value_json) ~= "string" then return nil, failure("INTERNAL", "sync projection value is corrupt") end
    local value, decode_error = json.decode(row.value_json)
    if decode_error or value == nil then return nil, failure("INTERNAL", "decode sync projection") end
    return {key = key, revision = revision, value = value, tombstone = false, sequence = sequence, updated_at = changed}, nil
end
local function ensure_feed(store: Store, tx: sql.Transaction, feed: string): (Feed?, Result?)
    local _, insert_error = tx:execute("INSERT INTO bee_sync_feeds (owner_id, feed, head_sequence, earliest_sequence, event_capacity, receipt_capacity) VALUES (?, ?, 0, 1, ?, ?) ON CONFLICT(owner_id, feed) DO NOTHING",
        {store.owner, feed, store.event_capacity, store.receipt_capacity})
    if insert_error then return nil, storage(insert_error, "create sync feed") end
    local row, row_error = query_one(tx, "SELECT head_sequence, earliest_sequence, event_capacity, receipt_capacity FROM bee_sync_feeds WHERE owner_id = ? AND feed = ?", {store.owner, feed}, "sync feed")
    if row_error then return nil, row_error end
    local current, current_error = feed_row(row)
    if not current then return nil, current_error or failure("INTERNAL", "created sync feed is missing") end
    return current, nil
end
local function receipt(store: Store, tx: sql.Transaction, input: Input): ({[string]: unknown}?, Result?)
    local row, row_error = query_one(tx, "SELECT event_id, request_json, sequence, projection_key, projection_revision FROM bee_sync_receipts WHERE owner_id = ? AND feed = ? AND idempotency_key = ?",
        {store.owner, input.feed, input.idempotency_key}, "sync receipt")
    if row_error or not row then return row, row_error end
    if row.event_id ~= input.event_id or row.request_json ~= input.request_json then
        return nil, failure("CONFLICT", "idempotency_key was used by a different append")
    end
    local sequence, revision = integer(row.sequence), integer(row.projection_revision)
    if not sequence or not revision or type(row.projection_key) ~= "string" then return nil, failure("INTERNAL", "sync receipt is corrupt") end
    return {sequence = sequence, revision = revision, event_id = input.event_id, projection_key = row.projection_key}, nil
end
local function event_receipt(store: Store, tx: sql.Transaction, input: Input): (boolean?, Result?)
    local row, row_error = query_one(tx, "SELECT idempotency_key, request_json FROM bee_sync_receipts WHERE owner_id = ? AND feed = ? AND event_id = ?",
        {store.owner, input.feed, input.event_id}, "sync event receipt")
    if row_error or not row then return row ~= nil, row_error end
    if row.idempotency_key ~= input.idempotency_key or row.request_json ~= input.request_json then
        return nil, failure("CONFLICT", "event_id was used by a different append")
    end
    return true, nil
end
local function encode_value(value: unknown): (string?, Result?)
    local encoded, encode_error = canonical.encode(value)
    if not encoded then return nil, failure("INVALID_ARGUMENT", "value is not encodable: " .. tostring(encode_error)) end
    return encoded, nil
end
-- Appends inside the caller's transaction. The caller must use the same
-- opened Store; this lets an owner atomically update its own table and this
-- projection when both are deliberately hosted in its linked SQLite resource.
function M.append_in(store: Store, tx: sql.Transaction, raw: unknown): Result
    if store.closed then return failure("CLOSED", "sync store is closed") end
    local input, invalid = decode_input(raw)
    if not input then return invalid or failure("INVALID_ARGUMENT", "invalid append") end
    local current_feed, feed_error = ensure_feed(store, tx, input.feed)
    if not current_feed then return feed_error or failure("INTERNAL", "open sync feed") end
    local replay, replay_error = receipt(store, tx, input)
    if replay_error then return replay_error end
    if replay then return shared.success(replay, true) end
    local same_event, same_event_error = event_receipt(store, tx, input)
    if same_event_error then return same_event_error end
    if same_event then return failure("INTERNAL", "sync event receipt has no idempotency receipt") end
    local count_row, count_error = query_one(tx, "SELECT COUNT(*) AS count FROM bee_sync_receipts WHERE owner_id = ? AND feed = ?", {store.owner, input.feed}, "sync receipt count")
    if count_error or not count_row then return count_error or failure("INTERNAL", "read sync receipt count") end
    local count = integer(count_row.count)
    if not count then return failure("INTERNAL", "sync receipt count is corrupt") end
    if count >= current_feed.receipt_capacity then return failure("CAPACITY_EXHAUSTED", "sync receipt capacity is exhausted") end
    local projection_raw, projection_read_error = query_one(tx, "SELECT projection_key, revision, value_json, tombstone, last_sequence, updated_at FROM bee_sync_projections WHERE owner_id = ? AND feed = ? AND projection_key = ?",
        {store.owner, input.feed, input.projection_key}, "sync projection")
    if projection_read_error then return projection_read_error end
    local prior, prior_error = projection_row(projection_raw)
    if prior_error then return prior_error end
    local current_revision = prior and prior.revision or 0
    if input.expected_revision ~= nil and input.expected_revision ~= current_revision then
        return failure("CONFLICT", "expected_revision does not match the projection")
    end
    local payload_json, payload_error = encode_value(input.payload)
    if not payload_json then return payload_error or failure("INVALID_ARGUMENT", "encode payload") end
    local value_json: string? = nil
    if not input.tombstone then
        value_json, payload_error = encode_value(input.projection_value)
        if not value_json then return payload_error or failure("INVALID_ARGUMENT", "encode projection value") end
    end
    local sequence, revision = current_feed.head + 1, current_revision + 1
    local changed_at = stamp()
    local _, projection_error = tx:execute("INSERT INTO bee_sync_projections (owner_id, feed, projection_key, revision, value_json, tombstone, last_sequence, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(owner_id, feed, projection_key) DO UPDATE SET revision = excluded.revision, value_json = excluded.value_json, tombstone = excluded.tombstone, last_sequence = excluded.last_sequence, updated_at = excluded.updated_at",
        {store.owner, input.feed, input.projection_key, revision, value_json, input.tombstone and 1 or 0, sequence, changed_at})
    if projection_error then return storage(projection_error, "write sync projection") end
    local _, event_error = tx:execute("INSERT INTO bee_sync_events (owner_id, feed, sequence, event_id, event_type, payload_json, projection_key, projection_revision, tombstone, committed_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        {store.owner, input.feed, sequence, input.event_id, input.event_type, payload_json, input.projection_key, revision, input.tombstone and 1 or 0, changed_at})
    if event_error then return storage(event_error, "append sync event") end
    local _, receipt_error = tx:execute("INSERT INTO bee_sync_receipts (owner_id, feed, idempotency_key, event_id, request_json, sequence, projection_key, projection_revision) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        {store.owner, input.feed, input.idempotency_key, input.event_id, input.request_json, sequence, input.projection_key, revision})
    if receipt_error then return storage(receipt_error, "record sync receipt") end
    local earliest = math.max(1, sequence - current_feed.event_capacity + 1)
    local _, head_error = tx:execute("UPDATE bee_sync_feeds SET head_sequence = ?, earliest_sequence = ? WHERE owner_id = ? AND feed = ?",
        {sequence, earliest, store.owner, input.feed})
    if head_error then return storage(head_error, "advance sync feed") end
    local _, trim_error = tx:execute("DELETE FROM bee_sync_events WHERE owner_id = ? AND feed = ? AND sequence < ?", {store.owner, input.feed, earliest})
    if trim_error then return storage(trim_error, "trim sync events") end
    return shared.success({sequence = sequence, revision = revision, event_id = input.event_id, projection_key = input.projection_key}, false)
end
function M.append(store: Store, raw: unknown): Result
    if store.closed then return failure("CLOSED", "sync store is closed") end
    return shared.write(store.db, "sync", function(tx: sql.Transaction): Result return M.append_in(store, tx, raw) end)
end
function M.projection_in(store: Store, tx: sql.Transaction, feed_raw: unknown, key_raw: unknown): Result
    if store.closed then return failure("CLOSED", "sync store is closed") end
    local feed, key = bounds.id(feed_raw), bounds.id(key_raw)
    if not feed or not key then return failure("INVALID_ARGUMENT", "feed and projection_key must be identifiers") end
    local row, row_error = query_one(tx, "SELECT projection_key, revision, value_json, tombstone, last_sequence, updated_at FROM bee_sync_projections WHERE owner_id = ? AND feed = ? AND projection_key = ?",
        {store.owner, feed, key}, "sync projection")
    if row_error then return row_error end
    local projection, projection_error = projection_row(row)
    if projection_error then return projection_error end
    if not projection then return shared.success(nil, false) end
    return shared.success({schema = "bee.sync-projection@1", owner_id = store.owner, feed = feed, key = projection.key,
        revision = projection.revision, value = projection.value, tombstone = projection.tombstone, sequence = projection.sequence,
        updated_at = projection.updated_at}, false)
end
function M.projection(store: Store, feed: unknown, key: unknown): Result
    if store.closed then return failure("CLOSED", "sync store is closed") end
    return shared.read(store.db, "sync", function(tx: sql.Transaction): Result return M.projection_in(store, tx, feed, key) end)
end
local function feed_for_read(store: Store, tx: sql.Transaction, feed: string): (Feed?, Result?)
    local row, row_error = query_one(tx, "SELECT head_sequence, earliest_sequence, event_capacity, receipt_capacity FROM bee_sync_feeds WHERE owner_id = ? AND feed = ?", {store.owner, feed}, "sync feed")
    if row_error then return nil, row_error end
    local result, result_error = feed_row(row)
    if result_error then return nil, result_error end
    if not result then return {head = 0, earliest = 1, event_capacity = store.event_capacity, receipt_capacity = store.receipt_capacity}, nil end
    return result, nil
end
local function event_value(store: Store, feed: string, row: {[string]: unknown}): ({[string]: unknown}?, Result?)
    local sequence, revision, tombstone = integer(row.sequence), integer(row.projection_revision), integer(row.tombstone)
    if not sequence or not revision or (tombstone ~= 0 and tombstone ~= 1) or type(row.event_id) ~= "string" or type(row.event_type) ~= "string" or type(row.projection_key) ~= "string" or type(row.payload_json) ~= "string" or type(row.committed_at) ~= "string" then
        return nil, failure("INTERNAL", "sync event is corrupt")
    end
    local payload, decode_error = json.decode(row.payload_json)
    if decode_error or payload == nil then return nil, failure("INTERNAL", "decode sync event") end
    return {schema = "bee.sync-event@1", owner_id = store.owner, feed = feed, sequence = sequence, event_id = row.event_id,
        event_type = row.event_type, payload = payload, projection_key = row.projection_key, revision = revision,
        tombstone = tombstone == 1, committed_at = row.committed_at}, nil
end
function M.read_after_in(store: Store, tx: sql.Transaction, feed_raw: unknown, cursor_raw: unknown, limit_raw: unknown): Result
    if store.closed then return failure("CLOSED", "sync store is closed") end
    local feed = bounds.id(feed_raw)
    local cursor = bounds.count(cursor_raw, 9007199254740991)
    local parsed_limit = bounds.count(limit_raw, bounds.MAX_PAGE)
    if not feed or cursor == nil or parsed_limit == nil or parsed_limit < 1 then return failure("INVALID_ARGUMENT", "feed, cursor and limit are invalid") end
    local limit = parsed_limit :: integer
    local head, head_error = feed_for_read(store, tx, feed)
    if not head then return head_error or failure("INTERNAL", "read sync feed") end
    if cursor > head.head then return failure("INVALID_ARGUMENT", "cursor is ahead of the feed") end
    if cursor < head.earliest - 1 then
        return failure("RESET_REQUIRED", "cursor is older than retained events", {schema = "bee.sync-page@1", owner_id = store.owner,
            feed = feed, earliest_cursor = head.earliest - 1, head_cursor = head.head, reset_required = true})
    end
    local rows, query_error = tx:query("SELECT sequence, event_id, event_type, payload_json, projection_key, projection_revision, tombstone, committed_at FROM bee_sync_events WHERE owner_id = ? AND feed = ? AND sequence > ? ORDER BY sequence LIMIT ?",
        {store.owner, feed, cursor, limit + 1})
    if query_error or not rows then return storage(query_error, "read sync events") end
    local events: {{[string]: unknown}} = {}
    local more = #rows > limit
    local last = cursor
    for index, row in ipairs(rows) do
        if index > limit then break end
        local event, event_error = event_value(store, feed, row)
        if not event then return event_error or failure("INTERNAL", "decode sync event") end
        events[#events + 1] = event
        last = event.sequence :: integer
    end
    return shared.success({schema = "bee.sync-page@1", owner_id = store.owner, feed = feed, events = events, next_cursor = last,
        more = more, head_cursor = head.head, earliest_cursor = head.earliest - 1, reset_required = false}, false)
end
function M.read_after(store: Store, feed: unknown, cursor: unknown, limit: unknown): Result
    if store.closed then return failure("CLOSED", "sync store is closed") end
    return shared.read(store.db, "sync", function(tx: sql.Transaction): Result return M.read_after_in(store, tx, feed, cursor, limit) end)
end
function M.snapshot_in(store: Store, tx: sql.Transaction, feed_raw: unknown, limit_raw: unknown, after_raw: unknown?, expected_cursor_raw: unknown?): Result
    if store.closed then return failure("CLOSED", "sync store is closed") end
    local feed = bounds.id(feed_raw)
    local after = after_raw == nil and "" or bounds.id(after_raw)
    local parsed_limit = bounds.count(limit_raw, bounds.MAX_PAGE)
    if not feed or not after or parsed_limit == nil or parsed_limit < 1 then return failure("INVALID_ARGUMENT", "snapshot feed, after_key or limit is invalid") end
    local limit = parsed_limit :: integer
    local head, head_error = feed_for_read(store, tx, feed)
    if not head then return head_error or failure("INTERNAL", "read sync feed") end
    if expected_cursor_raw ~= nil then
        local expected_cursor = bounds.count(expected_cursor_raw, 9007199254740991)
        if expected_cursor == nil then return failure("INVALID_ARGUMENT", "snapshot cursor is invalid") end
        if expected_cursor ~= head.head then
            return failure("RESET_REQUIRED", "snapshot cursor changed", {schema = "bee.sync-snapshot@1", owner_id = store.owner,
                feed = feed, cursor = head.head, earliest_cursor = head.earliest - 1, reset_required = true})
        end
    end
    local rows, query_error = tx:query("SELECT projection_key, revision, value_json, tombstone, last_sequence, updated_at FROM bee_sync_projections WHERE owner_id = ? AND feed = ? AND projection_key > ? ORDER BY projection_key LIMIT ?",
        {store.owner, feed, after, limit + 1})
    if query_error or not rows then return storage(query_error, "read sync snapshot") end
    local items: {{[string]: unknown}} = {}
    local more = #rows > limit
    local next_key: string? = nil
    for index, row in ipairs(rows) do
        if index > limit then break end
        local item, item_error = projection_row(row)
        if not item then return item_error or failure("INTERNAL", "decode sync snapshot") end
        items[#items + 1] = {schema = "bee.sync-projection@1", owner_id = store.owner, feed = feed, key = item.key,
            revision = item.revision, value = item.value, tombstone = item.tombstone, sequence = item.sequence, updated_at = item.updated_at}
        next_key = item.key
    end
    return shared.success({schema = "bee.sync-snapshot@1", owner_id = store.owner, feed = feed, items = items,
        next_key = more and next_key or nil, complete = not more, cursor = head.head, earliest_cursor = head.earliest - 1,
        reset_required = false}, false)
end
function M.snapshot(store: Store, feed: unknown, limit: unknown, after: unknown?, expected_cursor: unknown?): Result
    if store.closed then return failure("CLOSED", "sync store is closed") end
    return shared.read(store.db, "sync", function(tx: sql.Transaction): Result return M.snapshot_in(store, tx, feed, limit, after, expected_cursor) end)
end
function M.close(store: Store): (boolean, string?)
    if store.closed then return true, nil end
    store.closed = true
    local released, release_error = store.db:release()
    if released ~= true or release_error then return false, "close sync database" end
    return true, nil
end
function M.open(raw: unknown): (Store?, string?)
    local config = object(raw)
    if not config then return nil, "sync open configuration is invalid" end
    local unexpected = fields(config, {"resource", "owner", "event_capacity", "receipt_capacity"})
    if unexpected then return nil, "sync open " .. unexpected end
    local resource: unknown = config.resource
    local owner = bounds.id(config.owner)
    if type(resource) ~= "string" or resource == "" then return nil, "sync resource is not linked" end
    if not owner then return nil, "sync owner is not an identifier" end
    local values = config
    local event_capacity = bounds.capacity(values.event_capacity, bounds.MAX_EVENTS, bounds.MAX_EVENTS)
    local receipt_capacity = bounds.capacity(values.receipt_capacity, bounds.MAX_RECEIPTS, bounds.MAX_RECEIPTS)
    if not event_capacity or not receipt_capacity then return nil, "sync capacity is invalid" end
    local db, open_error = database.open(resource)
    if not db then return nil, open_error end
    return {db = db, owner = owner, event_capacity = event_capacity, receipt_capacity = receipt_capacity, closed = false,
        append = M.append, append_in = M.append_in, projection = M.projection, projection_in = M.projection_in,
        read_after = M.read_after, read_after_in = M.read_after_in, snapshot = M.snapshot, snapshot_in = M.snapshot_in,
        close = M.close}, nil
end
function M.open_linked(owner: unknown, options: {[string]: unknown}?): (Store?, string?)
    local resource, resource_error = resources.database()
    if not resource then return nil, resource_error end
    local values = options or {}
    values.resource = resource
    values.owner = owner
    return M.open(values)
end
return M
