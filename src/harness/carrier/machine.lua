-- MIT. The carrier machine: one attempt from plan to receipt, expressed as
-- steps over an injected IO so the same code runs in the production
-- process and under a test harness that stops it between steps. Every
-- durable fact lives in thread records, placement receipts and the
-- checkpoint; the machine keeps only what the checkpoint holds.
local json = require("json")
local bounds = require("bounds")
local record_bounds = require("record_bounds")
local policy = require("policy")
local checkpoint = require("checkpoint")
local prestart = require("prestart")
local settle = require("settle")
local stream_json = require("stream_json")
local placement_types = require("placement_types")
local placement_resolver = require("placement_resolver")
local placement_protocol = require("placement_protocol")
local placement_decode = require("placement_decode")
local record_types = require("record_types")
local thread_record = require("thread_record")
local gateway_protocol = require("gateway_protocol")
local hook_records = require("hook_records")
local carrier_types = require("carrier_types")
local admitted_request = require("admitted_request")
local hints = require("hints")
local permission_exchange = require("permission_exchange")
local hook_exchange = require("hook_exchange")
local gateway_hooks_catalog = require("gateway_hooks_catalog")
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
M.GATEWAY = "bee.gateway.binding"
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

type ThreadPage = {records: {record_types.Record}, scanned_through: integer, has_more: boolean}
local function thread_page(value: unknown, cursor: integer, limit: integer): (ThreadPage?, string?)
    local object = bounds.object(value)
    if not object then return nil, "page must be an object" end
    local unknown_field = bounds.fields(object, {"records", "scanned_through", "has_more"})
    local rows, rows_error = bounds.array(object.records, limit)
    local scanned_through = bounds.integer(object.scanned_through)
    if unknown_field then return nil, "page: " .. unknown_field end
    if not rows then return nil, "page records: " .. tostring(rows_error) end
    if scanned_through == nil then return nil, "page cursor is invalid" end
    if scanned_through < cursor or scanned_through > record_bounds.MAX_THREAD_RECORDS then return nil, "page cursor is invalid" end
    if type(object.has_more) ~= "boolean" then return nil, "page has_more flag is invalid" end
    local page_cursor: integer = scanned_through
    local has_more: boolean = object.has_more
    local records: {record_types.Record} = {}
    local previous_sequence = cursor
    for index, raw in ipairs(rows) do
        local decoded, decode_error = thread_record.decode(raw)
        if not decoded then return nil, "page records[" .. tostring(index) .. "]: " .. tostring(decode_error) end
        if decoded.sequence <= previous_sequence or decoded.sequence > page_cursor then return nil, "page records are not in sequence" end
        previous_sequence = decoded.sequence
        records[index] = decoded
    end
    if #records > 0 and page_cursor < previous_sequence then return nil, "page cursor precedes its final record" end
    return {records = records, scanned_through = page_cursor, has_more = has_more}, nil
end
-- Thread operations of the open sequence key on the attempt and the step,
-- so a start retried after an ambiguous failure replays the same records
-- instead of creating a second action, attempt or turn.
local function thread_call(io: IO, session_request: Request, operation: string, fields: {[string]: unknown}, step_key: string?): (unknown, string?)
    fields.thread_id = session_request.thread_id
    fields.idempotency_key = step_key and ("launch:" .. session_request.attempt_id .. ":" .. step_key) or io.key()
    return must(io, M.THREADS .. ":" .. operation, fields)
end
M.admitted_action = admitted_request.admitted_action

local function placement_observation(io: IO, session: Session, attempt: placement_types.Attempt): (boolean, string?)
    local payload = json.encode({placement_attempt_id = attempt.attempt_id, execution_state = attempt.execution_state, cleanup_state = attempt.cleanup_state,
        exit_source = attempt.exit_source, start_failure = attempt.start_failure, evidence_count = attempt.evidence_count, capability = attempt.capability})
    local record = {source = "bee", body = {type = "extension", event_key = "placement:" .. attempt.attempt_id .. ":" .. tostring(attempt.evidence_count),
        data = {type = "extension", event_name = "bee.placement.attempt", event_revision = "1", payload_json = payload}}}
    return M.commit(io, session, {record})
