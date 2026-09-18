-- MIT. Generic best-effort distribution of immutable Sync feeds over Hive.
-- Domain adapters publish measured descriptors and select exported feeds;
-- this worker owns paging, retries and durable destination cursors only.
local registry = require("registry")
local system = require("system")
local bounds = require("bounds")
local version = require("version")
local sync = require("sync")
local replicas = require("replicas")
local cursors = require("cursors")
local sender = require("sender")
local resources = require("resources")
local transaction = require("transaction")

local M = {}
local CONFIG = "bee.sync:exports"
local PAGE = 16
local MAX_PAGES = 4
local MAX_EXPORTS = 64
local MAX_KINDS = 32
type Result = transaction.Result
type Object = {[string]: unknown}
type Export = {feed: string, content_kinds: {[string]: boolean}}

local function object(value: unknown): Object?
    if type(value) ~= "table" then return nil end
    for key in pairs(value :: table) do if type(key) ~= "string" then return nil end end
    return value :: Object
end

local function fields(value: Object, allowed: {string}): string?
    local known: {[string]: boolean} = {}
    for _, name in ipairs(allowed) do known[name] = true end
    for name in pairs(value) do if not known[name] then return "unknown field " .. name end end
    return nil
end

local function failure(code: string, message: string): Result
    return transaction.failure(code, message)
end

local function dense(raw: unknown, label: string, maximum: integer): ({unknown}?, string?)
    if type(raw) ~= "table" then return nil, label .. " must be a list" end
    local source = raw :: table
    local count = 0
    for key in pairs(source) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
            return nil, label .. " must be a dense list"
        end
        count = count + 1
    end
    if count > maximum then return nil, label .. " exceeds its bound" end
    local result: {unknown} = {}
    for index = 1, count do
        if source[index] == nil then return nil, label .. " must be a dense list" end
        result[index] = source[index]
    end
    return result, nil
end

