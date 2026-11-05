-- MIT. The approvals inbox wire decoding: the owner's replies and request
-- views read into bounded typed values, and the bounded text every request
-- string passes through before it reaches a frame.
local text = require("text")
local bounds = require("bounds")
local caller = require("caller")
local windows = require("windows")
local states = require("states")
local M = {}
M.TEXT_LIMIT = 512
M.LINE_LIMIT = 160
M.INBOX_PAGE = 64
type Object = {[string]: unknown}
type Workspace = {label: string, folder: string}
type Decision = "approved" | "denied"
type ApprovalState = states.ApprovalState
type RequestKind = states.RequestKind
type ProposalKind = "operation" | "attempt"
type Prompt = {text: string, artifact_ref: nil} | {text: nil, artifact_ref: string}
type OperationProposal = {grant_adapter: string?, kind: "operation", ref: string, revision: string, action_id: nil, input_digest: string?, payload: Object}
type AttemptProposal = {grant_adapter: string?, kind: "attempt", ref: string, revision: string, action_id: string?, input_digest: string?, payload: Object}
type Proposal = OperationProposal | AttemptProposal
type ApprovalView = {contract: Object?, effect: Object?, window_grant: windows.Grant?, allowed_by_grant: string?, window_max_ttl_ms: integer?, reallow: boolean?, requesting_session: string?,
    approval_id: string, owner_node: string, owner_incarnation: integer, workspace_id: string,
    lifecycle_records: Object?, requester_id: string, request_kind: RequestKind, policy: string, proposal: Proposal,
    proposal_digest: string, reviewed_digest: string?, prompt: Prompt, revision: integer, state: ApprovalState,
    decision: Decision?, decider_id: string?, expires_at: string, created_at: string,
    response_schema: Object?, thread_id: string?, binding: Object?, response: unknown,
    decided_at: string?, validated_incarnation: integer?, validated_by: string?, validated_at: string?,
    consumer_id: string?, consumed_effect: string?, consumed_at: string?, effect_completed_at: string?,
    effect_result: unknown, updated_at: string?, source_approval_id: string?, source_workspace_id: string?,
}
type Reply =
    {kind: "success", value: unknown, replayed: boolean?} |
    {kind: "failure", code: string, message: string, retryable: boolean?, replayed: boolean?, purged: boolean?} |
    {kind: "reset", code: "RESET_REQUIRED", message: string, oldest_seq: integer, retryable: boolean?, replayed: boolean?, purged: boolean?} |
    {kind: "conflict", code: "CONFLICT", message: string, request: ApprovalView, retryable: boolean?, replayed: boolean?, purged: boolean?} |
    {kind: "settled", code: "INVALID_STATE", message: string, request: ApprovalView, retryable: boolean?, replayed: boolean?, purged: boolean?}
-- A row is the viewer's summary of one request at the revision last seen.
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
    local extra = bounds.fields(proposal, {"kind", "ref", "revision", "action_id", "input_digest", "payload", "grant_adapter"})
    if extra then return nil, extra end
    local kind = proposal_kind(proposal.kind)
    local ref, revision = bounds.id(proposal.ref), bounds.id(proposal.revision)
    local payload = object(proposal.payload)
    local action, action_valid = optional_id(proposal.action_id)
    local adapter, adapter_valid = optional_id(proposal.grant_adapter)
    if not adapter_valid then return nil, "approval proposal grant_adapter is invalid" end
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
        return {grant_adapter = adapter, kind = "operation", ref = ref, revision = revision, action_id = nil, input_digest = digest, payload = payload}, nil
    end
    return {grant_adapter = adapter, kind = "attempt", ref = ref, revision = revision, action_id = action, input_digest = digest, payload = payload}, nil
end

