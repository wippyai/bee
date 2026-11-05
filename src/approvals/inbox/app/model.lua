-- MIT. The approvals inbox model, pure: what the viewer sees of the owner's
-- requests, what may be asked of the owner and when, and how every reply
-- is folded back. Decision authority stays with the approval owner: the
-- model holds a viewed revision and one in-flight request, never a
-- decision of its own. Every text from a request is bounded and stripped
-- of control sequences before it reaches a frame, and a proposal payload
-- is rendered only as bounded key and value lines.
local json = require("json")
local bounds = require("bounds")
local windows = require("windows")
local grants = require("grants")
local glyphs = require("glyphs")
local typed_form = require("typed_form")
local states = require("states")
local wire = require("wire")
local M = {}
M.DISPLAY = "bee.approvals.display"
M.MAX_ROWS = 256
type Object = wire.Object
type Decision = wire.Decision
type ApprovalView = wire.ApprovalView
type Reply = wire.Reply
type ApprovalState = states.ApprovalState
type RequestKind = states.RequestKind
type Row = {
    approval_id: string,
    workspace_id: string,
    seq: integer,
    revision: integer,
    state: ApprovalState,
    decision: Decision?,
    decider_id: string?,
    request_kind: RequestKind,
    requester_id: string,
    owner_node: string,
    owner_incarnation: integer,
    policy: string,
    expires_at: string,
    created_at: string,
    effect: string,
    target: string,
    prompt: string,
    view: ApprovalView,
}
type Pending =
    {kind: "batch", request_id: string, approval_id: string, revision: integer, decision: Decision, items: {ApprovalView}} |
    {kind: "decide", request_id: string, approval_id: string, revision: integer, decision: Decision} |
    {kind: "withdraw", request_id: string, approval_id: string, revision: integer, decision: nil}
type Intent = {target: string, request: Object}
type Confirmation = {approval_id: string, revision: integer, proposal_digest: string, reviewed_digest: string?, owner_node: string, owner_incarnation: integer}
type Display = {requester: string?, duration: string?, consequence: string?, lasting: boolean, subject: string?, approved: string?, form: string?,
    answered_where_asked: boolean, effect_field: string?, target_field: string?}
type State = {
    requester_names: {[string]: string}?,
    displays: {[string]: Display}?,
    resyncing: {[string]: boolean},
    grant_line_count: integer?, grant_detail: {string}?, grants_view: boolean, grants: {grants.Grant}, grant_selected: integer, longer: boolean, longer_choices: {windows.Choice},
    workspaces: {string},
    cursors: {[string]: integer},
    unavailable: {[string]: string},
    rows: {[string]: Row},
    selected: string?,
    detail: ApprovalView?,
    technical: boolean,
    pending: Pending?,
    notice: string,
}
-- The proposed effect in words: the tool or operation, then the target.
local function effect_of(view: ApprovalView, displays: {[string]: Display}?): (string, string)
    local proposal = view.proposal
    local payload = proposal.payload
    local effect = wire.text(payload.tool_name or payload.operation or proposal.kind or view.request_kind, wire.LINE_LIMIT)
    local target = wire.text(proposal.ref, wire.LINE_LIMIT)
    local display = M.display(view, displays)
    if display and display.effect_field then effect = wire.text(payload[display.effect_field], wire.LINE_LIMIT) end
    local identity = display and display.target_field and bounds.object(payload[display.target_field])
    if identity then target = wire.text(identity.desktop_id or identity.instance_id or identity.profile_id or identity.app or identity.component or identity.client_id or identity.session or proposal.ref, wire.LINE_LIMIT) end
    if proposal.action_id ~= nil then target = target .. " action " .. wire.text(proposal.action_id, wire.LINE_LIMIT) end
    return effect, target
end
function M.prompt(view: ApprovalView): string
    return wire.text(view.prompt.text, 16384)
end
type Review = {title: string, access: string?, reason: string?, exposure: string?}
function M.review(view: ApprovalView): Review
    local fields = bounds.object(view.proposal.payload.review)
    local title = fields and bounds.text(fields.title, 8192)
    local access = fields and bounds.text(fields.access, 8192) or bounds.text(view.proposal.payload.access_summary, 8192)
    local reason = fields and bounds.text(fields.reason, 8192)
    local exposure = fields and bounds.text(fields.exposure, 8192)
    return {title = title and wire.text(title, 8192) or M.prompt(view), access = access and wire.text(access, 8192),
        reason = reason and wire.text(reason, 8192), exposure = exposure and wire.text(exposure, 8192)}
