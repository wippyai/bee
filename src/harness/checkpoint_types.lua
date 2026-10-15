local driver_types = require("driver_types")

type Positions = {stdout: integer, stderr: integer}
type Carry = {stdout: string, stderr: string}
type EventCursor = {envelope_index: integer, events_committed: integer}
type PendingWrite = {write_id: string, input_digest: string, data: string, dispatched: boolean}
type PermissionPhase = "intended" | "requested" | "decided" | "consumed" | "declined" | "written" | "acknowledged" | "closed"
type PermissionDecision = "approved" | "denied" | "expired" | "withdrawn"
type AttemptState = "prepared" | "running" | "ended"
type Outcome = "succeeded" | "failed" | "cancelled" | "uncertain"
type Permission = {lease_ref: string?,
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
    deadline_ms: integer?,
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
    -- conversation_ref: the provider conversation a resumed window was
    -- started with; it continues that conversation before any hook reports it.
    conversation_ref: string?,
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

return {}
