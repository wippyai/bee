-- MIT. Typed reads over the rich thread tables. Every function runs inside
-- the caller's transaction so checks and commits see one snapshot.
local sql = require("sql")
local M = {}
type Head = {thread_id: string, owner_actor: string, title: string, state: string, revision: integer, head_sequence: integer, created_at: string,
    workspace_id: string?}
type Member = {actor: string, role: string, revision: integer, active: boolean}
type Command = {operation: string, request_json: string, reply_json: string}
type Stored = {record_id: string, sequence: integer, kind: string, record_json: string}
type Action = {action_id: string, state: string, admitted_record_id: string}
type Attempt = {attempt_id: string, action_id: string, owner_epoch: integer?, state: string}
type Turn = {turn_id: string, action_id: string, attempt_id: string, ended: boolean}
type Subscription = {subscription_id: string, actor: string, consumer_id: string, filter_digest: string, filter: string, durability: string, after_sequence: integer, lease_generation: integer, owner_incarnation: integer, closed: boolean}
type Page = {page_id: string, lease_generation: integer, from_sequence: integer, scanned_through: integer}
type Obligations = {open_actions: integer, running_attempts: integer, open_turns: integer, open_requests: integer, live_claims: integer}
type Obligation = {message_id: string, recipient_id: string, message_record_id: string, kind: string, state: string, delivery_id: string?, reply_record_id: string?, created_sequence: integer}
type Notice = {notice_id: string, watcher_actor: string, watcher_thread_id: string, watcher_action_id: string?, target_thread_id: string,
    target_action_id: string?, target_attempt_id: string?, after_sequence: integer, state: string}
type Delivery = {delivery_id: string, message_id: string, recipient_id: string, batch_id: string, consumer_id: string, claimant_actor: string, channel: string, owner_incarnation: integer, state: string, expires_at: string}
local function integer(value: unknown): integer?
    if type(value) ~= "number" or value ~= math.floor(value) then return nil end
    return math.floor(value)
end
local function text(value: unknown): string?
    if type(value) ~= "string" then return nil end
    return value
end
local function single(tx: sql.Transaction, statement: string, params: {unknown}, what: string): ({[string]: unknown}?, string?)
    local rows, query_err = tx:query(statement, params)
    if query_err or not rows then return nil, "read " .. what end
    if #rows > 1 then return nil, what .. " rows are corrupt" end
    if #rows == 0 then return nil, nil end
    return rows[1] :: {[string]: unknown}, nil
end
local HEAD_COLUMNS = "thread_id, owner_actor, title, state, revision, head_sequence, created_at, workspace_id"
local function head_row(row: {[string]: unknown}): (Head?, string?)
    local id, owner, title, state = text(row.thread_id), text(row.owner_actor), text(row.title), text(row.state)
    local revision, head_sequence, created_at = integer(row.revision), integer(row.head_sequence), text(row.created_at)
    local workspace: unknown = row.workspace_id
    if not id or not owner or not title or not state or not revision or not head_sequence or not created_at
        or (workspace ~= nil and type(workspace) ~= "string") then return nil, "thread head row is corrupt" end
    local workspace_id: string? = nil
    if type(workspace) == "string" then workspace_id = workspace end
    return {thread_id = id, owner_actor = owner, title = title, state = state, revision = revision, head_sequence = head_sequence,
        created_at = created_at, workspace_id = workspace_id}, nil
end
function M.head(tx: sql.Transaction, thread_id: string): (Head?, string?)
    local row, err = single(tx, "SELECT " .. HEAD_COLUMNS .. " FROM bee_thread_heads WHERE thread_id = ?", {thread_id}, "thread head")
    if err then return nil, err end
    if not row then return nil, nil end
    return head_row(row)
end
local function member_row(row: {[string]: unknown}): (Member?, string?)
    local actor, role, revision, active = text(row.actor), text(row.role), integer(row.revision), integer(row.active)
    if not actor or not role or not revision or not active then return nil, "thread member row is corrupt" end
    return {actor = actor, role = role, revision = revision, active = active == 1}, nil
