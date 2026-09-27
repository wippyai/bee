-- MIT. The carrier checkpoint: everything a replacement carrier needs to
-- continue from acknowledged output without a second look at the bytes.
local bounds = require("bounds")
local canonical = require("canonical")
local driver_types = require("driver_types")
local record_values = require("record_values")
local M = {}
M.REVISION = "bee.carrier.checkpoint@1"
-- Carry bytes per stream: a frame the carrier cannot checkpoint is never
-- acknowledged, so the framing bound equals this.
M.MAX_CARRY_BYTES = 16384
M.MAX_PENDING_WRITES = 8
M.MAX_PENDING_WRITE_BYTES = 4096
M.MAX_PERMISSIONS = 4
M.MAX_NORMALIZER_STATE_BYTES = 32768
M.MAX_TERMINAL_BYTES = 8192
-- consumed: an approved effect consumed at the owner; declined: a denial or
-- expiry answered without any effect, never an authorization to act.
M.PERMISSION_PHASES = {"intended", "requested", "decided", "consumed", "declined", "written", "acknowledged", "closed"}
type Positions = {stdout: integer, stderr: integer}
type Carry = {stdout: string, stderr: string}
-- Where a partly committed envelope stands: events before events_committed
-- are in the thread; the rest are re-derived from the carry on resume.
type EventCursor = {envelope_index: integer, events_committed: integer}
-- A write whose intent is committed and whose acceptance is not yet
-- recorded; a resuming carrier asks the runner before deciding.
type PendingWrite = {write_id: string, input_digest: string, data: string, dispatched: boolean}
type PermissionPhase = "intended" | "requested" | "decided" | "consumed" | "declined" | "written" | "acknowledged" | "closed"
type PermissionDecision = "approved" | "denied" | "expired" | "withdrawn"
type AttemptState = "prepared" | "running" | "ended"
type Outcome = "succeeded" | "failed" | "cancelled" | "uncertain"
-- One permission exchange from the request the harness emitted to the
-- response the carrier wrote: every key is derived once and kept, so a
-- replacement asks the approval owner and the runner about the same
-- request, effect and write rather than inventing new ones.
type Permission = {
    permission_request_id: string,
    correlation_id: string,
    acknowledgment_id: string?,
    tool_name: string,
    input_digest: string,
    prompt: string,
    proposal_digest: string,
    idempotency_key: string,
    effect_key: string,
    write_id: string,
    phase: PermissionPhase,
    approval_id: string?,
    decision: PermissionDecision?,
    incarnation: integer?,
    response: string?,
}
type Checkpoint = {
    schema_revision: string,
    pending_writes: {PendingWrite},
    permissions: {Permission},
    consumed: Positions,
    carry: Carry,
    envelope_index: integer,
    event_cursor: EventCursor?,
    normalizer_state: {[string]: unknown}?,
    terminal: driver_types.Terminal?,
    -- stream_ended: the terminal was derived from the end of stdout, not
    -- read from an envelope, so it decides only after exit and the drain.
    stream_ended: boolean?,
    -- A frame exceeded the runner's unacknowledged window. Skip to its
    -- newline after restart without retaining unbounded partial bytes.
    dropping_stdout: boolean?,
    binding_ref: string,
    binding_digest: string,
    profile_id: string,
    profile_digest: string,
    plan_digest: string?,
    retained_session_ref: string?,
    hint_subscription: string?,
    output: string?,
    -- input_closed: the owner closed the child's stdin after settlement;
    -- a recovered carrier never writes to that session again.
    input_closed: boolean?,
    -- gateway_binding: the gateway binding this attempt was admitted under;
    -- an identifier, never a token.
    gateway_binding: string?,
    attachment_generation: integer,
}
type Pinned = {binding_ref: string, binding_digest: string, profile_id: string, profile_digest: string, plan_digest: string?, gateway_binding: string?}
type CheckpointView = {
    attempt_id: string,
    action_id: string,
    carrier_epoch: integer,
    checkpoint_revision: integer,
    checkpoint: unknown,
    attempt_state: AttemptState,
    attempt_outcome: Outcome?,
    attempt_error: {code: string, message: string, retryable: boolean}?,
    open_turn_id: string?,
    placement_binding: string?,
    placement_binding_digest: string?,
    placement_attempt_id: string?,
}
type CommittedRecord = {record_id: string, sequence: integer, replayed: boolean}
local function bounded_json_object(value: unknown, label: string, maximum: integer): ({[string]: unknown}?, string?)
    local object = bounds.object(value)
    if not object then return nil, label .. " must be an object" end
    local encoded, encode_error = canonical.encode(object)
    if not encoded then return nil, label .. " is not valid JSON: " .. tostring(encode_error) end
    if #encoded > maximum then return nil, label .. " exceeds " .. tostring(maximum) .. " bytes" end
    return object, nil
