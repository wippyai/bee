-- MIT. The approvals inbox model, pure: what the viewer sees of the owner's
-- requests, what may be asked of the owner and when, and how every reply
-- is folded back. Decision authority stays with the approval owner: the
-- model holds a viewed revision and one in-flight request, never a
-- decision of its own. Every text from a request is bounded and stripped
-- of control sequences before it reaches a frame, and a proposal payload
-- is rendered only as bounded key and value lines.
local json = require("json")
local text = require("text")
local M = {}
M.TEXT_LIMIT = 512
M.LINE_LIMIT = 160
M.MAX_ROWS = 256
M.MAX_PAYLOAD_LINES = 24
M.INBOX_PAGE = 64
type Object = {[string]: unknown}
type Reply = {ok: boolean, error: {code: string, message: string}?, value: unknown, replayed: boolean?}
-- A row is the viewer's summary of one request at the revision last seen.
type Row = {
    approval_id: string,
    workspace_id: string,
    seq: integer,
    revision: integer,
    state: string,
    decision: string?,
    decider_id: string?,
    request_kind: string,
    requester_id: string,
    owner_node: string,
    owner_incarnation: integer,
    policy: string,
    expires_at: string,
    created_at: string,
    effect: string,
    target: string,
    prompt: string,
    view: Object,
}
-- One request in flight toward the owner; its answer, or the read that
-- recovers an ambiguous answer, settles it.
type Pending = {kind: string, request_id: string, approval_id: string, revision: integer, decision: string?}
type Intent = {target: string, request: Object}
type Confirmation = {approval_id: string, revision: integer, proposal_digest: string, owner_node: string, owner_incarnation: integer}
type State = {
    workspaces: {string},
    cursors: {[string]: integer},
    unavailable: {[string]: string},
    rows: {[string]: Row},
    selected: string?,
    detail: Object?,
    technical: boolean,
    pending: Pending?,
    notice: string,
}
-- Bounded text with every control character, including escape sequences,
-- replaced by a space, cut at a character boundary.
function M.text(value: unknown, limit: integer?): string
    return text.bound(value, limit or M.TEXT_LIMIT)
end
local function object(value: unknown): Object
    if type(value) == "table" then return value :: Object end
    return {}
end
local function integer(value: unknown): integer
    local number = tonumber(value)
    if number == nil or number ~= number then return 0 end
    return math.floor(number)
end
-- The proposed effect in words: the tool or operation, then the target.
local function effect_of(view: Object): (string, string)
    local proposal = object(view.proposal)
    local payload = object(proposal.payload)
    local effect = M.text(payload.tool_name or payload.operation or proposal.kind or view.request_kind, M.LINE_LIMIT)
    local target = M.text(proposal.ref or "", M.LINE_LIMIT)
    if proposal.action_id ~= nil then target = target .. " action " .. M.text(proposal.action_id, M.LINE_LIMIT) end
    return effect, target
end
function M.summary(view: Object, seq: integer): Row
    local effect, target = effect_of(view)
    local prompt = object(view.prompt)
    local decision: string? = nil
    if view.decision ~= nil then decision = M.text(view.decision, 40) end
    local decider: string? = nil
    if view.decider_id ~= nil then decider = M.text(view.decider_id, 200) end
    local row: Row = {approval_id = M.text(view.approval_id, 200), workspace_id = M.text(view.workspace_id, 200), seq = seq, revision = integer(view.revision),
        state = M.text(view.state, 40), decision = decision, decider_id = decider,
        request_kind = M.text(view.request_kind, 40), requester_id = M.text(view.requester_id, 200), owner_node = M.text(view.owner_node, 200),
        owner_incarnation = integer(view.owner_incarnation), policy = M.text(view.policy, 200), expires_at = M.text(view.expires_at, 40), created_at = M.text(view.created_at, 40),
        effect = effect, target = target, prompt = M.text(prompt.text, M.TEXT_LIMIT), view = view}
    return row
end
function M.toggle_technical(state: State)
    state.technical = not state.technical
end
-- reset_cursor: read a workspace's changes again from the start, as after
-- a repeated delivery or a compaction reset.
function M.reset_cursor(state: State, workspace: string)
    state.cursors[workspace] = 0
