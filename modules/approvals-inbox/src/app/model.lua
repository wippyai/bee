-- MIT. The approvals inbox model, pure: what the viewer sees of the owner's
-- requests, what may be asked of the owner and when, and how every reply
-- is folded back. Decision authority stays with the approval owner: the
-- model holds a viewed revision and one in-flight request, never a
-- decision of its own. Every text from a request is bounded and stripped
-- of control sequences before it reaches a frame, and a proposal payload
-- is rendered only as bounded key and value lines.
local json = require("json")
local text = require("text")
local bounds = require("bounds")
local caller = require("caller")
local M = {}
M.TEXT_LIMIT = 512
M.LINE_LIMIT = 160
M.MAX_ROWS = 256
M.MAX_PAYLOAD_LINES = 24
M.INBOX_PAGE = 64
type Object = {[string]: unknown}
type Workspace = {label: string, folder: string}
type Decision = "approved" | "denied"
type ApprovalState = "pending" | "decided" | "expired" | "withdrawn"
type RequestKind = "permission" | "question"
type ProposalKind = "operation" | "attempt"
type Prompt = {text: string, artifact_ref: nil} | {text: nil, artifact_ref: string}
type OperationProposal = {kind: "operation", ref: string, revision: string, action_id: nil, input_digest: string?, payload: Object}
type AttemptProposal = {kind: "attempt", ref: string, revision: string, action_id: string?, input_digest: string?, payload: Object}
type Proposal = OperationProposal | AttemptProposal
type ApprovalView = {requesting_session: string?,
    approval_id: string, owner_node: string, owner_incarnation: integer, workspace_id: string,
    requester_id: string, request_kind: RequestKind, policy: string, proposal: Proposal,
    proposal_digest: string, prompt: Prompt, revision: integer, state: ApprovalState,
    decision: Decision?, decider_id: string?, expires_at: string, created_at: string,
    response_schema: Object?, thread_id: string?, binding: Object?, response: unknown,
    decided_at: string?, validated_incarnation: integer?, validated_by: string?, validated_at: string?,
    consumer_id: string?, consumed_effect: string?, consumed_at: string?, effect_completed_at: string?,
    effect_result: unknown, updated_at: string?, source_approval_id: string?, source_workspace_id: string?,
}
type Reply =
    {kind: "success", value: unknown, replayed: boolean?} |
    {kind: "failure", code: string, message: string, retryable: boolean?, replayed: boolean?} |
    {kind: "reset", code: "RESET_REQUIRED", message: string, oldest_seq: integer, retryable: boolean?, replayed: boolean?} |
    {kind: "conflict", code: "CONFLICT", message: string, request: ApprovalView, retryable: boolean?, replayed: boolean?} |
    {kind: "settled", code: "INVALID_STATE", message: string, request: ApprovalView, retryable: boolean?, replayed: boolean?}
-- A row is the viewer's summary of one request at the revision last seen.
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
    {kind: "decide", request_id: string, approval_id: string, revision: integer, decision: Decision} |
    {kind: "withdraw", request_id: string, approval_id: string, revision: integer, decision: nil}
