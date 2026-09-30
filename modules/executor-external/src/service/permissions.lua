-- MIT. One permission question asked by a session turn's harness, answered
-- from the approval owner. Detection reuses the harness permission adapter;
-- the request, decision and consumption reuse bee.approvals; the answer
-- reuses the driver's response shape over the placement stdin channel.
-- An approval that never decides is answered deny: a timeout never allows.
local bounds = require("bounds")
local canonical = require("canonical")
local hash = require("hash")
local permission = require("permission")
local M = {}
M.MAX_CONSUME_ATTEMPTS = 3
M.WAIT_GRACE_MS = 30000
M.MAX_INPUT_TEXT = 512
type Object = {[string]: unknown}
type Labels = {owner_id: string, attempt_id: string, action_id: string, plan_digest: string,
    workspace_id: string, session_ref: string}
type Exchange = {adapter: permission.Adapter, approver_policy: string, poll_ms: integer, ttl_ms: integer}
type ApprovalView = {approval_id: string, proposal_digest: string, owner_incarnation: integer,
    state: string, decision: string?, workspace_id: string}
type IO = {
    request_approval: (Object) -> (Object?, string?),
    read_approval: (string) -> (Object?, string?),
    consume: (string, string, string, integer) -> (boolean, string?, integer?),
    revalidate: (string, string, integer) -> (boolean, string?),
    write_stdin: (string, string) -> (boolean, string?),
    wait_ms: (integer) -> (),
    now_ms: () -> integer,
    waiting: () -> boolean,
}
local function id(value: unknown): string?
    return bounds.id(value)
end
local function approval_view(value: unknown): (ApprovalView?, string?)
    local view = bounds.object(value)
    if not view then return nil, "approval must be an object" end
    local approval_id, workspace_id = id(view.approval_id), id(view.workspace_id)
    local proposal_digest = bounds.text(view.proposal_digest, 64)
    local incarnation = bounds.count(view.owner_incarnation)
    local state = bounds.member(view.state, {"pending", "decided", "expired", "withdrawn"})
    local decision: string? = nil
    if view.decision ~= nil then
        decision = bounds.member(view.decision, {"approved", "denied"})
        if not decision then return nil, "approval decision is invalid" end
    end
    if not approval_id or not workspace_id or not proposal_digest or not incarnation or not state then
        return nil, "approval view is malformed"
    end
    if #proposal_digest ~= 64 or not proposal_digest:match("^[0-9a-f]+$") then
        return nil, "approval proposal digest is malformed"
    end
    if (state == "decided") ~= (decision ~= nil) then return nil, "approval decision disagrees with its state" end
    return {approval_id = approval_id, proposal_digest = proposal_digest, owner_incarnation = incarnation,
        state = state, decision = decision, workspace_id = workspace_id}, nil
end
local function digest_of(value: unknown): (string?, string?)
    local encoded, encode_error = canonical.encode(value)
    if not encoded then return nil, encode_error end
    local sum, hash_error = hash.sha256(encoded)
    if hash_error or not sum then return nil, "digest failed" end
    return sum, nil
end
function M.decode_exchange(adapter: permission.Adapter, value: unknown): (Exchange?, string?)
    local object = bounds.object(value)
    if not object then return nil, "permission exchange must be an object" end
    local unknown_field = bounds.fields(object, {"approver_policy", "poll_ms", "ttl_ms"})
    if unknown_field then return nil, "permission exchange: " .. unknown_field end
    local policy = id(object.approver_policy)
    if not policy then return nil, "permission exchange approver_policy is not an identifier" end
    local poll_ms = bounds.count(object.poll_ms == nil and 500 or object.poll_ms)
    if not poll_ms or poll_ms < 50 or poll_ms > 10000 then return nil, "permission exchange poll_ms is out of range" end
    local ttl_ms = bounds.count(object.ttl_ms == nil and 600000 or object.ttl_ms)
    if not ttl_ms or ttl_ms < 1000 then return nil, "permission exchange ttl_ms is out of range" end
    return {adapter = adapter, approver_policy = policy, poll_ms = poll_ms, ttl_ms = ttl_ms}, nil
end
function M.decode_labels(value: unknown): (Labels?, string?)
    local object = bounds.object(value)
    if not object then return nil, "permission labels must be an object" end
    local unknown_field = bounds.fields(object, {"owner_id", "attempt_id", "action_id", "plan_digest", "workspace_id", "session_ref"})
    if unknown_field then return nil, "permission labels: " .. unknown_field end
    local owner_id, attempt_id, action_id = id(object.owner_id), id(object.attempt_id), id(object.action_id)
    local workspace_id, session_ref = id(object.workspace_id), id(object.session_ref)
    local plan_text = bounds.text(object.plan_digest, 64)
    if not owner_id or not attempt_id or not action_id or not workspace_id or not session_ref then
        return nil, "permission labels carry invalid identities"
    end
    if not plan_text then return nil, "permission labels carry an invalid plan digest" end
    if #plan_text ~= 64 or not plan_text:match("^[0-9a-f]+$") then
        return nil, "permission labels carry an invalid plan digest"
    end
    local plan_digest: string = plan_text
    return {owner_id = owner_id, attempt_id = attempt_id, action_id = action_id, plan_digest = plan_digest,
        workspace_id = workspace_id, session_ref = session_ref}, nil
