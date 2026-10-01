-- MIT. Typed values and strict decoders for the bee.sessions owner contracts.
-- Every decoder accepts exactly the closed shapes of the owner schemas and
-- returns the typed value or a description of the first violation.
local bounds = require("bounds")
local budget_values = require("budget_values")
local profile_values = require("profile_values")
local canonical = require("canonical")
local record_values = require("record_values")
local record_types = require("record_types")
local M = {}

M.MAX_TEXT_BYTES = 16384
M.MAX_REF_BYTES = 256
M.MAX_KEY_BYTES = 128
M.MAX_CURSOR_BYTES = 2048
M.MAX_TITLE_BYTES = 512
M.MAX_CODE_BYTES = 128
M.MAX_VALUE_BYTES = 65536
M.MAX_VALUE_DEPTH = 16
M.MAX_ITEMS = 64
M.MAX_TIMEOUT_MS = 60000
M.DEFAULT_TIMEOUT_MS = 30000

type Retry = "never" | "same_key" | "refresh" | "reconcile"
type Evidence = {summary: string, artifacts: {string}}
type Placement = profile_values.Placement
type Budget = budget_values.Budget
type Budgets = budget_values.Budgets
type Supervision = budget_values.Supervision
type Sender = {kind: "session" | "principal", id: string}
type FaultExtra = {operation: string?, current_revision: integer?, evidence: Evidence?, retry_after_ms: integer?}
type Fault = {code: string, message: string, retry: Retry, operation_key: string?, operation: string?,
    current_revision: integer?, evidence: Evidence?, retry_after_ms: integer?}
type Action = {operation: string, label: string}
type BlockerKind = "budget" | "authority" | "capacity" | "recovery" | "stalled"
type Blocker = {kind: BlockerKind, message: string, subject: string, actions: {Action}}
type Succeeded = {outcome: "succeeded", schema: string, value: unknown, artifacts: {string}, usage: record_types.Usage}
type Unsuccessful = {outcome: "failed" | "cancelled" | "rejected", error: Fault, artifacts: {string}}
type BudgetExceeded = {outcome: "budget_exceeded", error: Fault, artifacts: {string}, evidence: Evidence}
type Result = Succeeded | Unsuccessful | BudgetExceeded
type WorkReceipt = {work: string, session: string, operation: string, committed_at: string, sequence: integer,
    kind: "request", state: "queued", output_schema: string, sender: Sender}
type WorkPhase = "queued" | "reserved" | "accepted"
type WorkState = {work: string, session: string, sender: Sender, revision: integer, cancelling: boolean,
    blocker: Blocker?, uncertainty: Evidence?, phase: WorkPhase, result: nil}
    | {work: string, session: string, sender: Sender, revision: integer, cancelling: false, phase: "settled", result: Result}
type ControlReceipt = {operation: string, subject: string, state: "requested",
    effect: "cancel" | "close"}
type Cleanup = "complete" | "pending" | "uncertain"
type ControlResult = {effect: "cancel", state: "stopped" | "already_terminal", work: string, evidence: Evidence}
    | {effect: "close", state: "closed", session: string, cleanup: Cleanup}
type OperationResult = {kind: "receipt", value: OperationReceipt} | {kind: "control", value: ControlResult} | {kind: "result", result: Result}

type Ready<K, R> = {subject_kind: K, subject: string, cursor: string, tag: "ready", result: R}
type Pending<K> = {subject_kind: K, subject: string, cursor: string, tag: "pending", reason: "timeout"}
type Blocked<K> = {subject_kind: K, subject: string, cursor: string, tag: "blocked", blocker: Blocker}
type Uncertain<K> = {subject_kind: K, subject: string, cursor: string, tag: "uncertain", evidence: Evidence}
type Await<K, R> = Ready<K, R> | Pending<K> | Blocked<K> | Uncertain<K>
type WorkAwait = Await<"work", Result>
type OperationAwait = Await<"operation", OperationResult>
type AnyAwait = WorkAwait | OperationAwait

type JoinResult = {succeeded: boolean, winners: {string}, values: {unknown}?}
type JoinAwait = {subject_kind: "join", subject: string, cursor: string, tag: "ready", children: {WorkAwait}, result: JoinResult}
    | {subject_kind: "join", subject: string, cursor: string, tag: "pending", children: {WorkAwait}, reason: "timeout"}
    | {subject_kind: "join", subject: string, cursor: string, tag: "blocked", children: {WorkAwait}, blocker: Blocker}
    | {subject_kind: "join", subject: string, cursor: string, tag: "uncertain", children: {WorkAwait}, evidence: Evidence}

type Limits = budget_values.Budgets
type Continuity = {mode: "exact" | "provider_resume" | "reconstructed" | "fresh", evidence: Evidence?}
type Execution = {state: "absent" | "starting" | "running" | "quiescent" | "unknown", evidence_at: string, stale: boolean}
type Lifecycle = "opening" | "active" | "suspended" | "closing" | "closed"
type Activity = "idle" | "working" | "blocked" | "stalled"
type ActivityEvidence = {kind: "quiet", turn: string, last_progress_at_ms: integer, quiet_period_ms: integer, quiet_for_ms: integer}
type LastOutcome = "succeeded" | "failed" | "cancelled" | "rejected" | "budget_exceeded"
type LastResult = {work: string, outcome: LastOutcome, summary: string, at: string}
type HistoryItem = {work: string, sequence: integer, input: unknown, created_at: string}
type HistoryPage = {items: {HistoryItem}, next: integer?}
type Presentation = "headless" | "window"
type SessionSnapshot = {effective_profile: profile_values.Profile?, profile_digest: string?,
    budget_consumption: {provider_steps: integer, tool_calls: integer, tokens: integer, wall_time_ms: integer}?, presentation: Presentation?, thread_ref: string?, workspace: string?, driver: string?, provider: string?, definition: string?, last_result: LastResult?, session: string, revision: integer, incarnation: integer, title: string, lifecycle: Lifecycle,
    activity: Activity, activity_evidence: ActivityEvidence?, execution: Execution, queue_count: integer, effective_limits: Limits, continuity: Continuity, actions: {Action}}
