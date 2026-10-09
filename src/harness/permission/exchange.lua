-- SPDX-License-Identifier: MIT
-- Durable permission decisions shared by stream carriers, executor turns and hooks.
local json = require("json")
local canonical = require("canonical")
local bounds = require("bounds")
local permission = require("permission")
local checkpoint = require("checkpoint")
local service_reply = require("service_reply")
local preferences = require("preferences")
local M = {}
M.MAX_CONSUME_ATTEMPTS = 3
type Object = {[string]: unknown}
type Request = {owner_id: string, attempt_id: string, action_id: string, thread_id: string,
    workspace_id: string?, session_ref: string?, preferences: preferences.Value?}
type Exchange = {answer_mode: string?, adapter: permission.Adapter, approver_policy: string, poll_ms: integer, ttl_ms: integer}
type State = {binding_id: string?, request: Request, plan_digest: string, exchange: Exchange?, permissions: {checkpoint.Permission},
    epoch: integer, turn_id: string?, proposal_kind: "operation" | "attempt"?}
type PermissionEventPhase = "refused" | "intended" | "acknowledged" | "requested" | "decided" | "revalidated" | "consumed" | "declined" | "closed"
type Context = {state: State, recovered: boolean?, now_ms: () -> integer, approvals: string, max_consume_attempts: integer,
    commit: ({Object}) -> (boolean, string?), call: (string, unknown) -> (unknown, string?),
    step: (string) -> (), digest_of: (unknown) -> (string?, string?),
    write: (string, string) -> (boolean, string?), revalidate: () -> string?,
    waiting: () -> boolean, settled: () -> boolean}
local function must(ctx: Context, target: string, value: unknown): (unknown, string?)
    local raw, err = ctx.call(target, value)
    if err then return nil, err end
    local reply, decode_error = service_reply.decode(raw)
    if not reply then return nil, decode_error end
    if not reply.ok then
        local fault = reply.error or {code = "INTERNAL", message = "owner refused the request"}
        return nil, fault.code .. ": " .. fault.message
    end
    return reply.value, nil
end
local function reply_of(value: unknown, err: string?): (service_reply.Reply?, string?)
    if err then return nil, err end
    return service_reply.decode(value)
end
local function permission_record(session: State, state: checkpoint.Permission, phase: PermissionEventPhase, extra: {[string]: unknown}): {[string]: unknown}
    local payload: {[string]: unknown} = {permission_request_id = state.permission_request_id, correlation_id = state.correlation_id, tool_name = state.tool_name, input_digest = state.input_digest,
        proposal_digest = state.proposal_digest, idempotency_key = state.idempotency_key, effect_key = state.effect_key, write_id = state.write_id, attempt_id = session.request.attempt_id,
        attachment_generation = session.epoch, phase = phase}
    local key = "permission:" .. state.permission_request_id .. ":" .. phase
    for name, value in pairs(extra) do
        payload[name] = value
        if name == "incarnation" then key = key .. ":" .. tostring(value) end
    end
    local record: {[string]: unknown} = {source = "bee", body = {type = "extension", event_key = key, data = {type = "extension", event_name = "bee.carrier.permission", event_revision = "1", payload_json = json.encode(payload)}}}
    if session.turn_id then record.turn_id = session.turn_id end
    return record
end
local function request_of(state: checkpoint.Permission): permission.Request
    return {permission_request_id = state.permission_request_id, correlation_id = state.correlation_id, acknowledgment_id = state.acknowledgment_id or state.correlation_id, tool_name = state.tool_name,
        input_digest = state.input_digest, input = {}, prompt = state.prompt}
end
local function proposal_of(session: State, exchange: Exchange, found: permission.Request): {[string]: unknown}
    local request = session.request
    local proposal = permission.proposal(exchange.adapter, {action_id = request.action_id, attempt_id = request.attempt_id, plan_digest = session.plan_digest}, found)
    if session.proposal_kind == "operation" then
        proposal.kind = "operation"
        proposal.action_id = nil
        local payload = bounds.object(proposal.payload) or {}
        payload.action_id = request.action_id
        payload.session_ref = request.session_ref
        proposal.payload = payload
    end
    return proposal
