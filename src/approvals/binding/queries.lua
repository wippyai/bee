-- MIT. Queries for the approvals authority.
local sql = require("sql")
local hash = require("hash")
local json = require("json")
local security = require("security")
local events = require("events")
local bounds = require("bounds")
local canonical = require("canonical")
local resources = require("resources")
local store = require("store")
local part_authority = require("part_authority")
local part_model = require("part_model")
local part_projections = require("part_projections")
local part_records = require("part_records")
local part_values = require("part_values")
local M = {}
type Result = part_model.Result
type Object = part_model.Object
type Row = part_model.Row
local failure = part_values.failure
local storage = part_values.storage
local success = part_values.success
local stamp = part_values.stamp
local node = part_values.node
local text = part_values.text
local integer = part_values.integer
local decode_row = part_records.decode_row
local load = part_records.load
local authenticated_definition = part_authority.authenticated_definition
local eligible = part_authority.eligible
local expire_if_due = part_projections.expire_if_due
local function op_events(tx: sql.Transaction, actor: string, object: Object, now: integer, prepared: Object?): Result
    local extra = bounds.fields(object, {"cursor", "limit", "destination", "acknowledge"})
    if extra then return failure("INVALID_ARGUMENT", extra) end
    local destination = object.destination == nil and "requester:" .. actor or bounds.id(object.destination)
    if not destination then return failure("INVALID_ARGUMENT", "destination is invalid") end
    if destination ~= "requester:" .. actor then
        local consumer, err = resources.consumer(destination)
        if not consumer then return failure("INVALID_ARGUMENT", err or "consumer is missing") end
        if not security.can(part_model.OWN, destination) then return failure("DENIED", "caller cannot read this destination's events") end
    end
    local acknowledged = bounds.array(object.acknowledge == nil and {} or object.acknowledge, 64)
    if not acknowledged then return failure("INVALID_ARGUMENT", "acknowledge must be an event id list") end
    for _, raw in ipairs(acknowledged) do
        local id = bounds.line(raw, 512)
        if not id then return failure("INVALID_ARGUMENT", "acknowledge needs event ids") end
        local _, err = tx:execute("UPDATE bee_approval_events SET acknowledged_at = COALESCE(acknowledged_at, ?) WHERE event_id = ? AND destination = ?", {stamp(now), id, destination})
        if err then return storage("acknowledge notification") end
    end
    local cursor = bounds.count(object.cursor == nil and 0 or object.cursor)
    local limit = bounds.integer(object.limit == nil and 64 or object.limit)
    if not cursor or not limit or limit < 1 or limit > 64 then return failure("INVALID_ARGUMENT", "cursor and limit are invalid") end
    local rows, err = tx:query("SELECT * FROM bee_approval_events WHERE destination = ? AND seq > ? ORDER BY seq LIMIT ?", {destination, cursor, limit})
    if not rows or err then return storage("read lifecycle events") end
    local events: {Object} = {}
    for _, raw in ipairs(rows) do
        local row = bounds.object(raw)
        local sequence = row and bounds.count(row.seq) or nil
        local body = row and type(row.body_json) == "string" and bounds.object(json.decode(row.body_json)) or nil
        if not row or not sequence or not body then return storage("lifecycle event is corrupt") end
        events[#events + 1] = {event_id = row.event_id, sequence = sequence, kind = row.kind, body = body, acknowledged_at = row.acknowledged_at}
        cursor = sequence
    end
    return success({events = events, cursor = cursor}, false)
end
local function op_effect_queue(tx: sql.Transaction, actor: string, object: Object, now: integer, prepared: Object?): Result
    local extra = bounds.fields(object, {"destination", "limit", "phase"})
    if extra then return failure("INVALID_ARGUMENT", extra) end
    local destination = bounds.id(object.destination)
    local limit = bounds.integer(object.limit == nil and 16 or object.limit)
    local phase = bounds.member(object.phase == nil and "all" or object.phase, {"all", "ready", "ended"})
    if not destination or not limit or limit < 1 or limit > 64 or not phase then return failure("INVALID_ARGUMENT", "destination, phase and limit are invalid") end
    local consumer, consumer_error = resources.consumer(destination)
    if not consumer then return failure("INVALID_ARGUMENT", consumer_error or "effect consumer is missing") end
    if not security.can(part_model.OWN, destination) then return failure("DENIED", "caller cannot enumerate this effect destination") end
    local rows, err = tx:query([[SELECT r.* FROM bee_approval_requests r JOIN bee_approval_effects e ON e.approval_id = r.approval_id
        WHERE e.destination = ? AND r.state <> 'pending' AND r.effect_completed_at IS NULL
        AND (r.consumer_id IS NULL OR r.consumer_id = r.requester_id OR r.consumer_id = ?)
        AND (? = 'all' OR (? = 'ready' AND e.state NOT IN ('canceled','uncertain')) OR (? = 'ended' AND e.state = 'canceled'))
        ORDER BY r.approval_id LIMIT ?]], {destination, actor, phase, phase, phase, limit})
    if not rows or err then return storage("read effect destination queue") end
    local effects: {Object} = {}
    for _, raw in ipairs(rows) do
        local row, decode_error = decode_row(raw, tx)
        if not row then return storage(decode_error or "decode effect") end
        if row.proposal.ref ~= consumer.operation_ref then return storage("effect destination operation differs") end
        effects[#effects + 1] = part_records.view(row)
    end
    return success({effects = effects}, false)
end
local function may_read(actor: string, row: Row): (boolean, string?)
    if row.requester_id == actor then return true, nil end
    if security.can(part_model.MANAGE, text(row.workspace_id) or "") then return true, nil end
    return eligible(actor, row)
end
local function op_read(tx: sql.Transaction, actor: string, object: Object, now: integer, prepared: Object?): Result
    local unknown_field = bounds.fields(object, {"approval_id"})
    if unknown_field then return failure("INVALID_ARGUMENT", unknown_field) end
    local approval_id = bounds.id(object.approval_id)
    if not approval_id then return failure("INVALID_ARGUMENT", "approval_id is not an identifier") end
    local row, load_error = load(tx, approval_id)
    if load_error then return storage(load_error) end
    if not row then return failure("NOT_FOUND", "approval request does not exist") end
    local allowed, policy_error = may_read(actor, row)
    if policy_error then return storage(policy_error) end
    if not allowed then return failure("DENIED", "caller may not read this request") end
    local current, expire_error, expired_now = expire_if_due(tx, row, now)
    if not current then return storage(expire_error or "expire approval") end
    return success(part_records.view(current), not expired_now)
end
-- inbox: an approver's bounded catch-up over one workspace's changes; a
-- cursor older than the retained window asks for a reset instead of
-- skipping changes.
local function op_inbox(tx: sql.Transaction, actor: string, object: Object, now: integer, prepared: Object?): Result
    local unknown_field = bounds.fields(object, {"workspace_id", "after_seq", "limit"})
    if unknown_field then return failure("INVALID_ARGUMENT", unknown_field) end
    local workspace_id = bounds.id(object.workspace_id)
    if not workspace_id then return failure("INVALID_ARGUMENT", "workspace_id is not an identifier") end
    local after = bounds.integer(object.after_seq == nil and 0 or object.after_seq)
    if not after or after < 0 then return failure("INVALID_ARGUMENT", "after_seq must be a nonnegative integer") end
    local limit = bounds.integer(object.limit == nil and part_model.MAX_INBOX or object.limit)
    if not limit or limit < 1 or limit > part_model.MAX_INBOX then return failure("INVALID_ARGUMENT", "limit must be between 1 and " .. tostring(part_model.MAX_INBOX)) end
    if not security.can(part_model.DECIDE, workspace_id) then return failure("DENIED", "caller may not read the inbox of workspace " .. workspace_id) end
    local owner, node_error = node()
    if not owner then return failure("UNAVAILABLE", node_error or "native node identity is unavailable") end
    local raw_oldest, oldest_error = store.oldest_inbox(tx, workspace_id)
    if oldest_error then return storage("read inbox") end
    local oldest_seq = raw_oldest == nil and nil or integer(raw_oldest)
    if raw_oldest ~= nil and oldest_seq == nil then return storage("oldest inbox position is corrupt") end
    if oldest_seq and after > 0 and after < oldest_seq - 1 then return failure("RESET_REQUIRED", "changes before " .. tostring(oldest_seq) .. " are compacted", {oldest_seq = oldest_seq}) end
    local rows, rows_error = store.inbox_after(tx, workspace_id, after, limit)
    if rows_error or not rows then return storage("read inbox") end
    local changes: {Object} = {}
    local next_seq = after
    for _, raw in ipairs(rows) do
        local change = bounds.object(raw)
        local sequence = change and bounds.count(change.seq)
        local approval_id = change and bounds.id(change.approval_id)
        local revision = change and bounds.count(change.revision)
        local at = change and bounds.timestamp(change.at)
        if not sequence or sequence <= next_seq or not approval_id or not revision or revision < 1 or not at then
            return storage("approval inbox entry is corrupt")
        end
        next_seq = sequence
        local row, load_error = load(tx, approval_id)
        if load_error then return storage(load_error) end
        if row and row.owner_node == owner then
            local visible, policy_error = eligible(actor, row)
            if policy_error then return storage(policy_error) end
            if visible then changes[#changes + 1] = {seq = sequence, approval_id = approval_id, revision = row.revision, at = at, request = part_records.view(row)} end
        end
    end
    return success({changes = changes, next_seq = next_seq, more = #rows == limit}, false)
end
-- list: the requester's own requests, newest first, bounded.
-- A visibility-scoped snapshot/feed adapter over the approval owner's existing
-- transactional ledger. It never copies approval authority into the sync store.
local function feed_scope(actor: string, workspace: string): (string?, string?, string?, Result?)
    local native, native_error = node()
    if not native then return nil, nil, nil, failure("UNAVAILABLE", "native node identity unavailable: " .. tostring(native_error)) end
    if not security.can(part_model.DECIDE, workspace) then return nil, nil, nil, failure("DENIED", "caller may not read this workspace inbox") end
    local policies, policy_error = resources.policies()
    if not policies then return nil, nil, nil, storage(policy_error or "read approver policies") end
    local encoded, encode_error = canonical.encode({actor = actor, definition_id = authenticated_definition(actor),
        workspace = workspace, policies = policies})
    if not encoded then return nil, nil, nil, storage(encode_error or "encode approval visibility") end
    local scope, scope_error = hash.sha256(encoded)
    local feed, feed_error = hash.sha256(workspace)
    if not scope or scope_error or not feed or feed_error then return nil, nil, nil, storage("measure approval visibility") end
    return "approvals." .. feed, scope, native, nil
end
local function inbox_head(tx: sql.Transaction): (integer?, Result?)
    local raw, exists, err = store.inbox_head(tx)
    if err then return nil, storage("read inbox watermark") end
    if not exists then return 0, nil end
    local cursor = bounds.count(raw)
    if cursor == nil then return nil, storage("inbox watermark is corrupt") end
    return cursor, nil
end
local function op_feed_snapshot(tx: sql.Transaction, actor: string, object: Object, now: integer, prepared: Object?): Result
    local extra = bounds.fields(object, {"workspace_id", "limit", "after_key", "expected_cursor", "expected_scope_revision"})
    if extra then return failure("INVALID_ARGUMENT", extra) end
    local workspace = bounds.id(object.workspace_id)
    local parsed_limit = bounds.integer(object.limit == nil and 64 or object.limit)
    local after = object.after_key == nil and "" or bounds.id(object.after_key)
    if not workspace then return failure("INVALID_ARGUMENT", "invalid snapshot workspace") end
    if not parsed_limit then return failure("INVALID_ARGUMENT", "invalid snapshot limit") end
    local fetch_limit: integer = parsed_limit + 1
    if parsed_limit < 1 or parsed_limit > 64 then return failure("INVALID_ARGUMENT", "snapshot limit must be between 1 and 64") end
    if not after then return failure("INVALID_ARGUMENT", "invalid snapshot after_key") end
    local limit: integer = parsed_limit
    local feed, scope, owner, refused = feed_scope(actor, workspace)
    if not feed or not scope or not owner then return refused or storage("read feed scope") end
    local cursor, cursor_error = inbox_head(tx)
    if not cursor then return cursor_error or storage("read inbox watermark") end
    if object.expected_cursor ~= nil and bounds.count(object.expected_cursor) == nil then return failure("INVALID_ARGUMENT", "invalid expected_cursor") end
    if object.expected_scope_revision ~= nil and (type(object.expected_scope_revision) ~= "string" or
        #object.expected_scope_revision ~= 64 or not object.expected_scope_revision:match("^[0-9a-f]+$")) then
        return failure("INVALID_ARGUMENT", "invalid expected_scope_revision")
    end
    if after ~= "" and (object.expected_cursor == nil or object.expected_scope_revision == nil) then return failure("INVALID_ARGUMENT", "snapshot continuation requires cursor and scope revision") end
    if (object.expected_cursor ~= nil and object.expected_cursor ~= cursor) or
        (object.expected_scope_revision ~= nil and object.expected_scope_revision ~= scope) then
        return failure("RESET_REQUIRED", "snapshot changed; restart from its first page")
    end
    local rows, err = store.snapshot(tx, owner, workspace, after, fetch_limit)
    if err or not rows then return storage("read approval snapshot") end
    local items: {Object} = {}
    local next_key: string? = nil
    local page_bytes, truncated = 0, false
    for index, raw in ipairs(rows) do
        if index > limit then break end
        local row, decode_error = decode_row(raw, tx)
        if not row then return storage("decode approval snapshot: " .. tostring(decode_error)) end
        local raw_row = bounds.object(raw)
        local sequence = raw_row and bounds.count(raw_row.last_sequence)
        if not sequence then return storage("approval projection has no valid ledger position") end
        local visible, policy_error = eligible(actor, row)
        if policy_error then return storage(policy_error) end
        if visible then
            local item: Object = {schema = "bee.sync-projection@1", owner_id = owner, feed = feed,
                key = row.approval_id, revision = row.revision, value = part_records.view(row), tombstone = false,
                sequence = sequence, updated_at = row.updated_at}
        local encoded = canonical.encode(item, 196608)
            if not encoded then return storage("encode approval projection") end
            if #encoded > 196608 then return failure("CAPACITY_EXHAUSTED", "approval projection exceeds feed capacity") end
            if page_bytes + #encoded > 196608 then truncated = true; break end
            page_bytes = page_bytes + #encoded
            items[#items + 1] = item
        end
        next_key = text(row.approval_id)
    end
    local _, checked_scope, checked_owner, checked_error = feed_scope(actor, workspace)
    if checked_error then return checked_error end
    if checked_scope ~= scope or checked_owner ~= owner then return failure("RESET_REQUIRED", "approval visibility changed") end
    return success({schema = "bee.sync-snapshot@1", owner_id = owner, feed = feed, cursor = cursor,
        earliest_cursor = 0, scope_revision = scope, items = items, complete = not truncated and #rows <= limit,
        next_key = (truncated or #rows > limit) and next_key or nil, reset_required = false}, false)
end
local function op_feed_read_after(tx: sql.Transaction, actor: string, object: Object, now: integer, prepared: Object?): Result
    local extra = bounds.fields(object, {"workspace_id", "cursor", "limit", "expected_scope_revision"})
    if extra then return failure("INVALID_ARGUMENT", extra) end
    local workspace, cursor = bounds.id(object.workspace_id), bounds.count(object.cursor)
    if not workspace or not cursor then return failure("INVALID_ARGUMENT", "invalid feed request") end
    if type(object.expected_scope_revision) ~= "string" or #object.expected_scope_revision ~= 64 or
        not object.expected_scope_revision:match("^[0-9a-f]+$") then return failure("INVALID_ARGUMENT", "invalid expected_scope_revision") end
    local feed, scope, owner, refused = feed_scope(actor, workspace)
    if not feed or not scope or not owner then return refused or storage("read feed scope") end
    if object.expected_scope_revision ~= scope then return failure("RESET_REQUIRED", "take a snapshot of the current approval visibility") end
    local page = op_inbox(tx, actor, {workspace_id = workspace, after_seq = cursor, limit = object.limit}, now, nil)
    if not page.ok then return page end
    local value = bounds.object(page.value)
    if not value then return storage("read approval page") end
    local changes = value.changes
    local events: {Object} = {}
    local page_bytes, truncated = 0, false
    local next_cursor = value.next_seq
    for _, change in ipairs(changes) do
        local request = bounds.object(change.request)
        if not request then return storage("read approval change") end
        local item: Object = {schema = "bee.sync-event@1", owner_id = owner, feed = feed, sequence = change.seq,
            event_id = tostring(change.approval_id) .. "/" .. tostring(change.seq), event_type = "approval.changed",
            projection_key = change.approval_id, revision = request.revision, tombstone = false,
            payload = {schema_revision = "bee.approval-projection@1", request = request}, committed_at = change.at}
            local encoded = canonical.encode(item, 196608)
        if not encoded then return storage("encode approval event") end
        if #encoded > 196608 then return failure("CAPACITY_EXHAUSTED", "approval event exceeds feed capacity") end
        if page_bytes + #encoded > 196608 then
            truncated = true
            next_cursor = events[#events].sequence
            break
        end
        page_bytes = page_bytes + #encoded
        events[#events + 1] = item
    end
    local head, head_error = inbox_head(tx)
    if not head then return head_error or storage("read inbox watermark") end
    if cursor > head then return failure("INVALID_ARGUMENT", "cursor is ahead of the inbox") end
    local _, checked_scope, checked_owner, checked_error = feed_scope(actor, workspace)
    if checked_error then return checked_error end
    if checked_scope ~= scope or checked_owner ~= owner then return failure("RESET_REQUIRED", "approval visibility changed") end
    return success({schema = "bee.sync-page@1", owner_id = owner, feed = feed, scope_revision = scope,
        events = events, next_cursor = next_cursor, more = truncated or value.more, head_cursor = head,
        earliest_cursor = 0, reset_required = false}, false)
end
local function op_list(tx: sql.Transaction, actor: string, object: Object, now: integer, prepared: Object?): Result
    local unknown_field = bounds.fields(object, {"workspace_id", "limit"})
    if unknown_field then return failure("INVALID_ARGUMENT", unknown_field) end
    local limit = bounds.integer(object.limit == nil and part_model.MAX_LIST or object.limit)
    if not limit or limit < 1 or limit > part_model.MAX_LIST then return failure("INVALID_ARGUMENT", "limit must be between 1 and " .. tostring(part_model.MAX_LIST)) end
    local workspace_id: string? = nil
    if object.workspace_id ~= nil then
        workspace_id = bounds.id(object.workspace_id)
        if not workspace_id then return failure("INVALID_ARGUMENT", "workspace_id is not an identifier") end
    end
    local rows, err = store.list(tx, actor, workspace_id, limit)
    if err or not rows then return storage("list approval requests") end
    local views: {Object} = {}
    for _, raw in ipairs(rows) do
        local row, decode_error = decode_row(raw, tx)
        if not row then return storage("decode approval list: " .. tostring(decode_error)) end
        views[#views + 1] = part_records.view(row)
    end
    return success({requests = views}, false)
end
local function op_attention_count(tx: sql.Transaction, actor: string, object: Object, now: integer, _: Object?): Result
    local workspace = bounds.id(object.workspace_id)
    if not workspace or bounds.fields(object, {"workspace_id"}) then return failure("INVALID_ARGUMENT", "attention count needs one workspace") end
    if not security.can("bee.approvals.attention", workspace) then return failure("DENIED", "caller may not count this workspace's attention") end
    local count, count_error = store.attention_count(tx, workspace, now)
    if count_error or count == nil then return storage(count_error or "count attention") end
    return success({count = count}, false)
end
local function op_node_summary(tx: sql.Transaction, _: string, object: Object, now: integer, _prepared: Object?): Result
    if next(object) ~= nil then return failure("INVALID_ARGUMENT", "node summary accepts an empty object") end
    if not security.can("bee.approvals.summary", "node") then return failure("DENIED", "caller may not summarize node approvals") end
    local current, node_error = node()
    if not current then return failure("UNAVAILABLE", node_error or "node identity is unavailable") end
    local count, count_error = store.node_pending_count(tx, current, now)
    if count == nil then return storage(count_error or "count node pending approvals") end
    return success({pending_approvals = count}, false)
end
M.op_attention_count = op_attention_count
M.op_effect_queue = op_effect_queue
M.op_events = op_events
M.op_feed_read_after = op_feed_read_after
M.op_feed_snapshot = op_feed_snapshot
M.op_inbox = op_inbox
M.op_list = op_list
M.op_node_summary = op_node_summary
M.op_read = op_read
return M