type OpenReceipt = {session: string, operation: string, snapshot: SessionSnapshot}
type OperationReceipt = OpenReceipt | WorkReceipt | ControlReceipt
type OperationState = {operation: string, operation_key: string, revision: integer, receipt: OperationReceipt, observation: OperationAwait}
type GetValue = {kind: "session", value: SessionSnapshot} | {kind: "work", value: WorkState}
    | {kind: "operation", value: OperationState}
type ListPage = {items: {SessionSnapshot}, next: string?}
type CandidateKind = "definition" | "profile"
type Candidate = {ref: string, kind: CandidateKind, revision: integer?, title: string,
    status: "ready" | "missing" | "unconfigured" | "incompatible" | "unknown", checked_at: string,
    reasons: {string}, features: {string}, actions: {Action}}
type CatalogPage = {items: {Candidate}, next: string?, complete: boolean, unavailable_count: integer, diagnostics: {Fault}}

local fault_metatable = {__tostring = function(value: unknown): string
    local fault = value
    return tostring(fault.code or "FAULT") .. ": " .. tostring(fault.message or "session operation failed")
end}

function M.fault(code: string, message: string, retry: Retry, operation_key: string?, extra: FaultExtra?): Fault
    local value: {[string]: unknown} = {code = code, message = message, retry = retry, operation_key = operation_key}
    if extra then
        value.operation = extra.operation
        value.current_revision = extra.current_revision
        value.evidence = extra.evidence
        value.retry_after_ms = extra.retry_after_ms
    end
    return setmetatable(value, fault_metatable)
end

M.PREFIX = {session = "bs", work = "bw", operation = "bo", join = "bj"}
type RefKind = "session" | "work" | "operation" | "join"

function M.ref(kind: RefKind, value: unknown): string?
    if type(value) ~= "string" or #value > M.MAX_REF_BYTES then return nil end
    local prefix = M.PREFIX[kind]
    if not value:match("^" .. prefix .. ":[^:]+:[^:]+:[^:]+$") or value:find("%c") then return nil end
    return value
end

function M.any_ref(value: unknown): string?
    if type(value) ~= "string" or #value == 0 or #value > M.MAX_REF_BYTES or value:find("%c") then return nil end
    return value
end

function M.subject_kind(ref: string): "work" | "operation" | nil
    if M.ref("work", ref) then return "work" end
    if M.ref("operation", ref) then return "operation" end
    return nil
end

function M.key(value: unknown): string?
    if type(value) ~= "string" or #value == 0 or #value > M.MAX_KEY_BYTES or value:find("%c") then return nil end
    return value
end

function M.cursor(value: unknown): string?
    if type(value) ~= "string" or #value == 0 or #value > M.MAX_CURSOR_BYTES then return nil end
    return value
end

function M.position(value: unknown): integer?
    local number = bounds.integer(value)
    if not number or number < 1 then return nil end
    return number
end

-- A JSON value the owner admits inline: bounded bytes and depth.
function M.json(value: unknown): boolean
    if value == nil then return false end
    local encoded = canonical.encode(value, M.MAX_VALUE_BYTES, M.MAX_VALUE_DEPTH)
    return encoded ~= nil
end

M.decode_placement = profile_values.placement
M.decode_budgets = budget_values.budgets
M.decode_supervision = budget_values.supervision
function M.decode_budget(value: unknown): (Budget?, string?)
    return budget_values.decode(value)
end

local function refs(value: unknown, kind: RefKind?): {string}?
    local rows = bounds.array(value, M.MAX_ITEMS)
    if not rows then return nil end
    local result: {string} = {}
    for index, raw in ipairs(rows) do
        local item = kind and M.ref(kind, raw) or M.any_ref(raw)
        if not item then return nil end
        result[index] = item
    end
    return result
end

local function texts(value: unknown): {string}?
    local rows = bounds.array(value, M.MAX_ITEMS)
    if not rows then return nil end
    local result: {string} = {}
    for index, raw in ipairs(rows) do
        local item = bounds.text(raw, M.MAX_TEXT_BYTES)
        if not item then return nil end
        result[index] = item
    end
    return result
end

local function one_of(value: unknown, allowed: {string}): string?
    if type(value) ~= "string" then return nil end
    for _, item in ipairs(allowed) do if item == value then return value end end
    return nil
end

local function shape(value: unknown, name: string, allowed: {string}): ({[string]: unknown}?, string?)
    local object = bounds.object(value)
    if not object then return nil, name .. " must be an object" end
    local unknown = bounds.fields(object, allowed)
    if unknown then return nil, name .. ": " .. unknown end
    return object, nil
end

local function decode_sender(value: unknown): (Sender?, string?)
    local object, failure = shape(value, "sender", {"kind", "id"})
    if not object then return nil, failure end
    local kind = one_of(object.kind, {"session", "principal"})
    local id = M.any_ref(object.id)
    if not kind or not id then return nil, "sender is malformed" end
    local sender_kind: "session" | "principal"
    if object.kind == "session" then sender_kind = "session"
    elseif object.kind == "principal" then sender_kind = "principal"
    else return nil, "sender is malformed" end
    return {kind = sender_kind, id = id}, nil
end


