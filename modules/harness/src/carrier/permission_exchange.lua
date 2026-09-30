-- MIT. Durable permission exchange and approval state transitions for a carrier attempt.
local json = require("json")
local bounds = require("bounds")
local permission = require("permission")
local checkpoint = require("checkpoint")
local placement_decode = require("placement_decode")
local service_reply = require("service_reply")
local carrier_types = require("carrier_types")
local M = {}
M.MAX_CONSUME_ATTEMPTS = 3
type IO = carrier_types.IO
type Request = carrier_types.Request
type Exchange = carrier_types.Exchange
type Plan = carrier_types.Plan
type Session = carrier_types.Session
type PermissionEventPhase = "refused" | "intended" | "acknowledged" | "requested" | "decided" | "revalidated" | "consumed" | "declined" | "closed"
type Context = {approvals: string, max_consume_attempts: integer,
    commit: (IO, Session, {{[string]: unknown}}) -> (boolean, string?),
    must: (IO, string, unknown) -> (unknown, string?), step: (IO, string) -> (),
    digest_of: (unknown) -> (string?, string?), plan: (IO, Request) -> (Plan?, string?),
    placement_target: (Plan, string) -> string?, write: (IO, Session, string, string) -> (boolean, string?),
    settle_write: (IO, Session, string, string, string?) -> (boolean, string?),
    thread_call: (IO, Request, string, {[string]: unknown}, string?) -> (unknown, string?),
    drain_hooks: (IO, Session) -> (integer, string?)}
local function reply_of(value: unknown, err: string?): (service_reply.Reply?, string?)
    if err then return nil, err end
    return service_reply.decode(value)
end
local function permission_record(session: Session, state: checkpoint.Permission, phase: PermissionEventPhase, extra: {[string]: unknown}): {[string]: unknown}
    local payload: {[string]: unknown} = {permission_request_id = state.permission_request_id, correlation_id = state.correlation_id, tool_name = state.tool_name, input_digest = state.input_digest,
        proposal_digest = state.proposal_digest, idempotency_key = state.idempotency_key, effect_key = state.effect_key, write_id = state.write_id, attempt_id = session.plan.request.attempt_id,
        attachment_generation = session.epoch, phase = phase}
    local key = "permission:" .. state.permission_request_id .. ":" .. phase
    for name, value in pairs(extra) do
        payload[name] = value
        if name == "incarnation" then key = key .. ":" .. tostring(value) end
    end
    local record: {[string]: unknown} = {source = "bee", body = {type = "extension", event_key = key, data = {type = "extension", event_name = "bee.carrier.permission", event_revision = "1", payload_json = json.encode(payload)}}}
    if session.turn_open then record.turn_id = session.turn_id end
    return record
end
local function request_of(state: checkpoint.Permission): permission.Request
    return {permission_request_id = state.permission_request_id, correlation_id = state.correlation_id, acknowledgment_id = state.acknowledgment_id or state.correlation_id, tool_name = state.tool_name,
        input_digest = state.input_digest, input = {}, prompt = state.prompt}
end
local function proposal_of(session: Session, exchange: Exchange, state: checkpoint.Permission): {[string]: unknown}
    local request = session.plan.request
    return permission.proposal(exchange.adapter, {action_id = request.action_id, attempt_id = request.attempt_id, plan_digest = session.plan.plan_digest}, request_of(state))
