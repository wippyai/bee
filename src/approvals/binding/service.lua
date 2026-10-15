-- MIT. Approval operation composition and transaction boundary.
local sql = require("sql")
local funcs = require("funcs")
local json = require("json")
local process = require("process")
local events = require("events")
local logger = require("logger")
local bounds = require("bounds")
local node_database = require("node_database")
local transaction = require("transaction")
local store = require("store")
local runtime_lease = require("runtime_lease")
local lifecycle = require("lifecycle")
local dispatch = require("dispatch")
local part_decisions = require("part_decisions")
local part_effects = require("part_effects")
local part_leases = require("part_leases")
local part_model = require("part_model")
local part_queries = require("part_queries")
local part_requests = require("part_requests")
local part_retention = require("part_retention")
local part_values = require("part_values")
local part_records = require("part_records")
local part_authority = require("part_authority")
local identity = require("identity")
local M = {}
type Reply = part_model.Reply
type Result = part_model.Result
type Object = part_model.Object
type Operation = part_model.Operation
type Preparation = part_model.Preparation
local failure = part_values.failure
local storage = part_values.storage
local success = part_values.success
local now_ms = part_values.now_ms
local thread_reply = part_requests.thread_reply
local prepare_request = part_requests.prepare_request
local op_request = part_requests.op_request
local op_decide = part_decisions.op_decide
local op_decide_batch = part_decisions.op_decide_batch
local op_withdraw_origin = part_decisions.op_withdraw_origin
local op_withdraw = part_decisions.op_withdraw
local op_revalidate = part_effects.op_revalidate
local op_consume = part_effects.op_consume
local op_end = part_effects.op_end
local op_effect = part_effects.op_effect
local op_grant = part_effects.op_grant
local op_events = part_queries.op_events
local op_effect_queue = part_queries.op_effect_queue
local op_read = part_queries.op_read
local op_inbox = part_queries.op_inbox
local op_feed_snapshot = part_queries.op_feed_snapshot
local op_feed_read_after = part_queries.op_feed_read_after
local op_list = part_queries.op_list
local op_attention_count = part_queries.op_attention_count
local op_node_summary = part_queries.op_node_summary
local op_reconcile = part_retention.op_reconcile
local op_runtime_lease = part_leases.op_runtime_lease
local op_grant_window = part_leases.op_grant_window
type ApprovalState = part_model.ApprovalState
type ApprovalView = part_model.ApprovalView
type Decision = part_model.Decision
type Fault = part_model.Fault
type RequestKind = part_model.RequestKind
type Row = part_model.Row
function M.open(): (sql.DB?, string?)
    return node_database.open()
end
local actor_id = identity.actor

local function wake_worker(name: string)
    local pid, err = process.registry.lookup(name)
    if err or not pid then return end
    process.send(tostring(pid), part_model.TOPIC_WAKE, {version = 1})
end
local function wake(db: sql.DB)
    wake_worker(part_model.WORKER_NAME)
    local _, err = dispatch.deliver(db, nil)
    if err then logger:warn("Approval effect dispatch failed", {cause = err}) end
end
function M.reply(result: Result): Reply
    if result.ok then return {ok = true, error = nil, value = result.value, replayed = result.replayed} end
    return {ok = false, error = {code = result.code or "INTERNAL", message = result.message or "approval operation failed"}, value = result.value, replayed = false}
end
local operations: {[string]: Operation} = {}
local preparations: {[string]: Preparation} = {}
local mutating: {[string]: boolean} = {read = true, request = true, decide = true, decide_batch = true, withdraw = true, withdraw_origin = true, consume = true, revalidate = true,
    grant_window = true, runtime_lease = true, reconcile = true, effect = true, events = true, end_request = true, grant = true}