end
-- scan: permission requests among fresh observations, one per durable
-- request identity, so a redelivered stream asks once.
function M.scan(adapter: permission.Adapter, observations: {unknown}): ({permission.Request}, string?)
    local found: {permission.Request} = {}
    local seen: {[string]: boolean} = {}
    for _, raw in ipairs(observations) do
        local request, request_error = permission.request(adapter, raw)
        if request_error then return {}, request_error end
        if request and not seen[request.permission_request_id] then
            seen[request.permission_request_id] = true
            found[#found + 1] = request
        end
    end
    return found, nil
end
local function input_text(request: permission.Request): string
    local encoded = canonical.encode(request.input)
    if not encoded then return "{}" end
    if #encoded > M.MAX_INPUT_TEXT then return encoded:sub(1, M.MAX_INPUT_TEXT) .. "…" end
    return encoded
end
local function prompt_of(labels: Labels, request: permission.Request): string
    return "Session " .. labels.session_ref .. " in workspace " .. labels.workspace_id
        .. " asks " .. request.tool_name .. " " .. input_text(request)
        .. " (" .. request.prompt .. ", input " .. request.input_digest:sub(1, 12) .. ")"
end
local function proposal_of(adapter: permission.Adapter, labels: Labels, request: permission.Request): Object
    return permission.proposal(adapter, {action_id = labels.action_id, attempt_id = labels.attempt_id,
        plan_digest = labels.plan_digest}, request)
end
local function write_answer(io: IO, exchange: Exchange, request: permission.Request, write_id: string,
    allow: boolean, reason: string?): (string?, string?)
    local line: string? = nil
    local encode_error: string? = nil
    if allow then
        line, encode_error = permission.allow(exchange.adapter, request, nil)
    else
        line, encode_error = permission.deny(exchange.adapter, request, reason or "decision denied")
    end
    if not line then return nil, "encode permission response: " .. tostring(encode_error) end
    local written, write_error = io.write_stdin(write_id, line)
    if not written then return nil, "write permission response: " .. tostring(write_error) end
    if allow then return "allowed", nil end
    return "denied", nil
end
-- consume_effect: reserve the approved effect under the observed authority
-- incarnation; a restarted authority revalidates before the next attempt.
local function consume_effect(io: IO, approval: ApprovalView, effect_key: string): (boolean, string?)
    local incarnation = approval.owner_incarnation
    for _ = 1, M.MAX_CONSUME_ATTEMPTS do
        local consumed, consume_error, current = io.consume(approval.approval_id, approval.proposal_digest, effect_key, incarnation)
        if consumed then return true, nil end
        if not consume_error or not consume_error:find("REVALIDATE", 1, true) or not current then
            return false, "consume: " .. tostring(consume_error)
        end
        local revalidated, revalidate_error = io.revalidate(approval.approval_id, approval.proposal_digest, current)
        if not revalidated then return false, "revalidate: " .. tostring(revalidate_error) end
        incarnation = current
    end
    return false, "consume: the authority restarted during consumption"
end
type Pending = {request: permission.Request, approval_id: string, proposal_digest: string,
    incarnation: integer, write_id: string, effect_key: string, deadline_ms: integer, answered: boolean}
type Drive = {adapter: permission.Adapter, exchange: Exchange?, labels: Labels?, broken: string?}
type PlanExchange = {adapter: permission.Adapter, approver_policy: string, poll_ms: integer, ttl_ms: integer}
type PlanRequest = {owner_id: string, attempt_id: string, action_id: string, workspace_id: string?, session_ref: string?}
type TurnPlan = {exchange: PlanExchange?, exchange_refusal: string?, request: PlanRequest, plan_digest: string}
-- drive: the turn's permission exchange from its measured plan. No exchange
-- means the host did not enable one; a broken drive still carries the
-- adapter so an asked question fails loudly instead of hanging.
function M.drive(plan: TurnPlan?): Drive?
    if not plan or not plan.exchange then return nil end
    local declared = plan.exchange
    if plan.exchange_refusal then
        return {adapter = declared.adapter, exchange = nil, labels = nil,
            broken = "permission exchange refused: " .. plan.exchange_refusal}
    end
    local exchange, exchange_error = M.decode_exchange(declared.adapter,
        {approver_policy = declared.approver_policy, poll_ms = declared.poll_ms, ttl_ms = declared.ttl_ms})
    if not exchange then
        return {adapter = declared.adapter, exchange = nil, labels = nil, broken = tostring(exchange_error)}
    end
    local asking = plan.request
    local labels, labels_error = M.decode_labels({owner_id = asking.owner_id, attempt_id = asking.attempt_id,
        action_id = asking.action_id, plan_digest = plan.plan_digest, workspace_id = asking.workspace_id,
        session_ref = asking.session_ref})
    if not labels then
        return {adapter = declared.adapter, exchange = nil, labels = nil, broken = tostring(labels_error)}
    end
    return {adapter = declared.adapter, exchange = exchange, labels = labels, broken = nil}
end
-- request: ask the owner once under the durable idempotency key. The
-- returned pending carries every identity the later poll needs.
function M.request(io: IO, exchange: Exchange, labels: Labels, found: permission.Request): (Pending?, string?)
    local proposal = proposal_of(exchange.adapter, labels, found)
    local proposal_digest, digest_error = digest_of(proposal)
    if not proposal_digest then return nil, "measure permission proposal: " .. tostring(digest_error) end
    local identity = permission.identity(labels.owner_id, labels.attempt_id, found.permission_request_id)
    local requested, request_error_text = io.request_approval({workspace_id = labels.workspace_id,
        idempotency_key = permission.idempotency_key(identity), request_kind = "permission",
        policy = exchange.approver_policy, proposal = proposal, prompt = {text = prompt_of(labels, found)},
        ttl_ms = exchange.ttl_ms})
    if not requested then return nil, "request approval: " .. tostring(request_error_text) end
    local approval, view_error = approval_view(requested)
    if not approval then return nil, "approval owner returned malformed data: " .. tostring(view_error) end
    if approval.workspace_id ~= labels.workspace_id or approval.proposal_digest ~= proposal_digest then
        return nil, "approval owner recorded a different workspace or proposal digest"
    end
    return {request = found, approval_id = approval.approval_id, proposal_digest = proposal_digest,
        incarnation = approval.owner_incarnation, write_id = permission.write_id(identity),
        effect_key = permission.effect_key(identity),
        deadline_ms = io.now_ms() + exchange.ttl_ms + M.WAIT_GRACE_MS, answered = false}, nil
end
-- poll: one decision check for a pending request. "wait" keeps polling;
-- anything but an approved, consumed decision is answered deny; "closed"
-- writes nothing because the harness no longer waits.
function M.poll(io: IO, exchange: Exchange, pending: Pending): (string?, string?)
    if not io.waiting() then return "closed", nil end
    local current, read_error = io.read_approval(pending.approval_id)
    if not current then return nil, "read approval: " .. tostring(read_error) end
    local approval, view_error = approval_view(current)
    if not approval then return nil, "approval owner returned malformed data: " .. tostring(view_error) end
    if approval.approval_id ~= pending.approval_id or approval.proposal_digest ~= pending.proposal_digest then
        return nil, "approval owner returned another approval or proposal"
    end
    if approval.state == "decided" and approval.decision == "approved" then
        local approval_state: ApprovalView = {approval_id = approval.approval_id,
            proposal_digest = approval.proposal_digest, owner_incarnation = approval.owner_incarnation,
            state = approval.state, decision = approval.decision, workspace_id = approval.workspace_id}
        local consumed, consume_error = consume_effect(io, approval_state, pending.effect_key)
        if not consumed then return nil, tostring(consume_error) end
        pending.answered = true
        return write_answer(io, exchange, pending.request, pending.write_id, true, nil)
    end
    if approval.state == "decided" or approval.state == "expired" or approval.state == "withdrawn" then
        pending.answered = true
        return write_answer(io, exchange, pending.request, pending.write_id, false, "decision " .. approval.state)
    end
    if io.now_ms() > pending.deadline_ms then
        pending.answered = true
        return write_answer(io, exchange, pending.request, pending.write_id, false, "permission wait timed out")
    end
    return "wait", nil
end
-- answer: ask the owner once under the durable idempotency key, wait for the
-- person's decision, and send exactly one response down the stdin channel.
-- Anything but an approved, consumed decision is answered deny.
function M.answer(io: IO, exchange: Exchange, labels: Labels, observation: unknown): (string?, string?)
    local found, request_error = permission.request(exchange.adapter, observation)
    if request_error then return nil, request_error end
    if not found then return nil, "observation is not a permission request" end
    local pending, pending_error = M.request(io, exchange, labels, found)
    if not pending then return nil, pending_error end
    while true do
        local outcome, poll_error = M.poll(io, exchange, pending)
        if not outcome then return nil, poll_error end
        if outcome ~= "wait" then return outcome, nil end
        io.wait_ms(exchange.poll_ms)
    end
end
return M
