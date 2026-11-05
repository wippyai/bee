-- MIT. The carrier machine: one attempt from plan to receipt, expressed as
-- steps over an injected IO so the same code runs in the production
-- process and under a test harness that stops it between steps. Every
-- durable fact lives in thread records, placement receipts and the
-- checkpoint; the machine keeps only what the checkpoint holds.
local settle_types = require("settle_types")
local checkpoint_types = require("checkpoint_types")
local json = require("json")
local checkpoint = require("checkpoint")
local prestart = require("prestart")
local settle = require("settle")
local placement_types = require("placement_types")
local placement_resolver = require("placement_resolver")
local placement_protocol = require("placement_protocol")
local placement_decode = require("placement_decode")
local carrier_types = require("carrier_types")
local hints = require("hints")
local permission_exchange = require("permission_exchange")
local M = {}
local part_output = require("part_output")
type Object = part_output.Object
type IO = part_output.IO
type Plan = part_output.Plan
local must = part_output.must
M.plan = part_output.plan
M.CARRIER_OPS = part_output.CARRIER_OPS
M.MAX_RECORDS_PER_COMMIT = part_output.MAX_RECORDS_PER_COMMIT
M.MAX_FRAME_BYTES = part_output.MAX_FRAME_BYTES
M.APPROVALS = part_output.APPROVALS
type OutputState = part_output.OutputState
type Session = part_output.Session
local step = part_output.step
M.commit = part_output.commit
type FrameProblem = part_output.FrameProblem
type FrameEnvelope = part_output.FrameEnvelope
M.placement_target = part_output.placement_target
type Normalized = part_output.Normalized
local from_runner = part_output.from_runner
local permission_context = part_output.permission_context
function M.on_output(io: IO, session: Session, sender: string, message: placement_protocol.Output): (boolean, string?)
    return part_output.on_output(io, session, sender, message, M.MAX_RECORDS_PER_COMMIT)
end
local control_record = part_output.control_record
local forget_write = part_output.forget_write
M.write = part_output.write
local part_planning = require("part_planning")
local part_launch = require("part_launch")
local part_gateway = require("part_gateway")
type Reply = part_planning.Reply
type Request = part_planning.Request
type Exchange = part_planning.Exchange
type Acceptance = part_planning.Acceptance
local reply_of = part_planning.reply_of
type ExecutableCapability = part_planning.ExecutableCapability
type Measured = part_planning.Measured
type DeclaredAcceptance = part_planning.DeclaredAcceptance
M.verify_acceptance = part_planning.verify_acceptance
M.required_file_refusal = part_planning.required_file_refusal
M.PLACEMENT_BINDING = placement_resolver.DEFAULT
M.CARRIER_REGISTRY_PREFIX = prestart.CARRIER_REGISTRY_PREFIX
M.THREADS = hints.THREADS
M.DELIVERY = hints.DELIVERY
type ProfileGrant = carrier_types.ProfileGrant
local inbox_context_value: hints.Context? = nil
local function inbox_context(): hints.Context
    if inbox_context_value == nil then error("carrier inbox context is not initialized") end
    return inbox_context_value
end

function M.open_hints(io: IO, session: Session): string?
    return hints.open_hints(inbox_context(), io, session)
end
function M.take_hints(io: IO, session: Session): (boolean, string?)
    return hints.take_hints(inbox_context(), io, session)
end
function M.acknowledge_hints(io: IO, session: Session): (boolean, string?)
    return hints.acknowledge_hints(inbox_context(), io, session)
end
function M.close_hints(io: IO, session: Session)
    hints.close_hints(inbox_context(), io, session)
end