end
local function permission_phase(value: unknown): PermissionPhase?
    if value == "intended" then return "intended" end
    if value == "requested" then return "requested" end
    if value == "decided" then return "decided" end
    if value == "consumed" then return "consumed" end
    if value == "declined" then return "declined" end
    if value == "written" then return "written" end
    if value == "acknowledged" then return "acknowledged" end
    if value == "closed" then return "closed" end
    return nil
end
local function permission_decision(value: unknown): PermissionDecision?
    if value == "approved" then return "approved" end
    if value == "denied" then return "denied" end
    if value == "expired" then return "expired" end
    if value == "withdrawn" then return "withdrawn" end
    return nil
end
local function terminal(value: unknown): (driver_types.Terminal?, string?)
    local object, object_error = bounded_json_object(value, "terminal", M.MAX_TERMINAL_BYTES)
    if not object then return nil, object_error end
    local unknown_field = bounds.fields(object, {"outcome", "answer", "resume_ref", "usage", "error"})
    if unknown_field then return nil, "terminal: " .. unknown_field end
    local outcome = record_values.outcome(object.outcome)
    if not outcome then return nil, "terminal outcome is invalid" end
    local answer: string? = nil
    if object.answer ~= nil then
        answer = bounds.text(object.answer, M.MAX_TERMINAL_BYTES)
        if answer == nil then return nil, "terminal answer is invalid" end
    end
    local resume_ref: string? = nil
    if object.resume_ref ~= nil then
        resume_ref = bounds.id(object.resume_ref)
        if resume_ref == nil then return nil, "terminal resume_ref is invalid" end
    end
    local usage: driver_types.Usage? = nil
    if object.usage ~= nil then
        local decoded_usage, usage_error = record_values.usage(object.usage)
        if not decoded_usage then return nil, "terminal usage is malformed: " .. tostring(usage_error) end
        usage = decoded_usage
    end
    local terminal_error: driver_types.Fault? = nil
    if object.error ~= nil then
        local decoded_error, fault_error = record_values.fault(object.error)
        if not decoded_error then return nil, "terminal error is malformed: " .. tostring(fault_error) end
        terminal_error = decoded_error
    end
    return {outcome = outcome, answer = answer, resume_ref = resume_ref, usage = usage, error = terminal_error}, nil
end
function M.decode_terminal(value: unknown): (driver_types.Terminal?, string?)
    return terminal(value)
end
function M.normalizer_state(value: unknown): ({[string]: unknown}?, string?)
    if value == nil then return nil, nil end
    return bounded_json_object(value, "normalizer_state", M.MAX_NORMALIZER_STATE_BYTES)
