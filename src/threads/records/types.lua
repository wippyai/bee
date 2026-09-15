-- MIT. Record families committed by the thread authority. Every value here is
-- produced by a decoder in this namespace; nothing outside it builds them from
-- raw input.
type Source = "stream" | "hook" | "transcript" | "mcp" | "bee"
type Outcome = "succeeded" | "failed" | "cancelled" | "uncertain"
type Kind = "observation" | "message" | "action.admitted" | "attempt.prepared" | "attempt.started" | "turn.request" | "turn.end" | "receipt" | "delivery.mark" | "request.answered" | "approval.request" | "approval.transition"
type Ref = {thread_id: string, record_id: string}
type Fault = {code: string, message: string, retryable: boolean}
type Usage = {
    input_tokens: integer?,
    output_tokens: integer?,
    cached_tokens: integer?,
    cost_decimal: string?,
    currency: string?,
}
type Content = {text: string?, artifact_ref: string?}
type SessionPhase = "started" | "resumed" | "ended"
type SessionState = {type: "session.state", state: SessionPhase, resume_ref: string?}
type SignalPhase = "submitted" | "started" | "ended"
type TurnSignal = {type: "turn.signal", phase: SignalPhase, reported_outcome: Outcome?, usage: Usage?}
type TextOperation = "append" | "replace" | "complete"
type TextChannel = "answer" | "progress" | "reasoning_summary"
type Text = {type: "text", segment_id: string, operation: TextOperation, text: string, channel: TextChannel}
type ToolCall = {type: "tool.call", call_id: string, tool_name: string, input: Content}
type ToolResult = {type: "tool.result", call_id: string, outcome: Outcome, output: Content, error: Fault?}
type NoticeLevel = "info" | "warning" | "error"
type Notice = {type: "notice", level: NoticeLevel, code: string, content: Content}
type ExecutionExit = {type: "execution.exit", exit_code: integer?, signal: string?}
type Extension = {type: "extension", event_name: string, event_revision: string, payload_json: string}
type ObservationData = SessionState | TurnSignal | Text | ToolCall | ToolResult | Notice | ExecutionExit | Extension
type Observation = {
    type: string,
    event_key: string,
    observed_at: string?,
    external_id: string?,
    data: ObservationData,
    raw_ref: string?,
}
type MessageKind = "request" | "progress" | "reply" | "notification"
type Message = {
    message_id: string,
    message_kind: MessageKind,
    sender_id: string,
    recipient_ids: {string},
    content: Content,
    in_reply_to: Ref?,
    outcome: Outcome?,
}
type Admitted = {
    request_id: string,
    principal_id: string,
    binding_ref: string,
    binding_digest: string,
    grant_refs: {string},
    budget_ref: string,
    input: Content,
}
type ExecutionKind = "process" | "runner"
-- The pinned execution plan of an attempt before anything external exists.
type Prepared = {
    binding_ref: string,
    binding_digest: string,
    profile_id: string,
    profile_digest: string,
    placement_binding: string,
    placement_binding_digest: string?,
    placement_attempt_id: string,
    plan_digest: string,
}
type Started = {execution_kind: ExecutionKind, execution_ref: string, owner_epoch: integer}
type TurnRequest = {input_message_ids: {string}, input: Content, resume_ref: string?, delivery_ids: {string}}
type TurnEnd = {outcome: Outcome, answer_message_ids: {string}, evidence_refs: {string}, usage: Usage?, error: Fault?}
type ReceiptScope = "attempt" | "action"
type Receipt = {scope: ReceiptScope, outcome: Outcome, evidence_refs: {string}, error: Fault?}
type DeliveryState = "claimed" | "delivered" | "released" | "uncertain"
type DeliveryMark = {
    delivery_id: string,
    message_id: string,
    recipient_id: string,
    state: DeliveryState,
    owner_epoch: integer,
    channel: string,
    evidence_ref: string?,
}
type Answered = {request_message_id: string, recipient_id: string, reply_message_id: string, outcome: Outcome}
-- Approval records are projections of the owner-scoped approval store;
-- they never commit a decision here.
type ApprovalKind = "permission" | "question"
type ApprovalState = "approved" | "denied" | "expired" | "cancelled"
type ApprovalRequest = {
    approval_id: string,
    request_kind: ApprovalKind,
    requester_id: string,
    operation_ref: string?,
    prompt: Content,
    response_schema: {[string]: unknown},
    expires_at: string,
    state: "pending",
}
type ApprovalTransition = {
    approval_id: string,
    expected_revision: integer,
    state: ApprovalState,
    decider_id: string?,
    response: Content?,
    reason: string,
}
type Body = Observation | Message | Admitted | Prepared | Started | TurnRequest | TurnEnd | Receipt | DeliveryMark | Answered | ApprovalRequest | ApprovalTransition
type Record = {
    schema_revision: string,
    record_id: string,
    thread_id: string,
    sequence: integer,
    recorded_at: string,
    kind: Kind,
    producer_id: string,
    source: Source,
    causation: Ref?,
    correlation_id: string?,
    action_id: string?,
    attempt_id: string?,
    turn_id: string?,
    body: Body,
}
local M = {}
return M