function M.decode_evidence(value: unknown): (Evidence?, string?)
    local object, failure = shape(value, "evidence", {"summary", "artifacts"})
    if not object then return nil, failure end
    local summary, artifacts = bounds.text(object.summary, M.MAX_TEXT_BYTES), refs(object.artifacts)
    if not summary or not artifacts then return nil, "evidence is malformed" end
    return {summary = summary, artifacts = artifacts}, nil
end

function M.decode_fault(value: unknown): (Fault?, string?)
    local object, failure = shape(value, "fault", {"code", "message", "retry", "operation_key", "operation",
        "current_revision", "evidence", "retry_after_ms"})
    if not object then return nil, failure end
    local code = bounds.line(object.code, M.MAX_CODE_BYTES)
    local message = bounds.text(object.message, M.MAX_TEXT_BYTES)
    local retry = one_of(object.retry, {"never", "same_key", "refresh", "reconcile"})
    if not code or not message or not retry then return nil, "fault is malformed" end
    local operation_key: string? = nil
    if object.operation_key ~= nil then
        operation_key = M.key(object.operation_key)
        if not operation_key then return nil, "fault operation_key is invalid" end
    end
    local operation: string? = nil
    if object.operation ~= nil then
        operation = M.ref("operation", object.operation)
        if not operation then return nil, "fault operation is invalid" end
    end
    local revision: integer? = nil
    if object.current_revision ~= nil then
        revision = M.position(object.current_revision)
        if not revision then return nil, "fault current_revision is invalid" end
    end
    local evidence: Evidence? = nil
    if object.evidence ~= nil then
        local decoded, evidence_error = M.decode_evidence(object.evidence)
        if not decoded then return nil, evidence_error end
        evidence = decoded
    end
    local retry_after: integer? = nil
    if object.retry_after_ms ~= nil then
        retry_after = bounds.count(object.retry_after_ms)
        if not retry_after then return nil, "fault retry_after_ms is invalid" end
    end
    local decoded_retry: Retry = "never"
    if retry == "same_key" then decoded_retry = "same_key" elseif retry == "refresh" then decoded_retry = "refresh"
    elseif retry == "reconcile" then decoded_retry = "reconcile" end
    return M.fault(code, message, decoded_retry, operation_key,
        {operation = operation, current_revision = revision, evidence = evidence, retry_after_ms = retry_after}), nil
end

local function decode_actions(value: unknown): {Action}?
    local rows = bounds.array(value, M.MAX_ITEMS)
    if not rows then return nil end
    local result: {Action} = {}
    for index, raw in ipairs(rows) do
        local object = shape(raw, "action", {"operation", "label"})
        if not object then return nil end
        local operation, label = M.any_ref(object.operation), bounds.text(object.label, M.MAX_TEXT_BYTES)
        if not operation or not label then return nil end
        result[index] = {operation = operation, label = label}
    end
    return result
end

function M.decode_blocker(value: unknown): (Blocker?, string?)
    local object, failure = shape(value, "blocker", {"kind", "message", "subject", "actions"})
    if not object then return nil, failure end
    local kind = one_of(object.kind, {"budget", "authority", "capacity", "recovery", "stalled"})
    local message, subject = bounds.text(object.message, M.MAX_TEXT_BYTES), M.any_ref(object.subject)
    local actions = decode_actions(object.actions)
    if not kind or not message or not subject or not actions then return nil, "blocker is malformed" end
    local decoded: BlockerKind = "budget"
    if kind == "authority" then decoded = "authority" elseif kind == "capacity" then decoded = "capacity"
    elseif kind == "recovery" then decoded = "recovery" elseif kind == "stalled" then decoded = "stalled" end
    return {kind = decoded, message = message, subject = subject, actions = actions}, nil
end

function M.decode_result(value: unknown): (Result?, string?)
    local object = bounds.object(value)
    if not object then return nil, "result must be an object" end
    if object.outcome == "succeeded" then
        local checked, failure = shape(object, "result", {"outcome", "schema", "value", "artifacts", "usage"})
        if not checked then return nil, failure end
        local schema, artifacts, usage = M.any_ref(checked.schema), refs(checked.artifacts), record_values.usage(checked.usage)
        if not schema or not artifacts or not usage or not M.json(checked.value) then return nil, "succeeded result is malformed" end
        return {outcome = "succeeded", schema = schema, value = checked.value, artifacts = artifacts, usage = usage}, nil
    end
    if object.outcome == "budget_exceeded" then
        local checked, failure = shape(object, "budget result", {"outcome", "error", "artifacts", "evidence"})
        if not checked then return nil, failure end
        local fault, fault_error = M.decode_fault(checked.error)
        local artifacts = refs(checked.artifacts)
        local evidence, evidence_error = M.decode_evidence(checked.evidence)
        if not fault or fault.code ~= "BUDGET_EXCEEDED" or not artifacts or not evidence then
            return nil, fault_error or evidence_error or "budget result is malformed"
        end
        return {outcome = "budget_exceeded", error = fault, artifacts = artifacts, evidence = evidence}, nil
    end
    local checked, failure = shape(object, "result", {"outcome", "error", "artifacts"})
    if not checked then return nil, failure end
    local outcome = one_of(checked.outcome, {"failed", "cancelled", "rejected"})
    local fault, fault_error = M.decode_fault(checked.error)
    local artifacts = refs(checked.artifacts)
    if not outcome or not artifacts then return nil, "result outcome is invalid" end
    if not fault then return nil, fault_error end
    local decoded: "failed" | "cancelled" | "rejected" = "failed"
    if outcome == "cancelled" then decoded = "cancelled"
    elseif outcome == "rejected" then decoded = "rejected" end
    return {outcome = decoded, error = fault, artifacts = artifacts}, nil
end

