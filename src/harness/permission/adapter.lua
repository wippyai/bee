-- MIT. The permission exchange adapter: a pinned typed description of how
-- one harness asks for permission mid-run, how the answer is encoded, how
-- the harness acknowledges it and what happens on cancellation. Pure: it
-- decodes definitions, recognizes request events, derives the durable
-- identities the approval owner and the carrier key on, encodes responses
-- and proves from a capture that the harness keeps waiting. Nothing here
-- talks to a thread, an approval owner or a runner.
local hash = require("hash")
local json = require("json")
local bounds = require("bounds")
local canonical = require("canonical")
local driver_types = require("driver_types")
local M = {}
M.REVISION = "bee.permission-adapter@2"
M.MAX_INPUT_BYTES = 16384
M.MAX_PATH_SEGMENTS = 8
M.ACKNOWLEDGMENTS = {"correlation_echo", "continued_output"}
M.DENY_ACKNOWLEDGMENTS = {"terminal_denial", "unproven"}
M.CANCELLATIONS = {"deny_before_close", "unsupported"}
type Object = {[string]: unknown}
-- acknowledgment names the request field the harness echoes back when
-- it acts, where that differs from the response correlation.
type Fields = {correlation: string, tool: string, input: string, prompt: string?, acknowledgment: string?}
type Response = {envelope: Object, correlation_field: string, decision_field: string, allow_value: string, deny_value: string, reason_field: string?, response_field: string?}
-- correlation_echo names the observation type and the field that carries
-- the request's correlation back; continued_output claims only that the
-- harness produced something afterwards.
type Acknowledgment = {mode: string, event_type: string?, field: string?}
-- A denial is acknowledged only by a terminal denial the adapter names; an
-- adapter that cannot name one reports denial dispatch as accepted by the
-- input transport with harness acknowledgment unproven.
type DenyAcknowledgment = {mode: string, event_type: string?, field: string?, value: string?, correlation_field: string?}
type Adapter = {
    adapter_id: string,
    schema_revision: string,
    event_name: string,
    event_revision: string,
    request: Fields,
    response: Response,
    acknowledgment: Acknowledgment,
    deny_acknowledgment: DenyAcknowledgment,
    cancellation: string,
    proof_fixture: string,
    digest: string,
}
type Request = {permission_request_id: string, correlation_id: string, acknowledgment_id: string, tool_name: string, input_digest: string, input: Object, prompt: string}
type Attempt = {action_id: string, attempt_id: string, plan_digest: string}
type Identity = {owner_id: string, attempt_id: string, permission_request_id: string}
local function digest_of(value: unknown): (string?, string?)
    local encoded, encode_error = canonical.encode(value)
    if not encoded then return nil, encode_error end
    local sum, hash_error = hash.sha256(encoded)
    if hash_error or not sum then return nil, "digest failed" end
    return sum, nil