-- execute: one named operation for an actor over an explicit store. A
-- preparation runs first, outside the transaction, for checks that call
-- other authorities through the executor; the operation then runs inside
-- one transaction and the caller's scope answers every authority check.
function M.execute(db: sql.DB, actor: string, name: string, request: unknown, now: integer?, executor: funcs.Executor?): Result
    local operation = operations[name]
    if not operation then return failure("INVALID_ARGUMENT", "unknown operation " .. name) end
    local object = bounds.object(request == nil and {} or request)
    if not object then return failure("INVALID_ARGUMENT", "request must be an object") end
    local prepared: Object? = nil
    local preparation = preparations[name]
    if preparation then
        local outcome, refused = preparation(executor or funcs.new(), actor, object)
        if refused then return refused end
        prepared = outcome
    end
    local at = now or now_ms()
    if mutating[name] then
        return transaction.write(db, part_model.LABEL, function(tx: sql.Transaction): Result
            return operation(tx, actor, object, at, prepared)
        end)
    end
    return transaction.read(db, part_model.LABEL, function(tx: sql.Transaction): Result
        return operation(tx, actor, object, at, prepared)
    end)
end
-- A new request waiting for the person is announced on this node, so the
-- desktops working in its workspace open Needs you.
local function announce(value: unknown, db: sql.DB, requested: boolean)
    local view = bounds.object(value)
    local workspace_id = view and bounds.id(view.workspace_id) or nil
    local approval_id = view and bounds.id(view.approval_id) or nil
    if not view or not workspace_id or not approval_id then return end
    local contract = bounds.object(view.contract)
    if contract and contract.presentation ~= "inbox" then return end
    requested = requested and view.state == "pending"
    local counted = transaction.read(db, part_model.LABEL, function(tx: sql.Transaction): Result
        local at = now_ms()
        local count, err = store.attention_count(tx, workspace_id, at)
        if count == nil then return storage(err or "count attention") end
        local target: unknown = nil
        if not requested and count > 0 then
            local found, target_error = store.attention_target(tx, workspace_id, at)
            if not found then return storage(target_error or "pending attention target is missing") end
            target = found
        end
        return success({count = count, target = target}, false)
    end)
    local counts = counted.ok and bounds.object(counted.value)
    local count = counts and bounds.count(counts.count)
    if count == nil then logger:warn("Approval count not announced", {approval_id = approval_id}); return end
    local prompt = bounds.object(view.prompt)
    local effect = bounds.object(view.effect)
    local receipt = effect and bounds.object(effect.receipt)
    local proposal = bounds.object(view.proposal)
    local failed = proposal and proposal.ref == "bee.gov:establish-overlay" and effect and effect.state == "failed" and receipt and type(receipt.error) == "string"
    local target = counts and bounds.object(counts.target)
    if target and not failed then
        approval_id = bounds.id(target.approval_id)
        prompt = type(target.prompt_json) == "string" and bounds.object(json.decode(target.prompt_json)) or nil
        if not approval_id or not prompt then logger:warn("Approval target not announced"); return end
    end
    local title = prompt and bounds.line(prompt.text, 160) or nil
    if not title and prompt and type(prompt.text) == "string" then title = prompt.text:gsub("%c", " "):sub(1, 160) end
    if failed then title = "Installation failed: " .. tostring(receipt and receipt.error):gsub("%c", " "):sub(1, 138) end
    local sent, send_error = events.send(part_model.ATTENTION, failed and "approval.failed" or (requested and "approval.requested" or "approval.changed"), workspace_id,
        {approval_id = approval_id, title = title or "Review request", count = count, failed = failed == true})
    if not sent then logger:warn("Approval not announced", {approval_id = approval_id, error = tostring(send_error)}) end