end
-- displays: the operation owners' bee.approvals.display declarations, keyed
-- by the operation they word: who asks, how long an approval lasts, what it
-- leads to, what the request is about and which decision form it takes.
function M.displays(entries: unknown): {[string]: Display}
    local result: {[string]: Display} = {}
    for _, raw in ipairs(bounds.dense_list(entries, 256, "approval displays") or {}) do
        local entry = bounds.object(raw)
        local meta = entry and bounds.object(entry.meta)
        local data = entry and bounds.object(entry.data)
        local ref = meta and meta.type == M.DISPLAY and bounds.id(meta.operation_ref) or nil
        if ref and data then
            local function line(value: unknown): string?
                local text = bounds.line(value, 160)
                return text and text ~= "" and wire.text(text, 160) or nil
            end
            local consequence = bounds.text(data.consequence, 2048)
            result[ref] = {requester = line(data.requester), duration = line(data.duration), subject = line(data.subject),
                approved = line(data.approved), form = bounds.id(data.form), lasting = data.lasting == true,
                consequence = consequence and wire.text(consequence, 2048) or nil,
                answered_where_asked = data.answered_where_asked == true,
                effect_field = bounds.id(data.effect_field), target_field = bounds.id(data.target_field)}
        end
    end
    return result
end
function M.display(view: ApprovalView, displays: {[string]: Display}?): Display?
    return displays and displays[view.proposal.ref] or nil
end
function M.requester_name(view: ApprovalView, names: {[string]: string}?, displays: {[string]: Display}?): string
    local supplied = names and names[view.requester_id] or bounds.line(view.proposal.payload.requester_name, 160)
    if supplied and supplied ~= "" then return wire.text(supplied, 160) end
    if view.requesting_session then return "Agent session" end
    local display = M.display(view, displays)
    if display and display.requester then return display.requester end
    local requester = view.contract and bounds.object(view.contract.requester)
    if requester and bounds.id(requester.definition_id) then return "App" end
    return "Bee"
end
function M.duration(view: ApprovalView, displays: {[string]: Display}?): string
    local stated = bounds.line(view.proposal.payload.duration, 160)
    if stated and stated ~= "" then return wire.text(stated, 160) end
    local display = M.display(view, displays)
    if display and display.duration then return display.duration end
    return "One action" .. ((view.window_max_ttl_ms or 0) >= 1800000 and " (or choose 30 minutes)" or "")
end
-- answered_where_asked: a pending request its display has answered in the
-- application that asked, unless the request asks to be reviewed in the inbox.
function M.answered_where_asked(view: ApprovalView, displays: {[string]: Display}?): boolean
    local display = M.display(view, displays)
    return display ~= nil and display.answered_where_asked and not (view.contract and view.contract.presentation == "inbox")
end
function M.summary(view: ApprovalView, seq: integer, displays: {[string]: Display}?): Row
    local effect, target = effect_of(view, displays)
    local decision = view.decision
    local decider = view.decider_id
    local row: Row = {approval_id = wire.text(view.approval_id, 200), workspace_id = wire.text(view.workspace_id, 200), seq = seq, revision = view.revision,
        state = view.state, decision = decision, decider_id = decider,
        request_kind = view.request_kind, requester_id = wire.text(view.requester_id, 200), owner_node = wire.text(view.owner_node, 200),
        owner_incarnation = view.owner_incarnation, policy = wire.text(view.policy, 200), expires_at = wire.text(view.expires_at, 40), created_at = wire.text(view.created_at, 40),
        effect = effect, target = target, prompt = wire.text(M.prompt(view), wire.TEXT_LIMIT), view = view}
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
    return {resyncing = {}, grants_view = false, grants = {}, grant_selected = 1, longer = false, longer_choices = {}, workspaces = workspaces, cursors = {}, unavailable = {}, rows = {}, selected = nil, detail = nil, technical = false, pending = nil, notice = ""}
end
-- inbox_intent: the next bounded page of one workspace's changes.
function M.inbox_intent(state: State, workspace: string): Intent
    return {target = "bee.approvals.binding:inbox", request = {workspace_id = workspace, after_seq = state.cursors[workspace] or 0, limit = M.INBOX_PAGE}}
