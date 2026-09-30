-- MIT. The timeline model, pure: threads the caller may read, one thread's
-- records in owner order through a subscription whose cursor only the
-- owner moves, the recap checkpoint as stored, and what is not known shown
-- as such. Viewing acknowledges no delivery and settles nothing; a page
-- acknowledgment moves this viewer's own cursor and nothing else.
local json = require("json")
local text = require("text")
local caller = require("caller")
local session = require("session")
local record = require("record")
local bounds = require("bounds")
local contract = require("contract")
local record_types = require("record_types")
local format = require("format")
local M = {}
M.MAX_ROWS = 512
M.PAGE_LIMIT = 64
M.WAIT_MS = 30000
M.LIST = "bee.threads.service:list"
M.LIST_WORKSPACE = "bee.threads.service:list_workspace"
M.GET = "bee.threads.service:get"
M.SUBSCRIBE = "bee.threads.delivery:subscribe"
M.PAGE = "bee.threads.delivery:page"
M.ACK_PAGE = "bee.threads.delivery:ack_page"
M.RESUME = "bee.threads.delivery:resume"
M.WATCH = "bee.threads.delivery:watch"
M.UNSUBSCRIBE = "bee.threads.delivery:unsubscribe"
M.RECAP = "bee.threads.projection:recap_read"
type Reply = caller.Reply
type Row = format.Row
type Object = {[string]: unknown}
type Intent = {target: string, request: Object}
type ThreadState = "open" | "closed"
type Summary = {thread_id: string, title: string, state: ThreadState, head_sequence: integer, owner_id: string}
type Recap = {through_sequence: integer, revision: integer, lines: {string}, last_turn: string}
type Picker = {threads: {Summary}, selected: string?, next_after: string?, unavailable: string?}
type Phase = "picking" | "attaching" | "attached" | "resume_required" | "reset_required" | "unavailable"
type State = {
    picker: Picker, thread_id: string?, consumer_id: string, workspace_id: string?, attach_key: string?, title: string, thread_state: string, head_sequence: integer,
    phase: Phase, session: session.Session?, subscription_id: string?, rows: {Row}, dropped_through: integer, gap_after: integer?,
    recap: Recap?, unavailable: string, notice: string, selected: integer?, follow: boolean, technical: boolean,
}
type PageResult = {kind: "accepted", has_more: boolean} | {kind: "refused"}
function M.text(value: unknown, limit: integer?): string
    return text.bound(value, limit or format.LINE_LIMIT)
end
function M.new(consumer_id: string, workspace_id: string?): State
    return {picker = {threads = {}, selected = nil, next_after = nil, unavailable = nil}, thread_id = nil, consumer_id = consumer_id, workspace_id = workspace_id, attach_key = nil, title = "", thread_state = "",
        head_sequence = 0, phase = "picking", session = nil, subscription_id = nil, rows = {}, dropped_through = 0, gap_after = nil,
        recap = nil, unavailable = "", notice = "", selected = nil, follow = true, technical = false}
end
local function fault_text(reply: Reply): string
    local fault = reply.error
    if not fault then return "no answer" end
    return M.text(fault.code .. ": " .. fault.message)
end
local function object(value: unknown): Object?
    return bounds.object(value)
end
local function decode_thread_summary(value: unknown): Summary?
    local summary = object(value)
    if not summary or bounds.fields(summary, {"thread_id", "title", "state", "revision", "head_sequence", "owner_id", "created_at", "workspace_id"}) then return nil end
    local thread_id = bounds.id(summary.thread_id)
    local title = bounds.line(summary.title, bounds.MAX_TITLE_BYTES)
    local state: ThreadState? = summary.state == "open" and "open" or (summary.state == "closed" and "closed" or nil)
    local revision = bounds.count(summary.revision)
    local head_sequence = bounds.cursor(summary.head_sequence)
    local owner_id = bounds.id(summary.owner_id)
    local created_at = bounds.timestamp(summary.created_at)
    if summary.workspace_id ~= nil and not contract.workspace_id(summary.workspace_id) then return nil end
    if not thread_id or not title or not state or not revision or revision < 1 or not head_sequence or not owner_id or not created_at then return nil end
    return {thread_id = thread_id, title = title, state = state, head_sequence = head_sequence, owner_id = owner_id}