end
function M.new(workspaces: {string}): State
    return {workspaces = workspaces, cursors = {}, unavailable = {}, rows = {}, selected = nil, detail = nil, technical = false, pending = nil, notice = ""}
end
-- inbox_intent: the next bounded page of one workspace's changes.
function M.inbox_intent(state: State, workspace: string): Intent
    return {target = "bee.approvals.binding:inbox", request = {workspace_id = workspace, after_seq = state.cursors[workspace] or 0, limit = M.INBOX_PAGE}}
end
local function keep(state: State, view: Object, seq: integer)
    local row = M.summary(view, seq)
    local known = state.rows[row.approval_id]
    if known and known.revision > row.revision then return end
    if known and known.seq > seq then row.seq = known.seq end
    state.rows[row.approval_id] = row
    if state.detail and state.detail.approval_id == row.approval_id and integer(state.detail.revision) <= row.revision then state.detail = view end
end
-- apply_inbox: fold a page in; a compacted cursor restarts from the oldest
-- retained change, a refusal marks the workspace unavailable. Returns true
-- when more changes wait.
function M.apply_inbox(state: State, workspace: string, reply: Reply): boolean
    if not reply.ok then
        local fault = reply.error or {code = "INTERNAL", message = "inbox failed"}
        if fault.code == "DENIED" or fault.code == "RESET_REQUIRED" then
            for key, row in pairs(state.rows) do
                if row.workspace_id == workspace then
                    state.rows[key] = nil
                    if state.selected == key then state.selected, state.detail = nil, nil end
                end
            end
        end
        if fault.code == "RESET_REQUIRED" then
            local details = object(reply.value)
            state.cursors[workspace] = math.max(0, integer(details.oldest_seq) - 1)
            return true
        end
        state.unavailable[workspace] = M.text(fault.code .. ": " .. fault.message, M.LINE_LIMIT)
        return false
    end
    state.unavailable[workspace] = nil
    local page = object(reply.value)
    if page.replace_source == true then
        local incoming: {[string]: boolean} = {}
        for _, item in ipairs(object(page.changes) :: {unknown}) do
            local request = object(object(item).request)
            if type(request.approval_id) == "string" then incoming[request.approval_id] = true end
        end
        for key, row in pairs(state.rows) do
            if row.workspace_id == workspace and not incoming[key] then
                state.rows[key] = nil
                if state.selected == key then state.selected, state.detail = nil, nil end
            end
        end
    end
    for _, item in ipairs(object(page.changes) :: {unknown}) do
        local change = object(item)
        keep(state, object(change.request), integer(change.seq))
    end
    state.cursors[workspace] = integer(page.next_seq)
    return page.more == true