end
local function live_permissions(session: Session): {permission.Request}
    local pending: {permission.Request} = {}
    for _, state in ipairs(session.checkpoint.permissions) do
        if state.phase ~= "closed" and state.phase ~= "acknowledged" then pending[#pending + 1] = request_of(state) end
    end
    return pending
end
-- detect: permission requests among a chunk's observations become intents
-- in the checkpoint and intent records in the same commit; a request the
-- protocol could not tell apart from a pending one is refused on record.
function M.detect(ctx: Context, session: Session, records: {{[string]: unknown}}): (integer, string?)
    local exchange = session.plan.exchange
    if not exchange then return 0, nil end
    local added = 0
    local count = #records
    for index = 1, count do
        local record = records[index]
        local found, request_error = permission.request(exchange.adapter, record.body)
        if request_error then return added, request_error end
        if found then
            local known = false
            for _, state in ipairs(session.checkpoint.permissions) do
                if state.permission_request_id == found.permission_request_id then known = true end
            end
            if not known then
                local admitted, ambiguity = permission.admit_pending(live_permissions(session), found)
                local identity = permission.identity(session.plan.request.owner_id, session.plan.request.attempt_id, found.permission_request_id)
                local proposal_digest = ctx.digest_of(permission.proposal(exchange.adapter, {action_id = session.plan.request.action_id, attempt_id = session.plan.request.attempt_id, plan_digest = session.plan.plan_digest}, found)) or ""
                local state: checkpoint.Permission = {permission_request_id = found.permission_request_id, correlation_id = found.correlation_id, acknowledgment_id = found.acknowledgment_id, tool_name = found.tool_name, input_digest = found.input_digest,
                    prompt = found.prompt, proposal_digest = proposal_digest, idempotency_key = permission.idempotency_key(identity), effect_key = permission.effect_key(identity),
                    write_id = permission.write_id(identity), phase = "intended", approval_id = nil, decision = nil, incarnation = nil, response = nil}
                if not admitted or #session.checkpoint.permissions >= checkpoint.MAX_PERMISSIONS then
                    state.phase = "closed"
                    records[#records + 1] = permission_record(session, state, "refused", {reason = ambiguity or ("more than " .. tostring(checkpoint.MAX_PERMISSIONS) .. " permission requests in one attempt")})
                else
                    session.checkpoint.permissions[#session.checkpoint.permissions + 1] = state
                    records[#records + 1] = permission_record(session, state, "intended", {})
                    added = added + 1
                end
            end
        end
    end
    return added, nil
end
-- Acknowledgments: a written response is acknowledged by the observation
-- the adapter names for its decision; a denial an adapter cannot name
-- stays written, and settlement reports it as unproven.
function M.acknowledge(session: Session, records: {{[string]: unknown}})
    local exchange = session.plan.exchange
    if not exchange then return end
    local count = #records
    for _, state in ipairs(session.checkpoint.permissions) do
        if state.phase == "written" then
            for index = 1, count do
                local body = records[index].body
                local acknowledged = false
                if state.decision == "approved" then
                    acknowledged = permission.acknowledged(exchange.adapter, request_of(state), body)
                else
                    acknowledged = permission.deny_acknowledged(exchange.adapter, request_of(state), body)
                end
                if acknowledged and state.phase == "written" then
                    state.phase = "acknowledged"
                    records[#records + 1] = permission_record(session, state, "acknowledged", {})
                end
            end
        end
    end
end
-- The runner may forget every chunk through this sequence: all of it is
-- committed, and no partial frame beyond the checkpoint's carry needs it.
type ApprovalDecision = "approved" | "denied"
type ApprovalView =
    {approval_id: string, workspace_id: string, proposal_digest: string, owner_incarnation: integer, state: "decided", decision: ApprovalDecision}
    | {approval_id: string, workspace_id: string, proposal_digest: string, owner_incarnation: integer,
        state: "pending" | "expired" | "withdrawn", decision: nil}
local function approval_view(value: unknown): (ApprovalView?, string?)
    local view = bounds.object(value)
    if not view then return nil, "approval must be an object" end
    local unknown_field = bounds.fields(view, {"approval_id", "owner_node", "owner_incarnation", "workspace_id", "requester_id", "request_kind", "policy",
        "proposal", "proposal_digest", "prompt", "response_schema", "thread_id", "binding", "revision", "state", "decision", "decider_id",
        "decided_at", "response", "validated_incarnation", "validated_by", "validated_at", "consumer_id", "consumed_effect", "consumed_at",
        "effect_completed_at", "effect_result", "expires_at", "created_at", "updated_at"})
    if unknown_field then return nil, "approval: " .. unknown_field end
    local approval_id, workspace_id = bounds.id(view.approval_id), bounds.id(view.workspace_id)
    local proposal_digest = bounds.text(view.proposal_digest, 64)
    local incarnation, state = bounds.count(view.owner_incarnation), bounds.member(view.state, {"pending", "decided", "expired", "withdrawn"})
    local decision: ApprovalDecision? = nil
    if view.decision ~= nil then
        local selected = bounds.member(view.decision, {"approved", "denied"})
        if selected == "approved" then decision = "approved"
        elseif selected == "denied" then decision = "denied"
        else return nil, "approval decision is invalid" end
    end
    if not approval_id then return nil, "approval identifier is malformed" end
    if not workspace_id then return nil, "approval workspace is malformed" end
    if proposal_digest == nil then return nil, "approval proposal digest is malformed" end
    if #proposal_digest ~= 64 or not proposal_digest:match("^[0-9a-f]+$") then return nil, "approval proposal digest is malformed" end
    if incarnation == nil or incarnation < 1 then return nil, "approval owner incarnation is malformed" end
    if not state then return nil, "approval state is malformed" end
    if (state == "decided") ~= (decision ~= nil) then return nil, "approval decision disagrees with its state" end
    if state == "decided" then
        if decision == "approved" then
            return {approval_id = approval_id, workspace_id = workspace_id, proposal_digest = proposal_digest,
                owner_incarnation = incarnation, state = "decided", decision = "approved"}, nil
        elseif decision == "denied" then
            return {approval_id = approval_id, workspace_id = workspace_id, proposal_digest = proposal_digest,
                owner_incarnation = incarnation, state = "decided", decision = "denied"}, nil
        end
        return nil, "decided approval has no decision"
    end
    if decision ~= nil then return nil, "undecided approval carries a decision" end
    if state == "pending" then
        return {approval_id = approval_id, workspace_id = workspace_id, proposal_digest = proposal_digest,
            owner_incarnation = incarnation, state = "pending", decision = nil}, nil
    elseif state == "expired" then
        return {approval_id = approval_id, workspace_id = workspace_id, proposal_digest = proposal_digest,
            owner_incarnation = incarnation, state = "expired", decision = nil}, nil
    end
    return {approval_id = approval_id, workspace_id = workspace_id, proposal_digest = proposal_digest,
        owner_incarnation = incarnation, state = "withdrawn", decision = nil}, nil
end
-- request_approval: the durable intent is asked under its idempotency key,
-- so a crash between the owner creating the approval and the checkpoint
-- recording it replays the same approval.
local function request_approval(ctx: Context, io: IO, session: Session, exchange: Exchange, state: checkpoint.Permission): (boolean, string?)
    local request = session.plan.request
    local value, err = ctx.must(io, ctx.approvals .. ":request", {workspace_id = request.workspace_id, idempotency_key = state.idempotency_key, request_kind = "permission", policy = exchange.approver_policy,
        proposal = proposal_of(session, exchange, state), prompt = {text = state.prompt}, thread_id = request.thread_id, ttl_ms = exchange.ttl_ms})
    if err then return false, err end
    ctx.step(io, "approval_created")
    local view, view_error = approval_view(value)
    if not view then return false, "approval owner returned malformed data: " .. tostring(view_error) end
    if view.workspace_id ~= request.workspace_id or view.proposal_digest ~= state.proposal_digest then
        return false, "approval owner recorded a different workspace or proposal digest"
    end
    state.approval_id = view.approval_id
    state.incarnation = view.owner_incarnation
    state.phase = "requested"
    local committed, commit_error = ctx.commit(io, session, {permission_record(session, state, "requested", {approval_id = state.approval_id})})
    if not committed then return false, commit_error end
    ctx.step(io, "permission_requested")
    return true, nil
end
local function poll_decision(ctx: Context, io: IO, session: Session, state: checkpoint.Permission): (boolean, string?)
    if not state.approval_id then return false, "approval id is missing" end
    local value, err = ctx.must(io, ctx.approvals .. ":read", {approval_id = state.approval_id})
    if err then return false, err end
    local view, view_error = approval_view(value)
    if not view then return false, "approval owner returned malformed data: " .. tostring(view_error) end
    if view.approval_id ~= state.approval_id or view.proposal_digest ~= state.proposal_digest then
        return false, "approval owner returned another approval or proposal"
    end
    local decision: checkpoint.PermissionDecision
    if view.state == "decided" then
        if not view.decision then return false, "decided approval has no decision" end
        decision = view.decision
    elseif view.state == "expired" then
        decision = "expired"
    elseif view.state == "withdrawn" then
        decision = "withdrawn"
    else
        return true, nil
    end
    state.decision = decision
    state.phase = "decided"
    local committed, commit_error = ctx.commit(io, session, {permission_record(session, state, "decided", {decision = decision})})
    if not committed then return false, commit_error end
    ctx.step(io, "permission_decided")
    return true, nil
end
local function close_permission(ctx: Context, io: IO, session: Session, state: checkpoint.Permission, reason: string): (boolean, string?)
    state.phase = "closed"
    return ctx.commit(io, session, {permission_record(session, state, "closed", {reason = reason})})
end
-- revalidate_context: before consuming under a new authority incarnation
-- and before any dispatch after recovery, the carrier re-checks everything
-- the approval was bound to: the attempt still waits with a bound runner,
-- the launch policy, binding, profile, adapter and acceptance still measure
-- as planned, the proposal still digests the same, and the placement,
-- reconciled now, still runs under its grants and projections.
local function revalidate_context(ctx: Context, io: IO, session: Session, exchange: Exchange, state: checkpoint.Permission): string?
    if session.terminal or session.settled or not session.runner then return "attempt no longer waiting" end
    local recorded = session.checkpoint.plan_digest
    if not recorded then return "the checkpoint records no plan digest" end
    local fresh, plan_error = ctx.plan(io, session.plan.request)
    if not fresh then return "measurements unavailable: " .. tostring(plan_error) end
    if fresh.exchange_refusal then return fresh.exchange_refusal end
    if fresh.plan_digest ~= recorded then return "plan measurements changed since the checkpoint" end
    local current = fresh.exchange
    if not current then return "permission exchange no longer enabled" end
    if current.adapter.digest ~= exchange.adapter.digest then return "permission adapter changed" end
    if current.acceptance_digest ~= exchange.acceptance_digest then return "acceptance record changed" end
    local proposal_digest = ctx.digest_of(proposal_of(session, exchange, state))
    if proposal_digest ~= state.proposal_digest then return "proposal no longer digests as recorded" end
    local reconcile_target = ctx.placement_target(session.plan, "reconcile")
    if not reconcile_target then return "selected placement binds no reconcile" end
    local reconciled, reconcile_error = ctx.must(io, reconcile_target, {attempt_id = session.plan.request.attempt_id})
    if reconcile_error then return "placement reconcile: " .. reconcile_error end
    local attempt, attempt_decode_error = placement_decode.attempt(reconciled)
    if not attempt then return "placement reconcile returned an invalid attempt: " .. tostring(attempt_decode_error) end
    if attempt.execution_state ~= "running" then return "placement is " .. tostring(attempt.execution_state) .. " under its grants and projections" end
    return nil
end
-- consume_effect: the effect is reserved under the authority incarnation the
-- carrier observed; a restarted authority answers REVALIDATE with its current
-- incarnation, the carrier re-checks its own domain, records the validation
-- and asks again. Replays are safe, so a resumed carrier repeats this
-- before creating its write intent.
local function consume_effect(ctx: Context, io: IO, session: Session, state: checkpoint.Permission): (boolean, string?)
    if not state.approval_id or not state.incarnation then return false, "approval identity or incarnation is missing" end
    for _ = 1, ctx.max_consume_attempts do
        local raw, call_error = io.call(ctx.approvals .. ":consume", {approval_id = state.approval_id, proposal_digest = state.proposal_digest, effect_key = state.effect_key, owner_incarnation = state.incarnation})
        local reply, reply_error = reply_of(raw, call_error)
        if not reply then return false, "consume: " .. tostring(reply_error) end
        if reply.ok then return true, nil end
        local fault = reply.error or {code = "INTERNAL", message = "consume failed"}
        if fault.code ~= "REVALIDATE" then return false, "consume: " .. fault.code .. ": " .. fault.message end
        local validation = bounds.object(reply.value)
        if not validation then return false, "consume: revalidation details must be an object" end
        local validation_field = bounds.fields(validation, {"request", "current_incarnation"})
        local current = bounds.count(validation.current_incarnation)
        if validation_field or not current or current < 1 then return false, "consume: revalidation names no valid incarnation" end
        local observed, observed_error = approval_view(validation.request)
        if not observed then return false, "consume: revalidation approval is malformed: " .. tostring(observed_error) end
        if observed.approval_id ~= state.approval_id or observed.proposal_digest ~= state.proposal_digest then
            return false, "consume: revalidation names another approval or proposal"
        end
        local exchange = session.plan.exchange
        if not exchange then return false, "consume: no permission exchange" end
        local refused = revalidate_context(ctx, io, session, exchange, state)
        if refused then return close_permission(ctx, io, session, state, "revalidation refused: " .. refused) end
        local _, revalidate_error = ctx.must(io, ctx.approvals .. ":revalidate", {approval_id = state.approval_id, proposal_digest = state.proposal_digest, owner_incarnation = current})
        if revalidate_error then return false, revalidate_error end
        state.incarnation = current
        local committed, commit_error = ctx.commit(io, session, {permission_record(session, state, "revalidated", {incarnation = current})})
        if not committed then return false, commit_error end
        ctx.step(io, "permission_revalidated")
    end
    return false, "consume: the authority restarted " .. tostring(ctx.max_consume_attempts) .. " times during consumption"
end
local function write_response(ctx: Context, io: IO, session: Session, exchange: Exchange, state: checkpoint.Permission): (boolean, string?)
    if not session.runner then return true, nil end
    local line = state.response
    if not line then return false, "permission response is missing" end
    if session.recovered then
        local refused = revalidate_context(ctx, io, session, exchange, state)
        if refused then return close_permission(ctx, io, session, state, "revalidation refused before dispatch: " .. refused) end
    end
    state.phase = "written"
    return ctx.write(io, session, state.write_id, line)
end
-- advance_permissions: drives every exchange forward from what the
-- checkpoint holds. Polling the owner happens only on the poll tick.
function M.advance(ctx: Context, io: IO, session: Session, poll: boolean): (boolean, string?)
    local exchange = session.plan.exchange
    if not exchange then return true, nil end
    for _, state in ipairs(session.checkpoint.permissions) do
        if state.phase == "intended" then
            local ok, err = request_approval(ctx, io, session, exchange, state)
            if not ok then return false, err end
        end
        if state.phase == "requested" and poll then
            local ok, err = poll_decision(ctx, io, session, state)
            if not ok then return false, err end
        end
        if state.phase == "decided" then
            local waiting = session.terminal == nil and not session.eof.stdout and session.runner ~= nil
            local settled = session.settled ~= nil or session.terminal ~= nil
            local outcome = permission.outcome(exchange.adapter, state.decision or "", waiting, settled)
            if outcome == "allow" then
                local consumed, consume_error = consume_effect(ctx, io, session, state)
                if not consumed then return false, consume_error end
                if state.phase == "decided" then
                    local line, encode_error = permission.allow(exchange.adapter, request_of(state), nil)
                    if not line then return false, "encode allow: " .. tostring(encode_error) end
                    state.response = line
                    state.phase = "consumed"
                    local committed, commit_error = ctx.commit(io, session, {permission_record(session, state, "consumed", {})})
                    if not committed then return false, commit_error end
                    ctx.step(io, "permission_consumed")
                end
            elseif outcome == "deny" then
                -- A denial or expiry reserves the response write only; no
                -- effect is consumed and nothing authorizes the tool.
                local line, encode_error = permission.deny(exchange.adapter, request_of(state), "decision " .. tostring(state.decision))
                if not line then return false, "encode deny: " .. tostring(encode_error) end
                state.response = line
                state.phase = "declined"
                local committed, commit_error = ctx.commit(io, session, {permission_record(session, state, "declined", {})})
                if not committed then return false, commit_error end
            else
                local closed, close_error = close_permission(ctx, io, session, state, "decision " .. tostring(state.decision) .. " arrived while not waiting")
                if not closed then return false, close_error end
            end
        end
        if state.phase == "consumed" then
            local consumed, consume_error = consume_effect(ctx, io, session, state)
            if not consumed then return false, consume_error end
        end
        if state.phase == "consumed" or state.phase == "declined" then
            local written, write_error = write_response(ctx, io, session, exchange, state)
            if not written then return false, write_error end
        end
    end
    return true, nil
end
function M.close_exchanges(ctx: Context, io: IO, session: Session, drain_elapsed: boolean): (boolean, string?)
    if #session.checkpoint.pending_writes > 0 then
        if not drain_elapsed then return false, nil end
        local pending = session.checkpoint.pending_writes
        for _, write in ipairs(pending) do
            local settled, err = ctx.settle_write(io, session, write.write_id, "uncertain", "no acknowledgment before settlement")
            if not settled then return false, err end
        end
    end
    for _, state in ipairs(session.checkpoint.permissions) do
        if state.phase ~= "closed" and state.phase ~= "acknowledged" then
            local reason = "settled while " .. state.phase
            if state.phase == "written" then reason = "response accepted by the input transport, harness acknowledgment unproven" end
            local closed, close_error = close_permission(ctx, io, session, state, reason)
            if not closed then return false, close_error end
        end
    end
    return true, nil
end

return M
