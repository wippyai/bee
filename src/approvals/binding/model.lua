-- MIT. Model for the approvals authority.
local sql = require("sql")
local funcs = require("funcs")
local transaction = require("transaction")
local windows = require("windows")
local M = {}
M.LABEL = "approval"
M.REQUEST = "bee.approvals.request"
M.DECIDE = "bee.approvals.decide"
M.MANAGE = "bee.approvals.manage"
M.OWN = "bee.approvals.own"
M.CONSUME = "bee.approvals.consume"
M.WORKER_NAME = "bee.approvals.outbox"
M.AUTHORITY_NAME = "bee.approvals.authority"
M.THREAD_GET = "bee.threads.binding:get"
M.THREAD_READ = "bee.threads.binding:read_after"
M.BINDING_PAGES = 4
M.TOPIC_WAKE = "bee.approvals.wake"
M.ATTENTION = "bee.attention"
M.DEFAULT_TTL_MS = 600000
M.MAX_PENDING = 32
M.MAX_INBOX = 64
M.MAX_LIST = 64
M.MAX_BATCH = 16
M.MAX_PROPOSAL_BYTES = 8192
M.MAX_SCHEMA_BYTES = 4096
M.EXPIRE_BOUND = 64
M.RETENTION_MS = 604800000
M.REQUEST_KINDS = {"permission", "question"}
M.DECISIONS = {"allow_once", "allow_grant", "deny", "answer", "approved", "denied"}
M.PROPOSAL_KINDS = {"operation", "attempt"}
M.STATES = {"pending", "decided", "expired", "withdrawn", "superseded", "invalidated"}
type Fault = {code: string, message: string}
type Reply = {ok: boolean, error: Fault?, value: unknown, replayed: boolean}
type Result = transaction.Result
type Object = {[string]: unknown}
type RequestKind = "permission" | "question"
type ApprovalState = "pending" | "decided" | "expired" | "withdrawn" | "superseded" | "invalidated"
type Decision = "approved" | "denied"
type Row = {contract_version: integer, contract: Object, reviewed_digest: string, effect_admission_ms: integer?, effect: Object, lifecycle_records: Object, window_grant: windows.Grant?, allowed_by_grant: string?, window_max_ttl_ms: integer, reallow: boolean,
    approval_id: string, owner_node: string, owner_incarnation: integer, workspace_id: string,
    requester_id: string, requester_key: string, request_digest: string, request_kind: RequestKind,
    policy: string, proposal_json: string, proposal: Object, proposal_digest: string,
    prompt_json: string, prompt: Object, response_schema_json: string, response_schema: Object,
    thread_id: string?, binding_json: string?, binding: Object?, revision: integer,
    state: ApprovalState, decision: Decision?, decider_id: string?, decided_at: string?,
    response_json: string?, response: unknown, validated_incarnation: integer?, validated_by: string?,
    validated_at: string?, consumer_id: string?, consumed_effect: string?, consumed_at: string?,
    expires_ms: integer, expires_at: string, created_at: string, updated_at: string?,
    effect_completed_at: string?, effect_result_json: string?, effect_result: unknown,
}
type ApprovalView = {request_digest: string, contract_version: integer, contract: Object, reviewed_digest: string, effect_admission_ms: integer?, effect: Object, lifecycle_records: Object, window_grant: windows.Grant?, allowed_by_grant: string?, window_max_ttl_ms: integer, reallow: boolean, requesting_session: string?,
    approval_id: string, owner_node: string, owner_incarnation: integer, workspace_id: string,
    requester_id: string, request_kind: RequestKind, policy: string, proposal: Object,
    proposal_digest: string, prompt: Object, response_schema: Object, thread_id: string?,
    binding: Object?, revision: integer, state: ApprovalState, decision: Decision?, decider_id: string?,
    decided_at: string?, response: unknown, validated_incarnation: integer?, validated_by: string?,
    validated_at: string?, consumer_id: string?, consumed_effect: string?, consumed_at: string?,
    effect_completed_at: string?, effect_result: unknown, expires_at: string, created_at: string,
    updated_at: string?,
}
type Operation = (sql.Transaction, string, Object, integer, Object?) -> Result
type Preparation = (funcs.Executor, string, Object) -> (Object?, Result?)
return M