end
local function new_session(plan: Plan, turn_id: string, epoch: integer, revision: integer, point: checkpoint.Checkpoint): Session
    local decoder = stream_json.new(M.MAX_FRAME_BYTES)
    decoder.framer.carry = point.carry.stdout
    decoder.index = point.envelope_index
    local terminal = point.terminal
    local output: OutputState = "open"
    if point.output == "complete" then output = "complete" elseif point.output == "truncated" then output = "truncated" end
    return {plan = plan, turn_id = turn_id, turn_open = true, epoch = epoch, revision = revision, checkpoint = point, decoder = decoder, normalizer = point.normalizer_state,
        terminal = terminal, stream_ended = point.stream_ended == true, exit = nil, eof = {stdout = point.output == "complete", stderr = point.output == "complete"}, runner = nil, settled = nil, recovered = false, output = output, pending_hint = nil, placement_evidence = 0, stderr_sequence = 0,
        last_sequence = {stdout = point.consumed.stdout, stderr = point.consumed.stderr}, held_from = nil,
        dropping_stdout = point.dropping_stdout == true}
end
-- The gateway binding of an attempt under a carrier epoch: admitted after
-- the durable action and attempt preparation, superseding whatever an
-- earlier or retried carrier admitted, and identified in the checkpoint.
local function gateway_admit(io: IO, plan: Plan, epoch: integer): (string?, string?)
    local gateway = plan.gateway
    if not gateway then return nil, nil end
    local request = plan.request
    -- The admitted attempt's workspace is host-selected, so it travels with the
    -- binding surface's fixed context: a bound tool reads which workspace it
    -- belongs to and no tool argument can replace a host key.
    local surface_value = plan.policy.gateway_surface
    if request.workspace_id then
        -- A policy may declare no surface; the binding then admits with the
        -- same default surface gateway.admit would build, so the workspace
        -- still travels as host-selected fixed context.
        if not surface_value then
            surface_value = {tools = {}, traits = {}, base_tools = gateway.tools, active_traits = {}, fixed_context = {}, dynamic_keys = {}}
        end
        surface_value = policy.with_workspace(surface_value, request.workspace_id)
        if not surface_value then return nil, "gateway admit: cannot compose the launch workspace" end
    end
    if request.preferences then
        local composed: Object = {}
        for key, value in pairs(surface_value or {tools = {}, traits = {}, base_tools = gateway.tools, active_traits = {}, fixed_context = {}, dynamic_keys = {}}) do composed[key] = value end
        composed.profile = request.preferences.bee
        composed.authority_grant_id = request.preferences.authority_grant_id
        local grants: {Object} = {}
        for _, file in ipairs(request.preferences.bee and request.preferences.bee.files or {}) do
            local found = false
            for _, resource in ipairs(request.profile_grants or {}) do
                if resource.workspace_id == file.workspace_id and resource.name == file.resource and resource.subpath == file.subpath and resource.access == file.access then
                    grants[#grants + 1] = {workspace_id = file.workspace_id, name = file.resource, subpath = file.subpath,
                        access = file.access, grant_ref = resource.grant_ref, subject = request.owner_id}; found = true
                end
            end
            if not found then return nil, "gateway profile file has no admitted resource grant" end
        end
        composed.resource_grants = grants
        surface_value = composed
    end
    local admitted, admit_error = must(io, M.GATEWAY .. ":admit", {subject = request.session_ref and request.session_ref:match("^bs:") and request.session_ref or request.owner_id, action_id = request.action_id, attempt_id = request.attempt_id, thread_id = request.thread_id,
        owner_incarnation = request.owner_incarnation, carrier_epoch = epoch, tools = gateway.tools, hooks = gateway.hooks, ttl_ms = plan.policy.gateway_ttl_ms, surface = surface_value,
        policy_ref = plan.policy.ref, workspace_id = request.workspace_id, origin_view = request.origin_view})
    if admit_error then return nil, "gateway admit: " .. admit_error end
    local binding, binding_error = gateway_protocol.admitted_binding(admitted)
    if not binding then return nil, "gateway admit returned an invalid binding: " .. tostring(binding_error) end
    local binding_id = binding.binding_id
    step(io, "gateway_admitted")
    return binding_id, nil