function M.decode_work_receipt(value: unknown): (WorkReceipt?, string?)
    local object, failure = shape(value, "work receipt", {"work", "session", "operation", "committed_at", "sequence",
        "kind", "state", "output_schema", "sender"})
    if not object then return nil, failure end
    local sender, sender_error = decode_sender(object.sender)
    if not sender then return nil, sender_error end
    local work, session, operation = M.ref("work", object.work), M.ref("session", object.session), M.ref("operation", object.operation)
    local committed, sequence = bounds.timestamp(object.committed_at), M.position(object.sequence)
    local schema = M.any_ref(object.output_schema)
    if not work or not session or not operation or not committed or not sequence or not schema
        or object.kind ~= "request" or object.state ~= "queued" then return nil, "work receipt is malformed" end
    return {work = work, session = session, operation = operation, committed_at = committed, sequence = sequence,
        kind = "request", state = "queued", output_schema = schema, sender = sender}, nil
end

function M.decode_work_state(value: unknown): (WorkState?, string?)
    local object, failure = shape(value, "work state", {"work", "session", "sender", "revision", "phase", "cancelling",
        "blocker", "uncertainty", "result"})
    if not object then return nil, failure end
    local work, session, revision = M.ref("work", object.work), M.ref("session", object.session), M.position(object.revision)
    local phase = one_of(object.phase, {"queued", "reserved", "accepted", "settled"})
    local sender, sender_error = decode_sender(object.sender)
    if not work or not session or not sender or not revision or not phase or type(object.cancelling) ~= "boolean" then
        return nil, sender_error or "work state is malformed"
    end
    if phase == "settled" then
        if object.cancelling ~= false or object.blocker ~= nil or object.uncertainty ~= nil or object.result == nil then
            return nil, "settled work state is malformed"
        end
        local result, result_error = M.decode_result(object.result)
        if not result then return nil, result_error end
        return {work = work, session = session, sender = sender, revision = revision, cancelling = false, phase = "settled",
            result = result}, nil
    end
    if object.result ~= nil then return nil, "unsettled work state carries a result" end
    local blocker: Blocker? = nil
    if object.blocker ~= nil then
        local decoded, blocker_error = M.decode_blocker(object.blocker)
        if not decoded then return nil, blocker_error end
        blocker = decoded
    end
    local uncertainty: Evidence? = nil
    if object.uncertainty ~= nil then
        local decoded, evidence_error = M.decode_evidence(object.uncertainty)
        if not decoded then return nil, evidence_error end
        uncertainty = decoded
    end
    local decoded_phase: WorkPhase = "queued"
    if phase == "reserved" then decoded_phase = "reserved" elseif phase == "accepted" then decoded_phase = "accepted" end
    return {work = work, session = session, sender = sender, revision = revision, cancelling = object.cancelling == true,
        blocker = blocker, uncertainty = uncertainty, phase = decoded_phase, result = nil}, nil
end

function M.decode_control_receipt(value: unknown): (ControlReceipt?, string?)
    local object, failure = shape(value, "control receipt", {"operation", "subject", "state", "effect"})
    if not object then return nil, failure end
    local operation, subject = M.ref("operation", object.operation), M.any_ref(object.subject)
    local effect = one_of(object.effect, {"cancel", "close"})
    if not operation or not subject or object.state ~= "requested" or not effect then
        return nil, "control receipt is malformed"
    end
    return {operation = operation, subject = subject, state = "requested", effect = effect == "close" and "close" or "cancel"}, nil
end

local function decode_control_result(value: unknown): (ControlResult?, string?)
    local object = bounds.object(value)
    if not object then return nil, "control result must be an object" end
    if object.effect == "cancel" then
        local checked, failure = shape(object, "cancel result", {"effect", "state", "work", "evidence"})
        if not checked then return nil, failure end
        local state = one_of(checked.state, {"stopped", "already_terminal"})
        local work = M.ref("work", checked.work)
        local evidence, evidence_error = M.decode_evidence(checked.evidence)
        if not state or not work then return nil, "cancel result is malformed" end
        if not evidence then return nil, evidence_error end
        return {effect = "cancel", state = state == "stopped" and "stopped" or "already_terminal", work = work,
            evidence = evidence}, nil
    end
    local checked, failure = shape(object, "close result", {"effect", "state", "session", "cleanup"})
    if not checked then return nil, failure end
    local session, cleanup = M.ref("session", checked.session), one_of(checked.cleanup, {"complete", "pending", "uncertain"})
    if checked.effect ~= "close" or checked.state ~= "closed" or not session or not cleanup then
        return nil, "close result is malformed"
    end
    local decoded: Cleanup = "complete"
    if cleanup == "pending" then decoded = "pending" elseif cleanup == "uncertain" then decoded = "uncertain" end
    return {effect = "close", state = "closed", session = session, cleanup = decoded}, nil
end

function M.decode_operation_result(value: unknown): (OperationResult?, string?)
    local object = bounds.object(value)
    if not object then return nil, "operation result must be an object" end
    if object.kind == "receipt" then
        local checked, failure = shape(object, "operation receipt result", {"kind", "value"})
        if not checked then return nil, failure end
        local receipt, receipt_error = M.decode_operation_receipt(checked.value)
        if not receipt then return nil, receipt_error end
        return {kind = "receipt", value = receipt}, nil
    end
    if object.kind == "control" then
        local checked, failure = shape(object, "operation result", {"kind", "value"})
        if not checked then return nil, failure end
        local control, control_error = decode_control_result(checked.value)
        if not control then return nil, control_error end
        return {kind = "control", value = control}, nil
    end
    local checked, failure = shape(object, "operation result", {"kind", "result"})
    if not checked then return nil, failure end
    if checked.kind ~= "result" then return nil, "operation result kind is invalid" end
    local result, result_error = M.decode_result(checked.result)
    if not result then return nil, result_error end
    return {kind = "result", result = result}, nil