end
-- Every method authenticates the caller, opens the linked owner store and
-- executes; a committed mutation wakes the outbox worker.
local function run(request: unknown, name: string): Reply
    local actor = actor_id()
    if not actor then return M.reply(failure("UNAUTHENTICATED", "no actor")) end
    local db, open_error = M.open()
    if not db then return M.reply(storage(open_error or "open approval store")) end
    local result = M.execute(db, actor, name, request, nil, nil)
    if mutating[name] and result.ok and not result.replayed then
        wake(db)
        local announced: unknown = result.value
        local envelope = bounds.object(announced)
        if name == "withdraw" then announced = envelope and envelope.request
        elseif name == "withdraw_origin" then
            local requests = envelope and bounds.array(envelope.requests, part_model.MAX_PENDING)
            for _, current in ipairs(requests or {}) do announce(current, db, false) end
            announced = nil
        elseif name == "decide_batch" then
            local decisions = envelope and bounds.array(envelope.decisions, part_model.MAX_BATCH)
            announced = decisions and decisions[1]
        end
        announce(announced, db, name == "request")
    end
    db:release()
    return M.reply(result)
end
operations.effect, operations.events, operations.end_request, operations.grant = op_effect, op_events, op_end, op_grant
operations.grant_window = op_grant_window
operations.runtime_lease = op_runtime_lease
operations.attention_count = op_attention_count
operations.node_summary = op_node_summary
operations.decide_batch = op_decide_batch
operations.withdraw_origin = op_withdraw_origin
operations.request, operations.decide, operations.withdraw, operations.consume, operations.revalidate = op_request, op_decide, op_withdraw, op_consume, op_revalidate
operations.effect_queue = op_effect_queue
operations.read, operations.inbox, operations.list, operations.reconcile = op_read, op_inbox, op_list, op_reconcile
operations.feed_snapshot, operations.feed_read_after = op_feed_snapshot, op_feed_read_after
preparations.request = prepare_request
preparations.waiting = function(executor: funcs.Executor, actor: string, object: Object): (Object?, Result?)
    if bounds.fields(object, {"thread_id"}) then return nil, failure("INVALID_ARGUMENT", "waiting needs only thread_id") end
    local id = bounds.id(object.thread_id)
    if not id then return nil, failure("INVALID_ARGUMENT", "invalid thread_id") end
    local summary, denied = thread_reply(executor, part_model.THREAD_GET, {thread_id = id})
    if not summary then return nil, denied end
    local membership = bounds.object(summary.membership)
    if not membership or membership.active ~= true then return nil, failure("DENIED", "thread membership is inactive") end
    return {thread_id = id}, nil
end
operations.waiting = function(tx: sql.Transaction, actor: string, object: Object, now: integer, prepared: Object?): Result
    if not prepared then return failure("DENIED", "thread access was not checked") end
    local rows, err = store.waiting(tx, tostring(prepared.thread_id), now)
    if not rows or err then return storage(err or "read waiting request") end
    local item = rows[1] and bounds.object(rows[1])
    if not item then return success({request = false}, false) end
    local proposal = type(item.proposal_json) == "string" and bounds.object(json.decode(item.proposal_json))
    local payload = proposal and bounds.object(proposal.payload)
    local review = payload and bounds.object(payload.review)
    local prompt = type(item.prompt_json) == "string" and bounds.object(json.decode(item.prompt_json))
    local title = review and bounds.text(review.title, 8192) or prompt and bounds.text(prompt.text, 16384)
    return success({request = {approval_id = item.approval_id, title = (title or "Review request"):gsub("%c", " "):sub(1, 160)}}, false)