function M.open(io: IO, plan: Plan): (Session?, string?)
    if plan.profile.mode == "window" or plan.profile.protocol ~= "stream-json" then
        return nil, "structured carrier requires a stream-json session or batch profile"
    end
    local prepared, preparation_error, failed_preparation = part_launch.prepare_attempt(io, plan)
    if not prepared then
        if failed_preparation and failed_preparation.attempt and failed_preparation.epoch then
            part_launch.settle_prestart_failure(io, plan, failed_preparation.epoch, failed_preparation.gateway_binding,
                "launch preparation failed: " .. tostring(preparation_error))
        end
        return nil, preparation_error
    end
    local request = plan.request
    local epoch, gateway_binding = prepared.epoch, prepared.gateway_binding
    local turn_id = "turn:" .. request.attempt_id .. ":1"
    local _, turn_error = part_launch.thread_call(io, request, "request_turn", {action_id = request.action_id, attempt_id = request.attempt_id, turn_id = turn_id, carrier_epoch = epoch,
        turn = {input_message_ids = {}, input = {text = request.brief}, resume_ref = plan.resume_ref, delivery_ids = {}}}, "turn")
    if turn_error then
        part_launch.settle_prestart_failure(io, plan, epoch, gateway_binding, "request turn failed: " .. turn_error, nil, turn_id)
        return nil, turn_error
    end
    step(io, "turn_requested")
    local point = checkpoint.new({binding_ref = plan.binding.binding_id, binding_digest = plan.binding.binding_digest.entry, profile_id = plan.profile.id, profile_digest = plan.binding.profile_digest.entry, plan_digest = plan.plan_digest, gateway_binding = gateway_binding}, epoch)
    point.retained_session_ref = request.session_ref
    local session = part_launch.new_session(plan, turn_id, epoch, 0, point)
    local committed, commit_error = M.commit(io, session, {})
    if not committed then
        local reason = "initial checkpoint failed: " .. tostring(commit_error or "commit")
        part_launch.settle_prestart_failure(io, plan, epoch, gateway_binding, reason, session, turn_id)
        return nil, commit_error or "commit"
    end
    local attach_target = M.placement_target(plan, "attach")
    if not attach_target then
        part_launch.settle_prestart_failure(io, plan, epoch, gateway_binding, "selected placement binds no attach", session, turn_id)
        return nil, "selected placement binds no attach"
    end
    local _, attach_error = must(io, attach_target, {attempt_id = request.attempt_id, recipient = io.self_pid(), generation = epoch})
    if attach_error then
        part_launch.settle_prestart_failure(io, plan, epoch, gateway_binding, "placement attach failed: " .. attach_error, session, turn_id)
        return nil, attach_error
    end
    step(io, "attached")
    if gateway_binding then
        local readiness_error = part_gateway.ready(io, gateway_binding)
        if readiness_error then
            part_launch.settle_prestart_failure(io, plan, epoch, gateway_binding, readiness_error, session, turn_id)
            return nil, readiness_error
        end
    end
    local start_target = M.placement_target(plan, "start")
    if not start_target then
        part_launch.settle_prestart_failure(io, plan, epoch, gateway_binding, "selected placement binds no start", session, turn_id)
        return nil, "selected placement binds no start"
    end
    local started_value, start_error = must(io, start_target, {attempt_id = request.attempt_id, gateway_binding = gateway_binding})
    if start_error then
        part_launch.settle_prestart_failure(io, plan, epoch, gateway_binding, "placement start failed: " .. start_error, session, turn_id)
        return nil, start_error
    end
    step(io, "placement_started")
    local attempt, attempt_error = placement_decode.attempt(started_value)
    if not attempt then
        local reason = "placement start returned an invalid attempt: " .. tostring(attempt_error)
        part_launch.settle_prestart_failure(io, plan, epoch, gateway_binding, reason, session, turn_id)
        return nil, reason
    end
    session.runner = attempt.runner
    session.placement_state = attempt.execution_state
    session.start_failure = attempt.start_failure
    session.start_cancelled = attempt.start_cancelled
    local started_error = part_launch.record_started(io, session, attempt)
    if started_error then
        part_launch.settle_prestart_failure(io, plan, epoch, gateway_binding, "recording placement start failed: " .. started_error, session, turn_id)
        return nil, started_error
    end
    local observed, observe_error = part_launch.placement_observation(io, session, attempt)
    if not observed then return nil, observe_error end
    return session, nil
end
function M.on_startup(io: IO, session: Session): (boolean, string?)
    local target = M.placement_target(session.plan, "status")
    if not target then return false, "selected placement binds no status" end
    local raw, read_error = must(io, target, {attempt_id = session.plan.request.attempt_id})
    if read_error then return false, read_error end
    local status, decode_error = placement_decode.status(raw)
    if not status then return false, "startup state: " .. tostring(decode_error) end
    local attempt = status.attempt
    if attempt.attempt_id ~= session.plan.request.attempt_id or attempt.attachment_generation ~= session.epoch then return false, "startup state belongs to another attempt or generation" end
    session.placement_state = attempt.execution_state
    session.start_failure = attempt.start_failure
    session.start_cancelled = attempt.start_cancelled
    local started_error = part_launch.record_started(io, session, attempt)
    if started_error then return false, started_error end
    return part_launch.placement_observation(io, session, attempt)
