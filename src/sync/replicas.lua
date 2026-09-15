-- MIT. Source-qualified, resumable immutable-content replicas. This cache has
-- no operation that selects, executes, republishes, or activates content.
local sql = require("sql")
local json = require("json")
local hash = require("hash")
local base64 = require("base64")
local database = require("database")
local transaction = require("transaction")
local version = require("version")
local bounds = require("bounds")
local M = {}

M.MAX_CHUNK_BYTES = 32768
type Result = transaction.Result
type Store = {db: sql.DB, closed: boolean}
type Key = {source_owner: string, feed: string, version_key: string, descriptor_digest: string}
type Status = {source_owner: string, feed: string, key: string, state: string, received_bytes: integer, total_bytes: integer}
type Source = {source_owner: string, feed: string}
type CursorCheckpoint = {source_owner: string, feed: string, expected_cursor: integer, next_cursor: integer}

local function fail(code: string, message: string): Result return transaction.failure(code, message) end
local function one(tx: sql.Transaction, statement: string, parameters: {unknown}, label: string): ({[string]: unknown}?, Result?)
    local rows, err = tx:query(statement, parameters)
    if err or not rows then return nil, fail("INTERNAL", "read " .. label) end
    if #rows > 1 then return nil, fail("INTERNAL", label .. " is corrupt") end
    return rows[1], nil
end
local function key(source: unknown, feed: unknown, version_key: unknown, descriptor_digest: unknown): (Key?, string?)
    local owner = bounds.id(source)
    local selected_feed = bounds.id(feed)
    local selected_key = bounds.id(version_key)
    if not owner or not selected_feed or not selected_key or type(descriptor_digest) ~= "string"
        or #descriptor_digest ~= 64 or not descriptor_digest:match("^[0-9a-f]+$") then
        return nil, "replica identity is invalid"
    end
    local selected_digest: string = descriptor_digest :: string
    local result: Key = {source_owner = owner :: string, feed = selected_feed :: string,
        version_key = selected_key :: string, descriptor_digest = selected_digest}
    return result, nil
end
local function source(raw_owner: unknown, raw_feed: unknown): (Source?, string?)
    local owner, feed = bounds.id(raw_owner), bounds.id(raw_feed)
    if not owner or not feed then return nil, "replica source identity is invalid" end
    return {source_owner = owner, feed = feed}, nil
end

function M.open(resource: string): (Store?, string?)
    local db, err = database.open(resource)
    if not db then return nil, err end
    return {db = db, closed = false}, nil
end

-- The stored cursor marks a fully processed discovery range. A transfer's
-- source_cursor is provenance only and is never enough to move this checkpoint.
function M.cursor(store: Store, raw_source: Source): Result
    if store.closed then return fail("CLOSED", "replica store is closed") end
    local selected, source_error = source(raw_source.source_owner, raw_source.feed)
    if not selected then return fail("INVALID", source_error or "replica source identity is invalid") end
    return transaction.read(store.db, "sync replica", function(tx: sql.Transaction): Result
        local row, row_error = one(tx, "SELECT cursor FROM bee_sync_replica_sources WHERE source_owner = ? AND feed = ?", {selected.source_owner, selected.feed}, "replica source cursor")
        if row_error then return row_error end
        local cursor = 0
        if row then cursor = bounds.count(row.cursor, 9007199254740991) end
        if cursor == nil then return fail("INTERNAL", "replica source cursor is corrupt") end
        return transaction.success({source_owner = selected.source_owner, feed = selected.feed, cursor = cursor}, false)
    end)
end