end
function M.waiting(value: unknown): Reply return run(value, "waiting") end
function M.grant(value: unknown): Reply return run(value, "grant") end
function M.effect(value: unknown): Reply return run(value, "effect") end
function M.events(value: unknown): Reply return run(value, "events") end
function M.end_request(value: unknown): Reply return run(value, "end_request") end
function M.grant_window(value: unknown): Reply return run(value, "grant_window") end
function M.runtime_lease(value: unknown): Reply return run(value, "runtime_lease") end
function M.request(value: unknown): Reply return run(value, "request") end
function M.decide(value: unknown): Reply return run(value, "decide") end
function M.decide_batch(value: unknown): Reply return run(value, "decide_batch") end
function M.withdraw_origin(value: unknown): Reply return run(value, "withdraw_origin") end
function M.withdraw(value: unknown): Reply return run(value, "withdraw") end
function M.consume(value: unknown): Reply return run(value, "consume") end
function M.effect_queue(value: unknown): Reply return run(value, "effect_queue") end
function M.revalidate(value: unknown): Reply return run(value, "revalidate") end
function M.read(value: unknown): Reply return run(value, "read") end
function M.attention_count(value: unknown): Reply return run(value, "attention_count") end
function M.node_summary(value: unknown): Reply return run(value, "node_summary") end
function M.inbox(value: unknown): Reply return run(value, "inbox") end
function M.feed_snapshot(value: unknown): Reply return run(value, "feed_snapshot") end
function M.feed_read_after(value: unknown): Reply return run(value, "feed_read_after") end
function M.list(value: unknown): Reply return run(value, "list") end
function M.reconcile(value: unknown): Reply return run(value, "reconcile") end
function M.capabilities(): Reply
    return M.reply(success({
        contract_version = lifecycle.VERSION, effect_states = lifecycle.EFFECT_STATES, grant_states = lifecycle.GRANT_STATES, states = part_model.STATES, request_kinds = part_model.REQUEST_KINDS, decisions = part_model.DECISIONS, proposal_kinds = part_model.PROPOSAL_KINDS,
        bounds = {max_pending_per_requester = part_model.MAX_PENDING, max_proposal_bytes = part_model.MAX_PROPOSAL_BYTES, max_schema_bytes = part_model.MAX_SCHEMA_BYTES,
            max_inbox_page = part_model.MAX_INBOX, max_list = part_model.MAX_LIST, default_ttl_ms = part_model.DEFAULT_TTL_MS},
        expiry = "owner_reconcile", retention_ms = part_model.RETENTION_MS, dedupe_horizon = "retention_after_expiry", projection = "thread_outbox_at_least_once",
        events = "durable_cursor_at_least_once_until_acknowledged", notifications = "durable_without_thread", effect_routing = "registry_meta", consumption = "effect_owner_single_effect_key", authority = "incarnation_per_authority_start", revalidation = "effect_owner_under_current_incarnation",
    }, false))
end
M.LABEL = part_model.LABEL
M.REQUEST = part_model.REQUEST
M.DECIDE = part_model.DECIDE
M.MANAGE = part_model.MANAGE
M.OWN = part_model.OWN
M.CONSUME = part_model.CONSUME
M.WORKER_NAME = part_model.WORKER_NAME
M.AUTHORITY_NAME = part_model.AUTHORITY_NAME
M.THREAD_GET = part_model.THREAD_GET
M.THREAD_READ = part_model.THREAD_READ
M.BINDING_PAGES = part_model.BINDING_PAGES
M.TOPIC_WAKE = part_model.TOPIC_WAKE
M.ATTENTION = part_model.ATTENTION
M.DEFAULT_TTL_MS = part_model.DEFAULT_TTL_MS
M.MAX_PENDING = part_model.MAX_PENDING
M.MAX_INBOX = part_model.MAX_INBOX
M.MAX_LIST = part_model.MAX_LIST
M.MAX_BATCH = part_model.MAX_BATCH
M.MAX_PROPOSAL_BYTES = part_model.MAX_PROPOSAL_BYTES
M.MAX_SCHEMA_BYTES = part_model.MAX_SCHEMA_BYTES
M.EXPIRE_BOUND = part_model.EXPIRE_BOUND
M.RETENTION_MS = part_model.RETENTION_MS
M.REQUEST_KINDS = part_model.REQUEST_KINDS
M.DECISIONS = part_model.DECISIONS
M.PROPOSAL_KINDS = part_model.PROPOSAL_KINDS
M.STATES = part_model.STATES
M.view = part_records.view
M.establish = part_authority.establish
M.node = part_authority.node
return M