end

local ENVELOPE = {"subject_kind", "subject", "cursor", "tag", "result", "reason", "blocker", "evidence"}

-- Exactly one branch: ready/result, pending/reason, blocked/blocker, uncertain/evidence.
local function branch(object: {[string]: unknown}): (string?, string?)
    local tag = one_of(object.tag, {"ready", "pending", "blocked", "uncertain"})
    if not tag then return nil, "await tag is invalid" end
    local carried = {ready = "result", pending = "reason", blocked = "blocker", uncertain = "evidence"}
    for _, name in ipairs({"result", "reason", "blocker", "evidence"}) do
        if (carried[tag] == name) ~= (object[name] ~= nil) then return nil, "await " .. tag .. " carries the wrong branch fields" end
    end
    if tag == "pending" and object.reason ~= "timeout" then return nil, "await pending reason is invalid" end
    return tag, nil
end

function M.decode_work_await(value: unknown): (WorkAwait?, string?)
    local object, failure = shape(value, "await", ENVELOPE)
    if not object then return nil, failure end
    local tag, tag_error = branch(object)
    local subject, cursor = M.ref("work", object.subject), M.cursor(object.cursor)
    if not tag then return nil, tag_error end
    if object.subject_kind ~= "work" or not subject or not cursor then return nil, "work await is malformed" end
    if tag == "ready" then
        local result, result_error = M.decode_result(object.result)
        if not result then return nil, result_error end
        return {subject_kind = "work", subject = subject, cursor = cursor, tag = "ready", result = result}, nil
    elseif tag == "pending" then
        return {subject_kind = "work", subject = subject, cursor = cursor, tag = "pending", reason = "timeout"}, nil
    elseif tag == "blocked" then
        local blocker, blocker_error = M.decode_blocker(object.blocker)
        if not blocker then return nil, blocker_error end
        return {subject_kind = "work", subject = subject, cursor = cursor, tag = "blocked", blocker = blocker}, nil
    end
    local evidence, evidence_error = M.decode_evidence(object.evidence)
    if not evidence then return nil, evidence_error end
    return {subject_kind = "work", subject = subject, cursor = cursor, tag = "uncertain", evidence = evidence}, nil
end

function M.decode_operation_await(value: unknown): (OperationAwait?, string?)
    local object, failure = shape(value, "await", ENVELOPE)
    if not object then return nil, failure end
    local tag, tag_error = branch(object)
    local subject, cursor = M.ref("operation", object.subject), M.cursor(object.cursor)
    if not tag then return nil, tag_error end
    if object.subject_kind ~= "operation" or not subject or not cursor then return nil, "operation await is malformed" end
    if tag == "ready" then
        local result, result_error = M.decode_operation_result(object.result)
        if not result then return nil, result_error end
        return {subject_kind = "operation", subject = subject, cursor = cursor, tag = "ready", result = result}, nil
    elseif tag == "pending" then
        return {subject_kind = "operation", subject = subject, cursor = cursor, tag = "pending", reason = "timeout"}, nil
    elseif tag == "blocked" then
        local blocker, blocker_error = M.decode_blocker(object.blocker)
        if not blocker then return nil, blocker_error end
        return {subject_kind = "operation", subject = subject, cursor = cursor, tag = "blocked", blocker = blocker}, nil
    end
    local evidence, evidence_error = M.decode_evidence(object.evidence)
    if not evidence then return nil, evidence_error end
    return {subject_kind = "operation", subject = subject, cursor = cursor, tag = "uncertain", evidence = evidence}, nil
end

function M.decode_any_await(value: unknown): (AnyAwait?, string?)
    local object = bounds.object(value)
    if not object then return nil, "await must be an object" end
    if object.subject_kind == "work" then return M.decode_work_await(value) end
    if object.subject_kind == "operation" then return M.decode_operation_await(value) end
    return nil, "await subject_kind is invalid"
end

local function decode_join_result(value: unknown): (JoinResult?, string?)
    local object, failure = shape(value, "join result", {"succeeded", "winners", "values"})
    if not object then return nil, failure end
    local winners = refs(object.winners, "work")
    if type(object.succeeded) ~= "boolean" or not winners then return nil, "join result is malformed" end
    if object.succeeded ~= (object.values ~= nil) then return nil, "join values exist exactly when the join succeeded" end
    if object.succeeded and #winners < 1 then return nil, "a succeeded join has a winner" end
    local values: {unknown}? = nil
    if object.values ~= nil then
        local rows = bounds.array(object.values, M.MAX_ITEMS)
        if not rows then return nil, "join values are malformed" end
        for _, item in ipairs(rows) do if not M.json(item) then return nil, "join value is not a bounded JSON value" end end
        values = rows
    end
    return {succeeded = object.succeeded, winners = winners, values = values}, nil
end