-- Catch-up code commits a discovery range only after it has handled every
-- descriptor in that range. The expected value fences concurrent catch-up
-- attempts; individual blob completion never invokes this operation.
function M.advance_cursor(store: Store, raw_checkpoint: CursorCheckpoint): Result
    if store.closed then return fail("CLOSED", "replica store is closed") end
    local selected, source_error = source(raw_checkpoint.source_owner, raw_checkpoint.feed)
    local expected = bounds.count(raw_checkpoint.expected_cursor, 9007199254740991)
    local next_cursor = bounds.count(raw_checkpoint.next_cursor, 9007199254740991)
    if not selected or expected == nil or next_cursor == nil or next_cursor < expected then
        return fail("INVALID", source_error or "replica source cursor checkpoint is invalid")
    end
    return transaction.write(store.db, "sync replica", function(tx: sql.Transaction): Result
        local _, insert_error = tx:execute("INSERT INTO bee_sync_replica_sources (source_owner, feed, cursor) VALUES (?, ?, 0) ON CONFLICT(source_owner, feed) DO NOTHING", {selected.source_owner, selected.feed})
        if insert_error then return fail("INTERNAL", "create replica source") end
        local row, row_error = one(tx, "SELECT cursor FROM bee_sync_replica_sources WHERE source_owner = ? AND feed = ?", {selected.source_owner, selected.feed}, "replica source cursor")
        if row_error then return row_error end
        local current = row and bounds.count(row.cursor, 9007199254740991) or nil
        if current == nil then return fail("INTERNAL", "replica source cursor is corrupt") end
        if current ~= expected then return fail("CONFLICT", "replica source cursor changed") end
        if next_cursor == expected then
            return transaction.success({source_owner = selected.source_owner, feed = selected.feed, cursor = current}, true)
        end
        local changed, update_error = tx:execute("UPDATE bee_sync_replica_sources SET cursor = ? WHERE source_owner = ? AND feed = ? AND cursor = ?", {next_cursor, selected.source_owner, selected.feed, expected})
        if update_error or not changed or changed.rows_affected ~= 1 then return fail("CONFLICT", "replica source cursor changed during checkpoint") end
        return transaction.success({source_owner = selected.source_owner, feed = selected.feed, cursor = next_cursor}, false)
    end)
end

-- source_cursor is retained on the transfer as discovery provenance. It is not
-- the durable catch-up checkpoint and finish() must not advance that checkpoint.
function M.begin(store: Store, raw: unknown, cursor_raw: unknown): Result
    if store.closed then return fail("CLOSED", "replica store is closed") end
    local item, decode_error = version.decode(raw)
    local cursor = bounds.count(cursor_raw, 9007199254740991)
    if not item or cursor == nil then return fail("INVALID", decode_error or "invalid source cursor") end
    local encoded, encode_error = json.encode(item)
    if not encoded or encode_error or #encoded > version.MAX_MANIFEST_BYTES then return fail("INVALID", "version descriptor exceeds bound") end
    return transaction.write(store.db, "sync replica", function(tx: sql.Transaction): Result
        local available, available_error = one(tx, "SELECT descriptor_digest FROM bee_sync_replica_versions WHERE source_owner = ? AND feed = ? AND version_key = ?", {item.owner_id, item.feed, item.key}, "available replica")
        if available_error then return available_error end
        if available then
            if available.descriptor_digest ~= item.digest then return fail("CONFLICT", "immutable version identity changed") end
            return transaction.success({source_owner = item.owner_id, feed = item.feed, key = item.key,
                state = "available", received_bytes = item.total_bytes, total_bytes = item.total_bytes}, true)
        end
        local _, source_error = tx:execute("INSERT INTO bee_sync_replica_sources (source_owner, feed, cursor) VALUES (?, ?, 0) ON CONFLICT(source_owner, feed) DO NOTHING", {item.owner_id, item.feed})
        if source_error then return fail("INTERNAL", "create replica source") end
        local prior, prior_error = one(tx, "SELECT descriptor_digest, total_bytes, received_bytes, state FROM bee_sync_replica_transfers WHERE source_owner = ? AND feed = ? AND version_key = ?", {item.owner_id, item.feed, item.key}, "replica transfer")
        if prior_error then return prior_error end
        if prior then
            if prior.descriptor_digest ~= item.digest then return fail("CONFLICT", "immutable version identity changed") end
            return transaction.success({source_owner = item.owner_id, feed = item.feed, key = item.key,
                state = prior.state, received_bytes = prior.received_bytes, total_bytes = prior.total_bytes}, true)
        end
        local _, insert_error = tx:execute("INSERT INTO bee_sync_replica_transfers (source_owner, feed, version_key, descriptor_digest, descriptor_json, content_digest, total_bytes, received_bytes, source_cursor, state) VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, 'receiving')", {item.owner_id, item.feed, item.key, item.digest, encoded, item.content_digest, item.total_bytes, cursor})
        if insert_error then return fail("INTERNAL", "create replica transfer") end
        return transaction.success({source_owner = item.owner_id, feed = item.feed, key = item.key,
            state = "receiving", received_bytes = 0, total_bytes = item.total_bytes}, false)
    end)
end