end
-- resume: a replacement carrier continues from the stored checkpoint under
-- a new epoch; the runner resends what the old carrier never acknowledged.
function M.resume(io: IO, plan: Plan): (Session?, string?)
    if plan.profile.mode == "window" or plan.profile.protocol ~= "stream-json" then
        return nil, "structured carrier requires a stream-json session or batch profile"
    end
    local request = plan.request
    local stored, stored_error = must(io, M.CARRIER_OPS .. ":checkpoint", {thread_id = request.thread_id, attempt_id = request.attempt_id})
    if stored_error then return nil, stored_error end
    local view, view_error = checkpoint.decode_checkpoint_view(stored)
    if not view then return nil, "stored checkpoint view: " .. tostring(view_error) end
    if view.attempt_state == "ended" then return nil, "attempt has ended" end
    if view.checkpoint == nil then return nil, "no checkpoint to resume from" end
    local point, point_error = checkpoint.decode(view.checkpoint)
    if not point then return nil, "stored checkpoint: " .. tostring(point_error) end
    if point.binding_digest ~= plan.binding.binding_digest.entry or point.profile_digest ~= plan.binding.profile_digest.entry then return nil, "pinned measurements changed since the checkpoint" end
    if view.placement_binding ~= plan.placement_binding.binding_id then return nil, "placement binding changed since the checkpoint" end
    if view.placement_binding_digest ~= plan.placement_binding.binding_digest then return nil, "placement binding digest missing or changed since the checkpoint" end
    step(io, "checkpoint_read")
    local claimed, claim_error = must(io, M.CARRIER_OPS .. ":claim", {thread_id = request.thread_id, idempotency_key = io.key(), attempt_id = request.attempt_id})
    if claim_error then return nil, claim_error end
    local epoch, claim_decode_error = checkpoint.decode_claim(claimed)
    if not epoch then return nil, "carrier claim returned an invalid epoch: " .. tostring(claim_decode_error) end
    -- A live carrier commits until the claim fences it, so the replacement
    -- continues from the checkpoint as the claim left it, not as first read.
    local fenced, fenced_error = must(io, M.CARRIER_OPS .. ":checkpoint", {thread_id = request.thread_id, attempt_id = request.attempt_id})
    if fenced_error then return nil, fenced_error end
    local fenced_view, fenced_view_error = checkpoint.decode_checkpoint_view(fenced)
    if not fenced_view then return nil, "fenced checkpoint view: " .. tostring(fenced_view_error) end
    view = fenced_view
    if view.carrier_epoch ~= epoch then return nil, "carrier epoch " .. tostring(epoch) .. " was superseded by " .. tostring(view.carrier_epoch) end
    if view.attempt_state == "ended" then return nil, "attempt has ended" end
    local fenced_point, fenced_point_error = checkpoint.decode(view.checkpoint)
    if not fenced_point then return nil, "stored checkpoint: " .. tostring(fenced_point_error) end
    local moved = checkpoint.continues(point, fenced_point)
    if moved then return nil, "stored checkpoint: " .. moved end
    point = fenced_point
    local session = part_launch.new_session(plan, "turn:" .. request.attempt_id .. ":1", epoch, view.checkpoint_revision, checkpoint.rebind(point, epoch))
    session.recovered = true
    session.attempt_started = view.attempt_state ~= "prepared"
    local status_target = M.placement_target(plan, "status")
    if not status_target then return nil, "selected placement binds no status" end
    local status_value, status_error = must(io, status_target, {attempt_id = request.attempt_id})
    if status_error then return nil, status_error end
    local status, status_decode_error = placement_decode.status(status_value)
    if not status then return nil, "placement status is malformed: " .. tostring(status_decode_error) end
    local attempt = status.attempt
    if attempt.start_failure then return nil, "failed start: " .. attempt.start_failure end
    -- Before placement starts, a plan whose digest differs from its record
    -- refuses: nothing was materialized under it. A started attempt is
    -- still carried, and revalidation refuses any dispatch under it.
    if attempt.execution_state == "intended" and point.plan_digest and point.plan_digest ~= plan.plan_digest then
        return nil, "pinned measurements changed since the checkpoint: the plan no longer digests as recorded"
    end
    if attempt.execution_state == "intended" then
        -- A start that failed between placement intent and placement start
        -- resumes by starting the same attempt; placement start is idempotent.
        -- The gateway binding is admitted anew under this epoch, which
        -- supersedes whatever the lost carrier admitted, and readiness is
        -- taken again immediately before the start.
        local gateway_binding, gateway_error = part_gateway.admit(io, plan, epoch)
        if gateway_error then return nil, gateway_error end
        session.checkpoint.gateway_binding = gateway_binding
        local function abandon(err: string): (Session?, string?)
            part_gateway.revoke(io, gateway_binding)
            return nil, err
        end
        if gateway_binding then
            local committed, commit_error = M.commit(io, session, {})
            if not committed then return abandon(commit_error or "commit") end
        end
        local attach_target = M.placement_target(plan, "attach")
        if not attach_target then return abandon("selected placement binds no attach") end
        local _, attach_first_error = must(io, attach_target, {attempt_id = request.attempt_id, recipient = io.self_pid(), generation = epoch})
        if attach_first_error then return abandon(attach_first_error) end
        if gateway_binding then
            local readiness_error = part_gateway.ready(io, gateway_binding)
            if readiness_error then return abandon(readiness_error) end
        end
        local start_target = M.placement_target(plan, "start")
        if not start_target then return abandon("selected placement binds no start") end
        local started_value, placement_error = must(io, start_target, {attempt_id = request.attempt_id, gateway_binding = gateway_binding})
        if placement_error then return abandon(placement_error) end
        local started_attempt, started_decode_error = placement_decode.attempt(started_value)
        if not started_attempt then return abandon("placement start returned an invalid attempt: " .. tostring(started_decode_error)) end
        attempt = started_attempt
        session.runner = attempt.runner
        session.placement_state = attempt.execution_state
        step(io, "placement_started")
        local started_error = part_launch.record_started(io, session, attempt)
        if started_error then return nil, started_error end
        local observed, observe_error = part_launch.placement_observation(io, session, attempt)
        if not observed then return nil, observe_error end
        session.turn_open = view.open_turn_id ~= nil
        if view.open_turn_id then session.turn_id = view.open_turn_id end
        step(io, "reattached")
        return session, nil
    end
    local started_error = part_launch.record_started(io, session, attempt)
    if started_error then return nil, started_error end
    session.turn_open = view.open_turn_id ~= nil
    if view.open_turn_id then session.turn_id = view.open_turn_id end
    if attempt.execution_state == "exited" then
        local exit = attempt.exit
        session.exit = {code = exit and exit.code or nil, signal = exit and exit.signal or nil, uncertain = attempt.exit_source == nil}
    end
    -- A runner that still holds unacknowledged output or an unanswered
    -- write outlives the child; attach reaches it while it lives. Once it
    -- is gone nothing resends output past the checkpoint, no write can be
    -- asked about, and settlement comes from the recorded exit after the
    -- drain.
    local attach_target = M.placement_target(plan, "attach")
    if not attach_target then return nil, "selected placement binds no attach" end
    -- A live reattachment requires placement's acknowledged, durable runner fence.
    local attached_value, attach_error = must(io, attach_target, {attempt_id = request.attempt_id, recipient = io.self_pid(), generation = epoch})
    if attach_error then
        if attempt.execution_state ~= "exited" and attempt.execution_state ~= "uncertain" then return nil, attach_error end
        -- Placement can prove neither exit nor presence and no runner
        -- answers: the outcome is uncertain, the effect unknown, and
        -- nothing is resent or rewritten.
        if attempt.execution_state == "uncertain" then session.exit = {code = nil, signal = nil, uncertain = true} end
        session.eof = {stdout = true, stderr = true}
        -- Durable evidence stands: only an output state the checkpoint never
        -- settled becomes unobserved.
        if session.output == "open" then session.output = "unobserved" end
        step(io, "reattached")
        return session, nil
    end
    local attached_attempt, attached_decode_error = placement_decode.attempt(attached_value)
    if not attached_attempt then return nil, "placement attach returned an invalid attempt: " .. tostring(attached_decode_error) end
    session.runner = attached_attempt.runner
    session.placement_state = attached_attempt.execution_state
    session.start_failure = attached_attempt.start_failure
    session.start_cancelled = attached_attempt.start_cancelled
    local attached_start_error = part_launch.record_started(io, session, attached_attempt)
    if attached_start_error then return nil, attached_start_error end
    step(io, "reattached")
    return session, nil