end
type ListResult = {ok: true, threads: {Summary}, next_after: string?} | {ok: false, error: string}
local function decode_list(value: unknown): ListResult
    local response = object(value)
    if not response or bounds.fields(response, {"threads", "next_after_thread_id"}) then return {ok = false, error = "thread list reply is malformed"} end
    local rows = bounds.array(response.threads, M.PAGE_LIMIT)
    if not rows then return {ok = false, error = "thread list page is malformed"} end
    local threads: {Summary} = {}
    local seen: {[string]: boolean} = {}
    for _, raw in ipairs(rows) do
        local summary = decode_thread_summary(raw)
        if not summary or seen[summary.thread_id] then return {ok = false, error = "thread list page contains a malformed or duplicate thread"} end
        seen[summary.thread_id] = true
        threads[#threads + 1] = summary
    end
    local next_after: string? = nil
    if response.next_after_thread_id ~= nil then
        next_after = bounds.id(response.next_after_thread_id)
        if not next_after then return {ok = false, error = "thread list cursor is malformed"} end
    end
    return {ok = true, threads = threads, next_after = next_after}
end
-- Picking: the workspace's threads when this viewer is bound to one, so
-- threads owned by other applications stay visible; otherwise the threads
-- the caller may read. One bounded page at a time either way.
function M.list_intent(state: State): Intent
    local request: Object = {limit = M.PAGE_LIMIT}
    if state.picker.next_after then request.after_thread_id = state.picker.next_after end
    if state.workspace_id then
        request.workspace_id = state.workspace_id
        return {target = M.LIST_WORKSPACE, request = request}
    end
    return {target = M.LIST, request = request}
end
function M.apply_list(state: State, reply: Reply): boolean
    if not reply.ok then
        state.picker.unavailable = fault_text(reply)
        return false
    end
    local result = decode_list(reply.value)
    if not result.ok then state.picker.unavailable = result.error; return false end
    state.picker.unavailable = nil
    if not state.picker.next_after then state.picker.threads = {} end
    if #state.picker.threads + #result.threads > M.MAX_ROWS then
        state.picker.unavailable = "thread list exceeds the viewer's row bound"
        return false
    end
    for _, summary in ipairs(result.threads) do state.picker.threads[#state.picker.threads + 1] = summary end
    state.picker.next_after = result.next_after
    if not state.picker.selected and state.picker.threads[1] then state.picker.selected = state.picker.threads[1].thread_id end
    return result.next_after ~= nil
end
function M.pick(state: State, thread_id: string?)
    state.picker.selected = thread_id
end
function M.picked(state: State): Summary?
    for _, summary in ipairs(state.picker.threads) do if summary.thread_id == state.picker.selected then return summary end end
    return nil
end
-- Opening a thread starts from nothing known about it; a remembered
-- subscription is resumed rather than replaced.
function M.open(state: State, thread_id: string, subscription_id: string?)
    state.thread_id = thread_id
    state.subscription_id = subscription_id
    state.attach_key = nil
    state.session = nil
    state.rows = {}
    state.dropped_through = 0
    state.gap_after = nil
    state.recap = nil
    state.selected = nil
    state.unavailable = ""
    state.notice = ""
    state.title = ""
    state.thread_state = ""
    state.head_sequence = 0
    state.phase = "attaching"
end
function M.close_thread(state: State)
    state.thread_id = nil
    state.subscription_id = nil
    state.attach_key = nil
    state.session = nil
    state.rows = {}
    state.phase = "picking"
    state.picker.next_after = nil
end
function M.get_intent(state: State): Intent?
    if not state.thread_id then return nil end
    return {target = M.GET, request = {thread_id = state.thread_id}}
end
function M.apply_get(state: State, reply: Reply)
    local response = reply.ok and object(reply.value) or nil
    local summary_value = response and not bounds.fields(response, {"summary", "membership"}) and decode_thread_summary(response.summary) or nil
    local member = response and object(response.membership) or nil
    local valid_member = member and not bounds.fields(member, {"member_id", "role", "revision", "active"})
        and bounds.id(member.member_id) ~= nil and (member.role == "owner" or member.role == "participant" or member.role == "observer")
        and bounds.count(member.revision) ~= nil and type(member.active) == "boolean"
    if not reply.ok or not summary_value or not valid_member then
        state.unavailable = reply.ok and "thread summary reply is malformed" or fault_text(reply)
        return
    end
    state.title = M.text(summary_value.title, 120)
    state.thread_state = summary_value.state
    state.head_sequence = summary_value.head_sequence
    state.unavailable = ""
end
function M.recap_intent(state: State): Intent?
    if not state.thread_id then return nil end
    return {target = M.RECAP, request = {thread_id = state.thread_id}}
end
function M.apply_recap(state: State, reply: Reply)
    if not reply.ok then state.recap = nil; return end
    local value = object(reply.value)
    local checkpoint = value and object(value.checkpoint)
    local lines_raw = checkpoint and bounds.array(checkpoint.summary_lines, 8)
    if not value or bounds.fields(value, {"through_sequence", "revision", "checkpoint", "digest", "head_sequence", "owner_authority", "owner_incarnation"})
        or not checkpoint or bounds.fields(checkpoint, {"schema", "messages", "open_requests", "answered", "deliveries", "actions", "summary_lines", "last_turn"})
        or checkpoint.schema ~= "bee.recap@1" or not lines_raw then state.recap = nil; return end
    local through = bounds.cursor(value.through_sequence)
    local revision = bounds.count(value.revision)
    local head = bounds.cursor(value.head_sequence)
    local authority = bounds.id(value.owner_authority)
    local incarnation = bounds.count(value.owner_incarnation)
    local messages, answered = bounds.count(checkpoint.messages), bounds.count(checkpoint.answered)
    local requests, deliveries, actions = object(checkpoint.open_requests), object(checkpoint.deliveries), object(checkpoint.actions)
    if not through or not revision or not head or not authority or not incarnation or not messages or not answered or not requests or not deliveries or not actions then
        state.recap = nil; return
    end
    local lines: {string} = {}
    for _, line in ipairs(lines_raw) do
        local bounded = bounds.text(line, 120)
        if bounded == nil then state.recap = nil; return end
        lines[#lines + 1] = M.text(bounded, 120)
    end
    local last_turn = ""
    if checkpoint.last_turn ~= nil then
        local turn = object(checkpoint.last_turn)
        if not turn or bounds.fields(turn, {"turn_id", "outcome"}) or not bounds.id(turn.turn_id)
            or not bounds.member(turn.outcome, {"succeeded", "failed", "cancelled", "uncertain"}) then state.recap = nil; return end
        last_turn = turn.outcome :: string
    end
    for _, key in ipairs({"claimed", "delivered", "released", "uncertain"}) do
        local count = bounds.count(deliveries[key])
        if not count then state.recap = nil; return end
    end
    state.recap = {through_sequence = through, revision = revision, lines = lines, last_turn = last_turn}
    state.head_sequence = head
end
local function decode_subscription_summary(value: unknown): session.Summary?
    local summary = object(value)
    if not summary or bounds.fields(summary, {"subscription_id", "consumer_id", "after_sequence", "lease_generation", "owner_incarnation", "owner_authority", "durability", "filter_digest", "closed"}) then return nil end
    local subscription_id = bounds.id(summary.subscription_id)
    local after_sequence = bounds.cursor(summary.after_sequence)
    local lease_generation = bounds.count(summary.lease_generation)
    local owner_incarnation = bounds.count(summary.owner_incarnation)
    local owner_authority = bounds.id(summary.owner_authority)
    if not subscription_id or not after_sequence or not lease_generation or lease_generation < 1 or not owner_incarnation or owner_incarnation < 1
        or not owner_authority or type(summary.closed) ~= "boolean" then return nil end
    return {subscription_id = subscription_id, after_sequence = after_sequence, lease_generation = lease_generation,
        owner_incarnation = owner_incarnation, owner_authority = owner_authority, closed = summary.closed}
end
-- Attaching: resume a remembered subscription, otherwise subscribe from the
-- beginning; the cursor that comes back is the owner's.
function M.attach_intent(state: State, idempotency_key: string): Intent?
    if not state.thread_id then return nil end
    state.attach_key = state.attach_key or idempotency_key
    if state.subscription_id then
        return {target = M.RESUME, request = {thread_id = state.thread_id, idempotency_key = state.attach_key, subscription_id = state.subscription_id}}
    end
    return {target = M.SUBSCRIBE, request = {thread_id = state.thread_id, idempotency_key = state.attach_key, consumer_id = state.consumer_id, after_sequence = 0, durability = "durable"}}
end
function M.apply_attach(state: State, reply: Reply)
    if not reply.ok then
        local code = reply.error and reply.error.code or ""
        if code == "NOT_FOUND" and state.subscription_id then
            -- The remembered subscription is gone at the owner; subscribe anew.
            state.subscription_id = nil
            state.attach_key = nil
            state.session = nil
            state.phase = "attaching"
            state.notice = "The owner no longer holds the remembered subscription; reading from the start"
            return
        end
        if code ~= "UNAVAILABLE" and code ~= "UNCERTAIN" and code ~= "DEADLINE_EXCEEDED" then state.attach_key = nil end
        state.phase = "unavailable"
        state.unavailable = fault_text(reply)
        return
    end
    local summary = decode_subscription_summary(reply.value)
    if not summary then state.phase = "unavailable"; state.unavailable = "the owner answered with an unreadable subscription"; return end
    if state.session and state.session.subscription_id == summary.subscription_id then
        local resumed, err = session.resumed(state.session, summary)
        state.session = resumed
        if err then state.phase = "resume_required"; state.notice = M.text(err); return end
    else
        state.session = session.attach(summary)
    end
    state.subscription_id = summary.subscription_id
    state.attach_key = nil
    if summary.after_sequence > 0 and #state.rows == 0 then state.gap_after = 0; state.dropped_through = summary.after_sequence end
    state.phase = state.session.state == "attached" and "attached" or "reset_required"
    state.unavailable = ""
end
function M.page_intent(state: State): Intent?
    if not state.thread_id or not state.session or state.phase ~= "attached" then return nil end
    return {target = M.PAGE, request = {thread_id = state.thread_id, subscription_id = state.session.subscription_id, limit = M.PAGE_LIMIT}}
end
local function append(state: State, row: Row)
    local last = state.rows[#state.rows]
    if last and row.sequence <= last.sequence then return end
    state.rows[#state.rows + 1] = row
    while #state.rows > M.MAX_ROWS do
        local dropped = table.remove(state.rows, 1)
        state.dropped_through = dropped.sequence
        if state.selected == dropped.sequence then state.selected = nil end
    end
end
-- A page counts only under the session's lease; its records fold in by
-- sequence. has_more says whether the owner has more after it.
function M.apply_page(state: State, reply: Reply): PageResult
    local current = state.session
    if not current then return {kind = "refused"} end
    if not reply.ok then
        local code = reply.error and reply.error.code or ""
        if code == "CONFLICT" or code == "INVALID_STATE" then state.phase = "resume_required"; state.notice = fault_text(reply)
        else state.phase = "unavailable"; state.unavailable = fault_text(reply) end
        return {kind = "refused"}
    end
    local value = object(reply.value)
    local invalid = value and bounds.fields(value, {"subscription_id", "page_id", "lease_generation", "from_sequence", "scanned_through", "records", "has_more"})
    local rows = value and bounds.array(value.records, M.PAGE_LIMIT)
    local subscription_id = value and bounds.id(value.subscription_id)
    local from_sequence = value and bounds.cursor(value.from_sequence)
    local scanned_through = value and bounds.cursor(value.scanned_through)
    if not value or invalid or not rows then
        state.phase = "unavailable"; state.unavailable = "thread owner returned a malformed page"; return {kind = "refused"}
    end
    if not subscription_id or subscription_id ~= current.subscription_id then
        state.phase = "unavailable"; state.unavailable = "thread owner returned a malformed page"; return {kind = "refused"}
    end
    if not from_sequence then
        state.phase = "unavailable"; state.unavailable = "thread owner returned a malformed page"; return {kind = "refused"}
    end
    if not scanned_through or scanned_through < from_sequence then
        state.phase = "unavailable"; state.unavailable = "thread owner returned a malformed page"; return {kind = "refused"}
    end
    if type(value.has_more) ~= "boolean" then
        state.phase = "unavailable"; state.unavailable = "thread owner returned a malformed page"; return {kind = "refused"}
    end
    local checked_has_more: boolean = value.has_more
    if value.page_id == nil then
        if value.lease_generation ~= nil or checked_has_more or #rows ~= 0 or scanned_through ~= from_sequence then
            state.phase = "unavailable"; state.unavailable = "thread owner returned a malformed empty page"; return {kind = "refused"}
        end
        return {kind = "accepted", has_more = checked_has_more}
    end
    local page_id = bounds.id(value.page_id)
    local lease_generation = bounds.count(value.lease_generation)
    if not page_id or not lease_generation then state.phase = "unavailable"; state.unavailable = "thread owner returned a malformed page"; return {kind = "refused"} end
    local page: session.Page = {page_id = page_id, lease_generation = lease_generation,
        from_sequence = from_sequence, scanned_through = scanned_through}
    if current.outstanding and (current.outstanding.page_id ~= page.page_id or current.outstanding.lease_generation ~= page.lease_generation
        or current.outstanding.from_sequence ~= page.from_sequence or current.outstanding.scanned_through ~= page.scanned_through) then
        state.phase = "unavailable"; state.unavailable = "thread owner changed an outstanding page"; return {kind = "refused"}
    end
    local records: {record_types.Record} = {}
    local prior = from_sequence
    for _, item in ipairs(rows) do
        local decoded = record.decode(item)
        if not decoded or decoded.thread_id ~= state.thread_id or decoded.sequence <= prior or decoded.sequence > scanned_through then
            state.phase = "unavailable"; state.unavailable = "thread owner returned a malformed page"; return {kind = "refused"}
        end
        records[#records + 1] = decoded
        prior = decoded.sequence
    end
    if page.lease_generation > current.lease_generation then
        -- A page under a newer lease proves this session's lease is fenced;
        -- only an explicit resume takes the owner's cursor again.
        state.phase = "resume_required"
        state.notice = "a newer lease holds the subscription; resume required"
        return {kind = "refused"}
    end
    local accepted, err = session.accept_page(current, page)
    if not accepted then state.notice = M.text(err); return {kind = "refused"} end
    local last = state.rows[#state.rows]
    if last and page.from_sequence > last.sequence then state.gap_after = last.sequence end
    for _, decoded in ipairs(records) do append(state, format.row(decoded)) end
    if page.scanned_through > state.head_sequence then state.head_sequence = page.scanned_through end
    state.unavailable = ""
    return {kind = "accepted", has_more = checked_has_more}
end
function M.ack_intent(state: State, idempotency_key: string): Intent?
    local current = state.session
    if not state.thread_id or not current then return nil end
    local acknowledgment = session.acknowledgment(current)
    if not acknowledgment then return nil end
    return {target = M.ACK_PAGE, request = {thread_id = state.thread_id, idempotency_key = idempotency_key, subscription_id = current.subscription_id,
        page_id = acknowledgment.page_id, scanned_through = acknowledgment.scanned_through}}
end
function M.apply_ack(state: State, reply: Reply)
    local current = state.session
    if not current then return end
    if not reply.ok then
        local code = reply.error and reply.error.code or ""
        if code == "CONFLICT" or code == "INVALID_STATE" then state.phase = "resume_required"; state.notice = fault_text(reply)
        else state.phase = "unavailable"; state.unavailable = fault_text(reply) end
        return
    end
    local value = object(reply.value)
    if not value or bounds.fields(value, {"subscription_id", "after_sequence"}) then
        state.phase = "unavailable"; state.unavailable = "thread owner returned a malformed acknowledgment"; return
    end
    local subscription_id = bounds.id(value.subscription_id)
    local after_sequence = bounds.cursor(value.after_sequence)
    local expected = session.acknowledgment(current)
    if not subscription_id or subscription_id ~= current.subscription_id or not after_sequence or not expected
        or after_sequence ~= expected.scanned_through then
        state.phase = "unavailable"; state.unavailable = "thread owner returned a malformed acknowledgment"; return
    end
    state.session = session.acknowledged(current, after_sequence)
end
-- Watching is bounded and read-only: it claims nothing for this viewer, so
-- reading a thread never takes an obligation. Its answer is only the
-- reason to page again.
function M.watch_intent(state: State): Intent?
    local current = state.session
    if not state.thread_id or not current or state.phase ~= "attached" then return nil end
    return {target = M.WATCH, request = {thread_id = state.thread_id, after_sequence = current.after_sequence, wait_ms = M.WAIT_MS}}
end
-- A bounded change-wait is a read hint: it claims nothing, and a wait that
-- ended without an answer is not evidence the owner is gone. Owner
-- availability is what attach, pages and lost() established; only they, and
-- never this hint, may change what the footer says about it.
-- Closing this viewer's own subscription when it leaves a thread; the
-- owner authorizes only the actor's own subscription. It is not sent on a
-- presenter reload, so a remembered subscription still resumes.
function M.unsubscribe_intent(state: State, idempotency_key: string): Intent?
    if not state.thread_id or not state.subscription_id then return nil end
    return {target = M.UNSUBSCRIBE, request = {thread_id = state.thread_id, idempotency_key = idempotency_key, subscription_id = state.subscription_id}}
end
-- Transport silence: the session is detached, nothing durable changes.
function M.lost(state: State)
    if state.session then state.session = session.disconnect(state.session) end
    state.unavailable = "no answer from the thread owner"
end
function M.reconnect(state: State)
    if state.session and state.session.state == "detached" then state.session.state = "attached" end
    if state.phase == "resume_required" or state.phase == "unavailable" then state.phase = "attaching" end
    if state.phase == "attaching" and state.session then state.phase = "attached" end
end
function M.retry(state: State)
    if state.phase == "resume_required" or state.phase == "unavailable" then state.phase = "attaching" end
end
function M.selected_row(state: State): Row?
    if not state.selected then return nil end
    for _, row in ipairs(state.rows) do if row.sequence == state.selected then return row end end
    return nil
end
function M.move(state: State, step: integer)
    if state.phase == "picking" then
        local keys = state.picker.threads
        if #keys == 0 then return end
        local index = 0
        for position, summary in ipairs(keys) do if summary.thread_id == state.picker.selected then index = position end end
        if index == 0 then index = step > 0 and 0 or #keys + 1 end
        index = math.floor(math.max(1, math.min(#keys, index + step)))
        state.picker.selected = keys[index].thread_id
        return
    end
    if #state.rows == 0 then return end
    local index = 0
    for position, row in ipairs(state.rows) do if row.sequence == state.selected then index = position end end
    if index == 0 then index = step > 0 and 0 or #state.rows + 1 end
    index = math.floor(math.max(1, math.min(#state.rows, index + step)))
    state.selected = state.rows[index].sequence
    state.follow = index == #state.rows
end
function M.select(state: State, sequence: integer?)
    state.selected = sequence
    if sequence ~= nil then state.follow = false end
end
function M.toggle_follow(state: State)
    state.follow = not state.follow
    if state.follow then state.selected = nil end
end
function M.toggle_technical(state: State)
    state.technical = not state.technical
end
function M.checkpoint(state: State): string
    return json.encode({thread_id = state.thread_id, subscription_id = state.subscription_id, attach_key = state.attach_key,
        selected = state.selected, follow = state.follow, technical = state.technical}) or "{}"
end
local function optional_string(value: unknown): boolean
    return value == nil or (type(value) == "string" and #(value :: string) <= 200 and not (value :: string):find("%c"))
end
function M.restore(state: State, encoded: string): boolean
    local decoded: unknown = json.decode(encoded)
    if type(decoded) ~= "table" then return false end
    local saved = decoded :: Object
    if not optional_string(saved.thread_id) or not optional_string(saved.subscription_id) or not optional_string(saved.attach_key) then return false end
    if saved.selected ~= nil and type(saved.selected) ~= "number" then return false end
    if saved.follow ~= nil and type(saved.follow) ~= "boolean" then return false end
    if saved.technical ~= nil and type(saved.technical) ~= "boolean" then return false end
    if type(saved.thread_id) == "string" and saved.thread_id ~= "" then
        M.open(state, saved.thread_id :: string, type(saved.subscription_id) == "string" and (saved.subscription_id :: string) or nil)
    end
    state.attach_key = type(saved.attach_key) == "string" and saved.attach_key or nil
    state.selected = saved.selected ~= nil and bounds.sequence(saved.selected) or nil
    state.follow = saved.follow ~= false
    state.technical = saved.technical == true
    return true
end
return M
