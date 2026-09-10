-- MIT. The carrier checkpoint: everything a replacement carrier needs to
-- continue from acknowledged output without a second look at the bytes.
local bounds = require("bounds")
local M = {}
M.REVISION = "bee.carrier.checkpoint@1"
-- Carry bytes per stream: a frame the carrier cannot checkpoint is never
-- acknowledged, so the framing bound equals this.
M.MAX_CARRY_BYTES = 16384
M.MAX_PENDING_WRITES = 8
M.MAX_PENDING_WRITE_BYTES = 4096
M.MAX_PERMISSIONS = 4
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
    phase: string,
    approval_id: string?,
    decision: string?,
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
    terminal: {[string]: unknown}?,
    binding_ref: string,
    binding_digest: string,
    profile_id: string,
    profile_digest: string,
    plan_digest: string?,
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
function M.new(pinned: Pinned, generation: integer): Checkpoint
    return {schema_revision = M.REVISION, pending_writes = {}, permissions = {}, consumed = {stdout = 0, stderr = 0}, carry = {stdout = "", stderr = ""}, envelope_index = 0,
        event_cursor = nil, normalizer_state = nil, terminal = nil, binding_ref = pinned.binding_ref, binding_digest = pinned.binding_digest, profile_id = pinned.profile_id,
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
    local unknown_field = bounds.fields(object, {"schema_revision", "pending_writes", "permissions", "consumed", "carry", "envelope_index", "event_cursor", "normalizer_state", "terminal", "binding_ref", "binding_digest", "profile_id", "profile_digest", "plan_digest", "hint_subscription", "output", "input_closed", "gateway_binding", "attachment_generation"})
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
        state = bounds.object(object.normalizer_state)
        if not state then return nil, "normalizer_state must be an object" end
    end
    local pending: {PendingWrite} = {}
    if object.pending_writes ~= nil then
        if type(object.pending_writes) ~= "table" then return nil, "pending_writes must be a list" end
        for index, item in ipairs(object.pending_writes :: {unknown}) do
            if index > M.MAX_PENDING_WRITES then return nil, "pending_writes exceeds " .. tostring(M.MAX_PENDING_WRITES) end
            local write = bounds.object(item)
            if not write then return nil, "pending_writes[" .. tostring(index) .. "] must be an object" end
            local write_field = bounds.fields(write, {"write_id", "input_digest", "data", "dispatched"})
            if write_field then return nil, "pending_writes[" .. tostring(index) .. "]: " .. write_field end
            local write_id, input_digest = bounds.id(write.write_id), bounds.id(write.input_digest)
            local data = bounds.text(write.data, M.MAX_PENDING_WRITE_BYTES)
            if not write_id or not input_digest or not data then return nil, "pending_writes[" .. tostring(index) .. "] is malformed" end
            pending[index] = {write_id = write_id, input_digest = input_digest, data = data, dispatched = write.dispatched == true}
        end
    end
    local permissions: {Permission} = {}
    if object.permissions ~= nil then
        if type(object.permissions) ~= "table" then return nil, "permissions must be a list" end
        for index, item in ipairs(object.permissions :: {unknown}) do
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
            local phase = bounds.member(permission.phase, M.PERMISSION_PHASES)
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
            local decision: string? = nil
            if permission.decision ~= nil then
                decision = bounds.id(permission.decision)
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
    local terminal: {[string]: unknown}? = nil
    if object.terminal ~= nil then
        terminal = bounds.object(object.terminal)
        if not terminal then return nil, "terminal must be an object" end
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
    local input_closed: boolean? = nil
    if object.input_closed ~= nil then
        if type(object.input_closed) ~= "boolean" then return nil, "input_closed must be a boolean" end
        input_closed = object.input_closed :: boolean
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
    return {schema_revision = M.REVISION, pending_writes = pending, permissions = permissions, consumed = consumed, carry = carried, envelope_index = envelope_index, event_cursor = cursor, normalizer_state = state, terminal = terminal,
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
    if previous.binding_digest ~= next.binding_digest or previous.profile_digest ~= next.profile_digest then return "pinned measurements changed" end
    if next.consumed.stdout < previous.consumed.stdout or next.consumed.stderr < previous.consumed.stderr then return "consumed positions moved backwards" end
    if next.envelope_index < previous.envelope_index then return "envelope index moved backwards" end
    return nil
end
return M