end
-- One output chunk: frame, normalize, commit in bounded batches, then
-- acknowledge. A chunk the carrier cannot checkpoint is never acknowledged.
-- attached: the runner names itself to the recipient of the current
-- generation; only that sender's traffic is honoured afterwards.
function M.on_attached(session: Session, sender: string, message: placement_protocol.Attached): boolean
    if message.generation ~= session.epoch or message.attempt_id ~= session.plan.request.attempt_id then return false end
    session.runner = sender
    return true
end
type ApprovalState = "pending" | "decided" | "expired" | "withdrawn"
-- Wakeup hints: a durable subscription to the thread's approval
-- transitions whose pages are only reasons to read the approval owner.
-- The projected decision never authorizes consumption or a write, bounded
-- polling stays the fallback through every failure here, and a page is
-- acknowledged only after its hints were processed, which certifies
-- nothing about consumption or child input.
function M.on_exit(io: IO, session: Session, sender: string, message: placement_protocol.Exit)
    if not from_runner(session, sender, message.generation) then return end
    session.exit = {code = message.code, signal = message.signal, uncertain = message.uncertain, stopped = message.stopped == true}
end
function M.on_runner_exit(session: Session, sender: string): boolean
    if not session.runner or sender ~= session.runner then return false end
    session.runner_ended = true
    if not session.exit then session.exit = {code = nil, uncertain = true} end
    return true
