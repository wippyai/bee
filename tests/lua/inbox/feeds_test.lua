-- MIT. The inbox feed adapter keeps an owner-qualified cache, applies typed
-- incremental events, and replaces that cache after a reset so revoked data
-- and stale route addresses disappear together.
local test = require("test")
local feeds = require("feeds")
local source_config = require("source_config")
type Object = {[string]: unknown}
type Source = {node_id: string, feed: string}
local function view(revision: integer): Object
    return {approval_id = "approval-a", owner_node = "node-a", workspace_id = "ws", requester_id = "requester",
        request_kind = "permission", policy = "policy", proposal_digest = string.rep("a", 64), revision = revision,
        state = revision == 1 and "pending" or "decided", proposal = {}, prompt = {}}
end
local function snapshot(source: Source, items: {Object}): Object
    return {ok = true, value = {schema = "bee.sync-snapshot@1", owner_id = source.node_id, feed = source.feed,
        cursor = #items == 0 and 2 or 1, earliest_cursor = 0, scope_revision = "scope-1", items = items,
        complete = true, reset_required = false}, replayed = false}
end
local function projection(source: Source, value: Object, sequence: integer): Object
    return {schema = "bee.sync-projection@1", owner_id = source.node_id, feed = source.feed, key = "approval-a",
        revision = value.revision, value = value, tombstone = false, sequence = sequence, updated_at = "2026-09-10T12:00:00.000Z"}
end
local function define_tests()
    test.describe("Inbox sync feed adapter", function()
        test.it("uses a typed incremental page, then purges and replaces a reset source", function()
            local snapshots, reads = 0, 0
            local configured, configure_error = source_config.configure("node-a", {"ws"}, nil)
            test.is_nil(configure_error)
            if not configured then error("configure inbox source") end
            local client = feeds.new(configured, function(source: Source, target: string, request: unknown): (unknown, string?)
                if target == "bee.approvals.binding:feed_snapshot" then
                    snapshots = snapshots + 1
                    if snapshots == 1 then return snapshot(source, {projection(source, view(1), 1)}), nil end
                    return snapshot(source, {}), nil
                end
                if target == "bee.approvals.binding:feed_read_after" then
                    reads = reads + 1
                    if reads == 1 then
                        local changed = view(2)
                        return {ok = true, value = {schema = "bee.sync-page@1", owner_id = source.node_id, feed = source.feed,
                            scope_revision = "scope-1", events = {{schema = "bee.sync-event@1", owner_id = source.node_id,
                                feed = source.feed, sequence = 2, event_id = "approval-a/2", event_type = "approval.changed",
                                projection_key = "approval-a", revision = 2, tombstone = false,
                                payload = {schema_revision = "bee.approval-projection@1", request = changed},
                                committed_at = "2026-09-10T12:01:00.000Z"}}, next_cursor = 2, more = false,
                            head_cursor = 2, earliest_cursor = 0, reset_required = false}, replayed = false}, nil
                    end
                    return {ok = false, error = {code = "RESET_REQUIRED", message = "scope changed"}, value = nil, replayed = false}, nil
                end
                return nil, "unexpected target"
            end)
            local first = client:invoke("bee.approvals.binding:inbox", {workspace_id = "ws"})
            test.is_true(first and first.ok)
            local first_page = (first :: Object).value :: Object
            local first_item = (first_page.changes :: {unknown})[1] :: Object
            test.eq((first_item.request :: Object).revision, 1)
            local second = client:invoke("bee.approvals.binding:inbox", {workspace_id = "ws"})
            test.is_true(second and second.ok)
            local second_page = (second :: Object).value :: Object
            local second_item = (second_page.changes :: {unknown})[1] :: Object
            test.eq((second_item.request :: Object).revision, 2)
            local third = client:invoke("bee.approvals.binding:inbox", {workspace_id = "ws"})
            test.is_true(third and third.ok)
            local third_page = (third :: Object).value :: Object
            test.is_true(third_page.replace_source :: boolean)
            test.eq(#(third_page.changes :: {unknown}), 0)
            local stale = client:invoke("bee.approvals.binding:read", {approval_id = "approval-a"})
            test.is_false(stale and stale.ok)
            test.eq(snapshots, 2)
            test.eq(reads, 2)
        end)
    end)
end
return test.run_cases(define_tests)