end
function M.decode_checkpoint_view(value: unknown): (CheckpointView?, string?)
    local object = bounds.object(value)
    if not object then return nil, "carrier checkpoint view must be an object" end
    local unknown_field = bounds.fields(object, {"attempt_id", "action_id", "carrier_epoch", "checkpoint_revision", "checkpoint", "attempt_state", "attempt_outcome", "attempt_error", "open_turn_id", "placement_binding", "placement_binding_digest", "placement_attempt_id", "cancel_intent"})
    if unknown_field then return nil, "carrier checkpoint view: " .. unknown_field end
    local attempt_id, action_id = bounds.id(object.attempt_id), bounds.id(object.action_id)
    local carrier_epoch, checkpoint_revision = bounds.count(object.carrier_epoch), bounds.count(object.checkpoint_revision)
    local attempt_state: AttemptState? = nil
    if object.attempt_state == "prepared" then attempt_state = "prepared"
    elseif object.attempt_state == "running" then attempt_state = "running"
    elseif object.attempt_state == "ended" then attempt_state = "ended" end
    if attempt_id == nil or action_id == nil or carrier_epoch == nil or checkpoint_revision == nil or attempt_state == nil then
        return nil, "carrier checkpoint identity or state is malformed"
    end
    local attempt_outcome: Outcome? = nil
    if object.attempt_outcome ~= nil then
        if object.attempt_outcome == "succeeded" then attempt_outcome = "succeeded"
        elseif object.attempt_outcome == "failed" then attempt_outcome = "failed"
        elseif object.attempt_outcome == "cancelled" then attempt_outcome = "cancelled"
        elseif object.attempt_outcome == "uncertain" then attempt_outcome = "uncertain"
        else return nil, "carrier attempt outcome is malformed" end
    end
    local attempt_error: {code: string, message: string, retryable: boolean}? = nil
    if object.attempt_error ~= nil then
        local fault = bounds.object(object.attempt_error)
        if not fault then return nil, "carrier attempt error must be an object" end
        local fault_field = bounds.fields(fault, {"code", "message", "retryable"})
        local code, message = bounds.id(fault.code), bounds.text(fault.message, 4096)
        if fault_field or code == nil or message == nil or type(fault.retryable) ~= "boolean" then
            return nil, "carrier attempt error is malformed"
        end
        attempt_error = {code = code, message = message, retryable = fault.retryable}
    end
    local open_turn_id: string? = nil
    if object.open_turn_id ~= nil then
        open_turn_id = bounds.id(object.open_turn_id)
        if open_turn_id == nil then return nil, "carrier open turn id is malformed" end
    end
    local placement_binding: string? = nil
    local placement_binding_digest: string? = nil
    local placement_attempt_id: string? = nil
    for _, name in ipairs({"placement_binding", "placement_binding_digest", "placement_attempt_id"}) do
        if object[name] ~= nil then
            local selected = bounds.id(object[name])
            if selected == nil then return nil, "carrier " .. name .. " is malformed" end
            if name == "placement_binding" then placement_binding = selected
            elseif name == "placement_binding_digest" then placement_binding_digest = selected
            else placement_attempt_id = selected end
        end
    end
    local has_placement_identity = placement_binding ~= nil or placement_binding_digest ~= nil or placement_attempt_id ~= nil
    if has_placement_identity and (placement_binding == nil or placement_binding_digest == nil or placement_attempt_id == nil) then
        return nil, "carrier placement identity is incomplete"
    end
    if object.cancel_intent ~= nil then
        local intent = bounds.object(object.cancel_intent)
        if not intent then return nil, "carrier cancel intent must be an object" end
        local intent_field = bounds.fields(intent, {"attempt_id", "idempotency_key", "state", "outcome"})
        local intent_attempt, intent_key = bounds.id(intent.attempt_id), bounds.id(intent.idempotency_key)
        local intent_state = bounds.member(intent.state, {"cancelling", "ended"})
        local intent_outcome = intent.outcome == nil and nil or bounds.member(intent.outcome, {"succeeded", "failed", "cancelled", "uncertain"})
        if intent_field or intent_attempt ~= attempt_id or intent_key == nil or intent_state == nil
            or (intent.outcome ~= nil and intent_outcome == nil) then return nil, "carrier cancel intent is malformed" end
    end
    if (checkpoint_revision == 0) ~= (object.checkpoint == nil) then return nil, "carrier checkpoint revision and value disagree" end
    return {attempt_id = attempt_id, action_id = action_id, carrier_epoch = carrier_epoch, checkpoint_revision = checkpoint_revision,
        checkpoint = object.checkpoint, attempt_state = attempt_state, attempt_outcome = attempt_outcome, attempt_error = attempt_error,
        open_turn_id = open_turn_id, placement_binding = placement_binding,
        placement_binding_digest = placement_binding_digest, placement_attempt_id = placement_attempt_id}, nil
end
function M.decode_claim(value: unknown): (integer?, string?)
    local view, view_error = M.decode_checkpoint_view(value)
    if not view then return nil, "carrier claim: " .. tostring(view_error) end
    if view.carrier_epoch < 1 then return nil, "carrier claim epoch is invalid" end
    return view.carrier_epoch, nil
end
function M.decode_commit(value: unknown, attempt_id: string, carrier_epoch: integer): (integer?, string?)
    local object = bounds.object(value)
    if not object then return nil, "carrier commit must be an object" end
    local unknown_field = bounds.fields(object, {"attempt_id", "carrier_epoch", "checkpoint_revision", "records"})
    local returned_attempt = bounds.id(object.attempt_id)
    local returned_epoch = bounds.count(object.carrier_epoch)
    local revision = bounds.count(object.checkpoint_revision)
    local records, records_error = bounds.array(object.records, bounds.MAX_ARRAY_ITEMS)
    if unknown_field or returned_attempt ~= attempt_id or returned_epoch ~= carrier_epoch or revision == nil or revision < 1 or records == nil then
        return nil, "carrier commit identity, revision or records are invalid: " .. tostring(records_error)
    end
    for index, raw in ipairs(records) do
        local record = bounds.object(raw)
        if not record then return nil, "carrier commit records[" .. tostring(index) .. "] must be an object" end
        local record_field = bounds.fields(record, {"record_id", "sequence", "replayed"})
        local record_id, sequence = bounds.id(record.record_id), bounds.count(record.sequence)
        if record_field or record_id == nil or sequence == nil or type(record.replayed) ~= "boolean" then
            return nil, "carrier commit records[" .. tostring(index) .. "] is malformed"
        end
    end
    return revision, nil
