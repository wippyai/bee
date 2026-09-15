-- MIT. The shared feed contract: an owner cannot impersonate another owner
-- through calls, every mutation has a durable replay receipt, event trimming
-- asks an old reader to reset, and snapshots retain tombstones.
local test = require("test")
local uuid = require("uuid")
local sync = require("store")
local function identifier(): string
    local value, err = uuid.v7()
    if not value then error(tostring(err)) end
    return value
end
local function opened(events: integer?, receipts: integer?): sync.Store
    local store, err = sync.open({resource = "bee.sync:sync_test_db", owner = "node-test-" .. identifier(),
        event_capacity = events, receipt_capacity = receipts})
    if not store then error(tostring(err)) end
    return store
end
local function append(store: sync.Store, feed: string, key: string, event: string, expected: integer?, value: unknown, tombstone: boolean?): sync.Result
    local request: {[string]: unknown} = {feed = feed, event_id = event, idempotency_key = key, event_type = "description.changed",
        expected_revision = expected, projection_key = "description", projection_value = value, tombstone = tombstone == true,
        payload = {schema = "bee.sync-test@1", actor_id = "node-test", causation_id = key, value = value}}
    -- Lua's `flag and nil or value` evaluates to value; remove the field
    -- explicitly so a tombstone exercises the contract rather than an
    -- invalid mixed value/tombstone request.
    if tombstone then request.projection_value = nil end
    return store:append(request)
end
local function define_tests()
    test.describe("Owner-local sync ledger", function()
        test.it("commits a projection and its stable receipt together", function()
            local store = opened()
            local feed = "metadata-" .. identifier()
            local first = append(store, feed, "write-1", "event-1", 0, {display_name = "First"})
            test.is_true(first.ok)
            test.eq((first.value :: {[string]: unknown}).sequence, 1)
            local projection = store:projection(feed, "description")
            test.is_true(projection.ok)
            local view = projection.value :: {[string]: unknown}
            test.eq(view.revision, 1)
            test.eq((view.value :: {[string]: unknown}).display_name, "First")
            local replay = append(store, feed, "write-1", "event-1", 0, {display_name = "First"})
            test.is_true(replay.ok)
            test.is_true(replay.replayed)
            test.eq((replay.value :: {[string]: unknown}).sequence, 1)
            local conflict = append(store, feed, "write-1", "event-1", 1, {display_name = "Changed"})
            test.is_false(conflict.ok)
            test.eq(conflict.code, "CONFLICT")
            local stale = append(store, feed, "write-2", "event-2", 0, {display_name = "Second"})
            test.is_false(stale.ok)
            test.eq(stale.code, "CONFLICT")
            test.is_true(store:close())
        end)
        test.it("requires reset after bounded event retention and retains deleted projections", function()
            local store = opened(2)
            local feed = "approvals-" .. identifier()
            test.is_true(append(store, feed, "one", "event-one", 0, {approval = "one"}).ok)
            test.is_true(append(store, feed, "two", "event-two", 1, {approval = "two"}).ok)
            test.is_true(append(store, feed, "three", "event-three", 2, {approval = "three"}, true).ok)
            local reset = store:read_after(feed, 0, 8)
            test.is_false(reset.ok)
            test.eq(reset.code, "RESET_REQUIRED")
            local page = store:read_after(feed, 1, 8)
            test.is_true(page.ok)
            local events = ((page.value :: {[string]: unknown}).events :: {unknown})
            test.eq(#events, 2)
            local snapshot = store:snapshot(feed, 8)
            test.is_true(snapshot.ok)
            local items = ((snapshot.value :: {[string]: unknown}).items :: {unknown})
            test.eq(#items, 1)
            test.is_true(((items[1] :: {[string]: unknown}).tombstone :: boolean))
            test.is_true(store:close())
        end)
        test.it("fails closed before it would discard an idempotency receipt", function()
            local store = opened(8, 2)
            local feed = "receipts-" .. identifier()
            test.is_true(append(store, feed, "one", "event-one", 0, {n = 1}).ok)
            test.is_true(append(store, feed, "two", "event-two", 1, {n = 2}).ok)
            local full = append(store, feed, "three", "event-three", 2, {n = 3})
            test.is_false(full.ok)
            test.eq(full.code, "CAPACITY_EXHAUSTED")
            local replay = append(store, feed, "one", "event-one", 0, {n = 1})
            test.is_true(replay.ok)
            test.is_true(replay.replayed)
            test.is_true(store:close())
        end)
        test.it("pins a multi-page snapshot and rejects an unknown append field", function()
            local store = opened()
            local feed = "snapshot-" .. identifier()
            local first = store:append({feed = feed, event_id = "event-a", idempotency_key = "key-a", event_type = "node.changed",
                projection_key = "a", projection_value = {n = 1}, expected_revision = 0, payload = {n = 1}})
            local second = store:append({feed = feed, event_id = "event-b", idempotency_key = "key-b", event_type = "node.changed",
                projection_key = "b", projection_value = {n = 2}, expected_revision = 0, payload = {n = 2}})
            test.is_true(first.ok)
            test.is_true(second.ok)
            local page = store:snapshot(feed, 1)
            test.is_true(page.ok)
            local snapshot = page.value :: {[string]: unknown}
            test.is_false(snapshot.complete :: boolean)
            local advanced = store:append({feed = feed, event_id = "event-c", idempotency_key = "key-c", event_type = "node.changed",
                projection_key = "c", projection_value = {n = 3}, expected_revision = 0, payload = {n = 3}})
            test.is_true(advanced.ok)
            local mixed = store:snapshot(feed, 1, snapshot.next_key, snapshot.cursor)
            test.is_false(mixed.ok)
            test.eq(mixed.code, "RESET_REQUIRED")
            local unknown = store:append({feed = feed, event_id = "event-d", idempotency_key = "key-d", event_type = "node.changed",
                projection_key = "d", projection_value = {n = 4}, expected_revision = 0, payload = {n = 4}, typo = true})
            test.is_false(unknown.ok)
            test.eq(unknown.code, "INVALID_ARGUMENT")
            test.is_true(store:close())
        end)
    end)
end
return test.run_cases(define_tests)