function M.put(store: Store, raw_key: Key, offset_raw: unknown, encoded_raw: unknown): Result
    if store.closed then return fail("CLOSED", "replica store is closed") end
    local selected, key_error = key(raw_key.source_owner, raw_key.feed, raw_key.version_key, raw_key.descriptor_digest)
    local offset = bounds.count(offset_raw, 16777216)
    if not selected or offset == nil or type(encoded_raw) ~= "string" or #encoded_raw > 43692 then
        return fail("INVALID", key_error or "replica chunk is invalid")
    end
    local content, decode_error = base64.decode(encoded_raw)
    if not content or decode_error or #content > M.MAX_CHUNK_BYTES then return fail("INVALID", "replica chunk encoding is invalid") end
    local normalized, normalize_error = base64.encode(content)
    if normalize_error or normalized ~= encoded_raw then return fail("INVALID", "replica chunk must use canonical base64") end
    local chunk_digest, digest_error = hash.sha256(content)
    if not chunk_digest or digest_error then return fail("INTERNAL", "measure replica chunk") end
    return transaction.write(store.db, "sync replica", function(tx: sql.Transaction): Result
        local transfer, transfer_error = one(tx, "SELECT descriptor_digest, total_bytes, received_bytes, state FROM bee_sync_replica_transfers WHERE source_owner = ? AND feed = ? AND version_key = ?", {selected.source_owner, selected.feed, selected.version_key}, "replica transfer")
        if transfer_error then return transfer_error end
        if not transfer then return fail("NOT_FOUND", "replica transfer does not exist") end
        if transfer.descriptor_digest ~= selected.descriptor_digest then return fail("CONFLICT", "replica descriptor changed") end
        if transfer.state == "available" then return transaction.success({state = "available", received_bytes = transfer.received_bytes, total_bytes = transfer.total_bytes}, true) end
        local existing, existing_error = one(tx, "SELECT byte_count, content_sha256, content_base64 FROM bee_sync_replica_chunks WHERE source_owner = ? AND feed = ? AND version_key = ? AND byte_offset = ?", {selected.source_owner, selected.feed, selected.version_key, offset}, "replica chunk")
        if existing_error then return existing_error end
        if existing then
            if existing.byte_count ~= #content or existing.content_sha256 ~= chunk_digest or existing.content_base64 ~= encoded_raw then return fail("CONFLICT", "replica chunk changed") end
            return transaction.success({state = "receiving", received_bytes = transfer.received_bytes, total_bytes = transfer.total_bytes}, true)
        end
        if transfer.received_bytes ~= offset then return fail("CONFLICT", "replica chunk offset is not contiguous") end
        if offset + #content > transfer.total_bytes then return fail("INVALID", "replica chunk exceeds declared content length") end
        if #content == 0 and transfer.total_bytes ~= 0 then return fail("INVALID", "empty replica chunk cannot advance transfer") end
        local _, insert_error = tx:execute("INSERT INTO bee_sync_replica_chunks (source_owner, feed, version_key, byte_offset, byte_count, content_sha256, content_base64) VALUES (?, ?, ?, ?, ?, ?, ?)", {selected.source_owner, selected.feed, selected.version_key, offset, #content, chunk_digest, encoded_raw})
        if insert_error then return fail("INTERNAL", "write replica chunk") end
        local next_offset = offset + #content
        local changed, update_error = tx:execute("UPDATE bee_sync_replica_transfers SET received_bytes = ? WHERE source_owner = ? AND feed = ? AND version_key = ? AND descriptor_digest = ? AND received_bytes = ? AND state = 'receiving'", {next_offset, selected.source_owner, selected.feed, selected.version_key, selected.descriptor_digest, offset})
        if update_error or not changed or changed.rows_affected ~= 1 then return fail("CONFLICT", "replica transfer changed during chunk write") end
        return transaction.success({state = "receiving", received_bytes = next_offset, total_bytes = transfer.total_bytes}, false)
    end)
end

local function assemble(tx: sql.Transaction, selected: Key, expected_bytes: integer): (string?, Result?)
    local rows, query_error = tx:query("SELECT byte_offset, byte_count, content_sha256, content_base64 FROM bee_sync_replica_chunks WHERE source_owner = ? AND feed = ? AND version_key = ? ORDER BY byte_offset", {selected.source_owner, selected.feed, selected.version_key})
    if query_error or not rows then return nil, fail("INTERNAL", "read replica content") end
    local parts: {string} = {}
    local offset = 0
    for index, row in ipairs(rows) do
        if row.byte_offset ~= offset then return nil, fail("CONFLICT", "replica content has a gap") end
        if type(row.content_base64) ~= "string" then return nil, fail("INTERNAL", "replica chunk encoding is corrupt") end
        local encoded: string = row.content_base64 :: string
        local bytes, decode_error = base64.decode(encoded)
        local measured = bytes and hash.sha256(bytes) or nil
        if not bytes or decode_error or #bytes ~= row.byte_count or measured ~= row.content_sha256 then return nil, fail("INTERNAL", "replica chunk is corrupt") end
        parts[index] = bytes
        offset = offset + #bytes
    end
    if offset ~= expected_bytes then return nil, fail("CONFLICT", "replica content is incomplete") end
    return table.concat(parts), nil
end

local function transfer_status(row: {[string]: unknown}, selected: Key): (Status?, Result?)
    if row.descriptor_digest ~= selected.descriptor_digest then return nil, fail("CONFLICT", "replica descriptor changed") end
    local state = row.state
    if state ~= "receiving" and state ~= "available" then return nil, fail("INTERNAL", "replica transfer state is corrupt") end
    local total_bytes = bounds.count(row.total_bytes, 16777216)
    local received_bytes = bounds.count(row.received_bytes, 16777216)
    if total_bytes == nil or received_bytes == nil or received_bytes > total_bytes
        or (state == "available" and received_bytes ~= total_bytes) then
        return nil, fail("INTERNAL", "replica transfer size is corrupt")
    end
    local total: integer = total_bytes :: integer
    local received: integer = received_bytes :: integer
    local status: Status = {source_owner = selected.source_owner, feed = selected.feed, key = selected.version_key,
        state = state, received_bytes = received, total_bytes = total}
    return status, nil
end

-- Status is a read-only reconciliation point for callers that received an
-- uncertain begin/put/finish reply. It reports durable transfer state only;
-- availability still has no selection or activation meaning.
function M.status(store: Store, raw_key: Key): Result
    if store.closed then return fail("CLOSED", "replica store is closed") end
    local selected, key_error = key(raw_key.source_owner, raw_key.feed, raw_key.version_key, raw_key.descriptor_digest)
    if not selected then return fail("INVALID", key_error or "replica identity is invalid") end
    return transaction.read(store.db, "sync replica", function(tx: sql.Transaction): Result
        local row, row_error = one(tx, "SELECT descriptor_digest, total_bytes, received_bytes, state FROM bee_sync_replica_transfers WHERE source_owner = ? AND feed = ? AND version_key = ?", {selected.source_owner, selected.feed, selected.version_key}, "replica transfer")
        if row_error then return row_error end
        if not row then return fail("NOT_FOUND", "replica transfer does not exist") end
        local value, status_error = transfer_status(row, selected)
        if not value then return status_error or fail("INTERNAL", "decode replica transfer") end
        return transaction.success(value, false)
    end)
end

function M.finish(store: Store, raw_key: Key): Result
    if store.closed then return fail("CLOSED", "replica store is closed") end
    local selected, key_error = key(raw_key.source_owner, raw_key.feed, raw_key.version_key, raw_key.descriptor_digest)
    if not selected then return fail("INVALID", key_error or "replica identity is invalid") end
    return transaction.write(store.db, "sync replica", function(tx: sql.Transaction): Result
        local transfer, transfer_error = one(tx, "SELECT descriptor_digest, descriptor_json, content_digest, total_bytes, received_bytes, state FROM bee_sync_replica_transfers WHERE source_owner = ? AND feed = ? AND version_key = ?", {selected.source_owner, selected.feed, selected.version_key}, "replica transfer")
        if transfer_error then return transfer_error end
        if not transfer then return fail("NOT_FOUND", "replica transfer does not exist") end
        if transfer.descriptor_digest ~= selected.descriptor_digest then return fail("CONFLICT", "replica descriptor changed") end
        if transfer.state == "available" then return transaction.success({state = "available", received_bytes = transfer.total_bytes, total_bytes = transfer.total_bytes}, true) end
        local total_bytes = bounds.count(transfer.total_bytes, 16777216)
        local received_bytes = bounds.count(transfer.received_bytes, 16777216)
        if total_bytes == nil or received_bytes == nil then return fail("INTERNAL", "replica transfer size is corrupt") end
        if received_bytes ~= total_bytes then return fail("CONFLICT", "replica content is incomplete") end
        local content, content_error = assemble(tx, selected, total_bytes)
        if not content then return content_error or fail("INTERNAL", "assemble replica content") end
        local measured, measure_error = hash.sha256(content)
        if not measured or measure_error or measured ~= transfer.content_digest then return fail("CONFLICT", "replica content digest does not match") end
        local _, insert_error = tx:execute("INSERT INTO bee_sync_replica_versions (source_owner, feed, version_key, descriptor_digest, descriptor_json) VALUES (?, ?, ?, ?, ?)", {selected.source_owner, selected.feed, selected.version_key, selected.descriptor_digest, transfer.descriptor_json})
        if insert_error then return fail("INTERNAL", "publish available replica") end
        local _, state_error = tx:execute("UPDATE bee_sync_replica_transfers SET state = 'available' WHERE source_owner = ? AND feed = ? AND version_key = ? AND state = 'receiving'", {selected.source_owner, selected.feed, selected.version_key})
        if state_error then return fail("INTERNAL", "finish replica transfer") end
        return transaction.success({state = "available", received_bytes = transfer.total_bytes, total_bytes = transfer.total_bytes}, false)
    end)
end

function M.content(store: Store, raw_key: Key): (string?, Result?)
    if store.closed then return nil, fail("CLOSED", "replica store is closed") end
    local selected, key_error = key(raw_key.source_owner, raw_key.feed, raw_key.version_key, raw_key.descriptor_digest)
    if not selected then return nil, fail("INVALID", key_error or "replica identity is invalid") end
    local result = transaction.read(store.db, "sync replica", function(tx: sql.Transaction): Result
        local transfer, transfer_error = one(tx, "SELECT descriptor_digest, total_bytes, state FROM bee_sync_replica_transfers WHERE source_owner = ? AND feed = ? AND version_key = ?", {selected.source_owner, selected.feed, selected.version_key}, "replica transfer")
        if transfer_error then return transfer_error end
        if not transfer or transfer.state ~= "available" then return fail("NOT_FOUND", "replica version is not available") end
        if transfer.descriptor_digest ~= selected.descriptor_digest then return fail("CONFLICT", "replica descriptor changed") end
        local total_bytes = bounds.count(transfer.total_bytes, 16777216)
        if total_bytes == nil then return fail("INTERNAL", "replica transfer size is corrupt") end
        local content, content_error = assemble(tx, selected, total_bytes)
        if not content then return content_error or fail("INTERNAL", "assemble replica content") end
        return transaction.success(content, false)
    end)
    if not result.ok then return nil, result end
    return result.value :: string, nil
end

-- Read returns one verified immutable version.  Availability is a durable
-- receiver state; it is not a selection or activation decision.  Keep the
-- descriptor and content checks in one read transaction so callers receive a
-- matching snapshot of both halves of the replica.
function M.read(store: Store, raw_key: Key): Result
    if store.closed then return fail("CLOSED", "replica store is closed") end
    local selected, key_error = key(raw_key.source_owner, raw_key.feed, raw_key.version_key, raw_key.descriptor_digest)
    if not selected then return fail("INVALID", key_error or "replica identity is invalid") end
    return transaction.read(store.db, "sync replica", function(tx: sql.Transaction): Result
        local transfer, transfer_error = one(tx, "SELECT descriptor_digest, descriptor_json, content_digest, total_bytes, received_bytes, state FROM bee_sync_replica_transfers WHERE source_owner = ? AND feed = ? AND version_key = ?", {selected.source_owner, selected.feed, selected.version_key}, "replica transfer")
        if transfer_error then return transfer_error end
        if not transfer then return fail("NOT_FOUND", "replica version does not exist") end
        if transfer.descriptor_digest ~= selected.descriptor_digest then return fail("CONFLICT", "replica descriptor changed") end
        if transfer.state == "receiving" then return fail("NOT_FOUND", "replica version is not available") end
        if transfer.state ~= "available" then return fail("INTERNAL", "replica transfer state is corrupt") end

        local total_bytes = bounds.count(transfer.total_bytes, 16777216)
        local received_bytes = bounds.count(transfer.received_bytes, 16777216)
        if total_bytes == nil or received_bytes == nil or received_bytes ~= total_bytes then
            return fail("INTERNAL", "replica transfer size is corrupt")
        end

        -- The available-version row is the durable descriptor record.  The
        -- transfer retains the same descriptor for the resumable lifecycle;
        -- requiring both rows keeps a substituted half from being accepted.
        local available, available_error = one(tx, "SELECT descriptor_digest, descriptor_json FROM bee_sync_replica_versions WHERE source_owner = ? AND feed = ? AND version_key = ?", {selected.source_owner, selected.feed, selected.version_key}, "available replica")
        if available_error then return available_error end
        if not available then return fail("INTERNAL", "available replica descriptor is missing") end
        if available.descriptor_digest ~= selected.descriptor_digest
            or available.descriptor_digest ~= transfer.descriptor_digest then
            return fail("CONFLICT", "replica descriptor changed")
        end

        local encoded_descriptor = available.descriptor_json
        if type(encoded_descriptor) ~= "string" then return fail("INTERNAL", "replica descriptor is corrupt") end
        local raw_descriptor, decode_error = json.decode(encoded_descriptor)
        if decode_error then return fail("INTERNAL", "replica descriptor is corrupt") end
        local descriptor, descriptor_error = version.decode(raw_descriptor)
        if not descriptor or descriptor_error then return fail("INTERNAL", "replica descriptor is corrupt") end
        if descriptor.digest ~= selected.descriptor_digest or descriptor.owner_id ~= selected.source_owner
            or descriptor.feed ~= selected.feed or descriptor.key ~= selected.version_key
            or descriptor.total_bytes ~= total_bytes or descriptor.content_digest ~= transfer.content_digest then
            return fail("CONFLICT", "replica descriptor changed")
        end

        local transfer_descriptor = transfer.descriptor_json
        if type(transfer_descriptor) ~= "string" then return fail("INTERNAL", "replica descriptor is corrupt") end
        local transfer_raw, transfer_decode_error = json.decode(transfer_descriptor)
        if transfer_decode_error then return fail("INTERNAL", "replica descriptor is corrupt") end
        local decoded_transfer, transfer_descriptor_error = version.decode(transfer_raw)
        if not decoded_transfer or transfer_descriptor_error or not version.same(descriptor, decoded_transfer) then
            return fail("CONFLICT", "replica descriptor changed")
        end

        local content, content_error = assemble(tx, selected, total_bytes)
        if not content then return content_error or fail("INTERNAL", "assemble replica content") end
        if #content ~= total_bytes then return fail("CONFLICT", "replica content length does not match") end
        local measured, measure_error = hash.sha256(content)
        if not measured or measure_error or measured ~= transfer.content_digest
            or measured ~= descriptor.content_digest then
            return fail("CONFLICT", "replica content digest does not match")
        end
        return transaction.success({descriptor = descriptor, content = content}, false)
    end)
end

-- Lists the immutable descriptors already made available for one exact source
-- feed. This is discovery metadata only: callers still use read() to verify a
-- descriptor and its bytes together before staging anything.
function M.available(store: Store, source_owner_raw: unknown, feed_raw: unknown, limit_raw: unknown): Result
    if store.closed then return fail("CLOSED", "replica store is closed") end
    local selected, source_error = source(source_owner_raw, feed_raw)
    local limit = bounds.count(limit_raw, 128)
    if not selected or limit == nil or limit < 1 then
        return fail("INVALID", source_error or "available replica query is invalid")
    end
    return transaction.read(store.db, "sync replica", function(tx: sql.Transaction): Result
        local rows, query_error = tx:query([[SELECT v.version_key, v.descriptor_digest, v.descriptor_json
FROM bee_sync_replica_versions v
JOIN bee_sync_replica_transfers t
  ON t.source_owner = v.source_owner AND t.feed = v.feed AND t.version_key = v.version_key
WHERE v.source_owner = ? AND v.feed = ? AND t.state = 'available'
ORDER BY t.source_cursor DESC, v.version_key
LIMIT ?]], {selected.source_owner, selected.feed, limit})
        if query_error or not rows then return fail("INTERNAL", "list available replicas") end
        local items: {unknown} = {}
        for _, row in ipairs(rows) do
            if type(row.version_key) ~= "string" or type(row.descriptor_digest) ~= "string"
                or type(row.descriptor_json) ~= "string" then return fail("INTERNAL", "available replica row is corrupt") end
            local decoded, decode_error = json.decode(row.descriptor_json)
            local descriptor, descriptor_error = version.decode(decoded)
            if decode_error or not descriptor or descriptor_error or descriptor.owner_id ~= selected.source_owner
                or descriptor.feed ~= selected.feed or descriptor.key ~= row.version_key
                or descriptor.digest ~= row.descriptor_digest then
                return fail("INTERNAL", "available replica descriptor is corrupt")
            end
            items[#items + 1] = descriptor
        end
        return transaction.success({source_owner = selected.source_owner, feed = selected.feed, items = items}, false)
    end)
end

function M.close(store: Store): boolean
    if store.closed then return true end
    store.closed = true
    return store.db:release() == true
end
return M