function M.decode_join_await(value: unknown): (JoinAwait?, string?)
    local object, failure = shape(value, "join await", {"subject_kind", "subject", "cursor", "tag", "children",
        "result", "reason", "blocker", "evidence"})
    if not object then return nil, failure end
    local tag, tag_error = branch(object)
    local subject, cursor = M.ref("join", object.subject), M.cursor(object.cursor)
    if not tag then return nil, tag_error end
    local rows = bounds.array(object.children, M.MAX_ITEMS)
    if object.subject_kind ~= "join" or not subject or not cursor or not rows or #rows < 1 then
        return nil, "join await is malformed"
    end
    local children: {WorkAwait} = {}
    for index, raw in ipairs(rows) do
        local child, child_error = M.decode_work_await(raw)
        if not child then return nil, "join child " .. tostring(index) .. ": " .. tostring(child_error) end
        children[index] = child
    end
    if tag == "ready" then
        local result, result_error = decode_join_result(object.result)
        if not result then return nil, result_error end
        return {subject_kind = "join", subject = subject, cursor = cursor, tag = "ready", children = children, result = result}, nil
    elseif tag == "pending" then
        return {subject_kind = "join", subject = subject, cursor = cursor, tag = "pending", children = children, reason = "timeout"}, nil
    elseif tag == "blocked" then
        local blocker, blocker_error = M.decode_blocker(object.blocker)
        if not blocker then return nil, blocker_error end
        return {subject_kind = "join", subject = subject, cursor = cursor, tag = "blocked", children = children, blocker = blocker}, nil
    end
    local evidence, evidence_error = M.decode_evidence(object.evidence)
    if not evidence then return nil, evidence_error end
    return {subject_kind = "join", subject = subject, cursor = cursor, tag = "uncertain", children = children, evidence = evidence}, nil
end

local function decode_limits(value: unknown): Limits?
    local object = bounds.object(value)
    if not object then return nil end
    if next(object) == nil then return {} end
    return budget_values.budgets(object)
end

function M.decode_snapshot(value: unknown): (SessionSnapshot?, string?)
    local object, failure = shape(value, "session snapshot", {"session", "revision", "incarnation", "title", "lifecycle",
        "activity", "activity_evidence", "execution", "queue_count", "effective_limits", "continuity", "actions", "thread_ref", "workspace", "driver", "provider", "definition", "last_result", "presentation", "effective_profile", "profile_digest", "budget_consumption"})
    if not object then return nil, failure end
    local presentation: Presentation = "headless"
    if object.presentation == "window" then presentation = "window"
    elseif object.presentation ~= nil and object.presentation ~= "headless" then return nil, "session presentation is invalid" end
    local extras: {[string]: string} = {}
    for _, name in ipairs({"thread_ref", "workspace", "driver", "provider", "definition"}) do
        if object[name] ~= nil then
            local value = bounds.id(object[name])
            if not value then return nil, "session " .. name .. " is invalid" end
            extras[name] = value
        end
    end
    local last_result: LastResult? = nil
    if object.last_result ~= nil then
        local last = shape(object.last_result, "last result", {"work", "outcome", "summary", "at"})
        local work = last and M.ref("work", last.work)
        local selected_outcome = last and one_of(last.outcome, {"succeeded", "failed", "cancelled", "rejected", "budget_exceeded"})
        local outcome: LastOutcome? = nil
        if selected_outcome == "succeeded" then outcome = "succeeded"
        elseif selected_outcome == "failed" then outcome = "failed"
        elseif selected_outcome == "cancelled" then outcome = "cancelled"
        elseif selected_outcome == "rejected" then outcome = "rejected"
        elseif selected_outcome == "budget_exceeded" then outcome = "budget_exceeded" end
        local summary = last and bounds.text(last.summary, 4096)
        local at = last and bounds.timestamp(last.at)
        if not work or not outcome or not summary or not at then return nil, "last result is malformed" end
        last_result = {work = work, outcome = outcome, summary = summary, at = at}
    end
    local session, revision, incarnation = M.ref("session", object.session), M.position(object.revision), M.position(object.incarnation)
    local title = bounds.text(object.title, M.MAX_TITLE_BYTES)
    local lifecycle = one_of(object.lifecycle, {"opening", "active", "suspended", "closing", "closed"})
    local activity = one_of(object.activity, {"idle", "working", "blocked", "stalled"})
    local activity_evidence: ActivityEvidence? = nil
    if object.activity_evidence ~= nil then
        local quiet = shape(object.activity_evidence, "activity evidence", {"kind", "turn", "last_progress_at_ms", "quiet_period_ms", "quiet_for_ms"})
        local turn = quiet and M.any_ref(quiet.turn)
        local last = quiet and bounds.count(quiet.last_progress_at_ms)
        local quiet_period = quiet and M.position(quiet.quiet_period_ms)
        local quiet_for = quiet and bounds.count(quiet.quiet_for_ms)
        if not quiet or quiet.kind ~= "quiet" or not turn or not last or not quiet_period or not quiet_for or quiet_for < quiet_period then
            return nil, "session activity evidence is malformed"
        end
        activity_evidence = {kind = "quiet", turn = turn, last_progress_at_ms = last,
            quiet_period_ms = quiet_period, quiet_for_ms = quiet_for}
    end
    local queue_count = bounds.count(object.queue_count)
    local limits, actions = decode_limits(object.effective_limits), decode_actions(object.actions)
    if not session or not revision or not incarnation or not title or not lifecycle or not activity
        or not queue_count or not limits or not actions then return nil, "session snapshot is malformed" end
    if (activity == "stalled") ~= (activity_evidence ~= nil) then return nil, "stalled activity must carry quiet-period evidence" end
    local execution_object = shape(object.execution, "execution", {"state", "evidence_at", "stale"})
    if not execution_object then return nil, "session execution is malformed" end
    local state = one_of(execution_object.state, {"absent", "starting", "running", "quiescent", "unknown"})
    local evidence_at = bounds.timestamp(execution_object.evidence_at)
    if not state or not evidence_at or type(execution_object.stale) ~= "boolean" then return nil, "session execution is malformed" end
    local continuity_object = shape(object.continuity, "continuity", {"mode", "evidence"})
    local continuity_mode = continuity_object and one_of(continuity_object.mode, {"exact", "provider_resume", "reconstructed", "fresh"})
    if not continuity_object or not continuity_mode then return nil, "session continuity is malformed" end
    local evidence: Evidence? = nil
    if continuity_object.evidence ~= nil then
        local decoded, evidence_error = M.decode_evidence(continuity_object.evidence)
        if not decoded then return nil, evidence_error end
        evidence = decoded
    end
    local decoded_lifecycle: Lifecycle = "opening"
    if lifecycle == "active" then decoded_lifecycle = "active" elseif lifecycle == "suspended" then decoded_lifecycle = "suspended"
    elseif lifecycle == "closing" then decoded_lifecycle = "closing" elseif lifecycle == "closed" then decoded_lifecycle = "closed" end
    local decoded_activity: Activity = "idle"
    if activity == "working" then decoded_activity = "working" elseif activity == "blocked" then decoded_activity = "blocked"
    elseif activity == "stalled" then decoded_activity = "stalled" end
    local decoded_state: "absent" | "starting" | "running" | "quiescent" | "unknown" = "absent"
    if state == "starting" then decoded_state = "starting" elseif state == "running" then decoded_state = "running"
    elseif state == "quiescent" then decoded_state = "quiescent" elseif state == "unknown" then decoded_state = "unknown" end
    local decoded_continuity: "exact" | "provider_resume" | "reconstructed" | "fresh" = "exact"
    if continuity_mode == "provider_resume" then decoded_continuity = "provider_resume"
    elseif continuity_mode == "reconstructed" then decoded_continuity = "reconstructed"
    elseif continuity_mode == "fresh" then decoded_continuity = "fresh" end
    local profile: profile_values.Profile? = nil
    if object.effective_profile ~= nil then
        local err: string?
        profile, err = profile_values.profile(object.effective_profile)
        if not profile then return nil, err end
    end
    local profile_digest: string? = nil
    if object.profile_digest ~= nil then
        profile_digest = bounds.line(object.profile_digest, 64)
        if not profile_digest or #profile_digest ~= 64 or profile_digest:find("[^0-9a-f]") then return nil, "profile digest is malformed" end
    end
    local consumed: {provider_steps: integer, tool_calls: integer, tokens: integer, wall_time_ms: integer}? = nil
    if object.budget_consumption ~= nil then
        local raw = bounds.object(object.budget_consumption)
        if not raw or bounds.fields(raw, {"provider_steps", "tool_calls", "tokens", "wall_time_ms"}) then return nil, "session consumption is malformed" end
        local steps, tools, tokens, wall = bounds.count(raw.provider_steps), bounds.count(raw.tool_calls), bounds.count(raw.tokens), bounds.count(raw.wall_time_ms)
        if not steps or not tools or not tokens or not wall then return nil, "session consumption is malformed" end
        consumed = {provider_steps = steps, tool_calls = tools, tokens = tokens, wall_time_ms = wall}
    end
    return {effective_profile = profile, profile_digest = profile_digest, budget_consumption = consumed, presentation = presentation, thread_ref = extras.thread_ref, workspace = extras.workspace, driver = extras.driver, provider = extras.provider,
        definition = extras.definition, last_result = last_result,
        session = session, revision = revision, incarnation = incarnation, title = title, lifecycle = decoded_lifecycle,
        activity = decoded_activity, activity_evidence = activity_evidence,
        execution = {state = decoded_state, evidence_at = evidence_at, stale = execution_object.stale == true},
        queue_count = queue_count, effective_limits = limits,
        continuity = {mode = decoded_continuity, evidence = evidence}, actions = actions}, nil
