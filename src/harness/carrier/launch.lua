-- MIT. The carrier's launch sequence: shared attempt preparation (action
-- admission, attempt claim, gateway admission, placement intent), the
-- thread operations keyed on the attempt, the failure settlement of a
-- launch that cannot start, and the session a started attempt opens with.
local json = require("json")
local bounds = require("bounds")
local record_bounds = require("record_bounds")
local checkpoint = require("checkpoint")
local prestart = require("prestart")
local stream_json = require("stream_json")
local placement_types = require("placement_types")
local placement_decode = require("placement_decode")
local record_types = require("record_types")
local thread_record = require("thread_record")
local admitted_request = require("admitted_request")
local hints = require("hints")
local checkpoint_types = require("checkpoint_types")
local part_output = require("part_output")
local part_planning = require("part_planning")
local part_gateway = require("part_gateway")
type IO = part_output.IO
type Plan = part_output.Plan
type Session = part_output.Session
type OutputState = part_output.OutputState
type Request = part_planning.Request
local must = part_output.must
local step = part_output.step
local M = {}
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
function M.thread_call(io: IO, session_request: Request, operation: string, fields: {[string]: unknown}, step_key: string?): (unknown, string?)
    fields.thread_id = session_request.thread_id
    fields.idempotency_key = step_key and ("launch:" .. session_request.attempt_id .. ":" .. step_key) or io.key()
    return must(io, hints.THREADS .. ":" .. operation, fields)
end
local admitted_action = admitted_request.admitted_action

function M.placement_observation(io: IO, session: Session, attempt: placement_types.Attempt): (boolean, string?)
    local payload = json.encode({placement_attempt_id = attempt.attempt_id, execution_state = attempt.execution_state, cleanup_state = attempt.cleanup_state,
        exit_source = attempt.exit_source, start_failure = attempt.start_failure, evidence_count = attempt.evidence_count, capability = attempt.capability})
    local record = {source = "bee", body = {type = "extension", event_key = "placement:" .. attempt.attempt_id .. ":" .. tostring(attempt.evidence_count),
        data = {type = "extension", event_name = "bee.placement.attempt", event_revision = "1", payload_json = payload}}}
    return part_output.commit(io, session, {record})
end
function M.new_session(plan: Plan, turn_id: string, epoch: integer, revision: integer, point: checkpoint_types.Checkpoint): Session
    local decoder = stream_json.new(part_output.MAX_FRAME_BYTES)
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
local ATTACH_SCAN_PAGES = 8
local ATTACH_PAGE_RECORDS = hints.DELIVERY_PAGE_RECORDS
function M.attach_action(io: IO, request: Request): (string?, boolean, string?)
    local owned = false
    local previous: string? = nil
    local previous_sequence = 0
    local cursor = 0
    for _ = 1, ATTACH_SCAN_PAGES do
        local page, read_error = must(io, hints.THREADS .. ":read_after", {thread_id = request.thread_id, cursor = cursor, limit = ATTACH_PAGE_RECORDS})
        if read_error then return nil, false, read_error end
        local decoded_page, page_error = thread_page(page, cursor, ATTACH_PAGE_RECORDS)
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
        local admitted_body = admitted_action(request, plan.binding.binding_id,
            plan.binding.binding_digest.entry, plan.policy.ref, grant_refs, action_input)
        local _, admit_error = M.thread_call(io, request, "admit_action", {action_id = request.action_id, admitted = admitted_body}, "admit")
        if admit_error then
            local previous, attached, attach_error = M.attach_action(io, request)
            if not attached then return nil, attach_error or admit_error, nil end
            expected_previous = previous
        end
        action_admitted = true
    end
    step(io, "admitted")
    local _, prepare_error = M.thread_call(io, request, "prepare_attempt", {action_id = request.action_id, attempt_id = request.attempt_id, expected_previous_attempt_id = expected_previous, prepared = {
        binding_ref = plan.binding.binding_id, binding_digest = plan.binding.binding_digest.entry, profile_id = plan.profile.id, profile_digest = plan.binding.profile_digest.entry,
        placement_binding = plan.placement_binding.binding_id, placement_binding_digest = plan.placement_binding.binding_digest,
        placement_attempt_id = request.attempt_id, plan_digest = plan.plan_digest}}, "prepare")
    if prepare_error then
        if not action_admitted then return nil, prepare_error, nil end
        return nil, prepare_error, {epoch = nil, gateway_binding = nil, attempt = false}
    end
    attempt_prepared = true
    step(io, "prepared")
    local claimed, claim_error = must(io, part_output.CARRIER_OPS .. ":claim", {thread_id = request.thread_id, idempotency_key = "launch:" .. request.attempt_id .. ":claim", attempt_id = request.attempt_id})
    if claim_error then return nil, claim_error, {epoch = nil, gateway_binding = nil, attempt = attempt_prepared} end
    local claimed_epoch, claim_decode_error = checkpoint.decode_claim(claimed)
    if not claimed_epoch then return nil, "carrier claim returned an invalid epoch: " .. tostring(claim_decode_error) end
    epoch = claimed_epoch
    local gateway_error: string?
    gateway_binding, gateway_error = part_gateway.admit(io, plan, epoch)
    if gateway_error then return nil, gateway_error, {epoch = epoch, gateway_binding = nil, attempt = attempt_prepared} end
    local function abandon(err: string): (PreparedAttempt?, string?, FailedPreparation?)
        part_gateway.revoke(io, gateway_binding)
        return nil, err, {epoch = epoch, gateway_binding = gateway_binding, attempt = attempt_prepared}
    end
    local prepare_target = part_output.placement_target(plan, "prepare")
    if not prepare_target then return abandon("selected placement binds no prepare") end
    local intent, intent_error = must(io, prepare_target, plan.placement_request)
    if intent_error then return abandon(intent_error) end
    local notice, notice_error = prepare_notice(intent)
    if notice_error then return abandon(notice_error) end
    step(io, "placement_intent")
    return {epoch = epoch, gateway_binding = gateway_binding, notice = notice}, nil, nil