end
-- rows: pending first, then newest first; bounded.
function M.rows(state: State): {Row}
    local list: {Row} = {}
    for _, row in pairs(state.rows) do list[#list + 1] = row end
    table.sort(list, function(a: Row, b: Row): boolean
        local a_pending, b_pending = a.state == "pending", b.state == "pending"
        if a_pending ~= b_pending then return a_pending end
        if a.created_at ~= b.created_at then return a.created_at > b.created_at end
        return a.approval_id < b.approval_id
    end)
    while #list > M.MAX_ROWS do table.remove(list) end
    return list
end
function M.selected_row(state: State): Row?
    if not state.selected then return nil end
    return state.rows[state.selected :: string]
end
function M.select(state: State, approval_id: string?)
    if approval_id ~= state.selected then state.detail = nil end
    state.selected = approval_id
end
function M.move(state: State, delta: integer)
    local list = M.rows(state)
    if #list == 0 then M.select(state, nil) return end
    local index = 1
    for position, row in ipairs(list) do
        if row.approval_id == state.selected then index = position end
    end
    index = math.floor(math.max(1, math.min(#list, index + delta)))
    M.select(state, list[index].approval_id)
end
-- read_intent: the selected request's current view from the owner.
function M.read_intent(state: State): Intent?
    if not state.selected then return nil end
    return {target = "bee.approvals.binding:read", request = {approval_id = state.selected}}
end
-- Bind the shell's question to exactly the owner revision the user opened.
function M.confirmation(state: State): Confirmation?
    local detail = state.detail
    if not detail or detail.approval_id ~= state.selected or detail.state ~= "pending" then return nil end
    if type(detail.approval_id) ~= "string" or type(detail.proposal_digest) ~= "string" or type(detail.owner_node) ~= "string" then return nil end
    return {approval_id = detail.approval_id, revision = integer(detail.revision), proposal_digest = detail.proposal_digest,
        owner_node = detail.owner_node, owner_incarnation = integer(detail.owner_incarnation)}
end
function M.confirmation_matches(state: State, asked: Confirmation): boolean
    local current = M.confirmation(state)
    return current ~= nil and current.approval_id == asked.approval_id and current.revision == asked.revision
        and current.proposal_digest == asked.proposal_digest and current.owner_node == asked.owner_node
        and current.owner_incarnation == asked.owner_incarnation
end
function M.apply_read(state: State, approval_id: string, reply: Reply)
    if reply.ok then
        local view = object(reply.value)
        local row = state.rows[approval_id]
        keep(state, view, row and row.seq or 0)
        if state.selected == approval_id then state.detail = view end
        return
    end
    local fault = reply.error or {code = "INTERNAL", message = "read failed"}
    if fault.code == "NOT_FOUND" then
        state.rows[approval_id] = nil
        if state.selected == approval_id then M.select(state, nil) end
        state.notice = "The request no longer exists"
    elseif fault.code == "DENIED" then
        if state.selected == approval_id then state.detail = nil end
        state.notice = "You may not read this request"
    else
        state.notice = M.text(fault.code .. ": " .. fault.message, M.LINE_LIMIT)
    end
end
-- decision_intent: an explicit decision on the request whose detail is
-- loaded and pending, at the revision and digest the viewer saw; nothing
-- else is asked. The intent stays pending until the owner answers or a
-- read recovers it.
function M.decision_intent(state: State, request_id: string, decision: string): (Intent?, string?)
    if state.pending then return nil, "a request is already awaiting the owner" end
    if decision ~= "approved" and decision ~= "denied" then return nil, "decision must be approved or denied" end
    local detail = state.detail
    if not detail or not state.selected or detail.approval_id ~= state.selected then return nil, "open the request before deciding" end
    if detail.state ~= "pending" then return nil, "the request is " .. M.text(detail.state, 40) end
    local revision = integer(detail.revision)
    state.pending = {kind = "decide", request_id = request_id, approval_id = state.selected :: string, revision = revision, decision = decision}
    return {target = "bee.approvals.binding:decide", request = {approval_id = state.selected, expected_revision = revision, decision = decision, proposal_digest = detail.proposal_digest}}, nil
end
-- withdraw_intent: the pending request whose detail is loaded; the owner
-- alone knows whether the viewer is its requester and refuses otherwise.
function M.withdraw_intent(state: State, request_id: string): (Intent?, string?)
    if state.pending then return nil, "a request is already awaiting the owner" end
    local detail = state.detail
    if not detail or not state.selected or detail.approval_id ~= state.selected then return nil, "open the request before withdrawing" end
    if detail.state ~= "pending" then return nil, "the request is " .. M.text(detail.state, 40) end
    state.pending = {kind = "withdraw", request_id = request_id, approval_id = state.selected :: string, revision = integer(detail.revision), decision = nil}
    return {target = "bee.approvals.binding:withdraw", request = {approval_id = state.selected}}, nil
end
local function outcome_text(view: Object): string
    local state = M.text(view.state, 40)
    if state == "decided" then return M.text(view.decision, 40) .. " by " .. M.text(view.decider_id, 120) end
    return state
end
-- apply_answer: the owner's answer to the in-flight request. A conflict or
-- a settled state carries the committed request, which replaces the view;
-- nothing is resubmitted. An absent answer leaves the request pending for
-- recovery.
function M.apply_answer(state: State, request_id: string, reply: Reply?)
    local pending = state.pending
    if not pending or pending.request_id ~= request_id then return end
    if not reply then
        state.notice = "The owner's answer is unknown; reading the request"
        return
    end
    state.pending = nil
    local row = state.rows[pending.approval_id]
    local seq = row and row.seq or 0
    if reply.ok then
        local value = object(reply.value)
        local view = value.request ~= nil and object(value.request) or value
        keep(state, view, seq)
        if state.selected == pending.approval_id then state.detail = view end
        if pending.kind == "withdraw" and value.withdrawn == false then state.notice = "Not withdrawn: the request is " .. outcome_text(view)
        elseif reply.replayed then state.notice = "Already " .. outcome_text(view)
        else state.notice = pending.kind == "withdraw" and "Withdrawn" or ("Recorded: " .. outcome_text(view)) end
        return
    end
    local fault = reply.error or {code = "INTERNAL", message = "the owner refused"}
    local committed = object(reply.value)
    if committed.approval_id ~= nil then
        keep(state, committed, seq)
        if state.selected == pending.approval_id then state.detail = committed end
        state.notice = fault.code .. ": " .. outcome_text(committed) .. " at revision " .. tostring(integer(committed.revision))
    else
        state.notice = M.text(fault.code .. ": " .. fault.message, M.LINE_LIMIT)
    end
end
-- recovery_intent: after an unknown answer the request is read; the owner's
-- record, not the lost reply, says what happened.
function M.recovery_intent(state: State): Intent?
    local pending = state.pending
    if not pending then return nil end
    return {target = "bee.approvals.binding:read", request = {approval_id = pending.approval_id}}
end
function M.apply_recovery(state: State, reply: Reply)
    local pending = state.pending
    if not pending then return end
    if reply.ok then
        local view = object(reply.value)
        local row = state.rows[pending.approval_id]
        keep(state, view, row and row.seq or 0)
        if state.selected == pending.approval_id then state.detail = view end
        if view.state == "pending" then
            state.notice = "Still pending at the owner; the earlier decision may remain in flight"
        else
            state.pending = nil
            state.notice = "Recovered: " .. outcome_text(view)
        end
        return
    end
    M.apply_read(state, pending.approval_id, reply)
    state.notice = "Decision outcome remains unknown; refresh to reconcile. " .. state.notice
end
-- payload_lines: a proposal payload as bounded key and value lines, in
-- key order; never interpreted.
function M.payload_lines(view: Object): {string}
    local lines: {string} = {}
    local proposal = object(view.proposal)
    local payload = object(proposal.payload)
    local keys: {string} = {}
    for key in pairs(payload) do keys[#keys + 1] = tostring(key) end
    table.sort(keys)
    for _, key in ipairs(keys) do
        if #lines >= M.MAX_PAYLOAD_LINES then break end
        local item = payload[key]
        local shown: string
        if type(item) == "table" then
            local encoded = json.encode(item)
            shown = encoded and tostring(encoded) or "{…}"
        else
            shown = tostring(item)
        end
        lines[#lines + 1] = M.text(key, 40) .. ": " .. M.text(shown, M.LINE_LIMIT)
    end
    return lines
end
function M.permission_lines(view: Object): {string}
    local proposal = object(view.proposal)
    local payload = object(proposal.payload)
    local lines: {string} = {}
    local function append(raw: unknown, prefix: string)
        if type(raw) ~= "table" then return end
        for _, value in ipairs(raw :: {unknown}) do
            if #lines >= M.MAX_PAYLOAD_LINES then break end
            if type(value) == "string" then lines[#lines + 1] = prefix .. M.text(value, M.LINE_LIMIT) end
        end
    end
    append(payload.permission_changes, "Change: ")
    append(payload.resolved_capabilities, "Capability: ")
    return lines
end
function M.checkpoint(state: State): string
    return json.encode({selected = state.selected, technical = state.technical}) or "{}"
end
function M.restore(state: State, encoded: string): boolean
    local decoded: unknown = json.decode(encoded)
    if type(decoded) ~= "table" then return false end
    local saved = decoded :: Object
    if saved.selected ~= nil and (type(saved.selected) ~= "string" or #(saved.selected :: string) > 200) then return false end
    if saved.technical ~= nil and type(saved.technical) ~= "boolean" then return false end
    state.selected = saved.selected :: string?
    state.technical = saved.technical == true
    return true
end
return M