end
local function fault_details(reply: Reply): (string, string)
    if reply.kind == "failure" then return reply.code, reply.message end
    if reply.kind == "reset" then return reply.code, reply.message end
    if reply.kind == "conflict" then return reply.code, reply.message end
    if reply.kind == "settled" then return reply.code, reply.message end
    return "INTERNAL", "unexpected successful reply"
end
local function keep(state: State, view: ApprovalView, seq: integer)
    local row = M.summary(view, seq, state.displays)
    local known = state.rows[row.approval_id]
    if known and known.revision > row.revision then return end
    if known and known.seq > seq then row.seq = known.seq end
    state.rows[row.approval_id] = row
    if state.detail and state.detail.approval_id == row.approval_id and state.detail.revision <= row.revision then state.detail = view end
end
-- apply_inbox: fold a page in; a compacted cursor restarts from the oldest
-- retained change, a refusal marks the workspace unavailable. Returns true
-- when more changes wait.
function M.apply_inbox(state: State, workspace: string, reply: Reply): boolean
    state.resyncing[workspace] = nil
    if reply.kind ~= "success" then
        local code, message = fault_details(reply)
        if reply.purged or code == "DENIED" or code == "RESET_REQUIRED" then
            for key, row in pairs(state.rows) do
                if row.workspace_id == workspace then
                    state.rows[key] = nil
                    if state.selected == key then state.selected, state.detail = nil, nil end
                end
            end
        end
        if reply.kind == "reset" then
            state.resyncing[workspace] = true
            state.cursors[workspace] = reply.oldest_seq - 1
            state.unavailable[workspace] = nil
            return true
        end
        if code == "RESET_REQUIRED" then
            state.resyncing[workspace] = true
            state.cursors[workspace] = 0
            state.unavailable[workspace] = nil
            return true
        end
        state.unavailable[workspace] = wire.text(code .. ": " .. message, wire.LINE_LIMIT)
        return false
    end
    local page, page_error = wire.decode_page(reply.value, workspace)
    if not page then
        state.unavailable[workspace] = wire.text("INVALID_REPLY: " .. tostring(page_error), wire.LINE_LIMIT)
        return false
    end
    if not page.replace_source and page.next_seq < (state.cursors[workspace] or 0) then
        state.unavailable[workspace] = "INVALID_REPLY: approval cursor moved backwards"
        return false
    end
    local incoming: {[string]: boolean} = {}
    local count = 0
    if not page.replace_source then
        for key, row in pairs(state.rows) do
            if row.workspace_id == workspace then incoming[key] = true; count = count + 1 end
        end
    end
    for _, change in ipairs(page.changes) do
        if not incoming[change.request.approval_id] then
            incoming[change.request.approval_id] = true
            count = count + 1
        end
    end
    if count > M.MAX_ROWS then
        state.unavailable[workspace] = "CAPACITY_EXHAUSTED: source exceeds 256 requests"
        return false
    end
    state.unavailable[workspace] = nil
    if page.replace_source then
        for key, row in pairs(state.rows) do
            if row.workspace_id == workspace and not incoming[key] then
                state.rows[key] = nil
                if state.selected == key then state.selected, state.detail = nil, nil end
            end
        end
    end
    for _, change in ipairs(page.changes) do keep(state, change.request, change.seq) end
    state.cursors[workspace] = page.next_seq
    return page.more
