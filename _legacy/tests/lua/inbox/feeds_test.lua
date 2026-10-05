-- MIT. The inbox feed adapter keeps an owner-qualified cache, applies typed
-- incremental events, and replaces that cache after a reset so revoked data
-- and stale route addresses disappear together.
local test = require("test")
local principals = require("principals")
local bounds = require("bounds")
local feeds = require("feeds")
local source_config = require("source_config")
local model = require("model")
type Object = {[string]: unknown}
type Source = {node_id: string, feed: string}
local function reply_code(reply: model.Reply?): string?
    if not reply or reply.kind == "success" then return nil end
    return reply.code
end
local function view(revision: integer): Object
    local state = revision == 1 and "pending" or "decided"
    return {approval_id = "approval-a", owner_node = "node-a", owner_incarnation = 1, workspace_id = "ws", requester_id = "requester",
        request_kind = "permission", policy = "policy", proposal = {kind = "operation", ref = "bee.test:run", revision = "r1", payload = {}},
        proposal_digest = string.rep("a", 64), prompt = {text = "Allow the operation?"}, revision = revision, state = state,
        decision = state == "decided" and "approved" or nil, expires_at = "2026-09-10T13:00:00.000Z",
        created_at = "2026-09-10T12:00:00.000Z"}
end
local function snapshot(source: Source, items: {Object}): Object
    return {ok = true, value = {schema = "bee.sync-snapshot@1", owner_id = source.node_id, feed = source.feed,
        cursor = #items == 0 and 2 or 1, earliest_cursor = 0, scope_revision = "scope-1", items = items,
        complete = true, reset_required = false}, replayed = false}