end

function M.decode_history(value: unknown): (HistoryPage?, string?)
    local page = shape(value, "work history", {"items", "next"})
    local rows = page and bounds.array(page.items, 64)
    if not page or not rows then return nil, "work history is malformed" end
    local items: {HistoryItem} = {}
    local previous = 0
    for _, raw in ipairs(rows) do
        local row = shape(raw, "history item", {"work", "sequence", "input", "created_at"})
        local work = row and M.ref("work", row.work)
        local sequence = row and M.position(row.sequence)
        local at = row and bounds.timestamp(row.created_at)
        if not row or not work or not sequence or sequence <= previous or not at or row.input == nil then return nil, "history item is malformed" end
        items[#items + 1] = {work = work, sequence = sequence, input = row.input, created_at = at}
        previous = sequence
    end
    local next_cursor = page.next == nil and nil or M.position(page.next)
    if page.next ~= nil and (not next_cursor or next_cursor ~= previous) then return nil, "history cursor is malformed" end
    return {items = items, next = next_cursor}, nil
end

function M.decode_open_receipt(value: unknown): (OpenReceipt?, string?)
    local object, failure = shape(value, "open receipt", {"session", "operation", "snapshot"})
    if not object then return nil, failure end
    local session, operation = M.ref("session", object.session), M.ref("operation", object.operation)
    local snapshot, snapshot_error = M.decode_snapshot(object.snapshot)
    if not session or not operation then return nil, "open receipt is malformed" end
    if not snapshot then return nil, snapshot_error end
    if snapshot.session ~= session then return nil, "open receipt snapshot names another session" end
    return {session = session, operation = operation, snapshot = snapshot}, nil
end

function M.decode_operation_receipt(value: unknown): (OperationReceipt?, string?)
    local opened, open_error = M.decode_open_receipt(value)
    if opened then return opened, nil end
    local work, work_error = M.decode_work_receipt(value)
    if work then return work, nil end
    local control, control_error = M.decode_control_receipt(value)
    if control then return control, nil end
    return nil, control_error or work_error or open_error
end

function M.decode_operation_state(value: unknown): (OperationState?, string?)
    local object, failure = shape(value, "operation state", {"operation", "operation_key", "revision", "receipt", "observation"})
    if not object then return nil, failure end
    local operation = M.ref("operation", object.operation)
    local operation_key = M.key(object.operation_key)
    local revision = M.position(object.revision)
    local receipt, receipt_error = M.decode_operation_receipt(object.receipt)
    local observation, observation_error = M.decode_operation_await(object.observation)
    if not operation or not operation_key or not revision then return nil, "operation state identity is malformed" end
    if not receipt then return nil, receipt_error end
    if not observation then return nil, observation_error end
    if observation.subject ~= operation then return nil, "operation state observation names another operation" end
    return {operation = operation, operation_key = operation_key, revision = revision, receipt = receipt, observation = observation}, nil
end

function M.decode_get(value: unknown): (GetValue?, string?)
    local object, failure = shape(value, "get value", {"kind", "value"})
    if not object then return nil, failure end
    if object.kind == "session" then
        local snapshot, snapshot_error = M.decode_snapshot(object.value)
        if not snapshot then return nil, snapshot_error end
        return {kind = "session", value = snapshot}, nil
    elseif object.kind == "work" then
        local state, state_error = M.decode_work_state(object.value)
        if not state then return nil, state_error end
        return {kind = "work", value = state}, nil
    elseif object.kind == "operation" then
        local state, state_error = M.decode_operation_state(object.value)
        if not state then return nil, state_error end
        return {kind = "operation", value = state}, nil
    end
    return nil, "get kind is invalid"
end

function M.decode_list_page(value: unknown): (ListPage?, string?)
    local object, failure = shape(value, "list page", {"items", "next"})
    if not object then return nil, failure end
    local rows = bounds.array(object.items, M.MAX_ITEMS)
    if not rows then return nil, "list page is malformed" end
    local items: {SessionSnapshot} = {}
    for index, raw in ipairs(rows) do
        local item, item_error = M.decode_snapshot(raw)
        if not item then return nil, item_error end
        items[index] = item
    end
    local next_cursor: string? = nil
    if object.next ~= nil then
        next_cursor = M.cursor(object.next)
        if not next_cursor then return nil, "list page next is invalid" end
    end
    return {items = items, next = next_cursor}, nil
end

local function decode_candidate(value: unknown): (Candidate?, string?)
    local object, failure = shape(value, "candidate", {"ref", "kind", "revision", "title", "status", "checked_at",
        "reasons", "features", "actions"})
    if not object then return nil, failure end
    local ref = M.any_ref(object.ref)
    local kind = one_of(object.kind, {"definition", "profile"})
    local title = bounds.text(object.title, M.MAX_TITLE_BYTES)
    local status = one_of(object.status, {"ready", "missing", "unconfigured", "incompatible", "unknown"})
    local checked = bounds.timestamp(object.checked_at)
    local reasons, features, actions = texts(object.reasons), refs(object.features), decode_actions(object.actions)
    if not ref or not kind or not title or not status or not checked or not reasons or not features
        or not actions then return nil, "candidate is malformed" end
    local revision: integer? = nil
    if object.revision ~= nil then
        revision = M.position(object.revision)
        if not revision then return nil, "candidate revision is invalid" end
    end
    local decoded_kind: CandidateKind = "definition"
    if kind == "profile" then decoded_kind = "profile" end
    local decoded_status: "ready" | "missing" | "unconfigured" | "incompatible" | "unknown" = "ready"
    if status == "missing" then decoded_status = "missing" elseif status == "unconfigured" then decoded_status = "unconfigured"
    elseif status == "incompatible" then decoded_status = "incompatible" elseif status == "unknown" then decoded_status = "unknown" end
    return {ref = ref, kind = decoded_kind, revision = revision, title = title, status = decoded_status,
        checked_at = checked, reasons = reasons, features = features, actions = actions}, nil
end

function M.decode_catalog_page(value: unknown): (CatalogPage?, string?)
    local object, failure = shape(value, "catalog page", {"items", "next", "complete", "unavailable_count", "diagnostics"})
    if not object then return nil, failure end
    local rows, diagnostics = bounds.array(object.items, M.MAX_ITEMS), bounds.array(object.diagnostics, M.MAX_ITEMS)
    local unavailable = bounds.count(object.unavailable_count)
    if not rows or not diagnostics or not unavailable or type(object.complete) ~= "boolean" then
        return nil, "catalog page is malformed"
    end
    local items: {Candidate} = {}
    for index, raw in ipairs(rows) do
        local item, item_error = decode_candidate(raw)
        if not item then return nil, item_error end
        items[index] = item
    end
    local faults: {Fault} = {}
    for index, raw in ipairs(diagnostics) do
        local fault, fault_error = M.decode_fault(raw)
        if not fault then return nil, fault_error end
        faults[index] = fault
    end
    local next_cursor: string? = nil
    if object.next ~= nil then
        next_cursor = M.cursor(object.next)
        if not next_cursor then return nil, "catalog page next is invalid" end
    end
    return {items = items, next = next_cursor, complete = object.complete, unavailable_count = unavailable,
        diagnostics = faults}, nil
end

-- The closed owner envelope: {ok = true, value} or {ok = false, error}.
type Reply = {ok: true, value: unknown} | {ok: false, error: Fault}
function M.decode_reply(value: unknown): (Reply?, string?)
    local object = bounds.object(value)
    if not object or type(object.ok) ~= "boolean" then return nil, "reply is not an owner envelope" end
    if object.ok then
        local checked, failure = shape(object, "reply", {"ok", "value"})
        if not checked then return nil, failure end
        if checked.value == nil then return nil, "reply carries no value" end
        return {ok = true, value = checked.value}, nil
    end
    local checked, failure = shape(object, "reply", {"ok", "error"})
    if not checked then return nil, failure end
    local fault, fault_error = M.decode_fault(checked.error)
    if not fault then return nil, fault_error end
    return {ok = false, error = fault}, nil
end

return M