end
-- Readiness under the current listener generation with a valid binding,
-- taken immediately before placement starts the child.
local function gateway_ready(io: IO, binding_id: string): string?
    local ready, ready_error = must(io, M.GATEWAY .. ":ready", {binding_id = binding_id})
    if ready_error then return "gateway readiness: " .. ready_error end
    local report, report_error = gateway_protocol.readiness(ready, binding_id)
    if not report then return "gateway readiness returned malformed data: " .. tostring(report_error) end
    if not report.listening then return "gateway readiness: the listener is not ready" end
    if report.binding_valid ~= true then return "gateway readiness: " .. tostring(report.binding_reason) end
    step(io, "gateway_ready")
    return nil
end
local function gateway_revoke(io: IO, binding_id: string?)
    if not binding_id then return end
    io.call(M.GATEWAY .. ":revoke", {binding_id = binding_id})
end
-- drain_hooks: claim what the gateway queued for this binding under this
-- carrier's epoch, commit it through the carrier's own commit path, then
-- acknowledge; a crash between the commit and the acknowledgment is
-- recovered by the next claim, whose commit replays. Nothing here settles
-- anything or extends an attempt.
function M.drain_hooks(io: IO, session: Session): (integer, string?)
    local binding_id = session.checkpoint.gateway_binding
    local gateway = session.plan.gateway
    if not binding_id then return 0, nil end
    if not gateway then return 0, nil end
    if #gateway.hooks == 0 or session.settled then return 0, nil end
    local drained = 0
    for _ = 1, 8 do
        local raw, call_error = io.call(M.GATEWAY .. ":hook_claim", {binding_id = binding_id, carrier_epoch = session.epoch, limit = 16})
        local reply, reply_error = reply_of(raw, call_error)
        if not reply then return drained, "hook claim: " .. tostring(reply_error) end
        if not reply.ok then
            local fault = reply.error or {code = "UNAVAILABLE", message = "hook claim failed"}
            -- An invalid binding may have rejected only unclaimed rows. A
            -- successful empty claim means no retained claim is recoverable
            -- by this carrier; a conflict leaves takeover to its successor.
            if fault.code == "DENIED" or fault.code == "CONFLICT" then return drained, nil end
            return drained, "hook claim: " .. fault.code .. ": " .. fault.message
        end
        local claim, claim_error = gateway_protocol.hook_claim(reply.value, binding_id, session.epoch)
        if not claim then return drained, "hook claim returned malformed data: " .. tostring(claim_error) end
        local turn_id = session.turn_open and session.turn_id or nil
        local batch, batch_error = hook_records.batch(binding_id, turn_id, claim.hooks)
        if not batch then return drained, "hook batch: " .. tostring(batch_error) end
        if #batch.event_ids == 0 then return drained, nil end
        step(io, "hooks_claimed")
        local records = batch.records
        local event_ids = batch.event_ids
        local committed, commit_error = M.commit(io, session, records)
        if not committed then return drained, commit_error end
        step(io, "hooks_committed")
        local _, ack_error = must(io, M.GATEWAY .. ":hook_ack", {binding_id = binding_id, carrier_epoch = session.epoch, event_ids = event_ids})
        if ack_error then return drained, "hook ack: " .. ack_error end
        step(io, "hooks_acknowledged")
        drained = drained + #event_ids
    end
    return drained, nil
end
-- Preparation is shared by structured and native-window execution. It admits
-- the action, prepares and claims its attempt, admits the gateway, and records
-- placement intent. It does not request a turn, attach a transport or start a
-- child; the selected execution path owns those operations.
type PreparedAttempt = {epoch: integer, gateway_binding: string?, notice: placement_types.LoginNotice?}
type FailedPreparation = {epoch: integer?, gateway_binding: string?, attempt: boolean}
local function prepare_notice(value: unknown): (placement_types.LoginNotice?, string?)
    local attempt, attempt_error = placement_decode.attempt(value)
    if not attempt then return nil, "placement prepare returned an invalid attempt: " .. tostring(attempt_error) end
    return attempt.notice, nil