end
function M.member(tx: sql.Transaction, thread_id: string, actor: string): (Member?, string?)
    local row, err = single(tx, "SELECT actor, role, revision, active FROM bee_thread_members WHERE thread_id = ? AND actor = ?", {thread_id, actor}, "thread member")
    if err then return nil, err end
    if not row then return nil, nil end
    return member_row(row)
end
function M.command(tx: sql.Transaction, thread_id: string, actor: string, key: string): (Command?, string?)
    local row, err = single(tx, "SELECT operation, request_json, reply_json FROM bee_thread_commands WHERE thread_id = ? AND actor = ? AND idempotency_key = ?", {thread_id, actor, key}, "thread command")
    if err then return nil, err end
    if not row then return nil, nil end
    local operation, request, reply = text(row.operation), text(row.request_json), text(row.reply_json)
    if not operation or not request or not reply then return nil, "thread command row is corrupt" end
    return {operation = operation, request_json = request, reply_json = reply}, nil
end
local function stored_row(row: {[string]: unknown}): (Stored?, string?)
    local record_id, sequence, kind, record_json = text(row.record_id), integer(row.sequence), text(row.kind), text(row.record_json)
    if not record_id or not sequence or not kind or not record_json then return nil, "thread record row is corrupt" end
    return {record_id = record_id, sequence = sequence, kind = kind, record_json = record_json}, nil
end
function M.record(tx: sql.Transaction, thread_id: string, record_id: string): (Stored?, string?)
    local row, err = single(tx, "SELECT record_id, sequence, kind, record_json FROM bee_thread_records WHERE thread_id = ? AND record_id = ?", {thread_id, record_id}, "thread record")
    if err then return nil, err end
    if not row then return nil, nil end
    return stored_row(row)
end
function M.producer_event(tx: sql.Transaction, thread_id: string, producer_id: string, scope: string, key: string): (Stored?, string?)
    local row, err = single(tx, "SELECT record_id, sequence, kind, record_json FROM bee_thread_records WHERE thread_id = ? AND producer_id = ? AND event_scope = ? AND event_key = ?", {thread_id, producer_id, scope, key}, "thread producer event")
    if err then return nil, err end
    if not row then return nil, nil end
    return stored_row(row)