end
function M.drained(session: Session): boolean
    return session.eof.stdout and session.eof.stderr
end
local function input_record(session: Session, phase: string, extra: {[string]: unknown}): {[string]: unknown}
    local payload: {[string]: unknown} = {attempt_id = session.plan.request.attempt_id, attachment_generation = session.epoch, phase = phase}
    for key, value in pairs(extra) do payload[key] = value end
    return {source = "bee", body = {type = "extension", event_key = "input:" .. session.plan.request.attempt_id .. ":" .. tostring(session.epoch) .. ":" .. phase,
        data = {type = "extension", event_name = "bee.carrier.input", event_revision = "1", payload_json = json.encode(payload)}}}
end
-- stop_session: the fallback end of a settled session, a cooperative stop
-- through placement, which keeps signal and cleanup authority.
function M.stop_session(io: IO, session: Session): (string, string?)
    if session.exit or not session.runner then return "none", nil end
    local stop_target = M.placement_target(session.plan, "stop")
    if not stop_target then return "none", "selected placement binds no stop" end
    local _, stop_error = must(io, stop_target, {attempt_id = session.plan.request.attempt_id, mode = "cooperative"})
    if stop_error then return "none", stop_error end
    return "stopping", nil
end
local function evidence_of(session: Session, drain_elapsed: boolean): settle_types.Evidence
    local delivery_ended = session.runner == nil or session.runner_ended == true
    return {terminal = session.terminal, stream_ended = session.stream_ended, exit = session.exit, drained = M.drained(session) or (delivery_ended and drain_elapsed),
        exit_codes_trustworthy = session.plan.exit_codes_trustworthy}
end
-- ready_to_settle: the turn's outcome is decidable and no write is still
-- awaiting its answer, so a declared session end may run before the
-- settlement records end the attempt.
function M.ready_to_settle(session: Session, drain_elapsed: boolean): boolean
    if session.settled then return false end
    local decided: settle_types.Settlement? = nil
    if session.start_cancelled then decided = {outcome = "cancelled", reason = "explicit stop before child creation", exit_reconciled = false}
    elseif session.start_failure then decided = {outcome = "failed", reason = session.start_failure, exit_reconciled = false}
    else decided = settle.decide(evidence_of(session, drain_elapsed)) end
    if not decided then return false end
    if #session.checkpoint.pending_writes > 0 and not drain_elapsed then return false end
    return true