end
local function projection(source: Source, value: Object, sequence: integer): Object
    return {schema = "bee.sync-projection@1", owner_id = source.node_id, feed = source.feed, key = value.approval_id,
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
            test.is_true(first and first.kind == "success")
            if not first or first.kind ~= "success" then error("first inbox page failed") end
            local first_page = assert(bounds.object(first.value))
            local first_item = assert(bounds.object((principals.items(first_page.changes))[1]))
            test.eq((assert(bounds.object(first_item.request))).revision, 1)
            local second = client:invoke("bee.approvals.binding:inbox", {workspace_id = "ws"})
            test.is_true(second and second.kind == "success")
            if not second or second.kind ~= "success" then error("second inbox page failed") end
            local second_page = assert(bounds.object(second.value))
            local second_item = assert(bounds.object((principals.items(second_page.changes))[1]))
            test.eq((assert(bounds.object(second_item.request))).revision, 2)
            local third = client:invoke("bee.approvals.binding:inbox", {workspace_id = "ws"})
            test.is_true(third and third.kind == "success")
            if not third or third.kind ~= "success" then error("third inbox page failed") end
            local third_page = assert(bounds.object(third.value))
            test.is_true(third_page.replace_source)
            test.eq(#(principals.items(third_page.changes)), 0)
            local stale = client:invoke("bee.approvals.binding:read", {approval_id = "approval-a"})
            test.eq(stale and stale.kind, "failure")
            test.eq(reply_code(stale), "DENIED")
            test.eq(snapshots, 2)
            test.eq(reads, 2)
        end)
        test.it("orders complete snapshot changes by their inbox sequence", function()
            local configured = assert(source_config.configure("node-a", {"ws"}))
            local source = configured.sources.ws
            if not source then error("source configuration omitted ws") end
            local ids = {"approval-a", "approval-b", "approval-c", "approval-d", "approval-e"}
            local probe: {[string]: boolean} = {}
            for _, id in ipairs(ids) do probe[id] = true end
            local pair_order: {string} = {}
            for id in pairs(probe) do pair_order[#pair_order + 1] = id end
            local sequence_by_id: {[string]: integer} = {}
            for index, id in ipairs(pair_order) do sequence_by_id[id] = #ids - index + 1 end

            local items: {Object} = {}
            for _, id in ipairs(ids) do
                local item = view(1)
                item.approval_id = id
                local sequence = sequence_by_id[id]
                if not sequence then error("test inbox sequence is missing") end
                items[#items + 1] = projection(source, item, sequence)
            end
            local page: Object = {ok = true, value = {schema = "bee.sync-snapshot@1", owner_id = source.node_id,
                feed = source.feed, cursor = #ids, earliest_cursor = 0, scope_revision = "scope-1", items = items,
                complete = true, reset_required = false}, replayed = false}
            local client = feeds.new(configured, function(source: Source, target: string, request: unknown): (unknown, string?)
                if target == "bee.approvals.binding:feed_snapshot" then return page, nil end
                return nil, "unexpected target"
            end)

            local result = client:invoke("bee.approvals.binding:inbox", {workspace_id = "ws"})
            if not result or result.kind ~= "success" then error("complete inbox snapshot failed") end
            local previous = 0
            for _, raw in ipairs((principals.items((assert(bounds.object(result.value))).changes))) do
                local change = assert(bounds.object(raw))
                local sequence = change.seq
                test.is_true(sequence > previous, "snapshot changes are not ordered by inbox sequence")
                previous = sequence
            end
            test.eq(previous, #ids)
        end)
        test.it("rejects malformed approval projections and malformed feed pages", function()
            local configured = assert(source_config.configure("node-a", {"ws"}))
            local malformed = view(1)
            malformed.state = "unknown"
            local invalid_view = feeds.new(configured, function(source: Source, target: string, request: unknown): (unknown, string?)
                return snapshot(source, {projection(source, malformed, 1)}), nil
            end)
            local bad_snapshot = invalid_view:invoke("bee.approvals.binding:inbox", {workspace_id = "ws"})
            test.eq(bad_snapshot and bad_snapshot.kind, "failure")
            test.eq(reply_code(bad_snapshot), "RESET_REQUIRED")

            local snapshot_count = 0
            local malformed_page = feeds.new(configured, function(source: Source, target: string, request: unknown): (unknown, string?)
                if target == "bee.approvals.binding:feed_snapshot" then
                    snapshot_count = snapshot_count + 1
                    return snapshot(source, snapshot_count == 1 and {projection(source, view(1), 1)} or {}), nil
                end
                return {ok = true, value = {schema = "bee.sync-page@1", owner_id = source.node_id, feed = source.feed,
                    scope_revision = "scope-1", events = "malformed", next_cursor = 2, more = false,
                    head_cursor = 2, earliest_cursor = 0, reset_required = false}, replayed = false}, nil
            end)
            local initial = malformed_page:invoke("bee.approvals.binding:inbox", {workspace_id = "ws"})
            test.is_true(initial and initial.kind == "success")
            local reset = malformed_page:invoke("bee.approvals.binding:inbox", {workspace_id = "ws"})
            if not reset or reset.kind ~= "success" then error("reset snapshot failed") end
            local page = assert(bounds.object(reset.value))
            test.is_true(page.replace_source)
            test.eq(#(principals.items(page.changes)), 0)
            test.eq(snapshot_count, 2)
        end)
        test.it("resets owner and revision mismatches and enforces the 256 request source limit", function()
            for _, mismatch in ipairs({"owner", "revision"}) do
                local configured = assert(source_config.configure("node-a", {"ws"}))
                local snapshots = 0
                local client = feeds.new(configured, function(source: Source, target: string, request: unknown): (unknown, string?)
                    if target == "bee.approvals.binding:feed_snapshot" then
                        snapshots = snapshots + 1
                        return snapshot(source, snapshots == 1 and {projection(source, view(1), 1)} or {}), nil
                    end
                    local event_owner = mismatch == "owner" and "another-node" or source.node_id
                    local event_revision = mismatch == "revision" and 3 or 2
                    return {ok = true, value = {schema = "bee.sync-page@1", owner_id = source.node_id, feed = source.feed,
                        scope_revision = "scope-1", events = {{schema = "bee.sync-event@1", owner_id = event_owner, feed = source.feed,
                            sequence = 2, event_id = "approval-a/2", event_type = "approval.changed", projection_key = "approval-a",
                            revision = event_revision, tombstone = false, payload = {schema_revision = "bee.approval-projection@1", request = view(2)},
                            committed_at = "2026-09-10T12:01:00.000Z"}}, next_cursor = 2, more = false,
                        head_cursor = 2, earliest_cursor = 0, reset_required = false}, replayed = false}, nil
                end)
                client:invoke("bee.approvals.binding:inbox", {workspace_id = "ws"})
                local reset = client:invoke("bee.approvals.binding:inbox", {workspace_id = "ws"})
                if not reset or reset.kind ~= "success" then error("replacement snapshot failed") end
                test.is_true(((assert(bounds.object(reset.value))).replace_source))
            end

            local configured = assert(source_config.configure("node-capacity", {"ws"}))
            local snapshot_count, key = 0, 0
            local client = feeds.new(configured, function(source: Source, target: string, request: unknown): (unknown, string?)
                snapshot_count = snapshot_count + 1
                local items: {Object} = {}
                local count = snapshot_count < 5 and 64 or 1
                for _ = 1, count do
                    key = key + 1
                    local id = "approval-" .. string.format("%03d", key)
                    items[#items + 1] = projection(source, {
                        approval_id = id, owner_node = source.node_id, owner_incarnation = 1, workspace_id = "ws", requester_id = "requester",
                        request_kind = "permission", policy = "policy", proposal = {kind = "operation", ref = "bee.test:run", revision = "r1", payload = {}},
                        proposal_digest = string.rep("a", 64), prompt = {text = "Allow?"}, revision = 1, state = "pending",
                        expires_at = "2026-09-10T13:00:00.000Z", created_at = "2026-09-10T12:00:00.000Z"}, key)
                end
                local complete = snapshot_count == 5
                local result: Object = {ok = true, value = {schema = "bee.sync-snapshot@1", owner_id = source.node_id, feed = source.feed,
                    cursor = 1, earliest_cursor = 0, scope_revision = "scope-1", items = items, complete = complete, reset_required = false}, replayed = false}
                if not complete then (assert(bounds.object(result.value))).next_key = items[#items].key end
                return result, nil
            end)
            local too_many = client:invoke("bee.approvals.binding:inbox", {workspace_id = "ws"})
            test.eq(too_many and too_many.kind, "failure")
            test.eq(reply_code(too_many), "CAPACITY_EXHAUSTED")
            test.eq(key, 257)
        end)
        test.it("qualifies a committed conflict view while retaining its structured owner fault", function()
            local configured = assert(source_config.configure("node-a", {"ws"}))
            local client = feeds.new(configured, function(source: Source, target: string, request: unknown): (unknown, string?)
                if target == "bee.approvals.binding:feed_snapshot" then
                    return snapshot(source, {projection(source, view(1), 1)}), nil
                end
                if target == "bee.approvals.binding:decide" then
                    return {ok = false, error = {code = "CONFLICT", message = "request changed"},
                        value = view(2), replayed = false}, nil
                end
                return nil, "unexpected target"
            end)
            local loaded = client:invoke("bee.approvals.binding:inbox", {workspace_id = "ws"})
            test.is_true(loaded and loaded.kind == "success")
            local conflict = client:invoke("bee.approvals.binding:decide", {approval_id = "approval-a"})
            test.not_nil(conflict)
            if not conflict then error("missing decision reply") end
            test.eq(conflict.kind, "conflict")
            if conflict.kind == "conflict" then
                test.eq(conflict.code, "CONFLICT")
                test.eq(conflict.message, "request changed")
                test.eq(conflict.request.approval_id, "approval-a")
                test.eq(conflict.request.workspace_id, "ws")
            end
        end)
        test.it("routes a batch to one owner with the owner's own identities and refuses a mixed batch", function()
            local configured = assert(source_config.configure("node-a", {"ws"}, {{node_id = "node-b", workspace_id = "ws-b"}}))
            local seen: Object? = nil
            local function item(id: string, node: string, workspace: string): Object
                local value = view(1)
                value.approval_id, value.owner_node, value.workspace_id = id, node, workspace
                return value
            end
            local client = feeds.new(configured, function(source: Source, target: string, request: unknown): (unknown, string?)
                if target == "bee.approvals.binding:feed_snapshot" then
                    local remote = source.node_id == "node-b"
                    return snapshot(source, {projection(source, item(remote and "approval-b" or "approval-a", source.node_id, remote and "ws-b" or "ws"), 1),
                        projection(source, item(remote and "approval-c" or "approval-d", source.node_id, remote and "ws-b" or "ws"), 2)}), nil
                end
                if target == "bee.approvals.binding:decide_batch" then
                    seen = assert(bounds.object(request))
                    local views: {Object} = {}
                    for _, raw in ipairs((principals.objects((assert(bounds.object(request))).decisions))) do
                        if type(raw.approval_id) ~= "string" then error("invalid fixture raw.approval_id") end
                        local decided = item(raw.approval_id, source.node_id, source.node_id == "node-b" and "ws-b" or "ws")
                        decided.revision, decided.state, decided.decision = 2, "decided", "approved"
                        views[#views + 1] = decided
                    end
                    return {ok = true, value = {decisions = views}, replayed = false}, nil
                end
                return nil, "unexpected target"
            end)
            local local_page = client:invoke("bee.approvals.binding:inbox", {workspace_id = "ws"})
            test.is_true(local_page ~= nil and local_page.kind == "success")
            local remote_id: string? = nil
            for _, id in ipairs(configured.workspaces) do if id ~= "ws" then remote_id = id end end
            local remote_page = client:invoke("bee.approvals.binding:inbox", {workspace_id = remote_id})
            assert(remote_page and remote_page.kind == "success")
            local remote_changes = principals.objects((assert(bounds.object(remote_page.value))).changes)
            local remote_ui = (assert(bounds.object(remote_changes[1].request))).approval_id
            local ok = client:invoke("bee.approvals.binding:decide_batch", {decisions = {
                {approval_id = "approval-a", expected_revision = 1, proposal_digest = string.rep("a", 64), decision = "approved"},
                {approval_id = "approval-d", expected_revision = 1, proposal_digest = string.rep("a", 64), decision = "approved"}}})
            test.is_true(ok ~= nil and ok.kind == "success")
            test.eq(#(principals.items(((assert(bounds.object(seen))).decisions))), 2)
            local mixed = client:invoke("bee.approvals.binding:decide_batch", {decisions = {
                {approval_id = "approval-a", expected_revision = 1, proposal_digest = string.rep("a", 64), decision = "approved"},
                {approval_id = remote_ui, expected_revision = 1, proposal_digest = string.rep("a", 64), decision = "approved"}}})
            test.eq(reply_code(mixed), "INVALID_ARGUMENT")
            test.eq(reply_code(client:invoke("bee.approvals.binding:decide_batch", {decisions = {}})), "INVALID_ARGUMENT")
        end)
        test.it("sends lease operations to a local governance owner only", function()
            local configured = assert(source_config.configure("node-a", {"ws"}, {{node_id = "node-b", workspace_id = "ws-b"}}))
            local sent: Object? = nil
            local client = feeds.new(configured, function(_source: Source, target: string, request: unknown): (unknown, string?)
                test.eq(target, "bee.gov.binding:destination_call")
                sent = assert(bounds.object(request))
                return {ok = true, value = {leases = {}}}, nil
            end)
            local answer = assert(bounds.object(client:lease("ws", {operation = "lease_list", workspace_id = "ignored"})))
            test.is_true(answer.ok == true)
            test.eq((assert(bounds.object(sent))).workspace_id, "ws")
            local remote_id: string? = nil
            for _, id in ipairs(configured.workspaces) do if id ~= "ws" then remote_id = id end end
            test.is_nil(client:lease(remote_id, {operation = "lease_list"}))
        end)
    end)
end
return test.run_cases(define_tests)