end
function M.new(pinned: Pinned, generation: integer): Checkpoint
    return {schema_revision = M.REVISION, retained_session_ref = nil, pending_writes = {}, permissions = {}, consumed = {stdout = 0, stderr = 0}, carry = {stdout = "", stderr = ""}, envelope_index = 0,
        event_cursor = nil, normalizer_state = nil, terminal = nil, stream_ended = nil, dropping_stdout = nil,
        binding_ref = pinned.binding_ref, binding_digest = pinned.binding_digest, profile_id = pinned.profile_id,
        profile_digest = pinned.profile_digest, plan_digest = pinned.plan_digest, hint_subscription = nil, output = nil, input_closed = nil, gateway_binding = pinned.gateway_binding, attachment_generation = generation}
end
local function positions(value: unknown, name: string): (Positions?, string?)
    local object = bounds.object(value)
    if not object then return nil, name .. " must be an object" end
    local unknown_field = bounds.fields(object, {"stdout", "stderr"})
    if unknown_field then return nil, name .. ": " .. unknown_field end
    local out, err = bounds.integer(object.stdout), bounds.integer(object.stderr)
    if not out or out < 0 or not err or err < 0 then return nil, name .. " positions must be nonnegative integers" end
    return {stdout = out, stderr = err}, nil
end
local function carry(value: unknown): (Carry?, string?)
    local object = bounds.object(value)
    if not object then return nil, "carry must be an object" end
    local unknown_field = bounds.fields(object, {"stdout", "stderr"})
    if unknown_field then return nil, "carry: " .. unknown_field end
    local out = bounds.text(object.stdout == nil and "" or object.stdout, M.MAX_CARRY_BYTES)
    local err = bounds.text(object.stderr == nil and "" or object.stderr, M.MAX_CARRY_BYTES)
    if not out or not err then return nil, "carry bytes exceed " .. tostring(M.MAX_CARRY_BYTES) end
    return {stdout = out, stderr = err}, nil