end
-- end_session: a turn whose outcome is decided while the child still runs
-- ends the way the driver declared. A session that ends when stdin closes
-- has the closure committed to the checkpoint first, so a recovered
-- carrier never writes to it again, then placement closes stdin and the
-- outcome is on record; the caller awaits the exit within the policy
-- grace, and the cooperative stop remains the fallback. Every exchange is
-- closed by then, so no response is owed when stdin closes. Records are
-- committed only while the attempt is still open on the thread; a resumed
-- carrier finding a settled attempt ends the session without them.
-- Returns "closed", "stopping" or "none".
function M.end_session(io: IO, session: Session, record: boolean): (string, string?)
    if session.exit or not session.runner then return "none", nil end
    if session.plan.launch.session_end == "stdin_close" then
        if record and not session.checkpoint.input_closed then
            session.checkpoint.input_closed = true
            local intended, intent_error = M.commit(io, session, {input_record(session, "close_intended", {})})
            if not intended then return "none", intent_error end
        end
        -- A refused closure with an observed exit needs no signal.
        -- A successful closure remains recorded even if the child exits
        -- during the reply; other refusals retain the stop fallback.
        local close_target = session.plan.placement_binding.methods.close_stdin
        if not close_target then return "none", "selected placement cannot close stdin" end
        local raw, call_error = io.call(close_target, {attempt_id = session.plan.request.attempt_id})
        local reply, reply_error = reply_of(raw, call_error)
        if not reply then return "none", reply_error end
        local closed = false
        local reason = "stdin could not be closed"
        if reply.ok then
            local answer, answer_error = placement_decode.stdin_closure(reply.value, session.plan.request.attempt_id)
            if not answer then return "none", "placement returned malformed close_stdin data: " .. tostring(answer_error) end
            if answer.attempt.attachment_generation ~= session.epoch then return "none", "stdin closure belongs to another generation" end
            if not answer.closed and answer.attempt.execution_state == "exited" and answer.attempt.exit_source then
                local exit = answer.attempt.exit
                session.exit = {code = exit and exit.code or nil, signal = exit and exit.signal or nil, uncertain = false}
                return "none", nil
            end
            closed = answer.closed
            if answer.reason then reason = answer.reason end
        else
            local fault = reply.error or {code = "INTERNAL", message = "close_stdin failed"}
            reason = fault.code .. ": " .. fault.message
        end
        if closed then
            if record then
                local recorded, record_error = M.commit(io, session, {input_record(session, "closed", {})})
                if not recorded then return "none", record_error end
            end
            return "closed", nil
        end
        if record then
            local recorded, record_error = M.commit(io, session, {input_record(session, "close_uncertain", {reason = reason})})
            if not recorded then return "none", record_error end
        end
    end
    return M.stop_session(io, session)
end
-- close: record the placement's final states as observations once the
-- attempt is settled; cleanup runs when the placement can prove its scope.
function M.close(io: IO, session: Session): (placement_types.Attempt?, string?)
    local request = session.plan.request
    -- Intake ends in order: seal, drain what was accepted within the host's
    -- drain budget, reject explicitly what is left, then revoke.
    local binding_id = session.checkpoint.gateway_binding
    if binding_id and session.plan.gateway and #session.plan.gateway.hooks > 0 then
        io.call(part_gateway.GATEWAY .. ":seal", {binding_id = binding_id})
        local deadline = io.now_ms() + session.plan.policy.drain_ms
        local was_settled = session.settled
        session.settled = nil
        while io.now_ms() < deadline do
            local drained = part_gateway.drain_hooks(io, session)
            if drained == 0 then break end
        end
        session.settled = was_settled
        io.call(part_gateway.GATEWAY .. ":hook_reject", {binding_id = binding_id, carrier_epoch = session.epoch, reason = "attempt settled"})
    end
    part_gateway.revoke(io, binding_id)
    local status_target = M.placement_target(session.plan, "status")
    if not status_target then return nil, "selected placement binds no status" end
    local status_value, status_error = must(io, status_target, {attempt_id = request.attempt_id})
    if status_error then return nil, status_error end
    local status, status_decode_error = placement_decode.status(status_value)
    if not status then return nil, "placement status is malformed: " .. tostring(status_decode_error) end
    local attempt = status.attempt
    if attempt.execution_state == "exited" and attempt.cleanup_state == "pending" then
        local cleanup_target = M.placement_target(session.plan, "cleanup")
        if not cleanup_target then return nil, "selected placement binds no cleanup" end
        local cleaned, cleanup_error = io.call(cleanup_target, {attempt_id = request.attempt_id})
        local reply, reply_error = reply_of(cleaned, cleanup_error)
        if not reply then return nil, "placement cleanup reply is malformed: " .. tostring(reply_error) end
        if reply.ok == true then
            local cleaned_attempt, cleaned_error = placement_decode.attempt(reply.value)
            if not cleaned_attempt then return nil, "placement cleanup returned an invalid attempt: " .. tostring(cleaned_error) end
            attempt = cleaned_attempt
        else
            return nil, "placement cleanup refused: " .. reply.error.code .. ": " .. reply.error.message
        end
    end
    return attempt, nil