end
local function segments_of(path: string): {string}
    local segments: {string} = {}
    for segment in path:gmatch("[^.]+") do segments[#segments + 1] = segment end
    return segments
end
-- A field is a dotted path of bounded depth with no empty segment.
local function field_name(object: Object, name: string, what: string): (string?, string?)
    local value = bounds.id(object[name])
    if not value then return nil, what .. "." .. name .. " is not an identifier" end
    local segments = segments_of(value)
    if #segments == 0 or #segments > M.MAX_PATH_SEGMENTS or value:find("%.%.") or value:sub(1, 1) == "." or value:sub(-1) == "." then
        return nil, what .. "." .. name .. " must be a dotted path of at most " .. tostring(M.MAX_PATH_SEGMENTS) .. " segments"
    end
    return value, nil
end
-- Two response paths overlap when one is the other or a prefix of it.
local function paths_overlap(first: string, second: string): boolean
    local a, b = segments_of(first), segments_of(second)
    local shorter = math.min(#a, #b)
    for index = 1, shorter do
        if a[index] ~= b[index] then return false end
    end
    return true
end
-- The envelope crosses a path when a value sits on the path or a segment
-- along it is not an object.
local function envelope_crosses(envelope: Object, path: string): boolean
    local current: unknown = envelope
    for _, segment in ipairs(segments_of(path)) do
        local object = bounds.object(current)
        if not object then return true end
        current = object[segment]
        if current == nil then return false end
    end
    return true
end
-- A request field is a dotted path into the event payload; a response
-- field is a dotted path into the response line.
local function lookup(payload: Object, path: string): unknown
    local current: unknown = payload
    for segment in path:gmatch("[^.]+") do
        local object = bounds.object(current)
        if not object then return nil end
        current = object[segment]
    end
    return current
end
local function copy_object(value: Object): Object
    local copied: Object = {}
    for name, item in pairs(value) do
        local nested = bounds.object(item)
        if nested and type(item) == "table" then copied[name] = copy_object(nested) else copied[name] = item end
    end
    return copied
end
local function assign(line: Object, path: string, value: unknown): string?
    local segments: {string} = {}
    for segment in path:gmatch("[^.]+") do segments[#segments + 1] = segment end
    local current = line
    for index = 1, #segments - 1 do
        local existing = current[segments[index]]
        if existing == nil then
            local created: Object = {}
            current[segments[index]] = created
            current = created
        else
            local object = bounds.object(existing)
            if not object then return "response field " .. path .. " crosses a value that is not an object" end
            current = object
        end
    end
    current[segments[#segments]] = value
    return nil
end
-- decode: an adapter definition is exact; the digest covers all of it.
function M.decode(adapter_id: string, value: unknown): (Adapter?, string?)
    local object = bounds.object(value)
    if not object then return nil, "adapter must be an object" end
    local unknown_field = bounds.fields(object, {"schema_revision", "event_name", "event_revision", "request", "response", "acknowledgment", "deny_acknowledgment", "cancellation", "proof_fixture"})
    if unknown_field then return nil, "adapter: " .. unknown_field end
    if object.schema_revision ~= M.REVISION then return nil, "adapter schema_revision must be " .. M.REVISION end
    local event_name, event_revision = bounds.id(object.event_name), bounds.id(object.event_revision)
    if not event_name then return nil, "adapter event_name is not an identifier" end
    if not event_revision then return nil, "adapter event_revision is not an identifier" end
    local request = bounds.object(object.request)
    if not request then return nil, "adapter request must be an object" end
    local unknown_request = bounds.fields(request, {"correlation", "tool", "input", "prompt", "acknowledgment"})
    if unknown_request then return nil, "adapter request: " .. unknown_request end
    local correlation, correlation_error = field_name(request, "correlation", "request")
    if not correlation then return nil, correlation_error end
    local tool, tool_error = field_name(request, "tool", "request")
    if not tool then return nil, tool_error end
    local input, input_error = field_name(request, "input", "request")
    if not input then return nil, input_error end
    local prompt: string? = nil
    if request.prompt ~= nil then
        local named, prompt_error = field_name(request, "prompt", "request")
        if not named then return nil, prompt_error end
        prompt = named
    end
    local acknowledgment_path: string? = nil
    if request.acknowledgment ~= nil then
        local named, acknowledgment_error = field_name(request, "acknowledgment", "request")
        if not named then return nil, acknowledgment_error end
        acknowledgment_path = named
    end
    local response = bounds.object(object.response)
    if not response then return nil, "adapter response must be an object" end
    local unknown_response = bounds.fields(response, {"envelope", "correlation_field", "decision_field", "allow_value", "deny_value", "reason_field", "response_field"})
    if unknown_response then return nil, "adapter response: " .. unknown_response end
    local envelope = bounds.object(response.envelope == nil and {} or response.envelope)
    if not envelope then return nil, "adapter response envelope must be an object" end
    local correlation_field, cf_error = field_name(response, "correlation_field", "response")
    if not correlation_field then return nil, cf_error end
    local decision_field, df_error = field_name(response, "decision_field", "response")
    if not decision_field then return nil, df_error end
    local allow_value = bounds.id(response.allow_value) or ""
    local deny_value = bounds.id(response.deny_value) or ""
    if allow_value == "" or deny_value == "" or allow_value == deny_value then return nil, "adapter response needs distinct allow_value and deny_value" end
    local reason_field: string? = nil
    if response.reason_field ~= nil then
        local named, reason_error = field_name(response, "reason_field", "response")
        if not named then return nil, reason_error end
        reason_field = named
    end
    local response_field: string? = nil
    if response.response_field ~= nil then
        local named, rf_error = field_name(response, "response_field", "response")
        if not named then return nil, rf_error end
        response_field = named
    end
    local paths: {string} = {correlation_field, decision_field}
    if reason_field then paths[#paths + 1] = reason_field end
    if response_field then paths[#paths + 1] = response_field end
    for index = 1, #paths do
        if envelope_crosses(envelope, paths[index]) then return nil, "adapter response envelope overlaps its fields" end
        for other = index + 1, #paths do
            if paths_overlap(paths[index], paths[other]) then return nil, "adapter response fields overlap: " .. paths[index] .. " and " .. paths[other] end
        end
    end
    local declared_ack = bounds.object(object.acknowledgment)
    if not declared_ack then return nil, "adapter acknowledgment must be an object" end
    local unknown_ack = bounds.fields(declared_ack, {"mode", "event_type", "field"})
    if unknown_ack then return nil, "adapter acknowledgment: " .. unknown_ack end
    local ack_mode = bounds.member(declared_ack.mode, M.ACKNOWLEDGMENTS)
    if not ack_mode then return nil, "adapter acknowledgment mode must be correlation_echo or continued_output" end
    local ack_type: string? = nil
    local ack_field: string? = nil
    if ack_mode == "correlation_echo" then
        ack_type, ack_field = bounds.id(declared_ack.event_type), bounds.id(declared_ack.field)
        if not ack_type or not ack_field then return nil, "adapter correlation_echo names the observation event_type and field that echo the correlation" end
    elseif declared_ack.event_type ~= nil or declared_ack.field ~= nil then
        return nil, "adapter continued_output names no event_type or field"
    end
    local acknowledgment: Acknowledgment = {mode = ack_mode, event_type = ack_type, field = ack_field}
    local declared_deny = bounds.object(object.deny_acknowledgment)
    if not declared_deny then return nil, "adapter deny_acknowledgment must be an object" end
    local unknown_deny = bounds.fields(declared_deny, {"mode", "event_type", "field", "value", "correlation_field"})
    if unknown_deny then return nil, "adapter deny_acknowledgment: " .. unknown_deny end
    local deny_mode = bounds.member(declared_deny.mode, M.DENY_ACKNOWLEDGMENTS)
    if not deny_mode then return nil, "adapter deny_acknowledgment mode must be terminal_denial or unproven" end
    local denial_type: string? = nil
    local denial_field: string? = nil
    local denial_value: string? = nil
    local denial_correlation: string? = nil
    if deny_mode == "terminal_denial" then
        denial_type, denial_field, denial_value = bounds.id(declared_deny.event_type), bounds.id(declared_deny.field), bounds.id(declared_deny.value)
        if not denial_type or not denial_field or not denial_value then return nil, "adapter terminal_denial names the observation event_type, field and value that report the denial" end
        if declared_deny.correlation_field ~= nil then
            local named, correlation_error = field_name(declared_deny, "correlation_field", "deny_acknowledgment")
            if not named then return nil, correlation_error end
            denial_correlation = named
        end
    elseif declared_deny.event_type ~= nil or declared_deny.field ~= nil or declared_deny.value ~= nil or declared_deny.correlation_field ~= nil then
        return nil, "adapter unproven deny_acknowledgment names no observation"
    end
    local deny_acknowledgment: DenyAcknowledgment = {mode = deny_mode, event_type = denial_type, field = denial_field, value = denial_value, correlation_field = denial_correlation}
    local cancellation = bounds.member(object.cancellation, M.CANCELLATIONS)
    if not cancellation then return nil, "adapter cancellation must be deny_before_close or unsupported" end
    local proof_fixture = bounds.id(object.proof_fixture)
    if not proof_fixture then return nil, "adapter proof_fixture names the capture that proves the harness keeps waiting" end
    local sum, digest_error = digest_of(object)
    if not sum then return nil, "adapter is not measurable: " .. tostring(digest_error) end
    local fields: Fields = {correlation = correlation, tool = tool, input = input, prompt = prompt, acknowledgment = acknowledgment_path}
    local shape: Response = {envelope = envelope, correlation_field = correlation_field, decision_field = decision_field, allow_value = allow_value, deny_value = deny_value, reason_field = reason_field, response_field = response_field}
    local decoded: Adapter = {adapter_id = adapter_id, schema_revision = M.REVISION, event_name = event_name, event_revision = event_revision, request = fields, response = shape,
        acknowledgment = acknowledgment, deny_acknowledgment = deny_acknowledgment, cancellation = cancellation, proof_fixture = proof_fixture, digest = sum}
    return decoded, nil
end
-- pinned: a profile enables the exchange only with this adapter's exact digest.
function M.pinned(adapter: Adapter, exchange: driver_types.PermissionExchange): string?
    if exchange.mode ~= "adapter" then return "the profile does not enable a permission exchange" end
    if exchange.adapter_ref ~= adapter.adapter_id then return "the profile pins adapter " .. tostring(exchange.adapter_ref) .. ", not " .. adapter.adapter_id end
    if exchange.adapter_digest ~= adapter.digest then return "the profile pins adapter digest " .. tostring(exchange.adapter_digest) .. ", the adapter measures " .. adapter.digest end
    return nil
end
local function extension_payload(adapter: Adapter, observation: unknown): Object?
    local event = bounds.object(observation)
    if not event or event.type ~= "extension" then return nil end
    local data = bounds.object(event.data)
    if not data or data.event_name ~= adapter.event_name or data.event_revision ~= adapter.event_revision then return nil end
    local payload_json = data.payload_json
    if type(payload_json) ~= "string" then return nil end
    return bounds.object(json.decode(payload_json))
end
-- request: recognizes one permission request in a driver observation and
-- gives it its durable identity: the observation's event key, which the
-- normalizer derives from the envelope position, so a replayed stream
-- names the same request.
function M.request(adapter: Adapter, observation: unknown): (Request?, string?)
    local event = bounds.object(observation)
    if not event then return nil, "observation must be an object" end
    local payload = extension_payload(adapter, observation)
    if not payload then return nil, nil end
    local event_key = bounds.id(event.event_key)
    if not event_key then return nil, "permission request observation has no event key" end
    local correlation_id = bounds.id(lookup(payload, adapter.request.correlation))
    if not correlation_id then return nil, "permission request has no " .. adapter.request.correlation end
    local tool_name = bounds.id(lookup(payload, adapter.request.tool))
    if not tool_name then return nil, "permission request has no " .. adapter.request.tool end
    local raw_input = lookup(payload, adapter.request.input)
    local input = bounds.object(raw_input == nil and {} or raw_input)
    if not input then return nil, "permission request " .. adapter.request.input .. " must be an object" end
    local input_json = canonical.encode(input)
    if not input_json then return nil, "permission request input is not encodable" end
    if #input_json > M.MAX_INPUT_BYTES then return nil, "permission request input exceeds " .. tostring(M.MAX_INPUT_BYTES) .. " bytes" end
    local input_digest, digest_error = digest_of(input)
    if not input_digest then return nil, "permission request input is not measurable: " .. tostring(digest_error) end
    local prompt = tool_name
    if adapter.request.prompt then
        local text = lookup(payload, adapter.request.prompt)
        if type(text) == "string" and #text > 0 then prompt = text end
    end
    local acknowledgment_id = correlation_id
    if adapter.request.acknowledgment then
        local echoed = bounds.id(lookup(payload, adapter.request.acknowledgment))
        if not echoed then return nil, "permission request has no " .. adapter.request.acknowledgment end
        acknowledgment_id = echoed
    end
    return {permission_request_id = event_key, correlation_id = correlation_id, acknowledgment_id = acknowledgment_id, tool_name = tool_name, input_digest = input_digest, input = input, prompt = prompt}, nil
end
-- admit_pending: two simultaneously pending requests with one correlation
-- id cannot be told apart by the response protocol, so the second is
-- refused rather than merged into the first.
function M.admit_pending(pending: {Request}, request: Request): (boolean, string?)
    for _, waiting in ipairs(pending) do
        if waiting.permission_request_id == request.permission_request_id then return true, nil end
        if waiting.correlation_id == request.correlation_id then
            return false, "correlation " .. request.correlation_id .. " is already pending as " .. waiting.permission_request_id
        end
    end
    return true, nil
end
-- proposal: the approval binds the attempt plan and the durable permission
-- request identity; the carrier epoch is execution fencing, never part of
-- the proposal.
function M.proposal(adapter: Adapter, attempt: Attempt, request: Request): Object
    return {kind = "attempt", ref = attempt.attempt_id, revision = attempt.plan_digest, action_id = attempt.action_id, input_digest = request.input_digest,
        payload = {adapter_ref = adapter.adapter_id, adapter_digest = adapter.digest, permission_request_id = request.permission_request_id,
            correlation_id = request.correlation_id, tool_name = request.tool_name}}
end
local function keyed(prefix: string, identity: Identity): string
    local sum = hash.sha256(prefix .. "\n" .. identity.owner_id .. "\n" .. identity.attempt_id .. "\n" .. identity.permission_request_id)
    return prefix .. "-" .. tostring(sum)
end
-- The deterministic identities: the approval idempotency key the carrier
-- checkpoints before asking, the effect key consumption reserves, and the
-- one write id the response goes out under. Harness correlation ids can
-- repeat, so every key is qualified by owner, attempt and request.
function M.idempotency_key(identity: Identity): string
    return keyed("permission-request", identity)
end
function M.effect_key(identity: Identity): string
    return keyed("permission-effect", identity)
end
function M.write_id(identity: Identity): string
    return keyed("permission-write", identity)
end
local function encode_response(adapter: Adapter, request: Request, decision: string, reason: string?, response: unknown): (string?, string?)
    local line = copy_object(adapter.response.envelope)
    local failed = assign(line, adapter.response.correlation_field, request.correlation_id) or assign(line, adapter.response.decision_field, decision)
    if not failed and reason and adapter.response.reason_field then failed = assign(line, adapter.response.reason_field, reason) end
    if not failed and response ~= nil and adapter.response.response_field then failed = assign(line, adapter.response.response_field, response) end
    if failed then return nil, failed end
    local encoded, encode_error = canonical.encode(line)
    if not encoded then return nil, encode_error end
    return encoded .. "\n", nil
end
-- allow and deny: one JSON line each, exactly the adapter's response shape.
function M.allow(adapter: Adapter, request: Request, response: unknown): (string?, string?)
    return encode_response(adapter, request, adapter.response.allow_value, nil, response)
end
function M.deny(adapter: Adapter, request: Request, reason: string): (string?, string?)
    return encode_response(adapter, request, adapter.response.deny_value, reason, nil)
end
local function is_terminal(observation: unknown): boolean
    local event = bounds.object(observation)
    if not event then return false end
    local data = bounds.object(event.data) or {}
    if event.type == "session.state" and data.state == "ended" then return true end
    if event.type == "turn.signal" and data.phase == "ended" then return true end
    return false
end
-- acknowledged: whether an observation after the response carries the
-- request's correlation back in the adapter's named observation and field;
-- continued_output accepts any non-terminal observation and claims no more.
function M.acknowledged(adapter: Adapter, request: Request, observation: unknown): boolean
    local event = bounds.object(observation)
    if not event then return false end
    if adapter.acknowledgment.mode == "correlation_echo" then
        if event.type ~= adapter.acknowledgment.event_type then return false end
        local data = bounds.object(event.data) or {}
        local echoed: unknown = nil
        if event.type == "extension" then
            local payload = extension_payload(adapter, observation) or {}
            echoed = lookup(payload, adapter.acknowledgment.field or "")
        else
            echoed = lookup(data, adapter.acknowledgment.field or "")
        end
        return echoed == request.acknowledgment_id
    end
    return not is_terminal(observation)
end
-- deny_acknowledged: whether an observation is the terminal denial the
-- adapter names, correlated to the request where the adapter names a
-- correlation field; false for every adapter whose denial handling is
-- unproven.
function M.deny_acknowledged(adapter: Adapter, request: Request, observation: unknown): boolean
    if adapter.deny_acknowledgment.mode ~= "terminal_denial" then return false end
    local event = bounds.object(observation)
    if not event or event.type ~= adapter.deny_acknowledgment.event_type then return false end
    local data = bounds.object(event.data) or {}
    if lookup(data, adapter.deny_acknowledgment.field or "") ~= adapter.deny_acknowledgment.value then return false end
    local correlation_field = adapter.deny_acknowledgment.correlation_field
    if correlation_field then return lookup(data, correlation_field) == request.acknowledgment_id end
    return true
end
-- identity: the tuple every permission key is derived from.
function M.identity(owner_id: string, attempt_id: string, permission_request_id: string): Identity
    return {owner_id = owner_id, attempt_id = attempt_id, permission_request_id = permission_request_id}
end
-- transcript_consistent: a transcript is consistent with a continuing
-- exchange when the request appears, nothing terminal follows it before the
-- response position, and an acknowledgment follows. This is transcript
-- consistency only: it does not show that the response was written to the
-- child or that the harness acted on it. Interactive acceptance is proven
-- by a live fixture runner that records the input-write boundary and the
-- correlated continuation, and is recorded by a host acceptance record.
function M.transcript_consistent(adapter: Adapter, observations: {unknown}, response_after: integer): (Request?, string?)
    local request: Request? = nil
    local request_index = 0
    for index, observation in ipairs(observations) do
        if not request then
            local found, request_error = M.request(adapter, observation)
            if request_error then return nil, request_error end
            if found then
                request, request_index = found, index
            end
        end
    end
    if not request then return nil, "the transcript has no permission request" end
    if response_after < request_index then return nil, "the response precedes the request" end
    if response_after > #observations then return nil, "the response position is past the transcript" end
    for index = request_index + 1, response_after do
        if is_terminal(observations[index]) then return nil, "the harness ended before the response" end
    end
    for index = response_after + 1, #observations do
        if M.acknowledged(adapter, request, observations[index]) then return request, nil end
        if is_terminal(observations[index]) then return nil, "the harness ended without acknowledging the response" end
    end
    return nil, "the transcript shows no acknowledgment after the response"
end
-- outcome: what the carrier does with a decision that arrives while the
-- exchange may or may not still be waiting. Nothing is sent after the
-- attempt settled; an approved decision left unused reaches its own
-- consumption deadline and its history stays as decided.
function M.outcome(adapter: Adapter, decision: string, waiting: boolean, settled: boolean): string
    if settled then return "none" end
    if decision == "approved" then
        if waiting then return "allow" end
        return "none"
    end
    if not waiting then return "none" end
    if adapter.cancellation == "unsupported" and decision ~= "denied" then return "none" end
    return "deny"
end
return M
