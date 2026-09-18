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
local format = require("format")
local M = {}
M.MAX_ROWS = 512
M.PAGE_LIMIT = 64
M.WAIT_MS = 30000
M.LIST = "bee.threads.service:list"
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
type Summary = {thread_id: string, title: string, state: string, head_sequence: integer, owner_id: string}
type Recap = {through_sequence: integer, revision: integer, lines: {string}, last_turn: string}
type Picker = {threads: {Summary}, selected: string?, next_after: string?, unavailable: string?}
type Phase = "picking" | "attaching" | "attached" | "resume_required" | "reset_required" | "unavailable"
type State = {
    picker: Picker, thread_id: string?, consumer_id: string, title: string, thread_state: string, head_sequence: integer,
    phase: Phase, session: session.Session?, subscription_id: string?, rows: {Row}, dropped_through: integer, gap_after: integer?,
    recap: Recap?, unavailable: string, notice: string, selected: integer?, follow: boolean, technical: boolean,
}
function M.text(value: unknown, limit: integer?): string
    return text.bound(value, limit or format.LINE_LIMIT)
end
function M.new(consumer_id: string): State
    return {picker = {threads = {}, selected = nil, next_after = nil, unavailable = nil}, thread_id = nil, consumer_id = consumer_id, title = "", thread_state = "",
        head_sequence = 0, phase = "picking", session = nil, subscription_id = nil, rows = {}, dropped_through = 0, gap_after = nil,
        recap = nil, unavailable = "", notice = "", selected = nil, follow = true, technical = false}
end
local function fault_text(reply: Reply): string
    local fault = reply.error
    if not fault then return "no answer" end
    return M.text(fault.code .. ": " .. fault.message)
end
local function object(value: unknown): Object
    if type(value) == "table" then return value :: Object end
    return {}
end
local function integer(value: unknown): integer
    local number = tonumber(value)
    if not number then return 0 end
    return math.floor(number)
end
-- Picking: threads the caller may read, one bounded page at a time.
function M.list_intent(state: State): Intent
    local request: Object = {limit = M.PAGE_LIMIT}
    if state.picker.next_after then request.after_thread_id = state.picker.next_after end
    return {target = M.LIST, request = request}
end
function M.apply_list(state: State, reply: Reply): boolean
    if not reply.ok or type(reply.value) ~= "table" then
        state.picker.unavailable = fault_text(reply)
        return false
    end
    state.picker.unavailable = nil
    local value = object(reply.value)
    if not state.picker.next_after then state.picker.threads = {} end
    if type(value.threads) == "table" then
        for _, item in ipairs(value.threads :: {unknown}) do
            local summary = object(item)
            local thread_id = summary.thread_id
            if type(thread_id) == "string" and thread_id ~= "" and #state.picker.threads < M.MAX_ROWS then
                state.picker.threads[#state.picker.threads + 1] = {thread_id = thread_id, title = M.text(summary.title, 120), state = M.text(summary.state, 24),
                    head_sequence = integer(summary.head_sequence), owner_id = M.text(summary.owner_id, 80)}
            end
        end
    end
    local more = type(value.next_after_thread_id) == "string" and value.next_after_thread_id ~= ""
    state.picker.next_after = more and (value.next_after_thread_id :: string) or nil
    if not state.picker.selected and state.picker.threads[1] then state.picker.selected = state.picker.threads[1].thread_id end
    return more
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
    if not reply.ok or type(reply.value) ~= "table" then state.unavailable = fault_text(reply); return end
    local summary = object(object(reply.value).summary)
    state.title = M.text(summary.title, 120)
    state.thread_state = M.text(summary.state, 24)
    state.head_sequence = integer(summary.head_sequence)
    state.unavailable = ""
end
function M.recap_intent(state: State): Intent?
    if not state.thread_id then return nil end
    return {target = M.RECAP, request = {thread_id = state.thread_id}}
end
function M.apply_recap(state: State, reply: Reply)
    if not reply.ok or type(reply.value) ~= "table" then state.recap = nil; return end
    local value = object(reply.value)
    local checkpoint = object(value.checkpoint)
    local lines: {string} = {}
    if type(checkpoint.summary_lines) == "table" then
        for _, line in ipairs(checkpoint.summary_lines :: {unknown}) do
            if #lines < 8 then lines[#lines + 1] = M.text(line, 120) end
        end
    end
    local last_turn = ""
    if type(checkpoint.last_turn) == "table" then
        local turn = object(checkpoint.last_turn)
        last_turn = M.text(turn.outcome, 16)
    end
    state.recap = {through_sequence = integer(value.through_sequence), revision = integer(value.revision), lines = lines, last_turn = last_turn}
    if value.head_sequence ~= nil then state.head_sequence = integer(value.head_sequence) end
end
local function decode_summary(value: unknown): session.Summary?
    local summary = object(value)
    if type(summary.subscription_id) ~= "string" or type(summary.owner_authority) ~= "string" then return nil end
    return {subscription_id = summary.subscription_id :: string, after_sequence = integer(summary.after_sequence), lease_generation = integer(summary.lease_generation),
        owner_incarnation = integer(summary.owner_incarnation), owner_authority = summary.owner_authority :: string, closed = summary.closed == true}