end
local function pending_write(session: Session, write_id: string): checkpoint_types.PendingWrite?
    for _, pending in ipairs(session.checkpoint.pending_writes) do
        if pending.write_id == write_id then return pending end
    end
    return nil
end
-- One record per write and phase, with deterministic content: an accepted
-- write carries no reason, an uncertain one carries why.
local function settle_write(io: IO, session: Session, write_id: string, phase: string, reason: string?): (boolean, string?)
    forget_write(session, write_id)
    local extra: {[string]: unknown} = {}
    if phase == "uncertain" then extra.reason = reason end
    local committed, commit_error = M.commit(io, session, {control_record(session, write_id, phase, extra)})
    if not committed then return false, commit_error end
    step(io, "write_settled")
    return true, nil
end
function M.on_write_ack(io: IO, session: Session, sender: string, message: placement_protocol.InputAck): (boolean, string?)
    if not from_runner(session, sender, message.generation) then return true, nil end
    if not pending_write(session, message.write_id) then return true, nil end
    local phase = message.accepted and "accepted" or "uncertain"
    return settle_write(io, session, message.write_id, phase, message.reason)
end
-- A resuming carrier asks the runner about every pending write; an answer
-- of accepted is recorded, an unknown write is dispatched for the first
-- time, and no answer at all leaves it uncertain.
function M.reconcile_writes(io: IO, session: Session): (boolean, string?)
    if #session.checkpoint.pending_writes == 0 then return true, nil end
    local runner = session.runner
    if not runner then
        for _, pending in ipairs(session.checkpoint.pending_writes) do
            local settled, err = settle_write(io, session, pending.write_id, "uncertain", "no runner survived to answer")
            if not settled then return false, err end
        end
        return true, nil
    end
    for _, pending in ipairs(session.checkpoint.pending_writes) do
        io.send(runner, placement_protocol.TOPIC_CONTROL, {command = "write_status", write_id = pending.write_id})
    end
    return true, nil
end
function M.on_write_status(io: IO, session: Session, sender: string, message: placement_protocol.WriteStatus): (boolean, string?)
    if not from_runner(session, sender, message.generation) then return true, nil end
    local found = pending_write(session, message.write_id)
    if not found then return true, nil end
    if message.status == "accepted" then
        return settle_write(io, session, message.write_id, "accepted", nil)
    end
    if found.dispatched then return true, nil end
    local runner = session.runner
    if not runner then return false, "no runner is bound" end
    io.send(runner, placement_protocol.TOPIC_INPUT, {write_id = found.write_id, generation = session.epoch, data = found.data})
    found.dispatched = true
    return true, nil
end
function M.advance_permissions(io: IO, session: Session, poll: boolean): (boolean, string?)
    return permission_exchange.advance(permission_context(io, session), poll)
end
function M.close_exchanges(io: IO, session: Session, drain_elapsed: boolean): (boolean, string?)
    if #session.checkpoint.pending_writes > 0 then
        if not drain_elapsed then return false, nil end
        local pending = session.checkpoint.pending_writes
        for _, write in ipairs(pending) do
            local settled, err = settle_write(io, session, write.write_id, "uncertain", "no acknowledgment before settlement")
            if not settled then return false, err end
        end
    end
    return permission_exchange.close(permission_context(io, session))