end
-- Records after the cursor within a bounded window, oldest first, at most
-- limit plus one so the caller learns whether more matches follow.
function M.page(tx: sql.Transaction, thread_id: string, cursor: integer, window_end: integer, limit: integer, kinds: {string}?, action_id: string?): ({Stored}?, string?)
    local clauses = "thread_id = ? AND sequence > ? AND sequence <= ?"
    local params: {unknown} = {thread_id, cursor, window_end}
    if kinds and #kinds > 0 then
        local marks: {string} = {}
        for index, kind in ipairs(kinds) do
            marks[index] = "?"
            params[#params + 1] = kind
        end
        clauses = clauses .. " AND kind IN (" .. table.concat(marks, ",") .. ")"
    end
    if action_id then
        clauses = clauses .. " AND action_id = ?"
        params[#params + 1] = action_id
    end
    params[#params + 1] = limit + 1
    local rows, query_err = tx:query("SELECT record_id, sequence, kind, record_json FROM bee_thread_records WHERE " .. clauses .. " ORDER BY sequence LIMIT ?", params)
    if query_err or not rows then return nil, "read thread records" end
    local result: {Stored} = {}
    for index, row in ipairs(rows) do
        local stored, stored_err = stored_row(row)
        if not stored then return nil, stored_err end
        result[index] = stored
    end
    return result, nil
end
local function heads_of(rows: {{[string]: unknown}}): ({Head}?, string?)
    local heads: {Head} = {}
    for index, row in ipairs(rows) do
        local head, err = head_row(row)
        if not head then return nil, err end
        heads[index] = head
    end
    return heads, nil
end
function M.accessible_heads(tx: sql.Transaction, actor: string, after: string, limit: integer): ({Head}?, string?)
    local rows, query_err = tx:query("SELECT h.thread_id, h.owner_actor, h.title, h.state, h.revision, h.head_sequence, h.created_at, h.workspace_id FROM bee_thread_heads h " ..
        "JOIN bee_thread_members m ON m.thread_id = h.thread_id WHERE m.actor = ? AND m.active = 1 AND h.thread_id > ? ORDER BY h.thread_id LIMIT ?", {actor, after, limit + 1})
    if query_err or not rows then return nil, "read accessible threads" end
    return heads_of(rows)
end
-- The threads one workspace owns, in thread order: one range of the
-- workspace index.
M.WORKSPACE_HEADS = "SELECT " .. HEAD_COLUMNS .. " FROM bee_thread_heads WHERE workspace_id = ? AND thread_id > ? ORDER BY thread_id LIMIT ?"
function M.workspace_heads(tx: sql.Transaction, workspace_id: string, after: string, limit: integer): ({Head}?, string?)
    local rows, query_err = tx:query(M.WORKSPACE_HEADS, {workspace_id, after, limit + 1})
    if query_err or not rows then return nil, "read workspace threads" end
    return heads_of(rows)
end
function M.count(tx: sql.Transaction, statement: string, params: {unknown}, what: string): (integer?, string?)
    local rows, query_err = tx:query(statement, params)
    if query_err or not rows or #rows ~= 1 then return nil, "count " .. what end
    local value = integer(rows[1].count)
    if not value then return nil, what .. " count is corrupt" end
    return value, nil
end
function M.action(tx: sql.Transaction, thread_id: string, action_id: string): (Action?, string?)
    local row, err = single(tx, "SELECT action_id, state, admitted_record_id FROM bee_thread_actions WHERE thread_id = ? AND action_id = ?", {thread_id, action_id}, "thread action")
    if err then return nil, err end
    if not row then return nil, nil end
    local id, state, admitted = text(row.action_id), text(row.state), text(row.admitted_record_id)
    if not id or not state or not admitted then return nil, "thread action row is corrupt" end
    return {action_id = id, state = state, admitted_record_id = admitted}, nil
end
-- The admission records of every action with this identifier in the store,
-- whichever thread holds it; the authority reads the admitted principal.
M.MAX_ADMISSIONS = 16
function M.admissions(tx: sql.Transaction, action_id: string): ({string}?, string?)
    local rows, query_err = tx:query("SELECT r.record_json FROM bee_thread_actions a JOIN bee_thread_records r ON r.record_id = a.admitted_record_id WHERE a.action_id = ? LIMIT ?", {action_id, M.MAX_ADMISSIONS})
    if query_err or not rows then return nil, "read action admissions" end
    local admissions: {string} = {}
    for index, row in ipairs(rows) do
        local encoded = text(row.record_json)
        if not encoded then return nil, "action admission row is corrupt" end
        admissions[index] = encoded
    end
    return admissions, nil
end
-- The heads that hold an action with this identifier, whichever thread owns
-- it. A node-qualified address names only the action, so a remote sender that
-- holds no thread identity resolves it here before addressing the inbox.
M.MAX_ACTION_HEADS = 16
function M.action_heads(tx: sql.Transaction, action_id: string): ({Head}?, string?)
    local rows, query_err = tx:query("SELECT h.thread_id, h.owner_actor, h.title, h.state, h.revision, h.head_sequence, h.created_at, h.workspace_id " ..
        "FROM bee_thread_actions a JOIN bee_thread_heads h ON h.thread_id = a.thread_id WHERE a.action_id = ? ORDER BY a.thread_id LIMIT ?",
        {action_id, M.MAX_ACTION_HEADS})
    if query_err or not rows then return nil, "read action heads" end
    local heads: {Head} = {}
    for index, row in ipairs(rows) do
        local decoded, decode_error = head_row(row)
        if not decoded then return nil, decode_error end
        heads[index] = decoded
    end
    return heads, nil
end
function M.attempt(tx: sql.Transaction, thread_id: string, attempt_id: string): (Attempt?, string?)
    local row, err = single(tx, "SELECT attempt_id, action_id, owner_epoch, state FROM bee_thread_attempts WHERE thread_id = ? AND attempt_id = ?", {thread_id, attempt_id}, "thread attempt")
    if err then return nil, err end
    if not row then return nil, nil end
    local id, action_id, epoch, state = text(row.attempt_id), text(row.action_id), integer(row.owner_epoch), text(row.state)
    if not id or not action_id or not state then return nil, "thread attempt row is corrupt" end
    if state == "running" and not epoch then return nil, "thread attempt row is corrupt" end
    return {attempt_id = id, action_id = action_id, owner_epoch = epoch, state = state}, nil
end
-- The action's live attempt: prepared or running, at most one.
function M.running_attempt(tx: sql.Transaction, thread_id: string, action_id: string): (Attempt?, string?)
    local row, err = single(tx, "SELECT attempt_id, action_id, owner_epoch, state FROM bee_thread_attempts WHERE thread_id = ? AND action_id = ? AND state IN ('prepared', 'running')", {thread_id, action_id}, "live attempt")
    if err then return nil, err end
    if not row then return nil, nil end
    local id, epoch = text(row.attempt_id), integer(row.owner_epoch)
    if not id then return nil, "thread attempt row is corrupt" end
    return {attempt_id = id, action_id = action_id, owner_epoch = epoch, state = "running"}, nil
end
function M.highest_epoch(tx: sql.Transaction, thread_id: string, action_id: string): (integer?, string?)
    local rows, query_err = tx:query("SELECT COALESCE(MAX(owner_epoch), 0) AS count FROM bee_thread_attempts WHERE thread_id = ? AND action_id = ?", {thread_id, action_id})
    if query_err or not rows or #rows ~= 1 then return nil, "read attempt epochs" end
    local value = integer(rows[1].count)
    if not value then return nil, "attempt epoch is corrupt" end
    return value, nil
end
function M.turn(tx: sql.Transaction, thread_id: string, turn_id: string): (Turn?, string?)
    local row, err = single(tx, "SELECT turn_id, action_id, attempt_id, end_record_id FROM bee_thread_turns WHERE thread_id = ? AND turn_id = ?", {thread_id, turn_id}, "thread turn")
    if err then return nil, err end
    if not row then return nil, nil end
    local id, action_id, attempt_id = text(row.turn_id), text(row.action_id), text(row.attempt_id)
    if not id or not action_id or not attempt_id then return nil, "thread turn row is corrupt" end
    return {turn_id = id, action_id = action_id, attempt_id = attempt_id, ended = row.end_record_id ~= nil}, nil
end
function M.open_turn(tx: sql.Transaction, thread_id: string, attempt_id: string): (Turn?, string?)
    local row, err = single(tx, "SELECT turn_id, action_id, attempt_id FROM bee_thread_turns WHERE thread_id = ? AND attempt_id = ? AND end_record_id IS NULL", {thread_id, attempt_id}, "open turn")
    if err then return nil, err end
    if not row then return nil, nil end
    local id, action_id = text(row.turn_id), text(row.action_id)
    if not id or not action_id then return nil, "thread turn row is corrupt" end
    return {turn_id = id, action_id = action_id, attempt_id = attempt_id, ended = false}, nil
end
-- The latest completed attempt in owner order, for conditional continuation.
function M.latest_settled_attempt(tx: sql.Transaction, thread_id: string, action_id: string): (string?, string?)
    local row, err = single(tx, "SELECT s.attempt_id FROM bee_thread_settlements s JOIN bee_thread_records r ON r.record_id = s.record_id WHERE s.thread_id = ? AND s.action_id = ? AND s.scope = 'attempt' ORDER BY r.sequence DESC LIMIT 1", {thread_id, action_id}, "latest settled attempt")
    if err then return nil, err end
    if not row then return nil, nil end
    local id = text(row.attempt_id)
    if not id then return nil, "attempt settlement row is corrupt" end
    return id, nil
end
type CancelIntent = {attempt_id: string, idempotency_key: string?, state: string, outcome: string?}
function M.cancel_intent(tx: sql.Transaction, thread_id: string, attempt_id: string): (CancelIntent?, string?)
    local row, err = single(tx, "SELECT attempt_id, idempotency_key, state, outcome FROM bee_thread_cancel_intents WHERE thread_id = ? AND attempt_id = ?",
        {thread_id, attempt_id}, "cancel intent")
    if err then return nil, err end
    if not row then return nil, nil end
    local id, state = text(row.attempt_id), text(row.state)
    if not id or not state then return nil, "cancel intent row is corrupt" end
    local key = text(row.idempotency_key)
    local outcome = text(row.outcome)
    return {attempt_id = id, idempotency_key = key, state = state, outcome = outcome}, nil
end
function M.attempt_outcome(tx: sql.Transaction, thread_id: string, attempt_id: string): (string?, string?)
    local row, err = single(tx, "SELECT outcome FROM bee_thread_settlements WHERE thread_id = ? AND scope = 'attempt' AND attempt_id = ?", {thread_id, attempt_id}, "attempt outcome")
    if err then return nil, err end
    if not row then return nil, nil end
    local outcome = text(row.outcome)
    if outcome ~= "succeeded" and outcome ~= "failed" and outcome ~= "cancelled" and outcome ~= "uncertain" then return nil, "attempt outcome row is corrupt" end
    return outcome, nil
end
-- Placement selection belongs to the original prepared record, not to a
-- later carrier checkpoint or the host's current launch policy.
function M.attempt_prepared(tx: sql.Transaction, thread_id: string, attempt_id: string): (Stored?, string?)
    local row, err = single(tx, [[SELECT r.record_id, r.sequence, r.kind, r.record_json
        FROM bee_thread_attempts a JOIN bee_thread_records r ON r.record_id = a.prepared_record_id
        WHERE a.thread_id = ? AND a.attempt_id = ?]], {thread_id, attempt_id}, "prepared attempt record")
    if err then return nil, err end
    if not row then return nil, nil end
    return stored_row(row)
end
function M.settled(tx: sql.Transaction, thread_id: string, scope: string, action_id: string, attempt_id: string?): (Stored?, string?)
    local select = "SELECT r.record_id, r.sequence, r.kind, r.record_json FROM bee_thread_settlements s JOIN bee_thread_records r ON r.record_id = s.record_id "
    local row: {[string]: unknown}?, err: string?
    if scope == "action" then
        row, err = single(tx, select .. "WHERE s.thread_id = ? AND s.scope = 'action' AND s.action_id = ?", {thread_id, action_id}, "settlement")
    else
        row, err = single(tx, select .. "WHERE s.thread_id = ? AND s.scope = 'attempt' AND s.attempt_id = ?", {thread_id, attempt_id}, "settlement")
    end
    if err then return nil, err end
    if not row then return nil, nil end
    return stored_row(row)
end
local function obligation_row(row: {[string]: unknown}): (Obligation?, string?)
    local message_id, recipient_id, record_id = text(row.message_id), text(row.recipient_id), text(row.message_record_id)
    local kind, state, created = text(row.kind), text(row.state), integer(row.created_sequence)
    if not message_id or not recipient_id or not record_id or not kind or not state or not created then return nil, "thread obligation row is corrupt" end
    return {message_id = message_id, recipient_id = recipient_id, message_record_id = record_id, kind = kind, state = state,
        delivery_id = text(row.delivery_id), reply_record_id = text(row.reply_record_id), created_sequence = created}, nil
end
function M.obligation(tx: sql.Transaction, thread_id: string, message_id: string, recipient_id: string): (Obligation?, string?)
    local row, err = single(tx, "SELECT message_id, recipient_id, message_record_id, kind, state, delivery_id, reply_record_id, created_sequence " ..
        "FROM bee_thread_obligations WHERE thread_id = ? AND message_id = ? AND recipient_id = ?", {thread_id, message_id, recipient_id}, "thread obligation")
    if err then return nil, err end
    if not row then return nil, nil end
    return obligation_row(row)
end
-- Pending obligations of one recipient, oldest first, at most limit.
function M.pending_obligations(tx: sql.Transaction, thread_id: string, recipient_id: string, limit: integer): ({Obligation}?, string?)
    local rows, query_err = tx:query("SELECT message_id, recipient_id, message_record_id, kind, state, delivery_id, reply_record_id, created_sequence " ..
        "FROM bee_thread_obligations WHERE thread_id = ? AND recipient_id = ? AND state = 'pending' ORDER BY created_sequence LIMIT ?", {thread_id, recipient_id, limit})
    if query_err or not rows then return nil, "read pending obligations" end
    local result: {Obligation} = {}
    for index, row in ipairs(rows) do
        local obligation, obligation_err = obligation_row(row)
        if not obligation then return nil, obligation_err end
        result[index] = obligation
    end
    return result, nil
end
function M.delivery(tx: sql.Transaction, thread_id: string, delivery_id: string): (Delivery?, string?)
    local row, err = single(tx, "SELECT d.delivery_id, d.message_id, d.recipient_id, d.batch_id, d.consumer_id, b.claimant_actor, d.channel, d.owner_incarnation, d.state, d.expires_at " ..
        "FROM bee_thread_deliveries d JOIN bee_thread_claim_batches b ON b.batch_id = d.batch_id WHERE d.thread_id = ? AND d.delivery_id = ?", {thread_id, delivery_id}, "thread delivery")
    if err then return nil, err end
    if not row then return nil, nil end
    local id, message_id, recipient_id, batch_id = text(row.delivery_id), text(row.message_id), text(row.recipient_id), text(row.batch_id)
    local consumer_id, claimant, channel, state, expires = text(row.consumer_id), text(row.claimant_actor), text(row.channel), text(row.state), text(row.expires_at)
    local incarnation = integer(row.owner_incarnation)
    if not id or not message_id or not recipient_id or not batch_id or not consumer_id or not claimant or not channel or not state or not expires or not incarnation then
        return nil, "thread delivery row is corrupt"
    end
    return {delivery_id = id, message_id = message_id, recipient_id = recipient_id, batch_id = batch_id, consumer_id = consumer_id,
        claimant_actor = claimant, channel = channel, owner_incarnation = incarnation, state = state, expires_at = expires}, nil
end
function M.dispatched(tx: sql.Transaction, delivery_id: string): (boolean, string?)
    local rows, query_err = tx:query("SELECT accepted FROM bee_thread_dispatches WHERE delivery_id = ?", {delivery_id})
    if query_err or not rows then return false, "read dispatch intent" end
    return #rows > 0, nil
end
local function subscription_row(row: {[string]: unknown}): (Subscription?, string?)
    local id, actor, consumer_id, digest, filter = text(row.subscription_id), text(row.actor), text(row.consumer_id), text(row.filter_digest), text(row.filter_json)
    local durability, after, generation, incarnation = text(row.durability), integer(row.after_sequence), integer(row.lease_generation), integer(row.owner_incarnation)
    if not id or not actor or not consumer_id or not digest or not filter or not durability or not after or not generation or not incarnation then return nil, "thread subscription row is corrupt" end
    return {subscription_id = id, actor = actor, consumer_id = consumer_id, filter_digest = digest, filter = filter, durability = durability,
        after_sequence = after, lease_generation = generation, owner_incarnation = incarnation, closed = row.closed_at ~= nil}, nil
end
local SUBSCRIPTION_COLUMNS = "subscription_id, actor, consumer_id, filter_digest, filter_json, durability, after_sequence, lease_generation, owner_incarnation, closed_at"
function M.subscription(tx: sql.Transaction, thread_id: string, subscription_id: string): (Subscription?, string?)
    local row, err = single(tx, "SELECT " .. SUBSCRIPTION_COLUMNS .. " FROM bee_thread_subscriptions WHERE thread_id = ? AND subscription_id = ?", {thread_id, subscription_id}, "thread subscription")
    if err then return nil, err end
    if not row then return nil, nil end
    return subscription_row(row)
end
function M.subscription_identity(tx: sql.Transaction, thread_id: string, actor: string, consumer_id: string, filter_digest: string): (Subscription?, string?)
    local row, err = single(tx, "SELECT " .. SUBSCRIPTION_COLUMNS .. " FROM bee_thread_subscriptions WHERE thread_id = ? AND actor = ? AND consumer_id = ? AND filter_digest = ? AND closed_at IS NULL",
        {thread_id, actor, consumer_id, filter_digest}, "thread subscription")
    if err then return nil, err end
    if not row then return nil, nil end
    return subscription_row(row)
end
function M.outstanding_page(tx: sql.Transaction, subscription_id: string): (Page?, string?)
    local row, err = single(tx, "SELECT page_id, lease_generation, from_sequence, scanned_through FROM bee_thread_subscription_pages WHERE subscription_id = ? AND acknowledged = 0", {subscription_id}, "subscription page")
    if err then return nil, err end
    if not row then return nil, nil end
    local id, generation, from, through = text(row.page_id), integer(row.lease_generation), integer(row.from_sequence), integer(row.scanned_through)
    if not id or not generation or not from or not through then return nil, "subscription page row is corrupt" end
    return {page_id = id, lease_generation = generation, from_sequence = from, scanned_through = through}, nil
end
-- Terminal records still owed: one receipt per unsettled action, one per
-- running attempt, one end per open turn, one answer or abandonment per
-- open request and one terminal mark per live claim. Capacity for them is
-- reserved before new work is admitted.
function M.obligations(tx: sql.Transaction, thread_id: string): (Obligations?, string?)
    local actions, actions_err = M.count(tx, "SELECT COUNT(*) AS count FROM bee_thread_actions WHERE thread_id = ? AND state <> 'ended'", {thread_id}, "open actions")
    if not actions then return nil, actions_err end
    local attempts, attempts_err = M.count(tx, "SELECT COUNT(*) AS count FROM bee_thread_attempts WHERE thread_id = ? AND state = 'running'", {thread_id}, "running attempts")
    if not attempts then return nil, attempts_err end
    local turns, turns_err = M.count(tx, "SELECT COUNT(*) AS count FROM bee_thread_turns WHERE thread_id = ? AND end_record_id IS NULL", {thread_id}, "open turns")
    if not turns then return nil, turns_err end
    local requests, requests_err = M.count(tx, "SELECT COUNT(*) AS count FROM bee_thread_obligations WHERE thread_id = ? AND kind = 'request' AND state NOT IN ('answered', 'abandoned')", {thread_id}, "open requests")
    if not requests then return nil, requests_err end
    local claims, claims_err = M.count(tx, "SELECT COUNT(*) AS count FROM bee_thread_deliveries WHERE thread_id = ? AND state = 'claimed'", {thread_id}, "live claims")
    if not claims then return nil, claims_err end
    return {open_actions = actions, running_attempts = attempts, open_turns = turns, open_requests = requests, live_claims = claims}, nil
end
-- Records of one action after a cursor that can end a turn or an attempt;
-- messages, deliveries and approvals never do.
function M.action_records(tx: sql.Transaction, thread_id: string, action_id: string, after: integer, limit: integer): ({Stored}?, string?)
    local rows, query_err = tx:query("SELECT record_id, sequence, kind, record_json FROM bee_thread_records WHERE thread_id = ? AND action_id = ? AND sequence > ? " ..
        "AND kind IN ('observation', 'turn.end', 'receipt') ORDER BY sequence LIMIT ?", {thread_id, action_id, after, limit})
    if query_err or not rows then return nil, "read action records" end
    local stored: {Stored} = {}
    for index, row in ipairs(rows) do
        local item, item_err = stored_row(row :: {[string]: unknown})
        if not item then return nil, item_err end
        stored[index] = item
    end
    return stored, nil
end
-- Records of one exact attempt after a cursor that can end a turn or attempt.
-- Attempt-addressed notices use this while the gateway session is not bound.
function M.attempt_records(tx: sql.Transaction, thread_id: string, attempt_id: string, after: integer, limit: integer): ({Stored}?, string?)
    local rows, query_err = tx:query("SELECT record_id, sequence, kind, record_json FROM bee_thread_records WHERE thread_id = ? AND attempt_id = ? AND sequence > ? " ..
        "AND kind IN ('observation', 'turn.end', 'receipt') ORDER BY sequence LIMIT ?", {thread_id, attempt_id, after, limit})
    if query_err or not rows then return nil, "read attempt records" end
    local stored: {Stored} = {}
    for index, row in ipairs(rows) do
        local item, item_err = stored_row(row :: {[string]: unknown})
        if not item then return nil, item_err end
        stored[index] = item
    end
    return stored, nil
end
-- The action's most recent settlement, attempt or action scope, by sequence.
function M.latest_settlement(tx: sql.Transaction, thread_id: string, action_id: string): (Stored?, string?)
    local row, err = single(tx, "SELECT r.record_id, r.sequence, r.kind, r.record_json FROM bee_thread_settlements s JOIN bee_thread_records r ON r.record_id = s.record_id " ..
        "WHERE s.thread_id = ? AND s.action_id = ? ORDER BY r.sequence DESC LIMIT 1", {thread_id, action_id}, "latest settlement")
    if err then return nil, err end
    if not row then return nil, nil end
    return stored_row(row)
end
local function notice_row(row: {[string]: unknown}): (Notice?, string?)
    local id, watcher, watcher_thread, target_thread = text(row.notice_id), text(row.watcher_actor), text(row.watcher_thread_id), text(row.target_thread_id)
    local target_action, target_attempt = text(row.target_action_id), text(row.target_attempt_id)
    local after, state = integer(row.after_sequence), text(row.state)
    if not id or not watcher or not watcher_thread or not target_thread or (not target_action and not target_attempt) or not after or not state then
        return nil, "thread notice row is corrupt"
    end
    return {notice_id = id, watcher_actor = watcher, watcher_thread_id = watcher_thread, watcher_action_id = text(row.watcher_action_id),
        target_thread_id = target_thread, target_action_id = target_action, target_attempt_id = target_attempt, after_sequence = after, state = state}, nil
end
function M.notice(tx: sql.Transaction, notice_id: string): (Notice?, string?)
    local row, err = single(tx, "SELECT * FROM bee_thread_notices WHERE notice_id = ?", {notice_id}, "thread notice")
    if err then return nil, err end
    if not row then return nil, nil end
    return notice_row(row)
end
-- Pending notices on one target thread, or on every thread when none is named.
function M.pending_notices(tx: sql.Transaction, target_thread_id: string?, limit: integer): ({Notice}?, string?)
    local rows: {unknown}?, query_err: string?
    if target_thread_id then
        rows, query_err = tx:query("SELECT * FROM bee_thread_notices WHERE target_thread_id = ? AND state = 'pending' ORDER BY created_at, notice_id LIMIT ?", {target_thread_id, limit})
    else
        rows, query_err = tx:query("SELECT * FROM bee_thread_notices WHERE state = 'pending' ORDER BY created_at, notice_id LIMIT ?", {limit})
    end
    if query_err or not rows then return nil, "read pending notices" end
    local notices: {Notice} = {}
    for index, row in ipairs(rows) do
        local notice, notice_err = notice_row(row :: {[string]: unknown})
        if not notice then return nil, notice_err end
        notices[index] = notice
    end
    return notices, nil
end
return M