type Intent = {target: string, request: Object}
type Confirmation = {approval_id: string, revision: integer, proposal_digest: string, owner_node: string, owner_incarnation: integer}
type State = {
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
-- Bounded text with every control character, including escape sequences,
-- replaced by a space, cut at a character boundary.
function M.text(value: unknown, limit: integer?): string
    return text.bound(value, limit or M.TEXT_LIMIT)
end
local function object(value: unknown): Object?
    return bounds.object(value)
end

function M.workspace(value: unknown, id: string): Workspace?
    local reply = caller.decode(value)
    if not reply or not reply.ok then return nil end
    local body = bounds.object(reply.value)
    local row = body and bounds.object(body.workspace)
    if not row or row.workspace_id ~= id then return nil end
    local label = bounds.text(row.label, 240)
    local path = bounds.subpath(row.subpath)
    if not label or not path then return nil end
    return {label = label ~= "" and label or "Workspace", folder = path ~= "" and path or "Workspace root"}
end

local function proposal_kind(value: unknown): ProposalKind?
    if value == "operation" then return "operation" end
    if value == "attempt" then return "attempt" end
    return nil
end

local function request_kind(value: unknown): RequestKind?
    if value == "permission" then return "permission" end
    if value == "question" then return "question" end
    return nil
end

local function approval_state(value: unknown): ApprovalState?
    if value == "pending" then return "pending" end
    if value == "decided" then return "decided" end
    if value == "expired" then return "expired" end
    if value == "withdrawn" then return "withdrawn" end
    return nil
end

local function decision(value: unknown): Decision?
    if value == "approved" then return "approved" end
    if value == "denied" then return "denied" end
    return nil
end

local function optional_id(value: unknown): (string?, boolean)
    if value == nil then return nil, true end
    local id = bounds.id(value)
    return id, id ~= nil
end

local function decode_prompt(value: unknown): (Prompt?, string?)
    local prompt = object(value)
    if not prompt then return nil, "approval prompt is not an object" end
    local extra = bounds.fields(prompt, {"text", "artifact_ref"})
    if extra then return nil, extra end
    if (prompt.text == nil) == (prompt.artifact_ref == nil) then return nil, "approval prompt needs one content field" end
    if prompt.text ~= nil then
        if type(prompt.text) ~= "string" then return nil, "approval prompt text is invalid" end
        return {text = prompt.text, artifact_ref = nil}, nil
    end
    local artifact = bounds.id(prompt.artifact_ref)
    if not artifact then return nil, "approval prompt artifact_ref is invalid" end
    return {text = nil, artifact_ref = artifact}, nil
end

local function decode_proposal(value: unknown): (Proposal?, string?)
    local proposal = object(value)
    if not proposal then return nil, "approval proposal is not an object" end
    local extra = bounds.fields(proposal, {"kind", "ref", "revision", "action_id", "input_digest", "payload"})
    if extra then return nil, extra end
    local kind = proposal_kind(proposal.kind)
    local ref, revision = bounds.id(proposal.ref), bounds.id(proposal.revision)
    local payload = object(proposal.payload)
    local action, action_valid = optional_id(proposal.action_id)
    local digest: string? = nil
    local raw_digest: unknown = proposal.input_digest
    if raw_digest ~= nil then
        if type(raw_digest) ~= "string" or #raw_digest ~= 64 or not raw_digest:match("^%x+$") then
            return nil, "approval proposal input_digest is invalid"
        end
        digest = raw_digest
    end
    if not kind or not ref or not revision or not payload or not action_valid then return nil, "approval proposal has invalid fields" end
    if kind == "operation" then
        if action ~= nil then return nil, "operation proposal carries an action_id" end
        return {kind = "operation", ref = ref, revision = revision, action_id = nil, input_digest = digest, payload = payload}, nil
    end
    return {kind = "attempt", ref = ref, revision = revision, action_id = action, input_digest = digest, payload = payload}, nil
end

function M.decode_view(value: unknown): (ApprovalView?, string?)
    local view = object(value)
    if not view then return nil, "approval view is not an object" end
    local extra = bounds.fields(view, {"approval_id", "owner_node", "owner_incarnation", "workspace_id", "requester_id", "request_kind", "policy",
        "proposal", "proposal_digest", "prompt", "response_schema", "thread_id", "binding", "revision", "state", "decision", "decider_id",
        "decided_at", "response", "validated_incarnation", "validated_by", "validated_at", "consumer_id", "consumed_effect", "consumed_at",
        "effect_completed_at", "effect_result", "expires_at", "created_at", "updated_at", "source_approval_id", "source_workspace_id", "requesting_session"})
    if extra then return nil, extra end
    local approval_id, owner_node, workspace_id = bounds.id(view.approval_id), bounds.id(view.owner_node), bounds.id(view.workspace_id)
    local requester_id, policy = bounds.id(view.requester_id), bounds.id(view.policy)
    local owner_incarnation, revision = bounds.count(view.owner_incarnation), bounds.count(view.revision)
    local request_kind_value = request_kind(view.request_kind)
    local state = approval_state(view.state)
    local proposal, proposal_error = decode_proposal(view.proposal)
    local prompt, prompt_error = decode_prompt(view.prompt)
    if not approval_id then return nil, "approval view approval_id is invalid" end
    if not owner_node then return nil, "approval view owner_node is invalid" end
    if not workspace_id then return nil, "approval view workspace_id is invalid" end
    if not requester_id then return nil, "approval view requester_id is invalid" end
    if not policy then return nil, "approval view policy is invalid" end
    if not owner_incarnation or owner_incarnation < 1 then return nil, "approval view owner_incarnation is invalid" end
    if not revision or revision < 1 then return nil, "approval view revision is invalid" end
    if not request_kind_value then return nil, "approval view request_kind is invalid" end
    if not state then return nil, "approval view state is invalid" end
    if not proposal then return nil, proposal_error or "approval view proposal is invalid" end
    if not prompt then return nil, prompt_error or "approval view prompt is invalid" end
    local raw_proposal_digest: unknown = view.proposal_digest
    if type(raw_proposal_digest) ~= "string" or #raw_proposal_digest ~= 64 or not raw_proposal_digest:match("^%x+$") then
        return nil, "approval view proposal_digest is invalid"
    end
    local proposal_digest = tostring(raw_proposal_digest)
    local approval_decision: Decision? = nil
    local raw_decision: unknown = view.decision
    if raw_decision ~= nil then
        approval_decision = decision(raw_decision)
        if not approval_decision then return nil, "approval view decision is invalid" end
    end
    if (state == "decided") ~= (approval_decision ~= nil) then return nil, "approval view state and decision disagree" end
    local response_schema: Object? = nil
    if view.response_schema ~= nil then
        response_schema = object(view.response_schema)
        if not response_schema then return nil, "approval response_schema is not an object" end
    end
    local binding: Object? = nil
    if view.binding ~= nil then
        binding = object(view.binding)
        if not binding then return nil, "approval binding is not an object" end
    end
    local thread_id, thread_valid = optional_id(view.thread_id)
    local decider_id, decider_valid = optional_id(view.decider_id)
    local validated_by, validated_valid = optional_id(view.validated_by)
    local consumer_id, consumer_valid = optional_id(view.consumer_id)
    local consumed_effect, effect_valid = optional_id(view.consumed_effect)
    local source_approval_id, source_approval_valid = optional_id(view.source_approval_id)
    local source_workspace_id, source_workspace_valid = optional_id(view.source_workspace_id)
    local expires_at, created_at = bounds.timestamp(view.expires_at), bounds.timestamp(view.created_at)
    if not thread_valid or not decider_valid or not validated_valid or not consumer_valid or not effect_valid
        or not source_approval_valid or not source_workspace_valid or not expires_at or not created_at then
        return nil, "approval view has invalid optional fields"
    end
    local validated_incarnation: integer? = nil
    if view.validated_incarnation ~= nil then
        validated_incarnation = bounds.count(view.validated_incarnation)
        if not validated_incarnation or validated_incarnation < 1 then return nil, "approval validated_incarnation is invalid" end
    end
    local function optional_timestamp(raw: unknown): string?
        if raw == nil then return nil end
        return bounds.timestamp(raw)
    end
    local decided_at, validated_at = optional_timestamp(view.decided_at), optional_timestamp(view.validated_at)
    local consumed_at, effect_completed_at, updated_at = optional_timestamp(view.consumed_at), optional_timestamp(view.effect_completed_at), optional_timestamp(view.updated_at)
    if (view.decided_at ~= nil and not decided_at) or (view.validated_at ~= nil and not validated_at)
        or (view.consumed_at ~= nil and not consumed_at) or (view.effect_completed_at ~= nil and not effect_completed_at)
        or (view.updated_at ~= nil and not updated_at) then return nil, "approval view has invalid timestamps" end
    local requesting_session = view.requesting_session == nil and nil or bounds.id(view.requesting_session)
    if view.requesting_session ~= nil and (not requesting_session or not requesting_session:match("^bs:[^:]+:[^:]+:[^:]+$")) then return nil, "requesting session is invalid" end
    local decoded_view: ApprovalView = {requesting_session = requesting_session, approval_id = approval_id, owner_node = owner_node, owner_incarnation = owner_incarnation, workspace_id = workspace_id,
        requester_id = requester_id, request_kind = request_kind_value, policy = policy, proposal = proposal, proposal_digest = proposal_digest,
        prompt = prompt, revision = revision, state = state, decision = approval_decision, decider_id = decider_id,
        expires_at = expires_at, created_at = created_at, response_schema = response_schema, thread_id = thread_id, binding = binding,
        response = view.response, decided_at = decided_at, validated_incarnation = validated_incarnation, validated_by = validated_by,
        validated_at = validated_at, consumer_id = consumer_id, consumed_effect = consumed_effect, consumed_at = consumed_at,
        effect_completed_at = effect_completed_at, effect_result = view.effect_result, updated_at = updated_at,
        source_approval_id = source_approval_id, source_workspace_id = source_workspace_id}
    return decoded_view, nil
end
-- The owner wire contract permits data on only two failures: a compacted
-- inbox cursor and the committed request behind a conflict. Decode those
-- into explicit variants so generic callers can stay strict.
function M.decode_reply(raw: unknown): Reply?
    local reply = caller.envelope(raw)
    if not reply then return nil end
    if reply.ok then return {kind = "success", value = reply.value, replayed = reply.replayed} end
    if reply.ok ~= false then return nil end
    local fault = reply.error
    if not fault then return nil end
    local code: string = fault.code
    local message: string = fault.message
    local retryable, replayed = fault.retryable, reply.replayed
    if reply.value == nil then return {kind = "failure", code = code, message = message, retryable = retryable, replayed = replayed} end
    if code == "RESET_REQUIRED" then
        local reset = object(reply.value)
        if not reset or bounds.fields(reset, {"oldest_seq"}) then return nil end
        local oldest_seq = bounds.count(reset.oldest_seq)
        if not oldest_seq or oldest_seq < 1 then return nil end
        return {kind = "reset", code = "RESET_REQUIRED", message = message, oldest_seq = oldest_seq, retryable = retryable, replayed = replayed}
    end
    if code == "CONFLICT" then
        local request = M.decode_view(reply.value)
        if not request then return nil end
        return {kind = "conflict", code = "CONFLICT", message = message, request = request, retryable = retryable, replayed = replayed}
    end
    if code == "INVALID_STATE" then
        local request = M.decode_view(reply.value)
        if not request then return nil end
        return {kind = "settled", code = "INVALID_STATE", message = message, request = request, retryable = retryable, replayed = replayed}
    end
    return nil
end
function M.unknown_reply(): Reply
    return {kind = "failure", code = "UNAVAILABLE", message = "no answer from the owner", replayed = false}
end
type Change = {seq: integer, at: string?, request: ApprovalView}
type InboxPage = {changes: {Change}, next_seq: integer, more: boolean, replace_source: boolean}
local function dense_list(value: unknown): {unknown}?
    if type(value) ~= "table" then return nil end
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return nil end
        count = count + 1
    end
    if count > M.INBOX_PAGE then return nil end
    local result: {unknown} = {}
    for index = 1, count do
        if (value)[index] == nil then return nil end
        result[index] = (value)[index]
    end
    return result
end
local function decode_page(value: unknown, workspace: string): (InboxPage?, string?)
    local page = object(value)
    if not page then return nil, "approval inbox page is not an object" end
    local extra = bounds.fields(page, {"changes", "next_seq", "more", "replace_source"})
    local raw_changes = dense_list(page.changes)
    local next_seq = bounds.count(page.next_seq)
    if extra or not raw_changes or next_seq == nil or type(page.more) ~= "boolean"
        or (page.replace_source ~= nil and type(page.replace_source) ~= "boolean") then
        return nil, extra or "approval inbox page has invalid fields"
    end
    local changes: {Change} = {}
    local previous = 0
    for index, raw in ipairs(raw_changes) do
        local item = object(raw)
        if not item then return nil, "approval inbox change is not an object" end
        local unknown = bounds.fields(item, {"seq", "approval_id", "revision", "at", "request"})
        local seq = bounds.count(item.seq)
        local request, view_error = M.decode_view(item.request)
        local at: string? = nil
        if item.at ~= nil then at = bounds.timestamp(item.at) end
        if unknown or not seq or seq < 1 or seq <= previous or seq > next_seq or not request
            or request.workspace_id ~= workspace or (item.at ~= nil and not at) then
            return nil, unknown or view_error or "approval inbox change has invalid identity, sequence, or timestamp"
        end
        if item.approval_id ~= nil and item.approval_id ~= request.approval_id then return nil, "approval inbox change id does not match its request" end
        if item.revision ~= nil and item.revision ~= request.revision then return nil, "approval inbox change revision does not match its request" end
        changes[index] = {seq = seq, at = at, request = request}
        previous = seq
    end
    if page.replace_source == true and page.more == true then return nil, "approval source replacement cannot be partial" end
    return {changes = changes, next_seq = next_seq, more = page.more,
        replace_source = page.replace_source == true}, nil
end
-- The proposed effect in words: the tool or operation, then the target.
local function effect_of(view: ApprovalView): (string, string)
    local proposal = view.proposal
    local payload = proposal.payload
    local effect = M.text(payload.tool_name or payload.operation or proposal.kind or view.request_kind, M.LINE_LIMIT)
    local target = M.text(proposal.ref, M.LINE_LIMIT)
    if proposal.action_id ~= nil then target = target .. " action " .. M.text(proposal.action_id, M.LINE_LIMIT) end
    return effect, target
end
function M.summary(view: ApprovalView, seq: integer): Row
    local effect, target = effect_of(view)
    local decision = view.decision
    local decider = view.decider_id
    local row: Row = {approval_id = M.text(view.approval_id, 200), workspace_id = M.text(view.workspace_id, 200), seq = seq, revision = view.revision,
        state = view.state, decision = decision, decider_id = decider,
        request_kind = view.request_kind, requester_id = M.text(view.requester_id, 200), owner_node = M.text(view.owner_node, 200),
        owner_incarnation = view.owner_incarnation, policy = M.text(view.policy, 200), expires_at = M.text(view.expires_at, 40), created_at = M.text(view.created_at, 40),
        effect = effect, target = target, prompt = M.text(view.prompt.text, M.TEXT_LIMIT), view = view}
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
local function fault_details(reply: Reply): (string, string)
    if reply.kind == "failure" then return reply.code, reply.message end
    if reply.kind == "reset" then return reply.code, reply.message end
    if reply.kind == "conflict" then return reply.code, reply.message end
    if reply.kind == "settled" then return reply.code, reply.message end
    return "INTERNAL", "unexpected successful reply"
end
local function keep(state: State, view: ApprovalView, seq: integer)
    local row = M.summary(view, seq)
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
    if reply.kind ~= "success" then
        local code, message = fault_details(reply)
        if code == "DENIED" or code == "RESET_REQUIRED" then
            for key, row in pairs(state.rows) do
                if row.workspace_id == workspace then
                    state.rows[key] = nil
                    if state.selected == key then state.selected, state.detail = nil, nil end
                end
            end
        end
        if reply.kind == "reset" then
            state.cursors[workspace] = reply.oldest_seq - 1
            state.unavailable[workspace] = nil
            return true
        end
        if code == "RESET_REQUIRED" then
            state.unavailable[workspace] = M.text("RESET_REQUIRED: " .. message, M.LINE_LIMIT)
            return false
        end
        state.unavailable[workspace] = M.text(code .. ": " .. message, M.LINE_LIMIT)
        return false
    end
    local page, page_error = decode_page(reply.value, workspace)
    if not page then
        state.unavailable[workspace] = M.text("INVALID_REPLY: " .. tostring(page_error), M.LINE_LIMIT)
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
    return state.rows[state.selected]
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
    return {approval_id = detail.approval_id, revision = detail.revision, proposal_digest = detail.proposal_digest,
        owner_node = detail.owner_node, owner_incarnation = detail.owner_incarnation}
end
function M.confirmation_matches(state: State, asked: Confirmation): boolean
    local current = M.confirmation(state)
    return current ~= nil and current.approval_id == asked.approval_id and current.revision == asked.revision
        and current.proposal_digest == asked.proposal_digest and current.owner_node == asked.owner_node
        and current.owner_incarnation == asked.owner_incarnation
end
function M.apply_read(state: State, approval_id: string, reply: Reply)
    if reply.kind == "success" then
        local view, view_error = M.decode_view(reply.value)
        if not view or view.approval_id ~= approval_id then
            state.notice = M.text("INVALID_REPLY: " .. tostring(view_error or "approval identity mismatch"), M.LINE_LIMIT)
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
        state.notice = M.text(code .. ": " .. message, M.LINE_LIMIT)
    end
end
-- decision_intent: an explicit decision on the request whose detail is
-- loaded and pending, at the revision and digest the viewer saw; nothing
-- else is asked. The intent stays pending until the owner answers or a
-- read recovers it.
function M.decision_intent(state: State, request_id: string, decision: string): (Intent?, string?)
    if state.pending then return nil, "a request is already awaiting the owner" end
    local selected_decision = bounds.member(decision, {"approved", "denied"})
    if not selected_decision then return nil, "decision must be approved or denied" end
    local detail = state.detail
    local selected = state.selected
    if not detail or not selected or detail.approval_id ~= selected then return nil, "open the request before deciding" end
    if detail.state ~= "pending" then return nil, "the request is " .. M.text(detail.state, 40) end
    local revision = detail.revision
    state.pending = {kind = "decide", request_id = request_id, approval_id = selected, revision = revision, decision = selected_decision}
    return {target = "bee.approvals.binding:decide", request = {approval_id = selected, expected_revision = revision, decision = selected_decision, proposal_digest = detail.proposal_digest}}, nil
end
-- withdraw_intent: the pending request whose detail is loaded; the owner
-- alone knows whether the viewer is its requester and refuses otherwise.
function M.withdraw_intent(state: State, request_id: string): (Intent?, string?)
    if state.pending then return nil, "a request is already awaiting the owner" end
    local detail = state.detail
    local selected = state.selected
    if not detail or not selected or detail.approval_id ~= selected then return nil, "open the request before withdrawing" end
    if detail.state ~= "pending" then return nil, "the request is " .. M.text(detail.state, 40) end
    state.pending = {kind = "withdraw", request_id = request_id, approval_id = selected, revision = detail.revision, decision = nil}
    return {target = "bee.approvals.binding:withdraw", request = {approval_id = selected}}, nil
end
local function outcome_text(view: ApprovalView): string
    if view.state == "decided" and view.decision then return M.text(view.decision, 40) .. " by " .. M.text(view.decider_id, 120) end
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
    local row = state.rows[pending.approval_id]
    local seq = row and row.seq or 0
    if reply.kind == "success" then
        local value = object(reply.value)
        local raw_view = value and value.request or reply.value
        local view, view_error = M.decode_view(raw_view)
        if not view or view.approval_id ~= pending.approval_id then
            state.notice = M.text("INVALID_REPLY: " .. tostring(view_error or "approval identity mismatch"), M.LINE_LIMIT)
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
        state.notice = M.text(notice or "INTERNAL: invalid settled request", M.LINE_LIMIT)
    else
        local code, message = fault_details(reply)
        state.notice = M.text(code .. ": " .. message, M.LINE_LIMIT)
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
        local view, view_error = M.decode_view(reply.value)
        if not view or view.approval_id ~= pending.approval_id then
            state.notice = M.text("INVALID_REPLY: " .. tostring(view_error or "approval identity mismatch"), M.LINE_LIMIT)
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
-- payload_lines: a proposal payload as bounded key and value lines, in
-- key order; never interpreted.
function M.payload_lines(value: unknown): {string}
    local view = M.decode_view(value)
    if not view then return {} end
    local lines: {string} = {}
    local payload = view.proposal.payload
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
function M.permission_lines(value: unknown): {string}
    local view = M.decode_view(value)
    if not view then return {} end
    local payload = view.proposal.payload
    local lines: {string} = {}
    -- A lease approval states its terms from the typed values the lease is
    -- stored with, ahead of the ceiling: what it covers, how long it lasts and
    -- when that starts, and how many applies it allows. The request's own
    -- expiry is a different deadline and is shown apart.
    if view.proposal.ref == "bee.gov:grant-lease" then
        local ttl, max = bounds.count(payload.ttl_seconds), bounds.count(payload.max_applies)
        lines[#lines + 1] = "Lease for: " .. M.text(payload.target, M.LINE_LIMIT)
        if ttl and ttl > 0 then
            local words = ttl % 86400 == 0 and (tostring(ttl // 86400) .. " days") or (ttl % 3600 == 0 and (tostring(ttl // 3600) .. " hours")
                or (ttl % 60 == 0 and (tostring(ttl // 60) .. " minutes") or (tostring(ttl) .. " seconds")))
            lines[#lines + 1] = "Lasts: " .. words .. " from the moment it is granted (not this request's expiry)"
        else
            lines[#lines + 1] = "Lasts: no expiry"
        end
        lines[#lines + 1] = max and max > 0 and ("Max applies: " .. tostring(max)) or "Max applies: unlimited"
    end
    -- A lease review renders complete text; the proposal itself is bounded to 8 KiB.
    local limit = view.proposal.ref == "bee.gov:grant-lease" and 8192 or M.LINE_LIMIT
    local function append(raw: unknown, prefix: string)
        if type(raw) ~= "table" then return end
        for _, value in ipairs(raw) do
            if #lines >= M.MAX_PAYLOAD_LINES then break end
            if type(value) == "string" then lines[#lines + 1] = prefix .. M.text(value, limit) end
        end
    end
    if view.proposal.ref ~= "bee.gov:grant-lease" then append(payload.permission_changes, "Change: ") end
    append(payload.resolved_capabilities, "Capability: ")
    return lines
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