end
M.ATTACH_SCAN_PAGES = 8
M.ATTACH_PAGE_RECORDS = hints.DELIVERY_PAGE_RECORDS
function M.attach_action(io: IO, request: Request): (string?, boolean, string?)
    local owned = false
    local previous: string? = nil
    local previous_sequence = 0
    local cursor = 0
    for _ = 1, M.ATTACH_SCAN_PAGES do
        local page, read_error = must(io, M.THREADS .. ":read_after", {thread_id = request.thread_id, cursor = cursor, limit = M.ATTACH_PAGE_RECORDS})
        if read_error then return nil, false, read_error end
        local decoded_page, page_error = thread_page(page, cursor, M.ATTACH_PAGE_RECORDS)
        if not decoded_page then return nil, false, "read_after answered with an invalid page: " .. tostring(page_error) end
        for _, record in ipairs(decoded_page.records) do
            if record.action_id == request.action_id then
                if record.kind == "action.admitted" then
                    local admitted = bounds.object(record.body)
                    if admitted and admitted.principal_id == request.owner_id then owned = true end
                elseif record.kind == "receipt" then
                    local receipt = bounds.object(record.body)
                    if receipt and receipt.scope == "attempt" and record.attempt_id and record.sequence > previous_sequence then
                        previous, previous_sequence = record.attempt_id, record.sequence
                    end
                end
            end
        end
        if not decoded_page.has_more then break end
        if decoded_page.scanned_through <= cursor then return nil, false, "read_after did not advance its cursor" end
        cursor = decoded_page.scanned_through
    end
    if not owned then return nil, false, nil end
    return previous, true, nil
