-- MIT. The pure consumer refuses malformed envelopes, tracks one owner/feed,
-- pins authorization scope through a snapshot, and leaves domain projection
-- folding to the source-specific reducer.
local test = require("test")
local protocol = require("protocol")
local function projection(key: string, revision: integer): {[string]: unknown}
    return {schema = "bee.sync-projection@1", owner_id = "node-a", feed = "approval", key = key, revision = revision,
        value = {approval_id = key, revision = revision}, tombstone = false, sequence = revision, updated_at = "2026-09-10T12:00:00.000Z"}
end
local function define_tests()
    test.describe("Sync transport protocol", function()
        test.it("decodes one strict owner/feed envelope and pins a snapshot token", function()
            local raw = {schema = "bee.sync-snapshot@1", owner_id = "node-a", feed = "approval", items = {projection("a", 1)},
                next_key = nil, complete = true, cursor = 1, earliest_cursor = 0, scope_revision = "scope-1", reset_required = false}
            local snapshot, snapshot_error = protocol.snapshot(raw, "node-a", "approval")
            test.is_nil(snapshot_error)
            if not snapshot then error("snapshot did not decode") end
            local state = protocol.new("node-a", "approval")
            local changed, apply_error = protocol.apply_snapshot(state, snapshot)
            test.is_nil(apply_error)
            test.is_true(changed)
            test.eq(state.cursor, 1)
            test.eq((state.projections.a.value :: {[string]: unknown}).approval_id, "a")
            local page, page_error = protocol.page({schema = "bee.sync-page@1", owner_id = "node-a", feed = "approval", events = {},
                next_cursor = 3, more = false, head_cursor = 3, earliest_cursor = 0, scope_revision = "scope-1", reset_required = false}, "node-a", "approval")
            test.is_nil(page_error)
            if not page then error("page did not decode") end
            local advanced, advanced_error = protocol.apply_page(state, page)
            test.is_nil(advanced_error)
            test.is_false(advanced)
            test.eq(state.cursor, 3)
            local changed_scope, changed_scope_error = protocol.page({schema = "bee.sync-page@1", owner_id = "node-a", feed = "approval", events = {},
                next_cursor = 3, more = false, head_cursor = 3, earliest_cursor = 0, scope_revision = "scope-2", reset_required = false}, "node-a", "approval")
            test.is_nil(changed_scope_error)
            if not changed_scope then error("scope page did not decode") end
            local _, rejected = protocol.apply_page(state, changed_scope)
            test.eq(rejected, "sync page scope changed")
        end)
        test.it("rejects untyped extras and permits a source reducer to own projection meaning", function()
            local event, event_error = protocol.event({schema = "bee.sync-event@1", owner_id = "node-a", feed = "approval", sequence = 1,
                event_id = "e1", event_type = "approval.changed", projection_key = "a", revision = 4, tombstone = false,
                committed_at = "2026-09-10T12:00:00.000Z", payload = {request = {approval_id = "a", revision = 4}}, typo = true}, "node-a", "approval")
            test.is_nil(event)
            test.eq(event_error, "unknown field typo")
            local page, page_error = protocol.page({schema = "bee.sync-page@1", owner_id = "node-a", feed = "approval", events = {
                {schema = "bee.sync-event@1", owner_id = "node-a", feed = "approval", sequence = 4, event_id = "e4", event_type = "approval.changed",
                    projection_key = "a", revision = 4, tombstone = false, committed_at = "2026-09-10T12:00:00.000Z", payload = {request = {approval_id = "a", revision = 4}}}},
                next_cursor = 6, more = false, head_cursor = 6, earliest_cursor = 0, reset_required = false}, "node-a", "approval")
            test.is_nil(page_error)
            if not page then error("page did not decode") end
            local state = protocol.new("node-a", "approval")
            local changed, reduce_error = protocol.apply_page(state, page, function(current: protocol.State, item: protocol.Event): (boolean?, string?)
                local payload = item.payload :: {[string]: unknown}
                local request = payload.request
                local next: protocol.Projection = {owner_id = item.owner_id, feed = item.feed, key = item.projection_key,
                    revision = item.revision, value = request, tombstone = item.tombstone, sequence = item.sequence, updated_at = item.committed_at}
                return protocol.fold_projection(current, next), nil
            end)
            test.is_nil(reduce_error)
            test.is_true(changed)
            test.eq(((state.projections.a.value :: {[string]: unknown}).approval_id), "a")
            test.eq(state.cursor, 6)
        end)
        test.it("does not commit an earlier reduced event when a later reducer fails", function()
            local page, page_error = protocol.page({schema = "bee.sync-page@1", owner_id = "node-a", feed = "approval", events = {
                {schema = "bee.sync-event@1", owner_id = "node-a", feed = "approval", sequence = 1, event_id = "e1", event_type = "approval.changed",
                    projection_key = "a", revision = 1, tombstone = false, committed_at = "2026-09-10T12:00:00.000Z", payload = {n = 1}},
                {schema = "bee.sync-event@1", owner_id = "node-a", feed = "approval", sequence = 2, event_id = "e2", event_type = "approval.changed",
                    projection_key = "b", revision = 1, tombstone = false, committed_at = "2026-09-10T12:00:00.000Z", payload = {n = 2}}},
                next_cursor = 2, more = false, head_cursor = 2, earliest_cursor = 0, reset_required = false}, "node-a", "approval")
            test.is_nil(page_error)
            if not page then error("page did not decode") end
            local state = protocol.new("node-a", "approval")
            local _, reduce_error = protocol.apply_page(state, page, function(current: protocol.State, event: protocol.Event): (boolean?, string?)
                if event.sequence == 2 then return nil, "source rejected second event" end
                local projection: protocol.Projection = {owner_id = event.owner_id, feed = event.feed, key = event.projection_key,
                    revision = event.revision, value = event.payload, tombstone = false, sequence = event.sequence, updated_at = event.committed_at}
                return protocol.fold_projection(current, projection), nil
            end)
            test.eq(reduce_error, "source rejected second event")
            test.eq(state.cursor, 0)
            test.is_nil(state.projections.a)
        end)
    end)
end
return test.run_cases(define_tests)