end
-- Attaching: resume a remembered subscription, otherwise subscribe from the
-- beginning; the cursor that comes back is the owner's.
function M.attach_intent(state: State, idempotency_key: string): Intent?
    if not state.thread_id then return nil end
    if state.subscription_id then
        return {target = M.RESUME, request = {thread_id = state.thread_id, idempotency_key = idempotency_key, subscription_id = state.subscription_id}}
    end
    return {target = M.SUBSCRIBE, request = {thread_id = state.thread_id, idempotency_key = idempotency_key, consumer_id = state.consumer_id, after_sequence = 0, durability = "durable"}}
end
function M.apply_attach(state: State, reply: Reply)
    if not reply.ok then
        local code = reply.error and reply.error.code or ""
        if code == "NOT_FOUND" and state.subscription_id then
            -- The remembered subscription is gone at the owner; subscribe anew.
            state.subscription_id = nil
            state.session = nil
            state.phase = "attaching"
            state.notice = "The owner no longer holds the remembered subscription; reading from the start"
            return
        end
        state.phase = "unavailable"
        state.unavailable = fault_text(reply)
        return
    end
    local summary = decode_summary(reply.value)
    if not summary then state.phase = "unavailable"; state.unavailable = "the owner answered with an unreadable subscription"; return end
    if state.session and state.session.subscription_id == summary.subscription_id then
        local resumed, err = session.resumed(state.session, summary)
        state.session = resumed
        if err then state.phase = "resume_required"; state.notice = M.text(err); return end
    else
        state.session = session.attach(summary)
    end
    state.subscription_id = summary.subscription_id
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
function M.apply_page(state: State, reply: Reply): boolean
    local current = state.session
    if not current then return false end
    if not reply.ok or type(reply.value) ~= "table" then
        local code = reply.error and reply.error.code or ""
        if code == "CONFLICT" or code == "INVALID_STATE" then state.phase = "resume_required"; state.notice = fault_text(reply)
        else state.phase = "unavailable"; state.unavailable = fault_text(reply) end
        return false
    end
    local value = object(reply.value)
    if value.page_id == nil then return false end
    local page: session.Page = {page_id = tostring(value.page_id), lease_generation = integer(value.lease_generation),
        from_sequence = integer(value.from_sequence), scanned_through = integer(value.scanned_through)}
    if page.lease_generation > current.lease_generation then
        -- A page under a newer lease proves this session's lease is fenced;
        -- only an explicit resume takes the owner's cursor again.
        state.phase = "resume_required"
        state.notice = "a newer lease holds the subscription; resume required"
        return false
    end
    local accepted, err = session.accept_page(current, page)
    if not accepted then state.notice = M.text(err); return false end
    local last = state.rows[#state.rows]
    if last and page.from_sequence > last.sequence then state.gap_after = last.sequence end
    if type(value.records) == "table" then
        for _, item in ipairs(value.records :: {unknown}) do
            local decoded = record.decode(item)
            if decoded then append(state, format.row(decoded)) end
        end
    end
    if page.scanned_through > state.head_sequence then state.head_sequence = page.scanned_through end
    state.unavailable = ""
    return value.has_more == true
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
    if not reply.ok or type(reply.value) ~= "table" then
        local code = reply.error and reply.error.code or ""
        if code == "CONFLICT" or code == "INVALID_STATE" then state.phase = "resume_required"; state.notice = fault_text(reply)
        else state.phase = "unavailable"; state.unavailable = fault_text(reply) end
        return
    end
    state.session = session.acknowledged(current, integer(object(reply.value).after_sequence))
end
-- Watching is bounded and read-only: it claims nothing for this viewer, so
-- reading a thread never takes an obligation. Its answer is only the
-- reason to page again.
function M.watch_intent(state: State): Intent?
    local current = state.session
    if not state.thread_id or not current or state.phase ~= "attached" then return nil end
    return {target = M.WATCH, request = {thread_id = state.thread_id, after_sequence = current.after_sequence, wait_ms = M.WAIT_MS}}
end
function M.apply_watch(state: State, reply: Reply)
    if reply.ok then state.unavailable = ""; return end
    state.unavailable = fault_text(reply)
end
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
function M.rows(state: State): {Row}
    return state.rows
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
    return json.encode({thread_id = state.thread_id, subscription_id = state.subscription_id, selected = state.selected, follow = state.follow, technical = state.technical}) or "{}"
end
local function optional_string(value: unknown): boolean
    return value == nil or (type(value) == "string" and #(value :: string) <= 200 and not (value :: string):find("%c"))
end
function M.restore(state: State, encoded: string): boolean
    local decoded: unknown = json.decode(encoded)
    if type(decoded) ~= "table" then return false end
    local saved = decoded :: Object
    if not optional_string(saved.thread_id) or not optional_string(saved.subscription_id) then return false end
    if saved.selected ~= nil and type(saved.selected) ~= "number" then return false end
    if saved.follow ~= nil and type(saved.follow) ~= "boolean" then return false end
    if saved.technical ~= nil and type(saved.technical) ~= "boolean" then return false end
    if type(saved.thread_id) == "string" and saved.thread_id ~= "" then
        M.open(state, saved.thread_id :: string, type(saved.subscription_id) == "string" and (saved.subscription_id :: string) or nil)
    end
    state.selected = saved.selected ~= nil and integer(saved.selected) or nil
    state.follow = saved.follow ~= false
    state.technical = saved.technical == true
    return true
end
return M