end
local function ctx_input(value: unknown): string?
    local text = canonical.encode(value)
    if not text then return nil end
    return text:sub(1, 512)
end
local function live_permissions(session: State): {permission.Request}
    local pending: {permission.Request} = {}
    for _, state in ipairs(session.permissions) do
        if state.phase ~= "closed" and state.phase ~= "acknowledged" then pending[#pending + 1] = request_of(state) end
    end
    return pending
end
-- detect: permission requests among a chunk's observations become intents
-- in the checkpoint and intent records in the same commit; a request the
-- protocol could not tell apart from a pending one is refused on record.
function M.detect(ctx: Context, records: {{[string]: unknown}}): (integer, string?)
    local session = ctx.state
    local exchange = session.exchange
    if not exchange then return 0, nil end
    local added = 0
    local count = #records
    for index = 1, count do
        local record = records[index]
        local found, request_error = permission.request(exchange.adapter, record.body)
        if request_error then return added, request_error end
        if found then
            local known = false
            for _, state in ipairs(session.permissions) do
                if state.permission_request_id == found.permission_request_id then known = true end
            end
            if not known then
                local admitted, ambiguity = permission.admit_pending(live_permissions(session), found)
                local identity = permission.identity(session.request.owner_id, session.request.attempt_id, found.permission_request_id)
                local proposal_digest, digest_error = ctx.digest_of(proposal_of(session, exchange, found))
                if not proposal_digest then return added, digest_error or "permission proposal is not measurable" end
                local state: checkpoint.Permission = {permission_request_id = found.permission_request_id, correlation_id = found.correlation_id, acknowledgment_id = found.acknowledgment_id, tool_name = found.tool_name, input_digest = found.input_digest,
                    prompt = "Session " .. (session.request.session_ref or session.request.action_id) .. " in workspace " .. (session.request.workspace_id or "unknown")
                        .. " asks " .. found.tool_name .. " " .. ((ctx_input(found.input)) or "{}") .. " (" .. found.prompt .. ")", proposal_digest = proposal_digest, idempotency_key = permission.idempotency_key(identity), effect_key = permission.effect_key(identity),
                    write_id = permission.write_id(identity), deadline_ms = ctx.now_ms() + exchange.ttl_ms, phase = "intended", approval_id = nil, decision = nil, incarnation = nil, response = nil}
                if not admitted or #session.permissions >= checkpoint.MAX_PERMISSIONS then
                    state.phase = "closed"
                    records[#records + 1] = permission_record(session, state, "refused", {reason = ambiguity or ("more than " .. tostring(checkpoint.MAX_PERMISSIONS) .. " permission requests in one attempt")})
                else
                    session.permissions[#session.permissions + 1] = state
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
function M.acknowledge(ctx: Context, records: {{[string]: unknown}})
    local session = ctx.state
    local exchange = session.exchange
    if not exchange then return end
    local count = #records
    for _, item in ipairs(session.permissions) do
        local state: checkpoint.Permission = item
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
    local unknown_field = bounds.fields(view, {"approval_id", "owner_node", "owner_incarnation", "workspace_id", "requester_id", "requesting_session", "request_kind", "policy",
        "proposal", "proposal_digest", "prompt", "response_schema", "thread_id", "binding", "revision", "state", "decision", "decider_id",
        "decided_at", "response", "validated_incarnation", "validated_by", "validated_at", "consumer_id", "consumed_effect", "consumed_at",
        "window_grant", "allowed_by_grant", "window_max_ttl_ms", "reallow", "effect_completed_at", "effect_result", "expires_at", "created_at", "updated_at", "request_digest", "contract_version", "contract", "reviewed_digest", "effect_admission_ms", "effect", "lifecycle_records"})
    if unknown_field then return nil, "approval: " .. unknown_field end
    if view.requesting_session ~= nil and not bounds.id(view.requesting_session) then return nil, "approval requesting session is malformed" end
    local approval_id, workspace_id = bounds.id(view.approval_id), bounds.id(view.workspace_id)
    local proposal_digest = bounds.text(view.proposal_digest, 64)
    local incarnation, state = bounds.count(view.owner_incarnation), bounds.member(view.state, {"pending", "decided", "expired", "withdrawn", "superseded", "invalidated"})
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
local function request_approval(ctx: Context, session: State, exchange: Exchange, state: checkpoint.Permission): (boolean, string?)
    local request = session.request
    for _, ref in ipairs(request.preferences and request.preferences.bee and request.preferences.bee.approval_leases or {}) do
        local raw, call_error = ctx.call(ctx.approvals .. ":runtime_lease", {operation = "use", lease_ref = ref, workspace_id = request.workspace_id,
            tool = state.tool_name, input_digest = state.input_digest, effect_key = state.effect_key})
        local reply, err = reply_of(raw, call_error)
        if not reply then return false, "runtime lease: " .. tostring(err) end
        if reply.ok then
            local value = bounds.object(reply.value)
            if not value or value.lease_ref ~= ref or value.consumed ~= true then return false, "runtime lease owner returned a different effect" end
            state.lease_ref = ref; state.decision = "approved"; state.phase = "decided"
            return ctx.commit({permission_record(session, state, "decided", {lease_ref = ref, decision = "approved"})})
        end
        local fault = reply.error
        if not fault or (fault.code ~= "DENIED" and fault.code ~= "NOT_FOUND") then return false, "runtime lease: " .. (fault and fault.message or "invalid owner reply") end
    end
    local value, err = must(ctx, ctx.approvals .. ":request", {contract_version = 2,
        origin = {instance_id = session.binding_id, session_id = request.session_ref, thread_id = request.thread_id, action_id = request.action_id, attempt_id = request.attempt_id},
        workspace_id = request.workspace_id, idempotency_key = state.idempotency_key, request_kind = "permission", policy = exchange.approver_policy,
        proposal = proposal_of(session, exchange, request_of(state)), prompt = {text = state.prompt}, thread_id = request.thread_id, ttl_ms = exchange.ttl_ms})
    if err then return false, err end
    ctx.step( "approval_created")
    local view, view_error = approval_view(value)
    if not view then return false, "approval owner returned malformed data: " .. tostring(view_error) end
    if view.workspace_id ~= request.workspace_id or view.proposal_digest ~= state.proposal_digest then
        return false, "approval owner recorded a different workspace or proposal digest"
    end
    state.approval_id = view.approval_id
    state.incarnation = view.owner_incarnation
    state.phase = "requested"
    local committed, commit_error = ctx.commit( {permission_record(session, state, "requested", {approval_id = state.approval_id})})
    if not committed then return false, commit_error end
    ctx.step( "permission_requested")
    return true, nil
end
local function poll_decision(ctx: Context, session: State, state: checkpoint.Permission): (boolean, string?)
    if not state.approval_id then return false, "approval id is missing" end
    local value, err = must(ctx, ctx.approvals .. ":read", {approval_id = state.approval_id})
    if err then return false, err end
    local view, view_error = approval_view(value)
    if not view then return false, "approval owner returned malformed data: " .. tostring(view_error) end
    if view.approval_id ~= state.approval_id or view.proposal_digest ~= state.proposal_digest or view.workspace_id ~= session.request.workspace_id then
        return false, "approval owner returned another approval or proposal"
    end
    if view.state == "pending" and state.deadline_ms and ctx.now_ms() >= state.deadline_ms then
        local current = assert(bounds.object(value))
        local closed, close_error = must(ctx, ctx.approvals .. ":withdraw", {approval_id = state.approval_id,
            expected_revision = current.revision, proposal_digest = state.proposal_digest, reviewed_digest = current.reviewed_digest})
        if close_error then return false, close_error end
        local result = bounds.object(closed)
        local ended, ended_error = approval_view(result and result.request)
        if not ended then return false, "withdrawal returned malformed data: " .. tostring(ended_error) end
        if ended.approval_id ~= state.approval_id or ended.proposal_digest ~= state.proposal_digest or ended.workspace_id ~= session.request.workspace_id or ended.state == "pending" then
            return false, "withdrawal did not settle the requested approval"
        end
        view = ended
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
    local committed, commit_error = ctx.commit( {permission_record(session, state, "decided", {decision = decision})})
    if not committed then return false, commit_error end
    ctx.step( "permission_decided")
    return true, nil
end
local function close_permission(ctx: Context, session: State, state: checkpoint.Permission, reason: string): (boolean, string?)
    if state.approval_id then
        local raw, err = must(ctx, ctx.approvals .. ":read", {approval_id = state.approval_id})
        if err then return false, err end
        local current = bounds.object(raw)
        if not current or current.approval_id ~= state.approval_id or current.proposal_digest ~= state.proposal_digest then
            return false, "approval owner returned another request while closing"
        end
        if current.state == "pending" then
            local _, withdrawn = must(ctx, ctx.approvals .. ":withdraw", {approval_id = state.approval_id,
                expected_revision = current.revision, proposal_digest = state.proposal_digest, reviewed_digest = current.reviewed_digest})
            if withdrawn then return false, withdrawn end
        end
    end
    state.phase = "closed"
    return ctx.commit( {permission_record(session, state, "closed", {reason = reason})})
end
-- revalidate_context: before consuming under a new authority incarnation
-- and before any dispatch after recovery, the carrier re-checks everything
-- the approval was bound to: the attempt still waits with a bound runner,
-- the launch policy, binding, profile, adapter and acceptance still measure
-- as planned, the proposal still digests the same, and the placement,
-- reconciled now, still runs under its grants and projections.
-- consume_effect: the effect is reserved under the authority incarnation the
-- carrier observed; a restarted authority answers REVALIDATE with its current
-- incarnation, the carrier re-checks its own domain, records the validation
-- and asks again. Replays are safe, so a resumed carrier repeats this
-- before creating its write intent.
local function consume_effect(ctx: Context, session: State, state: checkpoint.Permission): (boolean, string?)
    if state.lease_ref then
        local _, err = must(ctx, ctx.approvals .. ":runtime_lease", {operation = "use", lease_ref = state.lease_ref,
            workspace_id = session.request.workspace_id, tool = state.tool_name, input_digest = state.input_digest, effect_key = state.effect_key})
        return err == nil, err
    end
    if not state.approval_id or not state.incarnation then return false, "approval identity or incarnation is missing" end
    for _ = 1, ctx.max_consume_attempts do
        local raw, call_error = ctx.call(ctx.approvals .. ":consume", {approval_id = state.approval_id, proposal_digest = state.proposal_digest, effect_key = state.effect_key, owner_incarnation = state.incarnation})
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
        local exchange = session.exchange
        if not exchange then return false, "consume: no permission exchange" end
        local refused = ctx.revalidate()
        if refused then return close_permission(ctx, session, state, "revalidation refused: " .. refused) end
        local _, revalidate_error = must(ctx, ctx.approvals .. ":revalidate", {approval_id = state.approval_id, proposal_digest = state.proposal_digest, owner_incarnation = current})
        if revalidate_error then return false, revalidate_error end
        state.incarnation = current
        local committed, commit_error = ctx.commit( {permission_record(session, state, "revalidated", {incarnation = current})})
        if not committed then return false, commit_error end
        ctx.step( "permission_revalidated")
    end
    return false, "consume: the authority restarted " .. tostring(ctx.max_consume_attempts) .. " times during consumption"
end
local function write_response(ctx: Context, session: State, exchange: Exchange, state: checkpoint.Permission): (boolean, string?)
    if not ctx.waiting() then return close_permission(ctx, session, state, "attempt no longer waiting") end
    local line = state.response
    if not line then return false, "permission response is missing" end
    if ctx.recovered then
        local refused = ctx.revalidate()
        if refused then return close_permission(ctx, session, state, "revalidation refused before dispatch: " .. refused) end
    end
    state.phase = "written"
    return ctx.write( state.write_id, line)
end
-- advance_permissions: drives every exchange forward from what the
-- checkpoint holds. Polling the owner happens only on the poll tick.
function M.advance(ctx: Context, poll: boolean): (boolean, string?)
    local session = ctx.state
    local exchange = session.exchange
    if not exchange then return true, nil end
    for _, item in ipairs(session.permissions) do
        local state: checkpoint.Permission = item
        local replay_consumed = state.phase == "consumed"
        if state.phase == "intended" and exchange.answer_mode == "deny" then
            state.decision = "denied"
            state.phase = "decided"
            local ok, err = ctx.commit({permission_record(session, state, "decided", {decision = "denied", reason = "profile permission_answers=deny"})})
            if not ok then return false, err end
        end
        if state.phase == "intended" then
            local ok, err = request_approval(ctx, session, exchange, state)
            if not ok then return false, err end
        end
        if state.phase == "requested" and poll then
            local ok, err = poll_decision(ctx, session, state)
            if not ok then return false, err end
        end
        if state.phase == "decided" then
            local waiting = ctx.waiting()
            local settled = ctx.settled()
            local outcome = permission.outcome(exchange.adapter, state.decision or "", waiting, settled)
            if outcome == "allow" then
                local consumed, consume_error = consume_effect(ctx, session, state)
                if not consumed then return false, consume_error end
                if state.phase == "decided" then
                    local line, encode_error = permission.allow(exchange.adapter, request_of(state), nil)
                    if not line then return false, "encode allow: " .. tostring(encode_error) end
                    state.response = line
                    state.phase = "consumed"
                    local committed, commit_error = ctx.commit( {permission_record(session, state, "consumed", {})})
                    if not committed then return false, commit_error end
                    ctx.step( "permission_consumed")
                end
            elseif outcome == "deny" then
                -- A denial or expiry reserves the response write only; no
                -- effect is consumed and nothing authorizes the tool.
                local line, encode_error = permission.deny(exchange.adapter, request_of(state), "decision " .. tostring(state.decision))
                if not line then return false, "encode deny: " .. tostring(encode_error) end
                state.response = line
                state.phase = "declined"
                local committed, commit_error = ctx.commit( {permission_record(session, state, "declined", {})})
                if not committed then return false, commit_error end
            else
                local closed, close_error = close_permission(ctx, session, state, "decision " .. tostring(state.decision) .. " arrived while not waiting")
                if not closed then return false, close_error end
            end
        end
        if replay_consumed and state.phase == "consumed" then
            local consumed, consume_error = consume_effect(ctx, session, state)
            if not consumed then return false, consume_error end
        end
        if state.phase == "consumed" or state.phase == "declined" then
            local written, write_error = write_response(ctx, session, exchange, state)
            if not written then return false, write_error end
        end
    end
    return true, nil
end
function M.close(ctx: Context): (boolean, string?)
    local session = ctx.state
    for _, state in ipairs(session.permissions) do
        if state.phase ~= "closed" and state.phase ~= "acknowledged" then
            local reason = "settled while " .. state.phase
            if state.phase == "written" then reason = "response accepted by the input transport, harness acknowledgment unproven" end
            local closed, close_error = close_permission(ctx, session, state, reason)
            if not closed then return false, close_error end
        end
    end
    return true, nil
end

return M