end
function M.decode(value: unknown): (Checkpoint?, string?)
    local object = bounds.object(value)
    if not object then return nil, "checkpoint must be an object" end
    local unknown_field = bounds.fields(object, {"schema_revision", "pending_writes", "permissions", "consumed", "carry", "envelope_index", "event_cursor", "normalizer_state", "terminal", "stream_ended", "dropping_stdout", "binding_ref", "binding_digest", "profile_id", "profile_digest", "plan_digest", "retained_session_ref", "hint_subscription", "output", "input_closed", "gateway_binding", "attachment_generation"})
    if unknown_field then return nil, unknown_field end
    if object.schema_revision ~= M.REVISION then return nil, "schema_revision is not " .. M.REVISION end
    local consumed, consumed_error = positions(object.consumed, "consumed")
    if not consumed then return nil, consumed_error end
    local carried, carry_error = carry(object.carry == nil and {} or object.carry)
    if not carried then return nil, carry_error end
    local envelope = bounds.integer(object.envelope_index)
    if not envelope or envelope < 0 then return nil, "envelope_index must be a nonnegative integer" end
    local cursor: EventCursor? = nil
    if object.event_cursor ~= nil then
        local cursor_object = bounds.object(object.event_cursor)
        if not cursor_object then return nil, "event_cursor must be an object" end
        local cursor_field = bounds.fields(cursor_object, {"envelope_index", "events_committed"})
        if cursor_field then return nil, "event_cursor: " .. cursor_field end
        local at, done = bounds.integer(cursor_object.envelope_index), bounds.integer(cursor_object.events_committed)
        if not at or at < 0 or not done or done < 1 then return nil, "event_cursor must name an envelope and a positive count" end
        cursor = {envelope_index = at, events_committed = done}
    end
    local state: {[string]: unknown}? = nil
    if object.normalizer_state ~= nil then
        state, carry_error = bounded_json_object(object.normalizer_state, "normalizer_state", M.MAX_NORMALIZER_STATE_BYTES)
        if not state then return nil, carry_error end
    end
    local pending: {PendingWrite} = {}
    if object.pending_writes ~= nil then
        local pending_rows, array_error = bounds.array(object.pending_writes, M.MAX_PENDING_WRITES)
        if not pending_rows then return nil, "pending_writes must be a bounded dense list: " .. tostring(array_error) end
        for index, item in ipairs(pending_rows) do
            if index > M.MAX_PENDING_WRITES then return nil, "pending_writes exceeds " .. tostring(M.MAX_PENDING_WRITES) end
            local write = bounds.object(item)
            if not write then return nil, "pending_writes[" .. tostring(index) .. "] must be an object" end
            local write_field = bounds.fields(write, {"write_id", "input_digest", "data", "dispatched"})
            if write_field then return nil, "pending_writes[" .. tostring(index) .. "]: " .. write_field end
            local write_id, input_digest = bounds.id(write.write_id), bounds.id(write.input_digest)
            local data = bounds.text(write.data, M.MAX_PENDING_WRITE_BYTES)
            if not write_id or not input_digest or not data then return nil, "pending_writes[" .. tostring(index) .. "] is malformed" end
            local dispatched = false
            if write.dispatched ~= nil then
                if type(write.dispatched) ~= "boolean" then return nil, "pending_writes[" .. tostring(index) .. "].dispatched must be a boolean" end
                dispatched = write.dispatched
            end
            pending[index] = {write_id = write_id, input_digest = input_digest, data = data, dispatched = dispatched}
        end
    end
    local permissions: {Permission} = {}
    if object.permissions ~= nil then
        local permission_rows, array_error = bounds.array(object.permissions, M.MAX_PERMISSIONS)
        if not permission_rows then return nil, "permissions must be a bounded dense list: " .. tostring(array_error) end
        for index, item in ipairs(permission_rows) do
            if index > M.MAX_PERMISSIONS then return nil, "permissions exceeds " .. tostring(M.MAX_PERMISSIONS) end
            local permission = bounds.object(item)
            if not permission then return nil, "permissions[" .. tostring(index) .. "] must be an object" end
            local permission_field = bounds.fields(permission, {"permission_request_id", "correlation_id", "acknowledgment_id", "tool_name", "input_digest", "prompt", "proposal_digest", "idempotency_key", "effect_key", "write_id", "phase", "approval_id", "decision", "incarnation", "response"})
            if permission_field then return nil, "permissions[" .. tostring(index) .. "]: " .. permission_field end
            local request_id, correlation = bounds.id(permission.permission_request_id), bounds.id(permission.correlation_id)
            local tool, input_digest = bounds.id(permission.tool_name), bounds.id(permission.input_digest)
            local prompt = bounds.text(permission.prompt, 4096)
            local proposal_digest, idempotency_key = bounds.id(permission.proposal_digest), bounds.id(permission.idempotency_key)
            local effect_key, write_id = bounds.id(permission.effect_key), bounds.id(permission.write_id)
            local phase = permission_phase(permission.phase)
            if not request_id or not correlation or not tool or not input_digest or not prompt or not proposal_digest or not idempotency_key or not effect_key or not write_id or not phase then
                return nil, "permissions[" .. tostring(index) .. "] is malformed"
            end
            local acknowledgment_id: string? = nil
            if permission.acknowledgment_id ~= nil then
                acknowledgment_id = bounds.id(permission.acknowledgment_id)
                if not acknowledgment_id then return nil, "permissions[" .. tostring(index) .. "] acknowledgment_id is not an identifier" end
            end
            local approval_id: string? = nil
            if permission.approval_id ~= nil then
                approval_id = bounds.id(permission.approval_id)
                if not approval_id then return nil, "permissions[" .. tostring(index) .. "] approval_id is not an identifier" end
            end
            local decision: PermissionDecision? = nil
            if permission.decision ~= nil then
                decision = permission_decision(permission.decision)
                if not decision then return nil, "permissions[" .. tostring(index) .. "] decision is not an identifier" end
            end
            local incarnation: integer? = nil
            if permission.incarnation ~= nil then
                incarnation = bounds.integer(permission.incarnation)
                if not incarnation or incarnation < 1 then return nil, "permissions[" .. tostring(index) .. "] incarnation must be a positive integer" end
            end
            local response: string? = nil
            if permission.response ~= nil then
                response = bounds.text(permission.response, M.MAX_PENDING_WRITE_BYTES)
                if not response then return nil, "permissions[" .. tostring(index) .. "] response exceeds the write bound" end
            end
            permissions[index] = {permission_request_id = request_id, correlation_id = correlation, acknowledgment_id = acknowledgment_id, tool_name = tool, input_digest = input_digest, prompt = prompt, proposal_digest = proposal_digest,
                idempotency_key = idempotency_key, effect_key = effect_key, write_id = write_id, phase = phase, approval_id = approval_id, decision = decision, incarnation = incarnation, response = response}
        end
    end
    local retained_session: string? = nil
    if object.retained_session_ref ~= nil then
        retained_session = bounds.id(object.retained_session_ref)
        if not retained_session then return nil, "retained_session_ref is not an identifier" end
    end
    local decoded_terminal: driver_types.Terminal? = nil
    if object.terminal ~= nil then
        decoded_terminal, carry_error = terminal(object.terminal)
        if not decoded_terminal then return nil, carry_error end
    end
    local binding_ref, binding_digest = bounds.id(object.binding_ref), bounds.id(object.binding_digest)
    local profile_id, profile_digest = bounds.id(object.profile_id), bounds.id(object.profile_digest)
    if not binding_ref then return nil, "binding_ref is not an identifier" end
    if not binding_digest then return nil, "binding_digest is not an identifier" end
    if not profile_id then return nil, "profile_id is not an identifier" end
    if not profile_digest then return nil, "profile_digest is not an identifier" end
    local plan_digest: string? = nil
    if object.plan_digest ~= nil then
        plan_digest = bounds.id(object.plan_digest)
        if not plan_digest then return nil, "plan_digest is not an identifier" end
    end
    local stream_ended: boolean? = nil
    if object.stream_ended ~= nil then
        if type(object.stream_ended) ~= "boolean" then return nil, "stream_ended must be a boolean" end
        stream_ended = object.stream_ended
    end
    if object.dropping_stdout ~= nil and type(object.dropping_stdout) ~= "boolean" then
        return nil, "dropping_stdout must be a boolean"
    end
    local input_closed: boolean? = nil
    if object.input_closed ~= nil then
        if type(object.input_closed) ~= "boolean" then return nil, "input_closed must be a boolean" end
        input_closed = object.input_closed
    end
    local hint_subscription: string? = nil
    if object.hint_subscription ~= nil then
        hint_subscription = bounds.id(object.hint_subscription)
        if not hint_subscription then return nil, "hint_subscription is not an identifier" end
    end
    local output: string? = nil
    if object.output ~= nil then
        output = bounds.member(object.output, {"open", "complete", "truncated"})
        if not output then return nil, "output must be open, complete or truncated" end
    end
    local gateway_binding: string? = nil
    if object.gateway_binding ~= nil then
        gateway_binding = bounds.id(object.gateway_binding)
        if not gateway_binding then return nil, "gateway_binding is not an identifier" end
    end
    local generation = bounds.integer(object.attachment_generation)
    if not generation or generation < 0 then return nil, "attachment_generation must be a nonnegative integer" end
    local envelope_index: integer = envelope
    local attachment_generation: integer = generation
    return {schema_revision = M.REVISION, retained_session_ref = retained_session, pending_writes = pending, permissions = permissions, consumed = consumed, carry = carried, envelope_index = envelope_index, event_cursor = cursor, normalizer_state = state, terminal = decoded_terminal, stream_ended = stream_ended, dropping_stdout = object.dropping_stdout == true,
        binding_ref = binding_ref, binding_digest = binding_digest, profile_id = profile_id, profile_digest = profile_digest, plan_digest = plan_digest,
        hint_subscription = hint_subscription, output = output, input_closed = input_closed, gateway_binding = gateway_binding, attachment_generation = attachment_generation}, nil
end
-- The same checkpoint under a replacement carrier's generation.
function M.rebind(point: Checkpoint, generation: integer): Checkpoint
    point.attachment_generation = generation
    return point
end
-- A checkpoint continues another only forward and only for the same pins.
function M.continues(previous: Checkpoint, next: Checkpoint): string?
    if previous.retained_session_ref ~= next.retained_session_ref then return "retained session changed" end
    if previous.binding_digest ~= next.binding_digest or previous.profile_digest ~= next.profile_digest then return "pinned measurements changed" end
    if next.consumed.stdout < previous.consumed.stdout or next.consumed.stderr < previous.consumed.stderr then return "consumed positions moved backwards" end
    if next.envelope_index < previous.envelope_index then return "envelope index moved backwards" end
    return nil
end
return M