function M.decode_view(value: unknown): (ApprovalView?, string?)
    local view = object(value)
    if not view then return nil, "approval view is not an object" end
    local extra = bounds.fields(view, {"approval_id", "owner_node", "owner_incarnation", "workspace_id", "requester_id", "request_kind", "policy",
        "proposal", "proposal_digest", "prompt", "response_schema", "thread_id", "binding", "revision", "state", "decision", "decider_id",
        "decided_at", "response", "validated_incarnation", "validated_by", "validated_at", "consumer_id", "consumed_effect", "consumed_at",
        "window_grant", "allowed_by_grant", "window_max_ttl_ms", "reallow", "effect_completed_at", "effect_result", "expires_at", "created_at", "updated_at", "source_approval_id", "source_workspace_id", "requesting_session", "request_digest", "contract_version", "contract", "reviewed_digest", "effect_admission_ms", "effect", "lifecycle_records"})
    if extra then return nil, extra end
    local approval_id, owner_node, workspace_id = bounds.id(view.approval_id), bounds.id(view.owner_node), bounds.id(view.workspace_id)
    local requester_id, policy = bounds.id(view.requester_id), bounds.id(view.policy)
    local owner_incarnation, revision = bounds.count(view.owner_incarnation), bounds.count(view.revision)
    local request_kind_value = states.request_kind(view.request_kind)
    local state = states.approval_state(view.state)
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
    local grant: windows.Grant? = nil
    if view.window_grant ~= nil then
        local grant_error: string? = nil
        grant, grant_error = windows.decode(view.window_grant)
        if not grant then return nil, grant_error end
        local scope_digest, scope_error = windows.scope_digest(proposal)
        if not scope_digest then return nil, scope_error end
        if grant.owner_node ~= owner_node or grant.requester_id ~= requester_id or grant.policy ~= policy
            or grant.scope_digest ~= scope_digest or state ~= "decided" or approval_decision ~= "approved" then return nil, "approval window scope differs" end
    end
    local automatic = view.allowed_by_grant == nil and nil or bounds.id(view.allowed_by_grant)
    local cap = view.window_max_ttl_ms == nil and 0 or bounds.count(view.window_max_ttl_ms)
    if cap == nil or (view.reallow ~= nil and type(view.reallow) ~= "boolean")
        or (view.allowed_by_grant ~= nil and (not automatic or not grant or automatic ~= grant.grant_id)) then return nil, "approval window metadata is invalid" end
    local contract = bounds.object(view.contract)
    local function requester_principal(value: Object): Object?
        local principal = bounds.object(value.requester)
        local actor = principal and bounds.id(principal.actor_id)
        if not principal or not actor then return nil end
        return {actor_id = actor, definition_id = bounds.id(principal.definition_id)}
    end
    local effect = bounds.object(view.effect)
    if view.effect ~= nil and (not effect or not bounds.member(effect.state, {"waiting", "authorized", "reserved", "admitted", "started", "succeeded", "failed", "canceled", "uncertain"})) then
        return nil, "approval effect state is invalid"
    end
    local decoded_view: ApprovalView = {effect = effect and {state = effect.state, receipt = bounds.object(effect.receipt)}, contract = contract and {presentation = bounds.member(contract.presentation, {"inbox", "inline", "dialog"}), requester = requester_principal(contract)}, window_grant = grant, allowed_by_grant = automatic, window_max_ttl_ms = cap, reallow = view.reallow == true, requesting_session = requesting_session, approval_id = approval_id, owner_node = owner_node, owner_incarnation = owner_incarnation, workspace_id = workspace_id,
        requester_id = requester_id, request_kind = request_kind_value, policy = policy, proposal = proposal, proposal_digest = proposal_digest, reviewed_digest = bounds.id(view.reviewed_digest),
        prompt = prompt, revision = revision, state = state, decision = approval_decision, decider_id = decider_id,
        expires_at = expires_at, created_at = created_at, response_schema = response_schema, thread_id = thread_id, binding = binding,
        response = view.response, decided_at = decided_at, validated_incarnation = validated_incarnation, validated_by = validated_by,
        lifecycle_records = bounds.object(view.lifecycle_records), validated_at = validated_at, consumer_id = consumer_id, consumed_effect = consumed_effect, consumed_at = consumed_at,
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
function M.decode_page(value: unknown, workspace: string): (InboxPage?, string?)
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
return M