function M.configuration(raw: unknown): ({Export}?, string?)
    local value = object(raw)
    if not value or fields(value, {"exports"}) then
        return nil, "Sync exports must be an object with an export list"
    end
    local rows, rows_error = dense(value.exports, "Sync exports", MAX_EXPORTS)
    if not rows then return nil, rows_error end
    local result: {Export} = {}
    local feeds: {[string]: boolean} = {}
    for _, raw_export in ipairs(rows) do
        local item = object(raw_export)
        if not item or fields(item, {"feed", "content_kinds"}) then
            return nil, "Sync export is malformed"
        end
        local feed = bounds.id(item.feed)
        local kinds, kinds_error = dense(item.content_kinds, "Sync export content kinds", MAX_KINDS)
        if not feed or not kinds or #kinds == 0 or feeds[feed] then
            return nil, kinds_error or "Sync export identity is invalid or duplicated"
        end
        local accepted: {[string]: boolean} = {}
        for _, raw_kind in ipairs(kinds) do
            local kind = bounds.id(raw_kind)
            if not kind or accepted[kind] then return nil, "Sync export content kind is invalid or duplicated" end
            accepted[kind] = true
        end
        feeds[feed] = true
        result[#result + 1] = {feed = feed, content_kinds = accepted}
    end
    return result, nil
end

local function send_one(replica_store: replicas.Store, destination: string, export: Export,
    raw_descriptor: unknown, source_cursor: integer): Result
    local descriptor, descriptor_error = version.decode(raw_descriptor)
    if not descriptor or descriptor.feed ~= export.feed or not export.content_kinds[descriptor.content_kind] then
        return failure("INVALID", descriptor_error or "Sync feed contains a descriptor outside its export")
    end
    local stored = replicas.read(replica_store, {source_owner = descriptor.owner_id, feed = descriptor.feed,
        version_key = descriptor.key, descriptor_digest = descriptor.digest})
    if not stored.ok then return stored end
    local value = object(stored.value)
    if not value or type(value.content) ~= "string" then return failure("INTERNAL", "exported Sync bytes are unavailable") end
    return sender.send(destination, descriptor, value.content, {source_cursor = source_cursor, timeout = "60s"})
end

local function snapshot(feed_store: sync.Store, replica_store: replicas.Store, destination: string,
    export: Export): (integer?, Result?)
    local after = ""
    local pinned: integer? = nil
    while true do
        local page = sync.snapshot(feed_store, export.feed, PAGE, after, pinned)
        if not page.ok then return nil, page end
        local value = object(page.value)
        local items = value and value.items
        local cursor = value and bounds.count(value.cursor, 9007199254740991) or nil
        if type(items) ~= "table" or cursor == nil or (pinned ~= nil and cursor ~= pinned) then
            return nil, failure("INTERNAL", "Sync export snapshot is malformed")
        end
        pinned = cursor
        for _, raw in ipairs(items :: {unknown}) do
            local projection = object(raw)
            if not projection then return nil, failure("INTERNAL", "Sync export projection is malformed") end
            if projection.tombstone ~= true then
                local sent = send_one(replica_store, destination, export, projection.value, cursor)
                if not sent.ok then return nil, sent end
            end
        end
        if value.complete == true then return cursor, nil end
        after = bounds.id(value.next_key) or ""
        if after == "" then return nil, failure("INTERNAL", "Sync export continuation is malformed") end
    end
end

function M.distribute(resource: string, source: string, destination: string, export: Export): Result
    local feed_store, feed_error = sync.open({resource = resource, owner = source})
    if not feed_store then return failure("UNAVAILABLE", feed_error or "open Sync export feed") end
    local replica_store, replica_error = replicas.open(resource)
    if not replica_store then sync.close(feed_store); return failure("UNAVAILABLE", replica_error or "open Sync replicas") end
    local cursor_store, cursor_error = cursors.open(resource)
    if not cursor_store then replicas.close(replica_store); sync.close(feed_store); return failure("UNAVAILABLE", cursor_error or "open Sync distribution cursors") end
    local current = cursors.cursor(cursor_store, source, export.feed, destination)
    local current_value = object(current.value)
    local cursor = current.ok and current_value and bounds.count(current_value.cursor, 9007199254740991) or nil
    local outcome: Result = current
    if cursor ~= nil then
        for _ = 1, MAX_PAGES do
            local page = sync.read_after(feed_store, export.feed, cursor, PAGE)
            if page.code == "RESET_REQUIRED" then
                local pinned, snapshot_error = snapshot(feed_store, replica_store, destination, export)
                if not pinned then outcome = snapshot_error or failure("INTERNAL", "snapshot Sync export"); break end
                outcome = cursors.advance(cursor_store, source, export.feed, destination, cursor, pinned)
                if outcome.ok then cursor = pinned end
                break
            end
            if not page.ok then outcome = page; break end
            local value = object(page.value)
            local rows = value and value.events
            local next_cursor = value and bounds.count(value.next_cursor, 9007199254740991) or nil
            if type(rows) ~= "table" or next_cursor == nil then outcome = failure("INTERNAL", "Sync export page is malformed"); break end
            local failed: Result? = nil
            for _, raw in ipairs(rows :: {unknown}) do
                local event = object(raw)
                local sequence = event and bounds.count(event.sequence, 9007199254740991) or nil
                if not event or sequence == nil then failed = failure("INTERNAL", "Sync export event is malformed"); break end
                local sent = send_one(replica_store, destination, export, event.payload, sequence)
                if not sent.ok then failed = sent; break end
            end
            if failed then outcome = failed; break end
            outcome = cursors.advance(cursor_store, source, export.feed, destination, cursor, next_cursor)
            if not outcome.ok then break end
            cursor = next_cursor
            if value.more ~= true then break end
        end
    end
    cursors.close(cursor_store)
    replicas.close(replica_store)
    sync.close(feed_store)
    return outcome
end

local function load(): ({Export}?, string?)
    local entry, entry_error = registry.get(CONFIG)
    if not entry then return nil, tostring(entry_error or "Sync exports are unavailable") end
    return M.configuration(entry.data)
end

function M.run_once(): (boolean, string?)
    local source, source_error = system.node.id()
    local resource, resource_error = resources.database()
    local members, members_error = system.cluster.members()
    local exports, exports_error = load()
    if not source or source_error or not resource or members_error or type(members) ~= "table" or not exports then
        return false, tostring(source_error or resource_error or members_error or exports_error or "Hive membership is unavailable")
    end
    local failures: {string} = {}
    for _, raw in ipairs(members :: {unknown}) do
        local member = object(raw)
        local destination = member and bounds.id(member.id) or nil
        local meta = member and object(member.meta) or nil
        if destination and destination ~= source and member.is_local ~= true
            and (not meta or meta["bee.role"] ~= "client") then
            for _, export in ipairs(exports) do
                local result = M.distribute(resource, source, destination, export)
                if not result.ok then failures[#failures + 1] = destination .. "/" .. export.feed .. ": " .. tostring(result.code) end
            end
        end
    end
    if #failures > 0 then return false, table.concat(failures, "; ") end
    return true, nil
end

return M
