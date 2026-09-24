-- MIT. The record envelope: family decoding and the canonical encoding used
-- for storage, identity comparison and size limits.
local json = require("json")
local types = require("types")
local bounds = require("bounds")
local values = require("values")
local observation = require("observation")
local message = require("message")
local lifecycle = require("lifecycle")
local delivery = require("delivery")
local approval = require("approval")
local canonical = require("canonical")
local M = {}
type Field = {key: string, json: string}
local function encode_string(value: string): string
    local escaped = value:gsub('[%c"\\]', function(char: string): string
        if char == '"' then return '\\"' end
        if char == "\\" then return "\\\\" end
        return string.format("\\u%04x", char:byte())
    end)
    return '"' .. escaped .. '"'
end
local function encode_strings(list: {string}): string
    local parts: {string} = {}
    for index, item in ipairs(list) do parts[index] = encode_string(item) end
    return "[" .. table.concat(parts, ",") .. "]"
end
local function encode_object(fields: {Field}): string
    table.sort(fields, function(left: Field, right: Field): boolean return left.key < right.key end)
    local parts: {string} = {}
    for index, field in ipairs(fields) do parts[index] = encode_string(field.key) .. ":" .. field.json end
    return "{" .. table.concat(parts, ",") .. "}"
end
local function field(fields: {Field}, key: string, encoded: string?)
    if encoded ~= nil then fields[#fields + 1] = {key = key, json = encoded} end
end
local function optional_string(value: string?): string?
    if value == nil then return nil end
    return encode_string(value)
end
local function optional_integer(value: integer?): string?
    if value == nil then return nil end
    return string.format("%d", value)
end
local function encode_content(content: types.Content): string
    local fields: {Field} = {}
    field(fields, "text", optional_string(content.text))
    field(fields, "artifact_ref", optional_string(content.artifact_ref))
    return encode_object(fields)
end
local function encode_ref(ref: types.Ref?): string?
    if ref == nil then return nil end
    return encode_object({{key = "thread_id", json = encode_string(ref.thread_id)}, {key = "record_id", json = encode_string(ref.record_id)}})
end
local function encode_fault(fault: types.Fault?): string?
    if fault == nil then return nil end
    return encode_object({{key = "code", json = encode_string(fault.code)}, {key = "message", json = encode_string(fault.message)},
        {key = "retryable", json = fault.retryable and "true" or "false"}})
end
local function encode_usage(usage: types.Usage?): string?
    if usage == nil then return nil end
    local fields: {Field} = {}
    field(fields, "input_tokens", optional_integer(usage.input_tokens))
    field(fields, "output_tokens", optional_integer(usage.output_tokens))
    field(fields, "cached_tokens", optional_integer(usage.cached_tokens))
    field(fields, "cost_decimal", optional_string(usage.cost_decimal))
    field(fields, "currency", optional_string(usage.currency))
    return encode_object(fields)
end
local function encode_data(data: types.ObservationData): string
    local fields: {Field} = {{key = "type", json = encode_string(data.type)}}
    if data.type == "session.state" then
        field(fields, "state", encode_string(data.state))
        field(fields, "resume_ref", optional_string(data.resume_ref))
    elseif data.type == "turn.signal" then
        field(fields, "phase", encode_string(data.phase))
        field(fields, "reported_outcome", optional_string(data.reported_outcome))
        field(fields, "usage", encode_usage(data.usage))
    elseif data.type == "text" then
        field(fields, "segment_id", encode_string(data.segment_id))
        field(fields, "operation", encode_string(data.operation))
        field(fields, "text", encode_string(data.text))
        field(fields, "channel", encode_string(data.channel))
    elseif data.type == "tool.call" then
        field(fields, "call_id", encode_string(data.call_id))
        field(fields, "tool_name", encode_string(data.tool_name))
        field(fields, "input", encode_content(data.input))
    elseif data.type == "tool.result" then
        field(fields, "call_id", encode_string(data.call_id))
        field(fields, "outcome", encode_string(data.outcome))
        field(fields, "output", encode_content(data.output))
        field(fields, "error", encode_fault(data.error))
    elseif data.type == "notice" then
        field(fields, "level", encode_string(data.level))
        field(fields, "code", encode_string(data.code))
        field(fields, "content", encode_content(data.content))
    elseif data.type == "execution.exit" then
        field(fields, "exit_code", optional_integer(data.exit_code))
        field(fields, "signal", optional_string(data.signal))
    else
        field(fields, "event_name", encode_string(data.event_name))
        field(fields, "event_revision", encode_string(data.event_revision))
        field(fields, "payload_json", encode_string(data.payload_json))
    end
    return encode_object(fields)
end
local function encode_observation(body: types.Observation): string
    local fields: {Field} = {}
    field(fields, "type", encode_string(body.type))
    field(fields, "event_key", encode_string(body.event_key))
    field(fields, "observed_at", optional_string(body.observed_at))
    field(fields, "external_id", optional_string(body.external_id))
    field(fields, "data", encode_data(body.data))
    field(fields, "raw_ref", optional_string(body.raw_ref))
    return encode_object(fields)
end
local function encode_message(body: types.Message): string
    local fields: {Field} = {}
    field(fields, "message_id", encode_string(body.message_id))
    field(fields, "message_kind", encode_string(body.message_kind))
    field(fields, "sender_id", encode_string(body.sender_id))
    field(fields, "recipient_ids", encode_strings(body.recipient_ids))
    local recipient_actions = body.recipient_action_ids
    if recipient_actions then field(fields, "recipient_action_ids", encode_strings(recipient_actions)) end
    field(fields, "sender_action_id", optional_string(body.sender_action_id))
    field(fields, "content", encode_content(body.content))
    field(fields, "in_reply_to", encode_ref(body.in_reply_to))
    field(fields, "outcome", optional_string(body.outcome))
    return encode_object(fields)
end
local function encode_admitted(body: types.Admitted): string
    local fields: {Field} = {}
    field(fields, "request_id", encode_string(body.request_id))
    field(fields, "principal_id", encode_string(body.principal_id))
    field(fields, "binding_ref", encode_string(body.binding_ref))
    field(fields, "binding_digest", encode_string(body.binding_digest))
    field(fields, "grant_refs", encode_strings(body.grant_refs))
    field(fields, "budget_ref", encode_string(body.budget_ref))
    field(fields, "parent_action_id", optional_string(body.parent_action_id))
    field(fields, "input", encode_content(body.input))
    return encode_object(fields)
end
local function encode_prepared(body: types.Prepared): string
    local fields: {Field} = {{key = "binding_ref", json = encode_string(body.binding_ref)},
        {key = "binding_digest", json = encode_string(body.binding_digest)},
        {key = "profile_id", json = encode_string(body.profile_id)},
        {key = "profile_digest", json = encode_string(body.profile_digest)},
        {key = "placement_binding", json = encode_string(body.placement_binding)},
        {key = "placement_attempt_id", json = encode_string(body.placement_attempt_id)},
        {key = "plan_digest", json = encode_string(body.plan_digest)}}
    field(fields, "placement_binding_digest", optional_string(body.placement_binding_digest))
    return encode_object(fields)
end
local function encode_approval_request(body: types.ApprovalRequest): string
    local fields: {Field} = {}
    field(fields, "approval_id", encode_string(body.approval_id))
    field(fields, "request_kind", encode_string(body.request_kind))
    field(fields, "requester_id", encode_string(body.requester_id))
    if body.operation_ref then field(fields, "operation_ref", encode_string(body.operation_ref)) end
    field(fields, "prompt", encode_content(body.prompt))
    local schema = canonical.encode(body.response_schema)
    field(fields, "response_schema", schema or "{}")
    field(fields, "expires_at", encode_string(body.expires_at))
    field(fields, "state", encode_string("pending"))
    return encode_object(fields)
end
local function encode_approval_transition(body: types.ApprovalTransition): string
    local fields: {Field} = {}
    field(fields, "approval_id", encode_string(body.approval_id))
    field(fields, "expected_revision", string.format("%d", body.expected_revision))
    field(fields, "state", encode_string(body.state))
    if body.decider_id then field(fields, "decider_id", encode_string(body.decider_id)) end
    if body.response then field(fields, "response", encode_content(body.response)) end
    field(fields, "reason", encode_string(body.reason))
    return encode_object(fields)
end
local function encode_started(body: types.Started): string
    return encode_object({{key = "execution_kind", json = encode_string(body.execution_kind)},
        {key = "execution_ref", json = encode_string(body.execution_ref)},
        {key = "owner_epoch", json = string.format("%d", body.owner_epoch)}})
end
local function encode_turn_request(body: types.TurnRequest): string
    local fields: {Field} = {}
    field(fields, "input_message_ids", encode_strings(body.input_message_ids))
    field(fields, "input", encode_content(body.input))
    field(fields, "resume_ref", optional_string(body.resume_ref))
    field(fields, "delivery_ids", encode_strings(body.delivery_ids))
    return encode_object(fields)
end
local function encode_turn_end(body: types.TurnEnd): string
    local fields: {Field} = {}
    field(fields, "outcome", encode_string(body.outcome))
    field(fields, "answer_message_ids", encode_strings(body.answer_message_ids))
    field(fields, "evidence_refs", encode_strings(body.evidence_refs))
    field(fields, "usage", encode_usage(body.usage))
    field(fields, "error", encode_fault(body.error))
    return encode_object(fields)
end
local function encode_mark(body: types.DeliveryMark): string
    local fields: {Field} = {}
    field(fields, "delivery_id", encode_string(body.delivery_id))
    field(fields, "message_id", encode_string(body.message_id))
    field(fields, "recipient_id", encode_string(body.recipient_id))
    field(fields, "state", encode_string(body.state))
    field(fields, "owner_epoch", string.format("%d", body.owner_epoch))
    field(fields, "channel", encode_string(body.channel))
    field(fields, "evidence_ref", optional_string(body.evidence_ref))
    return encode_object(fields)
end
local function encode_answered(body: types.Answered): string
    return encode_object({{key = "request_message_id", json = encode_string(body.request_message_id)},
        {key = "recipient_id", json = encode_string(body.recipient_id)},
        {key = "reply_message_id", json = encode_string(body.reply_message_id)},
        {key = "outcome", json = encode_string(body.outcome)}})
end
local function encode_receipt(body: types.Receipt): string
    local fields: {Field} = {}
    field(fields, "scope", encode_string(body.scope))
    field(fields, "outcome", encode_string(body.outcome))
    field(fields, "evidence_refs", encode_strings(body.evidence_refs))
    field(fields, "error", encode_fault(body.error))
    return encode_object(fields)
end
-- Decodes a body of the named family; each family has exactly one decoder.
function M.decode_body(kind: types.Kind, value: unknown): (types.Body?, string?)
    if kind == "observation" then return observation.decode(value) end
    if kind == "message" then return message.decode(value) end
    if kind == "action.admitted" then return lifecycle.admitted(value) end
    if kind == "attempt.prepared" then return lifecycle.prepared(value) end
    if kind == "attempt.started" then return lifecycle.started(value) end
    if kind == "turn.request" then return lifecycle.turn_request(value) end
    if kind == "turn.end" then return lifecycle.turn_end(value) end
    if kind == "delivery.mark" then return delivery.mark(value) end
    if kind == "request.answered" then return delivery.answered(value) end
    if kind == "approval.request" then return approval.request(value) end
    if kind == "approval.transition" then return approval.transition(value) end
    return lifecycle.receipt(value)
end
function M.encode_body(kind: types.Kind, body: types.Body): string
    if kind == "observation" then return encode_observation(body :: types.Observation) end
    if kind == "message" then return encode_message(body :: types.Message) end
    if kind == "action.admitted" then return encode_admitted(body :: types.Admitted) end
    if kind == "attempt.prepared" then return encode_prepared(body :: types.Prepared) end
    if kind == "attempt.started" then return encode_started(body :: types.Started) end
    if kind == "turn.request" then return encode_turn_request(body :: types.TurnRequest) end
    if kind == "turn.end" then return encode_turn_end(body :: types.TurnEnd) end
    if kind == "delivery.mark" then return encode_mark(body :: types.DeliveryMark) end
    if kind == "request.answered" then return encode_answered(body :: types.Answered) end
    if kind == "approval.request" then return encode_approval_request(body :: types.ApprovalRequest) end
    if kind == "approval.transition" then return encode_approval_transition(body :: types.ApprovalTransition) end
    return encode_receipt(body :: types.Receipt)
end
local function context_rule(kind: types.Kind, record: types.Record): string?
    if kind == "action.admitted" or kind == "receipt" then
        if not record.action_id then return kind .. " names its action_id" end
    end
    if kind == "attempt.prepared" or kind == "attempt.started" or kind == "turn.request" or kind == "turn.end" then
        if not record.action_id or not record.attempt_id then return kind .. " names action_id and attempt_id" end
    end
    if kind == "turn.request" or kind == "turn.end" then
        if not record.turn_id then return kind .. " names its turn_id" end
    end
    if kind == "action.admitted" and (record.attempt_id or record.turn_id) then return "action.admitted carries no attempt or turn" end
    if (kind == "attempt.prepared" or kind == "attempt.started") and record.turn_id then return kind .. " carries no turn" end
    if kind == "receipt" and record.turn_id then return "receipt carries no turn" end
    if (kind == "approval.request" or kind == "approval.transition") and record.turn_id then return kind .. " carries no turn" end
    return nil
end
function M.decode(value: unknown): (types.Record?, string?)
    local object = bounds.object(value)
    if not object then return nil, "record must be an object" end
    local unknown_field = bounds.fields(object, {"schema_revision", "record_id", "thread_id", "sequence", "recorded_at", "kind",
        "producer_id", "source", "causation", "correlation_id", "action_id", "attempt_id", "turn_id", "body"})
    if unknown_field then return nil, unknown_field end
    if object.schema_revision ~= bounds.SCHEMA_REVISION then return nil, "schema_revision is not " .. bounds.SCHEMA_REVISION end
    local record_id, thread_id, producer_id = bounds.id(object.record_id), bounds.id(object.thread_id), bounds.id(object.producer_id)
    local sequence, recorded_at = bounds.sequence(object.sequence), bounds.timestamp(object.recorded_at)
    local kind, source = values.kind(object.kind), values.source(object.source)
    if not record_id then return nil, "record_id is not an identifier" end
    if not thread_id then return nil, "thread_id is not an identifier" end
    if not sequence then return nil, "sequence is out of range" end
    if not recorded_at then return nil, "recorded_at is not a canonical UTC timestamp" end
    if not kind then return nil, "kind is not a supported record family" end
    if not producer_id then return nil, "producer_id is not an identifier" end
    if not source then return nil, "source is not supported" end
    local body, body_error = M.decode_body(kind, object.body)
    if not body then return nil, kind .. ": " .. tostring(body_error) end
    local record: types.Record = {schema_revision = bounds.SCHEMA_REVISION, record_id = record_id, thread_id = thread_id,
        sequence = sequence, recorded_at = recorded_at, kind = kind, producer_id = producer_id, source = source, body = body}
    if object.causation ~= nil then
        local ref, ref_error = values.ref(object.causation)
        if not ref then return nil, "causation: " .. tostring(ref_error) end
        record.causation = ref
    end
    for _, name in ipairs({"correlation_id", "action_id", "attempt_id", "turn_id"}) do
        local id, valid = values.optional_id(object, name)
        if not valid then return nil, name .. " is not an identifier" end
        if name == "correlation_id" then record.correlation_id = id
        elseif name == "action_id" then record.action_id = id
        elseif name == "attempt_id" then record.attempt_id = id
        else record.turn_id = id end
    end
    local rule = context_rule(kind, record)
    if rule then return nil, rule end
    return record, nil
end
function M.decode_json(text: string): (types.Record?, string?)
    if #text > bounds.MAX_RECORD_BYTES then return nil, "record exceeds " .. tostring(bounds.MAX_RECORD_BYTES) .. " bytes" end
    local decoded: unknown, decode_error = json.decode(text)
    if decode_error then return nil, "record is not valid JSON" end
    return M.decode(decoded)
end
-- Revalidates, then emits sorted keys without whitespace so equal records
-- always produce equal bytes.
function M.encode(value: types.Record): (string?, string?)
    local record, record_error = M.decode(value)
    if not record then return nil, record_error end
    local fields: {Field} = {}
    field(fields, "schema_revision", encode_string(record.schema_revision))
    field(fields, "record_id", encode_string(record.record_id))
    field(fields, "thread_id", encode_string(record.thread_id))
    field(fields, "sequence", string.format("%d", record.sequence))
    field(fields, "recorded_at", encode_string(record.recorded_at))
    field(fields, "kind", encode_string(record.kind))
    field(fields, "producer_id", encode_string(record.producer_id))
    field(fields, "source", encode_string(record.source))
    field(fields, "causation", encode_ref(record.causation))
    field(fields, "correlation_id", optional_string(record.correlation_id))
    field(fields, "action_id", optional_string(record.action_id))
    field(fields, "attempt_id", optional_string(record.attempt_id))
    field(fields, "turn_id", optional_string(record.turn_id))
    field(fields, "body", M.encode_body(record.kind, record.body))
    local encoded = encode_object(fields)
    if #encoded > bounds.MAX_RECORD_BYTES then return nil, "record exceeds " .. tostring(bounds.MAX_RECORD_BYTES) .. " bytes" end
    return encoded, nil
end
return M