end

function M.settle(io: IO, session: Session, drain_elapsed: boolean): (settle_types.Settlement?, string?)
    if session.settled then return session.settled, nil end
    local decided: settle_types.Settlement? = nil
    if session.start_failure then decided = {outcome = "failed", reason = session.start_failure, exit_reconciled = false}
    else decided = settle.decide(evidence_of(session, drain_elapsed)) end
    if not decided then return nil, nil end
    -- Settling while the streams are still open, whether the carrier's own
    -- deadline won or a terminal envelope arrived first, is incomplete
    -- output; elapsed time never implies completeness.
    if session.output == "open" then session.output = "incomplete" end
    local reason = decided.reason
    if session.output ~= "complete" then
        reason = reason .. "; output " .. session.output .. ", so the ended streams do not prove complete output"
    end
    local decision: settle_types.Settlement = {outcome = decided.outcome, answer = decided.answer, resume_ref = decided.resume_ref, reason = reason, exit_reconciled = decided.exit_reconciled}
    local closed_all, close_error = M.close_exchanges(io, session, drain_elapsed)
    if close_error then return nil, close_error end
    if not closed_all then return nil, nil end
    -- What the child reported before its end is committed before the turn
    -- ends; anything queued after this is rejected at close.
    local _, hooks_error = part_gateway.drain_hooks(io, session)
    if hooks_error then return nil, hooks_error end
    local request = session.plan.request
    local fault: {code: string, message: string, retryable: boolean}? = nil
    if session.terminal and session.terminal.error then fault = session.terminal.error end
    if decision.outcome ~= "succeeded" and not fault then fault = {code = decision.outcome, message = decision.reason, retryable = false} end
    step(io, "terminal_received")
    -- The output state is recorded before the turn ends, once per carrier
    -- generation since each observed its own stretch: complete only when
    -- both streams ended on their own; anything else is not complete output.
    local state_record: {[string]: unknown} = {source = "bee", body = {type = "extension", event_key = "output:" .. request.attempt_id .. ":" .. tostring(session.epoch),
        data = {type = "extension", event_name = "bee.carrier.output", event_revision = "1", payload_json = json.encode({attempt_id = request.attempt_id, state = session.output, attachment_generation = session.epoch})}}}
    if session.turn_open then state_record.turn_id = session.turn_id end
    local state_committed, state_error = M.commit(io, session, {state_record})
    if not state_committed then return nil, state_error end
    if session.turn_open then
        local _, end_error = part_launch.thread_call(io, request, "end_turn", {action_id = request.action_id, attempt_id = request.attempt_id, turn_id = session.turn_id, carrier_epoch = session.epoch,
            turn_end = {outcome = decision.outcome, answer_message_ids = {}, evidence_refs = {}, usage = session.terminal and session.terminal.usage or nil, error = fault}})
        if end_error then return nil, end_error end
        session.turn_open = false
    end
    step(io, "turn_ended")
    local _, receipt_error = part_launch.thread_call(io, request, "receipt", {action_id = request.action_id, attempt_id = request.attempt_id, carrier_epoch = session.epoch,
        receipt = {scope = "attempt", outcome = decision.outcome, evidence_refs = {}, error = fault}})
    if receipt_error then return nil, receipt_error end
    session.settled = decision
    return decision, nil
end
-- What this carrier can promise; the resource mode is the placement's.
function M.capabilities(): {[string]: unknown}
    return {max_frame_bytes = M.MAX_FRAME_BYTES, max_records_per_commit = M.MAX_RECORDS_PER_COMMIT, max_checkpoint_bytes = 65536,
        max_pending_writes = checkpoint.MAX_PENDING_WRITES, max_pending_write_bytes = checkpoint.MAX_PENDING_WRITE_BYTES,
        max_permissions = checkpoint.MAX_PERMISSIONS, permission_exchange = "host_policy_with_acceptance_record",
        takeover = "claim", resource_authority = "host_configured", delegated_resource_grants = false, credential_broker = false}
end
inbox_context_value = {threads = M.THREADS, delivery = M.DELIVERY, must = must, commit = M.commit, step = step,
    thread_call = part_launch.thread_call, write = M.write}

return M