end
function M.prepare_attempt(io: IO, plan: Plan): (PreparedAttempt?, string?, FailedPreparation?)
    if plan.exchange_refusal then return nil, plan.exchange_refusal, nil end
    local request = plan.request
    local attempt_prepared = false
    local action_admitted = false
    local epoch: integer? = nil
    local gateway_binding: string? = nil
    local grant_refs: {string} = {}
    for _, grant in ipairs(request.resources) do grant_refs[#grant_refs + 1] = grant.grant_ref end
    -- A sequential attempt chains the action's latest settled attempt. A
    -- resumed attempt names its predecessor; a fresh one discovers it when
    -- the action is already admitted, so two starters still serialize on
    -- the owner's chain check.
    local expected_previous: string? = request.previous_attempt_id
    if not request.previous_attempt_id then
        -- Opening an interactive UI is an action even with no initial prompt.
        -- Describe that action in the ledger without sending text to the child.
        local action_input = request.brief
        if action_input == "" and plan.profile.mode == "window" then action_input = "Open " .. plan.binding.title .. " window" end
        local admitted_body = M.admitted_action(request, plan.binding.binding_id,
            plan.binding.binding_digest.entry, plan.policy.ref, grant_refs, action_input)
        local _, admit_error = thread_call(io, request, "admit_action", {action_id = request.action_id, admitted = admitted_body}, "admit")
        if admit_error then
            local previous, attached, attach_error = M.attach_action(io, request)
            if not attached then return nil, attach_error or admit_error, nil end
            expected_previous = previous
        end
        action_admitted = true
    end
    step(io, "admitted")
    local _, prepare_error = thread_call(io, request, "prepare_attempt", {action_id = request.action_id, attempt_id = request.attempt_id, expected_previous_attempt_id = expected_previous, prepared = {
        binding_ref = plan.binding.binding_id, binding_digest = plan.binding.binding_digest.entry, profile_id = plan.profile.id, profile_digest = plan.binding.profile_digest.entry,
        placement_binding = plan.placement_binding.binding_id, placement_binding_digest = plan.placement_binding.binding_digest,
        placement_attempt_id = request.attempt_id, plan_digest = plan.plan_digest}}, "prepare")
    if prepare_error then
        if not action_admitted then return nil, prepare_error, nil end
        return nil, prepare_error, {epoch = nil, gateway_binding = nil, attempt = false}
    end
    attempt_prepared = true
    step(io, "prepared")
    local claimed, claim_error = must(io, M.CARRIER_OPS .. ":claim", {thread_id = request.thread_id, idempotency_key = "launch:" .. request.attempt_id .. ":claim", attempt_id = request.attempt_id})
    if claim_error then return nil, claim_error, {epoch = nil, gateway_binding = nil, attempt = attempt_prepared} end
    local claimed_epoch, claim_decode_error = checkpoint.decode_claim(claimed)
    if not claimed_epoch then return nil, "carrier claim returned an invalid epoch: " .. tostring(claim_decode_error) end
    epoch = claimed_epoch
    local gateway_error: string?
    gateway_binding, gateway_error = gateway_admit(io, plan, epoch)
    if gateway_error then return nil, gateway_error, {epoch = epoch, gateway_binding = nil, attempt = attempt_prepared} end
    local function abandon(err: string): (PreparedAttempt?, string?, FailedPreparation?)
        gateway_revoke(io, gateway_binding)
        return nil, err, {epoch = epoch, gateway_binding = gateway_binding, attempt = attempt_prepared}
    end
    local prepare_target = M.placement_target(plan, "prepare")
    if not prepare_target then return abandon("selected placement binds no prepare") end
    local intent, intent_error = must(io, prepare_target, plan.placement_request)
    if intent_error then return abandon(intent_error) end
    local notice, notice_error = prepare_notice(intent)
    if notice_error then return abandon(notice_error) end
    step(io, "placement_intent")
    return {epoch = epoch, gateway_binding = gateway_binding, notice = notice}, nil, nil
end
local function settle_prestart_failure(io: IO, plan: Plan, epoch: integer, gateway_binding: string?, reason: string,
    session: Session?, turn_id: string?, outcome: prestart.Outcome?)
    local request = plan.request
    local inspection = prestart.inspect(io.call, M.placement_target(plan, "status"), M.placement_target(plan, "stop"),
        request.attempt_id, outcome or "failed", reason)
    local settled_outcome, message = inspection.outcome, inspection.reason
    gateway_revoke(io, gateway_binding)
    local code = settled_outcome == "uncertain" and "launch_uncertain" or "launch_failed"
    local failure = {code = code, message = message, retryable = false}
    if turn_id then
        thread_call(io, request, "end_turn", {action_id = request.action_id, attempt_id = request.attempt_id,
            turn_id = turn_id, carrier_epoch = epoch, turn_end = {outcome = settled_outcome, answer_message_ids = {},
                evidence_refs = {}, error = failure}}, "failed:end_turn")
    end
    local point = session and session.checkpoint or checkpoint.new({binding_ref = plan.binding.binding_id,
        binding_digest = plan.binding.binding_digest.entry, profile_id = plan.profile.id,
        profile_digest = plan.binding.profile_digest.entry, plan_digest = plan.plan_digest,
        gateway_binding = gateway_binding}, epoch)
    point.terminal = {outcome = settled_outcome, answer = nil, error = failure}
    local stored, stored_error = must(io, M.CARRIER_OPS .. ":checkpoint", {thread_id = request.thread_id, attempt_id = request.attempt_id})
    local stored_object = bounds.object(stored)
    local revision = stored_object and bounds.integer(stored_object.checkpoint_revision)
    if not stored_error and revision and stored_object and stored_object.carrier_epoch == epoch then
        must(io, M.CARRIER_OPS .. ":commit", {thread_id = request.thread_id,
            attempt_id = request.attempt_id, idempotency_key = "launch:" .. request.attempt_id .. ":failure:checkpoint",
            carrier_epoch = epoch, expected_revision = revision, checkpoint = point, records = {}})
    end
    thread_call(io, request, "receipt", {action_id = request.action_id, attempt_id = request.attempt_id,
        carrier_epoch = epoch, receipt = {scope = "attempt", outcome = settled_outcome, evidence_refs = {}, error = failure}}, "failed:receipt")
end
-- Structured execution requests a turn and starts the pipe runner only after
-- shared preparation. Failures before execution retire the admitted gateway.
local function record_started(io: IO, session: Session, attempt: placement_types.Attempt): string?
    if session.attempt_started or attempt.start_cancelled or attempt.start_failure then return nil end
    if attempt.execution_state ~= "running" and not (attempt.execution_state == "exited" and attempt.exit_source ~= nil) then return nil end
    local request = session.plan.request
    local _, started_error = thread_call(io, request, "start_attempt", {action_id = request.action_id, attempt_id = request.attempt_id,
        started = {execution_kind = "process", execution_ref = attempt.attempt_id, owner_epoch = io.now_ms()}})
    if started_error then return started_error end
    session.attempt_started = true
    step(io, "attempt_started")
    return nil
end
function M.open(io: IO, plan: Plan): (Session?, string?)
    if plan.profile.mode == "window" or plan.profile.protocol ~= "stream-json" then
        return nil, "structured carrier requires a stream-json session or batch profile"
    end
    local prepared, preparation_error, failed_preparation = M.prepare_attempt(io, plan)
    if not prepared then
        if failed_preparation and failed_preparation.attempt and failed_preparation.epoch then
            settle_prestart_failure(io, plan, failed_preparation.epoch, failed_preparation.gateway_binding,
                "launch preparation failed: " .. tostring(preparation_error))
        end
        return nil, preparation_error
    end
    local request = plan.request
    local epoch, gateway_binding = prepared.epoch, prepared.gateway_binding
    local turn_id = "turn:" .. request.attempt_id .. ":1"
    local _, turn_error = thread_call(io, request, "request_turn", {action_id = request.action_id, attempt_id = request.attempt_id, turn_id = turn_id, carrier_epoch = epoch,
        turn = {input_message_ids = {}, input = {text = request.brief}, resume_ref = plan.resume_ref, delivery_ids = {}}}, "turn")
    if turn_error then
        settle_prestart_failure(io, plan, epoch, gateway_binding, "request turn failed: " .. turn_error, nil, turn_id)
        return nil, turn_error
    end
    step(io, "turn_requested")
    local point = checkpoint.new({binding_ref = plan.binding.binding_id, binding_digest = plan.binding.binding_digest.entry, profile_id = plan.profile.id, profile_digest = plan.binding.profile_digest.entry, plan_digest = plan.plan_digest, gateway_binding = gateway_binding}, epoch)
    point.retained_session_ref = request.session_ref
    local session = new_session(plan, turn_id, epoch, 0, point)
    local committed, commit_error = M.commit(io, session, {})
    if not committed then
        local reason = "initial checkpoint failed: " .. tostring(commit_error or "commit")
        settle_prestart_failure(io, plan, epoch, gateway_binding, reason, session, turn_id)
        return nil, commit_error or "commit"
    end
    local attach_target = M.placement_target(plan, "attach")
    if not attach_target then
        settle_prestart_failure(io, plan, epoch, gateway_binding, "selected placement binds no attach", session, turn_id)
        return nil, "selected placement binds no attach"
    end
    local _, attach_error = must(io, attach_target, {attempt_id = request.attempt_id, recipient = io.self_pid(), generation = epoch})
    if attach_error then
        settle_prestart_failure(io, plan, epoch, gateway_binding, "placement attach failed: " .. attach_error, session, turn_id)
        return nil, attach_error
    end
    step(io, "attached")
    if gateway_binding then
        local readiness_error = gateway_ready(io, gateway_binding)
        if readiness_error then
            settle_prestart_failure(io, plan, epoch, gateway_binding, readiness_error, session, turn_id)
            return nil, readiness_error
        end
    end
    local start_target = M.placement_target(plan, "start")
    if not start_target then
        settle_prestart_failure(io, plan, epoch, gateway_binding, "selected placement binds no start", session, turn_id)
        return nil, "selected placement binds no start"
    end
    local started_value, start_error = must(io, start_target, {attempt_id = request.attempt_id, gateway_binding = gateway_binding})
    if start_error then
        settle_prestart_failure(io, plan, epoch, gateway_binding, "placement start failed: " .. start_error, session, turn_id)
        return nil, start_error
    end
    step(io, "placement_started")
    local attempt, attempt_error = placement_decode.attempt(started_value)
    if not attempt then
        local reason = "placement start returned an invalid attempt: " .. tostring(attempt_error)
        settle_prestart_failure(io, plan, epoch, gateway_binding, reason, session, turn_id)
        return nil, reason
    end
    session.runner = attempt.runner
    session.placement_state = attempt.execution_state
    session.start_failure = attempt.start_failure
    session.start_cancelled = attempt.start_cancelled
    local started_error = record_started(io, session, attempt)
    if started_error then
        settle_prestart_failure(io, plan, epoch, gateway_binding, "recording placement start failed: " .. started_error, session, turn_id)
        return nil, started_error
    end
    local observed, observe_error = placement_observation(io, session, attempt)
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
    local started_error = record_started(io, session, attempt)
    if started_error then return false, started_error end
    return placement_observation(io, session, attempt)
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
    local session = new_session(plan, "turn:" .. request.attempt_id .. ":1", epoch, view.checkpoint_revision, checkpoint.rebind(point, epoch))
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
        local gateway_binding, gateway_error = gateway_admit(io, plan, epoch)
        if gateway_error then return nil, gateway_error end
        session.checkpoint.gateway_binding = gateway_binding
        local function abandon(err: string): (Session?, string?)
            gateway_revoke(io, gateway_binding)
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
            local readiness_error = gateway_ready(io, gateway_binding)
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
        local started_error = record_started(io, session, attempt)
        if started_error then return nil, started_error end
        local observed, observe_error = placement_observation(io, session, attempt)
        if not observed then return nil, observe_error end
        session.turn_open = view.open_turn_id ~= nil
        if view.open_turn_id then session.turn_id = view.open_turn_id end
        step(io, "reattached")
        return session, nil
    end
    local started_error = record_started(io, session, attempt)
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
    local attached_start_error = record_started(io, session, attached_attempt)
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
function M.permission_hook(io: IO, session: Session, raw: unknown): (Object?, string?)
    local input = bounds.object(raw)
    local event_id = input and bounds.id(input.event_id)
    local payload = input and bounds.object(input.payload)
    local request = session.plan.request
    if not input or not event_id or not payload or input.binding_id ~= session.checkpoint.gateway_binding
        or input.attempt_id ~= request.attempt_id or input.subject ~= (request.session_ref and request.session_ref:match("^bs:") and request.session_ref or request.owner_id)
        or input.epoch ~= session.epoch then return nil, "hook differs from this carrier attachment" end
    local selected = session.plan.exchange
    if not selected then return {}, nil end
    if selected.transport ~= "hook_http" then return nil, "carrier does not answer HTTP permission hooks" end
    local checked, check_error = must(io, M.GATEWAY .. ":check", {binding_id = input.binding_id})
    local binding = bounds.object(checked)
    if not binding or binding.valid ~= true or binding.carrier_epoch ~= session.epoch then return nil, check_error or "hook binding changed" end
    local queue, queue_error = must(io, M.GATEWAY .. ":hook_queue", {binding_id = input.binding_id, event_id = event_id})
    local queued = bounds.object(queue)
    local rows = queued and bounds.array(queued.hooks, 1)
    if not rows then return nil, queue_error or "hook evidence unavailable" end
    local evidence: Object? = nil
    for _, row in ipairs(rows) do
        local item = bounds.object(row)
        if item and item.event_id == event_id then evidence = item end
    end
    if not evidence then return nil, "permission hook is not admitted" end
    local ctx = permission_context(io, session)
    local prepared, prepare_error = hook_exchange.request(ctx, event_id, payload, evidence)
    if not prepared then return nil, prepare_error end
    local advanced, advance_error = permission_exchange.advance(ctx, true)
    if not advanced then return nil, advance_error end
    local line, response_error = hook_exchange.response(ctx, event_id)
    if response_error then return nil, response_error end
    return {pending = line == nil, permission_response = line}, nil
end
function M.extension_hook(io: IO, session: Session, raw: unknown): (Object?, string?)
    local input = bounds.object(raw)
    local payload = input and bounds.object(input.payload)
    local event_id = input and bounds.id(input.event_id)
    local request = session.plan.request
    if not input or not payload or not event_id or input.binding_id ~= session.checkpoint.gateway_binding
        or input.attempt_id ~= request.attempt_id or input.epoch ~= session.epoch
        or input.subject ~= (request.session_ref and request.session_ref:match("^bs:") and request.session_ref or request.owner_id) then return nil, "hook differs from this carrier attachment" end
    local checked, check_error = must(io, M.GATEWAY .. ":check", {binding_id = input.binding_id})
    local binding = bounds.object(checked)
    if not binding or binding.valid ~= true or binding.carrier_epoch ~= session.epoch then return nil, check_error or "hook binding changed" end
    local queue, queue_error = must(io, M.GATEWAY .. ":hook_queue", {binding_id = input.binding_id, event_id = event_id})
    local queued = bounds.object(queue)
    local rows = queued and bounds.array(queued.hooks, 1)
    if not rows then return nil, queue_error or "hook evidence unavailable" end
    local event = tostring(payload.hook_event_name or payload.event)
    local normalized, normalize_error = gateway_hooks_catalog.normalize(event, payload)
    if not normalized then return nil, normalize_error end
    local admitted = false
    for _, raw_hook in ipairs(rows) do
        local item = bounds.object(raw_hook)
        if item and item.event_id == event_id and item.event == event and item.digest == normalized.digest
            and (item.status == "queued" or item.status == "committed") then admitted = true end
    end
    if not admitted then return nil, "hook occurrence is not admitted" end
    local points = {SessionStart = "session.start", UserPromptSubmit = "prompt.submit", PreToolUse = "tool.before", PostToolUse = "tool.after"}
    local point = points[event]
    if not point then return nil, "unknown extension hook point" end
    local tool_input: unknown = payload.tool_input
    if type(tool_input) == "string" then tool_input = json.decode(tool_input) end
    local response, err = must(io, "bee.threads.hooks:dispatch", {session_ref = request.session_ref and request.session_ref:match("^bs:") and request.session_ref or nil,
        action_id = request.action_id, thread_id = request.thread_id, workspace_id = request.workspace_id,
        point = point, occurrence_id = event_id, turn_ref = session.turn_id, tool_name = payload.tool_name, tool_call_id = payload.tool_use_id,
        input = tool_input, output = payload.tool_response, text = payload.prompt})
    if not response then return nil, err end
    return {extension_response = response, hook_driver = session.plan.binding.driver_id}, nil
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
local function evidence_of(session: Session, drain_elapsed: boolean): settle.Evidence
    local delivery_ended = session.runner == nil or session.runner_ended == true
    return {terminal = session.terminal, stream_ended = session.stream_ended, exit = session.exit, drained = M.drained(session) or (delivery_ended and drain_elapsed),
        exit_codes_trustworthy = session.plan.exit_codes_trustworthy}
end
-- ready_to_settle: the turn's outcome is decidable and no write is still
-- awaiting its answer, so a declared session end may run before the
-- settlement records end the attempt.
function M.ready_to_settle(session: Session, drain_elapsed: boolean): boolean
    if session.settled then return false end
    local decided: settle.Settlement? = nil
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
        io.call(M.GATEWAY .. ":seal", {binding_id = binding_id})
        local deadline = io.now_ms() + session.plan.policy.drain_ms
        local was_settled = session.settled
        session.settled = nil
        while io.now_ms() < deadline do
            local drained = M.drain_hooks(io, session)
            if drained == 0 then break end
        end
        session.settled = was_settled
        io.call(M.GATEWAY .. ":hook_reject", {binding_id = binding_id, carrier_epoch = session.epoch, reason = "attempt settled"})
    end
    gateway_revoke(io, binding_id)
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
local function pending_write(session: Session, write_id: string): checkpoint.PendingWrite?
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

function M.settle(io: IO, session: Session, drain_elapsed: boolean): (settle.Settlement?, string?)
    if session.settled then return session.settled, nil end
    local decided: settle.Settlement? = nil
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
    local decision: settle.Settlement = {outcome = decided.outcome, answer = decided.answer, resume_ref = decided.resume_ref, reason = reason, exit_reconciled = decided.exit_reconciled}
    local closed_all, close_error = M.close_exchanges(io, session, drain_elapsed)
    if close_error then return nil, close_error end
    if not closed_all then return nil, nil end
    -- What the child reported before its end is committed before the turn
    -- ends; anything queued after this is rejected at close.
    local _, hooks_error = M.drain_hooks(io, session)
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
        local _, end_error = thread_call(io, request, "end_turn", {action_id = request.action_id, attempt_id = request.attempt_id, turn_id = session.turn_id, carrier_epoch = session.epoch,
            turn_end = {outcome = decision.outcome, answer_message_ids = {}, evidence_refs = {}, usage = session.terminal and session.terminal.usage or nil, error = fault}})
        if end_error then return nil, end_error end
        session.turn_open = false
    end
    step(io, "turn_ended")
    local _, receipt_error = thread_call(io, request, "receipt", {action_id = request.action_id, attempt_id = request.attempt_id, carrier_epoch = session.epoch,
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
    thread_call = thread_call, write = M.write}

return M