end
-- rows: pending first, then newest first; bounded.
function M.rows(state: State): {Row}
    local list: {Row} = {}
    for _, row in pairs(state.rows) do
        if row.state ~= "pending" or not M.answered_where_asked(row.view, state.displays) then list[#list + 1] = row end
    end
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
    return state.rows[state.selected]
end
function M.select(state: State, approval_id: string?)
    if approval_id ~= state.selected then state.detail = nil end
    state.selected = approval_id
    state.longer = false
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
    if not state.selected then
        local first = M.rows(state)[1]
        if not first then return nil end
        M.select(state, first.approval_id)
    end
    return {target = "bee.approvals.binding:read", request = {approval_id = state.selected}}
end
-- Bind the shell's question to exactly the owner revision the user opened.
function M.confirmation(state: State): Confirmation?
    local detail = state.detail
    if not detail or detail.approval_id ~= state.selected or detail.state ~= "pending" or M.answered_where_asked(detail, state.displays) then return nil end
    return {approval_id = detail.approval_id, revision = detail.revision, proposal_digest = detail.proposal_digest, reviewed_digest = detail.reviewed_digest,
        owner_node = detail.owner_node, owner_incarnation = detail.owner_incarnation}
end
function M.confirmation_matches(state: State, asked: Confirmation): boolean
    local current = M.confirmation(state)
    return current ~= nil and current.approval_id == asked.approval_id and current.revision == asked.revision
        and current.proposal_digest == asked.proposal_digest and current.reviewed_digest == asked.reviewed_digest and current.owner_node == asked.owner_node
        and current.owner_incarnation == asked.owner_incarnation
end
function M.apply_read(state: State, approval_id: string, reply: Reply)
    if reply.kind == "success" then
        local view, view_error = wire.decode_view(reply.value)
        if not view or view.approval_id ~= approval_id then
            state.notice = wire.text("INVALID_REPLY: " .. tostring(view_error or "approval identity mismatch"), wire.LINE_LIMIT)
            return
        end
        local row = state.rows[approval_id]
        keep(state, view, row and row.seq or 0)
        if state.selected == approval_id then state.detail = view end
        return
    end
    local code, message = fault_details(reply)
    if code == "NOT_FOUND" then
        state.rows[approval_id] = nil
        if state.selected == approval_id then M.select(state, nil) end
        state.notice = "The request no longer exists"
    elseif code == "DENIED" then
        if state.selected == approval_id then state.detail = nil end
        state.notice = "You may not read this request"
    else
        state.notice = wire.text(code .. ": " .. message, wire.LINE_LIMIT)
    end
end
-- decision_intent: an explicit decision on the request whose detail is
-- loaded and pending, at the revision and digest the viewer saw; nothing
-- else is asked. The intent stays pending until the owner answers or a
-- read recovers it.
function M.decision_intent(state: State, request_id: string, decision: string, ttl_ms: integer?, response: unknown?): (Intent?, string?)
    if state.pending then return nil, "a request is already awaiting the owner" end
    local selected_decision = bounds.member(decision, {"approved", "denied"})
    if not selected_decision then return nil, "decision must be approved or denied" end
    local detail = state.detail
    local selected = state.selected
    if not detail or not selected or detail.approval_id ~= selected then return nil, "open the request before deciding" end
    if detail.state ~= "pending" then return nil, "the request is " .. wire.text(detail.state, 40) end
    if ttl_ms and (ttl_ms < 1 or ttl_ms > (detail.window_max_ttl_ms or 0) or selected_decision ~= "approved" or detail.request_kind ~= "permission") then return nil, "duration exceeds this request's policy" end
    if detail.request_kind == "question" and selected_decision == "approved" then
        local problem = typed_form.validate({id = "answer", schema = detail.response_schema or {}, has_default = false}, response)
        if problem then return nil, problem end
    end
    local revision = detail.revision
    state.pending = {kind = "decide", request_id = request_id, approval_id = selected, revision = revision, decision = selected_decision}
    return {target = "bee.approvals.binding:decide", request = {approval_id = selected, expected_revision = revision, decision = detail.request_kind == "question" and selected_decision == "approved" and "answer" or selected_decision, response = response, proposal_digest = detail.proposal_digest, reviewed_digest = detail.reviewed_digest, window_ttl_ms = ttl_ms}}, nil
end
function M.decision_group(state: State): {ApprovalView}
    local detail = state.detail
    if not detail or detail.state ~= "pending" then return {} end
    return {detail}
end
function M.window_cap(state: State): integer
    local cap: integer = 31536000000
    local group = M.decision_group(state)
    if #group == 0 then return 0 end
    for _, view in ipairs(group) do
        local limit = bounds.integer(view.window_max_ttl_ms or 0)
        if limit == nil then error("approval policy cap is not an integer") end
        if limit < cap then cap = limit end
    end
    return cap
end
function M.combined_intent(state: State, request_id: string, decision: string, ttl_ms: integer?): (Intent?, string?)
    if state.pending then return nil, "a request is already awaiting the owner" end
    local group = M.decision_group(state)
    if #group <= 1 then return M.decision_intent(state, request_id, decision, ttl_ms) end
    if #group > 16 then return nil, "CAPACITY_EXHAUSTED: a combined decision exceeds 16 requests" end
    if decision ~= "approved" and decision ~= "denied" then return nil, "decision must be approved or denied" end
    if ttl_ms and (ttl_ms < 1 or ttl_ms > M.window_cap(state) or decision ~= "approved") then return nil, "duration exceeds this batch's policy" end
    local items: {Object} = {}
    for _, view in ipairs(group) do items[#items + 1] = {approval_id = view.approval_id, expected_revision = view.revision, proposal_digest = view.proposal_digest, reviewed_digest = view.reviewed_digest, decision = decision} end
    local detail = assert(state.detail)
    state.pending = {kind = "batch", request_id = request_id, approval_id = detail.approval_id, revision = detail.revision, decision = decision, items = group}
    return {target = "bee.approvals.binding:decide_batch", request = {decisions = items, window_ttl_ms = ttl_ms}}, nil
end
function M.history(view: ApprovalView, displays: {[string]: Display}?): string?
    local display = M.display(view, displays)
    if display and display.approved and view.decision == "approved" then return display.approved:lower() end
    local grant = view.window_grant
    if view.allowed_by_grant and grant then return "allowed by your " .. windows.duration(grant.until_ms - grant.granted_ms) .. " grant" end
    return nil
end
-- withdraw_intent: the pending request whose detail is loaded; the owner
-- alone knows whether the viewer is its requester and refuses otherwise.
function M.withdraw_intent(state: State, request_id: string): (Intent?, string?)
    if state.pending then return nil, "a request is already awaiting the owner" end
    local detail = state.detail
    local selected = state.selected
    if not detail or not selected or detail.approval_id ~= selected then return nil, "open the request before withdrawing" end
    if detail.state ~= "pending" then return nil, "the request is " .. wire.text(detail.state, 40) end
    state.pending = {kind = "withdraw", request_id = request_id, approval_id = selected, revision = detail.revision, decision = nil}
    return {target = "bee.approvals.binding:withdraw", request = {approval_id = selected, expected_revision = detail.revision, proposal_digest = detail.proposal_digest, reviewed_digest = detail.reviewed_digest}}, nil
end
-- Who decided, as the person reads it: a decision the owner recorded from
-- an application principal is the person's own, "you"; any other approver
-- is named by the last part of its identity.
function M.decider(view: ApprovalView, decider_id: string?): string
    if not decider_id then return "unknown" end
    local decisions = view.lifecycle_records and bounds.array(view.lifecycle_records.decisions, 64)
    local record = decisions and decisions[#decisions] and bounds.object(decisions[#decisions])
    local raw = record and bounds.text(record.decider_json, 4096)
    local principal = raw and bounds.object(json.decode(raw))
    if principal and principal.actor_id == decider_id and bounds.id(principal.definition_id) then return "you" end
    return wire.text(decider_id:match("([^:]+)$") or decider_id, 40)
end
-- The decision line of a request: what was decided and by whom, or why it is
-- not pending any more.
function M.assurance(view: ApprovalView): string?
    local decisions = view.lifecycle_records and bounds.array(view.lifecycle_records.decisions, 64)
    local record = decisions and decisions[#decisions] and bounds.object(decisions[#decisions])
    local raw = record and bounds.text(record.assurance_json, 4096)
    local assurance = raw and bounds.object(json.decode(raw))
    if not assurance or assurance.kind ~= "explicit_gesture" then return nil end
    return wire.text(assurance.gesture, 32) .. " · " .. wire.text(assurance.presentation, 32)
end
function M.decision_line(view: ApprovalView, displays: {[string]: Display}?): string
    local effect = bounds.object(view.effect)
    local display = M.display(view, displays)
    local label = display and display.subject or "Action"
    if effect and effect.state == "failed" then return label .. " failed" end
    if effect and effect.state == "uncertain" then return label .. " outcome uncertain" end
    if view.state == "decided" and view.decision then
        return (view.decision == "approved" and (display and display.approved or "Approved") or "Denied") .. " by " .. M.decider(view, view.decider_id)
    end
    if view.state == "pending" then return "Waiting for your decision" end
    if view.state == "withdrawn" then return "Withdrawn" end
    return "Expired"
end
local function outcome_text(view: ApprovalView): string
    if view.state == "decided" and view.decision then return wire.text(view.decision, 40) .. " by " .. M.decider(view, view.decider_id) end
    return view.state
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
    if reply.kind == "failure" and reply.code == "UNKNOWN_OUTCOME" then
        state.notice = wire.text(reply.code .. ": " .. reply.message, wire.LINE_LIMIT)
        return
    end
    if pending.kind == "batch" and reply.kind == "success" then
        local body = bounds.object(reply.value)
        local raw_views = body and bounds.array(body.decisions, 16)
        if not raw_views or #raw_views ~= #pending.items then state.notice = "INVALID_REPLY: batch decision count differs"; return end
        local views: {ApprovalView} = {}
        for index, raw in ipairs(raw_views) do
            local view, err = wire.decode_view(raw)
            if not view or view.approval_id ~= pending.items[index].approval_id then state.notice = "INVALID_REPLY: " .. tostring(err or "batch identity differs"); return end
            views[#views + 1] = view
        end
        for _, view in ipairs(views) do
            local known = state.rows[view.approval_id]
            keep(state, view, known and known.seq or 0)
        end
        state.pending = nil
        state.notice = "Recorded: " .. tostring(#views) .. " requests " .. pending.decision
        return
    end
    local row = state.rows[pending.approval_id]
    local seq = row and row.seq or 0
    if reply.kind == "success" then
        local value = bounds.object(reply.value)
        local raw_view = value and value.request or reply.value
        local view, view_error = wire.decode_view(raw_view)
        if not view or view.approval_id ~= pending.approval_id then
            state.notice = wire.text("INVALID_REPLY: " .. tostring(view_error or "approval identity mismatch"), wire.LINE_LIMIT)
            return
        end
        if value and value.withdrawn ~= nil and type(value.withdrawn) ~= "boolean" then
            state.notice = "INVALID_REPLY: withdrawal result is malformed"
            return
        end
        state.pending = nil
        keep(state, view, seq)
        if state.selected == pending.approval_id then state.detail = view end
        if pending.kind == "withdraw" and value and value.withdrawn == false then state.notice = "Not withdrawn: the request is " .. outcome_text(view)
        elseif reply.replayed then state.notice = "Already " .. outcome_text(view)
        else state.notice = pending.kind == "withdraw" and "Withdrawn" or ("Recorded: " .. outcome_text(view)) end
        return
    end
    state.pending = nil
    local committed: ApprovalView? = nil
    local notice: string? = nil
    if reply.kind == "conflict" then
        committed = reply.request
        notice = reply.code .. ": " .. outcome_text(reply.request) .. " at revision " .. tostring(reply.request.revision)
    elseif reply.kind == "settled" then
        committed = reply.request
        notice = reply.code .. ": " .. reply.message .. " (" .. outcome_text(reply.request) .. ")"
    end
    if committed and committed.approval_id == pending.approval_id then
        keep(state, committed, seq)
        if state.selected == pending.approval_id then state.detail = committed end
        state.notice = wire.text(notice or "INTERNAL: invalid settled request", wire.LINE_LIMIT)
    else
        local code, message = fault_details(reply)
        state.notice = wire.text(code .. ": " .. message, wire.LINE_LIMIT)
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
    if reply.kind == "success" then
        local view, view_error = wire.decode_view(reply.value)
        if not view or view.approval_id ~= pending.approval_id then
            state.notice = wire.text("INVALID_REPLY: " .. tostring(view_error or "approval identity mismatch"), wire.LINE_LIMIT)
            return
        end
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
-- The state word of a request with its glyph.
function M.state_mark(state: string): string
    if state == "approved" then return glyphs.installed end
    if state == "denied" or state == "withdrawn" or state == "expired" then return glyphs.removed end
    return glyphs.waiting
end

function M.checkpoint(state: State): string
    return json.encode({selected = state.selected, technical = state.technical}) or "{}"
end
function M.restore(state: State, encoded: string): boolean
    local decoded: unknown = json.decode(encoded)
    if type(decoded) ~= "table" then return false end
    local saved = decoded
    if saved.selected ~= nil and (type(saved.selected) ~= "string" or #(saved.selected) > 200) then return false end
    if saved.technical ~= nil and type(saved.technical) ~= "boolean" then return false end
    state.selected = saved.selected
    state.technical = saved.technical == true
    return true
end
return M