end
function M.settle_prestart_failure(io: IO, plan: Plan, epoch: integer, gateway_binding: string?, reason: string,
    session: Session?, turn_id: string?, outcome: prestart.Outcome?)
    local request = plan.request
    local inspection = prestart.inspect(io.call, part_output.placement_target(plan, "status"), part_output.placement_target(plan, "stop"),
        request.attempt_id, outcome or "failed", reason)
    local settled_outcome, message = inspection.outcome, inspection.reason
    part_gateway.revoke(io, gateway_binding)
    local code = settled_outcome == "uncertain" and "launch_uncertain" or "launch_failed"
    local failure = {code = code, message = message, retryable = false}
    if turn_id then
        M.thread_call(io, request, "end_turn", {action_id = request.action_id, attempt_id = request.attempt_id,
            turn_id = turn_id, carrier_epoch = epoch, turn_end = {outcome = settled_outcome, answer_message_ids = {},
                evidence_refs = {}, error = failure}}, "failed:end_turn")
    end
    local point = session and session.checkpoint or checkpoint.new({binding_ref = plan.binding.binding_id,
        binding_digest = plan.binding.binding_digest.entry, profile_id = plan.profile.id,
        profile_digest = plan.binding.profile_digest.entry, plan_digest = plan.plan_digest,
        gateway_binding = gateway_binding}, epoch)
    point.terminal = {outcome = settled_outcome, answer = nil, error = failure}
    local stored, stored_error = must(io, part_output.CARRIER_OPS .. ":checkpoint", {thread_id = request.thread_id, attempt_id = request.attempt_id})
    local stored_object = bounds.object(stored)
    local revision = stored_object and bounds.integer(stored_object.checkpoint_revision)
    if not stored_error and revision and stored_object and stored_object.carrier_epoch == epoch then
        must(io, part_output.CARRIER_OPS .. ":commit", {thread_id = request.thread_id,
            attempt_id = request.attempt_id, idempotency_key = "launch:" .. request.attempt_id .. ":failure:checkpoint",
            carrier_epoch = epoch, expected_revision = revision, checkpoint = point, records = {}})
    end
    M.thread_call(io, request, "receipt", {action_id = request.action_id, attempt_id = request.attempt_id,
        carrier_epoch = epoch, receipt = {scope = "attempt", outcome = settled_outcome, evidence_refs = {}, error = failure}}, "failed:receipt")
end
-- Structured execution requests a turn and starts the pipe runner only after
-- shared preparation. Failures before execution retire the admitted gateway.
function M.record_started(io: IO, session: Session, attempt: placement_types.Attempt): string?
    if session.attempt_started or attempt.start_cancelled or attempt.start_failure then return nil end
    if attempt.execution_state ~= "running" and not (attempt.execution_state == "exited" and attempt.exit_source ~= nil) then return nil end
    local request = session.plan.request
    local _, started_error = M.thread_call(io, request, "start_attempt", {action_id = request.action_id, attempt_id = request.attempt_id,
        started = {execution_kind = "process", execution_ref = attempt.attempt_id, owner_epoch = io.now_ms()}})
    if started_error then return started_error end
    session.attempt_started = true
    step(io, "attempt_started")
    return nil
end
return M
