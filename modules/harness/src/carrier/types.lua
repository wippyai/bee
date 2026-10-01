local classify = require("classify")
local driver_types = require("driver_types")
local placement_types = require("placement_types")
local policy = require("policy")
local permission = require("permission")
local checkpoint = require("checkpoint")
local stream_json = require("stream_json")
local settle = require("settle")
local record_types = require("record_types")
local M = {}

type IO = {
    call: (string, unknown) -> (unknown, string?),
    send: (string, string, unknown) -> (),
    self_pid: () -> string,
    now_ms: () -> integer,
    key: () -> string,
    after: ((string) -> ())?,
}
type Request = {
    preferences: placement_types.Preferences?,
    thread_id: string,
    action_id: string,
    attempt_id: string,
    owner_id: string,
    owner_incarnation: integer,
    binding_ref: string,
    profile_id: string,
    brief: string,
    policy_ref: string,
    placement_binding_ref: string?,
    placement_binding_digest: string?,
    resources: {placement_types.ResourceGrant},
    environment: {[string]: string},
    session_ref: string?,
    previous_attempt_id: string?,
    reauthorize: boolean?,
    working_directory: string?,
    projections: {string}?,
    workspace_id: string?,
    parent_action_id: string?,
    origin_view: {view_id: string, instance_id: string}?,
    options: placement_types.WorkdirOptions?,
}
type Exchange = {
    transport: string?,
    answer_mode: string?,
    adapter: permission.Adapter,
    acceptance_ref: string,
    acceptance_digest: string,
    executable_revision: string,
    executable_kind: string,
    executable_digest: string,
    approver_policy: string,
    poll_ms: integer,
    ttl_ms: integer,
}
type Acceptance = {
    adapter: permission.Adapter,
    acceptance_ref: string,
    acceptance_digest: string,
    executable_revision: string,
    executable_kind: string,
    executable_digest: string,
}
type Plan = {
    request: Request,
    binding: classify.Binding,
    profile: classify.Profile,
    launch: driver_types.Launch,
    policy: policy.Policy,
    placement_binding: placement_types.PlacementBinding,
    plan_digest: string,
    placement_request: placement_types.LaunchRequest,
    exit_codes_trustworthy: boolean,
    exchange_refusal: string?,
    prepare_target: string,
    resume_ref: string?,
    normalize_target: string,
    exchange: Exchange?,
    gateway: placement_types.Gateway?,
}
type OutputState = "open" | "complete" | "truncated" | "unobserved" | "incomplete"
type Session = {
    plan: Plan,
    turn_id: string,
    turn_open: boolean,
    epoch: integer,
    revision: integer,
    checkpoint: checkpoint.Checkpoint,
    decoder: stream_json.Decoder,
    normalizer: unknown,
    terminal: driver_types.Terminal?,
    stream_ended: boolean,
    exit: settle.Exit?,
    eof: {stdout: boolean, stderr: boolean},
    runner: string?,
    settled: settle.Settlement?,
    recovered: boolean,
    output: OutputState,
    pending_hint: {page_id: string, scanned_through: integer}?,
    placement_evidence: integer,
    stderr_sequence: integer,
    last_sequence: {stdout: integer, stderr: integer},
    held_from: integer?,
    dropping_stdout: boolean,
}
type Offer = {
    thread_id: string,
    action_id: string,
    record_id: string,
    inbox_sequence: integer,
    payload_digest: string,
    message_id: string,
    message_kind: "request" | "progress" | "reply" | "notification",
    sender_action_id: string,
    sender_thread_id: string,
    sender_node_id: string,
    content: record_types.Content,
    in_reply_to: record_types.Ref?,
    state: "offered" | "transport_accepted",
    dispatch: boolean,
    offer_count: integer,
}

return M
