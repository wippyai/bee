-- MIT. In-process runner for native Wippy agent driver.
local json = require("json")
local registry = require("registry")
local funcs = require("funcs")
local security = require("security")
local bounds = require("bounds")
local canonical = require("canonical")
local client = require("client")
local types = require("types")
local driver_configuration = require("driver_configuration")

local M = {}
local THREADS = "bee.threads.binding"
type CheckpointTerminal = {outcome: types.Outcome, answer: string?}
type Checkpoint = {messages: {types.Message}, terminal: CheckpointTerminal?}
type InboxContent = {text: string?, artifact_ref: string?}
type InboxOffer = {kind: "empty"}
    | {kind: "item", sequence: integer, record_id: string, content: InboxContent, dispatch: boolean}
type InboxCall = (string, {[string]: unknown}) -> (unknown, string?)
type InboxDelivery = {kind: "empty"}
    | {kind: "item", content: InboxContent}
    | {kind: "failed", outcome: "failed" | "uncertain", message: string}

M.MAX_TOOL_CALLS_PER_TURN = 16
M.MAX_TOOL_OUTPUT_BYTES = 8192
M.MAX_TEXT_BYTES = 32768
M.MAX_CHECKPOINT_BYTES = 60000
M.MAX_CHECKPOINT_MESSAGES = 512
M.MAX_TOOL_ARGUMENT_BYTES = 8192
M.MAX_TOOL_EVENT_OUTPUT_BYTES = 3000
M.MAX_TOOL_EVENT_BATCH_BYTES = 262144
M.MAX_ENDPOINT_BYTES = 512
M.CHECKPOINT_REVISION = "bee.carrier.checkpoint@1"

local function call_func(target: string, request: unknown): (unknown, string?)
    local ok, reply, err = pcall(function()
        return funcs.call(target, request)
    end)
    if not ok then return nil, tostring(reply) end
    if err then return nil, tostring(err) end
    return reply, nil
end

local function reply_value(reply: unknown): ({[string]: unknown}?, string?, boolean?)
    local object = bounds.object(reply)
    if not object then return nil, "reply must be an object", false end
    local extra = bounds.fields(object, {"ok", "error", "value", "replayed"})
    if extra then return nil, "reply: " .. extra, false end
    if type(object.ok) ~= "boolean" then return nil, "reply.ok must be a boolean", false end
    if object.replayed ~= nil and type(object.replayed) ~= "boolean" then return nil, "reply.replayed must be a boolean", false end
    if object.ok == false then
        if object.value ~= nil then return nil, "failed reply carries a value", false end
        local fault = bounds.object(object.error)
        if not fault or bounds.fields(fault, {"code", "message", "retryable"}) or type(fault.retryable) ~= "boolean" then
            return nil, "owner returned a malformed fault", false
        end
        local code, message = bounds.id(fault.code), bounds.text(fault.message, bounds.MAX_FAULT_MESSAGE_BYTES)
        if not code or not message then return nil, "owner returned an invalid fault", false end
        return nil, code .. ": " .. message, true
    end
    if object.error ~= nil then return nil, "successful reply carries a fault", false end
    local value = bounds.object(object.value)
    if not value then return nil, "successful reply has no object value", false end
    return value, nil
end

local function decode_inbox_content(value: unknown): (InboxContent?, string?)
    local object = bounds.object(value)
    if not object then return nil, "content must be an object" end
    local extra = bounds.fields(object, {"text", "artifact_ref"})
    if extra then return nil, "content: " .. extra end
    local text: string? = nil
    if object.text ~= nil then
        text = bounds.text(object.text, M.MAX_TEXT_BYTES)
        if not text then return nil, "content.text is malformed" end
    end
    local artifact_ref: string? = nil
    if object.artifact_ref ~= nil then
        artifact_ref = bounds.id(object.artifact_ref)
        if not artifact_ref then return nil, "content.artifact_ref is malformed" end
    end
    if text == nil and artifact_ref == nil then return nil, "content is empty" end
    return {text = text, artifact_ref = artifact_ref}, nil
end

local function decode_inbox_offer(value: unknown, thread_id: string, action_id: string): (InboxOffer?, string?)
    local object = bounds.object(value)
    if not object then return nil, "offer must be an object" end
    if object.empty == true then
        if bounds.fields(object, {"empty"}) then return nil, "empty offer has unknown fields" end
        return {kind = "empty"}, nil
    end
    local extra = bounds.fields(object, {"thread_id", "action_id", "inbox_sequence", "record_id", "payload_digest",
        "message_id", "message_kind", "content", "sender_action_id", "sender_thread_id", "sender_node_id",
        "state", "dispatch", "offer_count", "in_reply_to"})
    if extra then return nil, "offer: " .. extra end
    local offered_thread, offered_action = bounds.id(object.thread_id), bounds.id(object.action_id)
    local sequence, record_id = bounds.sequence(object.inbox_sequence), bounds.id(object.record_id)
    local digest = bounds.text(object.payload_digest, 64)
    local message_id = bounds.id(object.message_id)
    local message_kind = bounds.member(object.message_kind, {"request", "progress", "reply", "notification"})
    local sender_action, sender_thread, sender_node = bounds.id(object.sender_action_id), bounds.id(object.sender_thread_id), bounds.id(object.sender_node_id)
    local state = bounds.member(object.state, {"committed", "offered", "transport_accepted", "acknowledged", "replied"})
    local count = bounds.count(object.offer_count)
    local content, content_error = decode_inbox_content(object.content)
    if not offered_thread or offered_thread ~= thread_id then return nil, "offer thread identity is malformed" end
    if not offered_action or offered_action ~= action_id then return nil, "offer action identity is malformed" end
    if not sequence then return nil, "offer sequence is malformed" end
    if not record_id then return nil, "offer record identity is malformed" end
    if not digest or #digest ~= 64 or digest:find("[^0-9a-f]") then return nil, "offer payload digest is malformed" end
    if not message_id or not message_kind or not sender_action or not sender_thread or not sender_node or not state then
        return nil, "offer message identity is malformed"
    end
    local dispatch: boolean
    if object.dispatch == true then dispatch = true
    elseif object.dispatch == false then dispatch = false
    else return nil, "offer dispatch must be a boolean" end
    if not count or count < 1 then return nil, "offer count is malformed" end
    if not content then return nil, "offer content is malformed: " .. tostring(content_error) end
    if object.in_reply_to ~= nil then
        local reference = bounds.object(object.in_reply_to)
        if not reference or bounds.fields(reference, {"thread_id", "record_id"})
            or not bounds.id(reference.thread_id) or not bounds.id(reference.record_id) then
            return nil, "offer.in_reply_to is malformed"
        end
    elseif message_kind == "reply" then
        return nil, "reply offer has no correlation"
    end
    return {kind = "item", sequence = sequence, record_id = record_id, content = content, dispatch = dispatch}, nil
end

function M.process_inbox(thread_id: string, action_id: string, attempt_id: string, carrier_epoch: integer,
    idempotency_key: string, call: InboxCall): InboxDelivery
    local offered_raw, offer_call_error = call("inbox_offer", {thread_id = thread_id, action_id = action_id,
        attempt_id = attempt_id, carrier_epoch = carrier_epoch})
    if offer_call_error then return {kind = "failed", outcome = "failed", message = "offer inbox: " .. offer_call_error} end
    local offered, offer_error = reply_value(offered_raw)
    if not offered then return {kind = "failed", outcome = "failed", message = "offer inbox: " .. tostring(offer_error)} end
    local decoded, decode_error = decode_inbox_offer(offered, thread_id, action_id)
    if not decoded then return {kind = "failed", outcome = "failed", message = "decode inbox offer: " .. tostring(decode_error)} end
    if decoded.kind == "empty" or not decoded.dispatch then return {kind = "empty"} end

    local transport_raw, transport_call_error = call("inbox_transport", {thread_id = thread_id, action_id = action_id,
        attempt_id = attempt_id, carrier_epoch = carrier_epoch, inbox_sequence = decoded.sequence, record_id = decoded.record_id})
    if transport_call_error then
        return {kind = "failed", outcome = "uncertain", message = "transport inbox item: " .. transport_call_error}
    end
    local transport, transport_error, transport_refused = reply_value(transport_raw)
    if not transport then
        local outcome: "failed" | "uncertain" = transport_refused and "failed" or "uncertain"
        return {kind = "failed", outcome = outcome, message = "transport inbox item: " .. tostring(transport_error)}
    end
    local transport_state = bounds.member(transport.state, {"transport_accepted", "acknowledged", "replied"})
    if bounds.fields(transport, {"record_id", "inbox_sequence", "state"})
        or transport.record_id ~= decoded.record_id or transport.inbox_sequence ~= decoded.sequence or not transport_state then
        return {kind = "failed", outcome = "uncertain", message = "transport inbox item returned a malformed receipt"}
    end

    local acknowledged_raw, ack_call_error = call("inbox_ack", {thread_id = thread_id, action_id = action_id,
        inbox_sequence = decoded.sequence, idempotency_key = idempotency_key .. "-ack-" .. tostring(decoded.sequence)})
    if ack_call_error then
        return {kind = "failed", outcome = "uncertain", message = "acknowledge inbox item: " .. ack_call_error}
    end
    local acknowledged, ack_error = reply_value(acknowledged_raw)
    if not acknowledged then
        return {kind = "failed", outcome = "uncertain", message = "acknowledge inbox item: " .. tostring(ack_error)}
    end
    local ack_state = bounds.member(acknowledged.state, {"acknowledged", "replied"})
    if bounds.fields(acknowledged, {"record_id", "inbox_sequence", "state"})
        or acknowledged.record_id ~= decoded.record_id or acknowledged.inbox_sequence ~= decoded.sequence or not ack_state then
        return {kind = "failed", outcome = "uncertain", message = "acknowledge inbox item returned a malformed receipt"}
    end
    return {kind = "item", content = decoded.content}
end

local function model_id(value: unknown): string?
    local model = bounds.text(value, 128)
    if not model or model == "" or not model:match("^[A-Za-z0-9][A-Za-z0-9._:-]*$") then return nil end
    return model
end

-- The endpoint is a host-selected chat destination: https to a named host,
-- or plain http to the loopback address only, mirroring the managed
-- provider endpoint rule. The key itself is never read here.
function M.decode_host_config(value: unknown): (types.HostConfig?, string?)
    local object = bounds.object(value == nil and {} or value)
    if not object then return nil, "host_config must be an object" end
    local unknown_field = bounds.fields(object, {"endpoint", "credential_ref", "model", "timeout_ms", "stream", "admitted_delegates"})
    if unknown_field then return nil, "host_config: " .. unknown_field end
    local url, url_error = driver_configuration.endpoint(object.endpoint, true, "endpoint")
    if not url then return nil, "host_config: " .. tostring(url_error) end
    local credential_ref: string? = nil
    if object.credential_ref ~= nil then
        credential_ref = bounds.id(object.credential_ref)
        if not credential_ref then return nil, "host_config: credential_ref is not an identifier" end
    end
    local model: string? = nil
    if object.model ~= nil then
        model = model_id(object.model)
        if not model then return nil, "host_config: model is not a bounded model identifier" end
    end
    local timeout_ms = 30000
    if object.timeout_ms ~= nil then
        local timeout = bounds.integer(object.timeout_ms)
        if not timeout then return nil, "host_config: timeout_ms must be an integer" end
        timeout_ms = math.floor(math.min(120000, math.max(1000, timeout)))
    end
    if object.stream ~= nil and type(object.stream) ~= "boolean" then
        return nil, "host_config: stream must be a boolean"
    end
    local admitted: {string} = {}
    if object.admitted_delegates ~= nil then
        local delegates, delegates_error = bounds.ids(object.admitted_delegates, true)
        if not delegates then return nil, "host_config: admitted_delegates: " .. tostring(delegates_error) end
        admitted = delegates
    end
    return {
        endpoint = url,
        credential_ref = credential_ref,
        model = model,
        timeout_ms = timeout_ms,
        stream = object.stream == true,
        admitted_delegates = admitted,
    }, nil
end

function M.resolve_agent(pinned: registry.Snapshot, agent_ref: string, host_config: types.HostConfig?): ({[string]: unknown}?, string?)
    local resolver = require("agent_resolver")
    local closure, code, err = resolver.resolve(pinned, agent_ref)
    if not closure then return nil, err or code or "agent resolve failed" end

    local model_map: {[string]: string} = {}
    if host_config and host_config.model then
        if closure.model then model_map[closure.model] = host_config.model end
    elseif closure.model then
        model_map[closure.model] = closure.model
    end

    -- Delegates are admitted by the host configuration, never by the agent
    -- definition itself: self-admission would bypass the host policy.
    local admitted_delegates: {string} = {}
    if host_config and host_config.admitted_delegates then
        for _, ref in ipairs(host_config.admitted_delegates) do
            admitted_delegates[#admitted_delegates + 1] = ref
        end
    end

    local checked, route_code, route_err = resolver.check_route(pinned, closure, {
        driver_id = "wippy",
        model_map = model_map,
        admitted_delegates = admitted_delegates,
    })
    if not checked then return nil, route_err or route_code or "route check failed" end

    return closure, nil
end

-- A tool runs under a fresh per-attempt actor narrowed to the tool's own
-- declared scopes: the agent's grants only, never ambient authority. Every
-- narrowing failure denies instead of falling back to a wider executor.
function M.execute_tool(tool_entry: {[string]: unknown}, args: {[string]: unknown}, caller_id: string, workspace_id: string?): (boolean, unknown)
    local tool_ref = bounds.id(tool_entry.ref)
    if not tool_ref then
        return false, {code = "DENIED", message = "tool reference is not an identifier"}
    end
    local raw_scopes = tool_entry.scopes
    if raw_scopes ~= nil and type(raw_scopes) ~= "table" then
        return false, {code = "DENIED", message = "tool scopes must be a list"}
    end
    local scope_names, scopes_error = bounds.ids(raw_scopes == nil and {} or raw_scopes, true)
    if not scope_names then
        return false, {code = "DENIED", message = "tool scopes: " .. tostring(scopes_error)}
    end

    local policies: {security.Policy} = {}
    for _, name in ipairs(scope_names) do
        local pol, _ = security.policy(name)
        if not pol then
            return false, {code = "DENIED", message = "tool scope " .. name .. " is not admitted"}
        end
        policies[#policies + 1] = pol
    end

    local actor, actor_err = security.new_actor(caller_id, {workspace_id = workspace_id or ""})
    if not actor then
        return false, {code = "DENIED", message = "actor creation failed: " .. tostring(actor_err)}
    end

    local acted, act_err = funcs.new():with_actor(actor)
    if not acted then
        return false, {code = "DENIED", message = "actor attachment failed: " .. tostring(act_err)}
    end

    local executor = acted
    if #policies > 0 then
        local scope = security.new_scope(policies)
        local scoped, scope_err = executor:with_scope(scope)
        if not scoped then
            return false, {code = "DENIED", message = "scope attachment failed: " .. tostring(scope_err)}
        end
        executor = scoped
    end

    local reply, call_err = executor:call(tool_ref, args)
    if call_err then
        return false, {code = "FAILED", message = tostring(call_err)}
    end
    return true, reply
end

local function truncate_text(value: string, limit: integer): string
    if #value <= limit then return value end
    return value:sub(1, limit) .. "...[truncated]"
end

local function encode_tool_output(output: unknown): string
    local encoded, encode_err = canonical.encode(output)
    if not encoded then
        local failure = canonical.encode({code = "FAILED", message = "tool output is not encodable: " .. tostring(encode_err)})
        return failure or "{}"
    end
    if #encoded > M.MAX_TOOL_OUTPUT_BYTES then
        return canonical.encode({code = "OUTPUT_TOO_LARGE", message = "tool output exceeds its byte bound"}) or "{}"
    end
    return encoded
end

local function output_record(event_key: string, payload: {[string]: unknown}): ({[string]: unknown}?, string?)
    local payload_json, encode_error = canonical.encode(payload)
    if not payload_json then return nil, "encode tool event: " .. tostring(encode_error) end
    local record: {[string]: unknown} = {source = "bee", body = {type = "extension", event_key = event_key,
        data = {type = "extension", event_name = "bee.carrier.output", event_revision = "1", payload_json = payload_json}}}
    local encoded_record, record_error = canonical.encode(record)
    if not encoded_record or #encoded_record > bounds.MAX_RECORD_BYTES then
        return nil, "tool event record exceeds " .. tostring(bounds.MAX_RECORD_BYTES) .. " bytes: " .. tostring(record_error or "")
    end
    return record, nil
end

local function copy_messages(messages: {types.Message}): {types.Message}
    local copied: {types.Message} = {}
    for index, message in ipairs(messages) do copied[index] = message end
    return copied
end

local function decode_tool_arguments(value: unknown): ({[string]: unknown}?, string?)
    local text = bounds.text(value, M.MAX_TOOL_ARGUMENT_BYTES)
    if not text then return nil, "tool arguments must be bounded JSON text" end
    if not text:match("^%s*{") then return nil, "tool arguments must decode to an object" end
    local decoded, decode_error = json.decode(text)
    local object = bounds.object(decoded)
    if decode_error or not object then return nil, "tool arguments must decode to an object" end
    local encoded, encode_error = canonical.encode(object)
    if not encoded or #encoded > M.MAX_TOOL_ARGUMENT_BYTES then
        return nil, "tool arguments exceed " .. tostring(M.MAX_TOOL_ARGUMENT_BYTES) .. " bytes: " .. tostring(encode_error or "")
    end
    return object, nil
end
M.decode_tool_arguments = decode_tool_arguments

local function decode_tool_call(value: unknown, index: integer): (types.ToolCall?, string?)
    local raw = bounds.object(value)
    if not raw then return nil, "tool call must be an object" end
    local unknown = bounds.fields(raw, {"id", "kind", "name", "arguments"})
    if unknown then return nil, "tool call: " .. unknown end
    local id, name = bounds.id(raw.id), bounds.id(raw.name)
    if not id or not name or raw.kind ~= "function" then return nil, "tool call identity or kind is invalid" end
    local arguments = bounds.text(raw.arguments, M.MAX_TOOL_ARGUMENT_BYTES)
    if not arguments then return nil, "tool call arguments exceed their byte bound" end
    local _, arguments_error = decode_tool_arguments(arguments)
    if arguments_error then return nil, arguments_error end
    return {id = id, kind = "function", name = name, arguments = arguments}, nil
end

local function decode_message(value: unknown, index: integer): (types.Message?, string?)
    local raw = bounds.object(value)
    if not raw then return nil, "checkpoint messages[" .. tostring(index) .. "] must be an object" end
    local role = bounds.member(raw.role, {"system", "user", "assistant", "tool"})
    if role == "system" or role == "user" then
        local unknown = bounds.fields(raw, {"role", "content"})
        local content = bounds.text(raw.content, M.MAX_TEXT_BYTES)
        if unknown or not content then return nil, "checkpoint message content or fields are invalid" end
        return {role = role, content = content}, nil
    elseif role == "tool" then
        local unknown = bounds.fields(raw, {"role", "tool_call_id", "content"})
        local call_id, content = bounds.id(raw.tool_call_id), bounds.text(raw.content, M.MAX_TOOL_OUTPUT_BYTES + 128)
        if unknown or not call_id or not content then return nil, "checkpoint tool message is invalid" end
        return {role = "tool", tool_call_id = call_id, content = content}, nil
    elseif role == "assistant" then
        local unknown = bounds.fields(raw, {"role", "content", "tool_calls"})
        if unknown then return nil, "checkpoint assistant message: " .. unknown end
        local content: string? = nil
        if raw.content ~= nil then
            content = bounds.text(raw.content, M.MAX_TEXT_BYTES)
            if not content then return nil, "checkpoint assistant content exceeds its byte bound" end
        end
        local calls: {types.ToolCall}? = nil
        if raw.tool_calls ~= nil then
            local list, list_error = bounds.array(raw.tool_calls, M.MAX_TOOL_CALLS_PER_TURN)
            if not list then return nil, "checkpoint assistant tool_calls: " .. tostring(list_error) end
            if #list == 0 then return nil, "checkpoint assistant tool_calls must not be empty" end
            calls = {}
            for position, raw_call in ipairs(list) do
                local call, call_error = decode_tool_call(raw_call, position)
                if not call then return nil, "checkpoint tool_calls[" .. tostring(position) .. "]: " .. tostring(call_error) end
                calls[position] = call
            end
        end
        if content == nil and calls == nil then return nil, "checkpoint assistant message has no content or tool calls" end
        return {role = "assistant", content = content, tool_calls = calls}, nil
    end
    return nil, "checkpoint message role is invalid"
end

local function execution_outcome(value: unknown): types.Outcome?
    if value == "succeeded" then return "succeeded" end
    if value == "failed" then return "failed" end
    if value == "cancelled" then return "cancelled" end
    if value == "uncertain" then return "uncertain" end
    return nil
end

local function decode_checkpoint(value: unknown): (Checkpoint?, string?)
    if value == nil then return {messages = {}, terminal = nil}, nil end
    local checkpoint = bounds.object(value)
    if not checkpoint then return nil, "checkpoint must be an object" end
    local unknown = bounds.fields(checkpoint, {"schema_revision", "normalizer_state", "terminal"})
    if unknown then return nil, "checkpoint: " .. unknown end
    if checkpoint.schema_revision ~= M.CHECKPOINT_REVISION then return nil, "checkpoint schema revision is unsupported" end
    local state = bounds.object(checkpoint.normalizer_state)
    if not state then return nil, "checkpoint.normalizer_state must be an object" end
    local state_unknown = bounds.fields(state, {"messages"})
    if state_unknown then return nil, "checkpoint.normalizer_state: " .. state_unknown end
    local list, list_error = bounds.array(state.messages, M.MAX_CHECKPOINT_MESSAGES)
    if not list then return nil, "checkpoint.normalizer_state.messages: " .. tostring(list_error) end
    local messages: {types.Message} = {}
    for index, raw in ipairs(list) do
        local decoded, decode_error = decode_message(raw, index)
        if not decoded then return nil, decode_error end
        messages[index] = decoded
    end
    local decoded_terminal: CheckpointTerminal? = nil
    if checkpoint.terminal ~= nil then
        local terminal = bounds.object(checkpoint.terminal)
        if not terminal or bounds.fields(terminal, {"outcome", "answer"}) then return nil, "checkpoint.terminal is malformed" end
        local terminal_outcome = execution_outcome(terminal.outcome)
        if not terminal_outcome then
            return nil, "checkpoint.terminal.outcome is invalid"
        end
        local answer: string? = nil
        if terminal.answer ~= nil then
            answer = bounds.text(terminal.answer, M.MAX_TEXT_BYTES)
            if not answer then return nil, "checkpoint.terminal.answer exceeds its byte bound" end
        end
        decoded_terminal = {outcome = terminal_outcome, answer = answer}
    end
    local encoded, encode_error = canonical.encode(checkpoint)
    if not encoded or #encoded > M.MAX_CHECKPOINT_BYTES then
        return nil, "checkpoint exceeds " .. tostring(M.MAX_CHECKPOINT_BYTES) .. " bytes: " .. tostring(encode_error or "")
    end
    return {messages = messages, terminal = decoded_terminal}, nil
end
M.decode_checkpoint = decode_checkpoint

local function checkpoint_fits(messages: {types.Message}, terminal: {[string]: unknown}?): boolean
    local value: {[string]: unknown} = {schema_revision = M.CHECKPOINT_REVISION, normalizer_state = {messages = messages}}
    if terminal then value.terminal = terminal end
    local encoded, _ = canonical.encode(value)
    return encoded ~= nil and #encoded <= M.MAX_CHECKPOINT_BYTES
end

-- History keeps tool calls decoded flat; the chat endpoint receives the
-- OpenAI wire shape, so resumed histories stay valid payloads.
local function wire_messages(messages: {types.Message}): {{[string]: unknown}}
    local out: {{[string]: unknown}} = {}
    for _, msg in ipairs(messages) do
        if msg.tool_calls and #msg.tool_calls > 0 then
            local calls: {{[string]: unknown}} = {}
            for _, tc in ipairs(msg.tool_calls) do
                calls[#calls + 1] = {
                    id = tc.id,
                    type = "function",
                    ["function"] = {
                        name = tc.name,
                        arguments = tc.arguments,
                    },
                }
            end
            out[#out + 1] = {role = msg.role, content = msg.content, tool_calls = calls}
        elseif msg.tool_call_id then
            out[#out + 1] = {role = msg.role, tool_call_id = msg.tool_call_id, content = msg.content}
        else
            out[#out + 1] = {role = msg.role, content = msg.content}
        end
    end
    return out
end

function M.execute(context: types.ExecutionContext, request: types.RunRequest): types.ExecutionResult
    local thread_id = request.thread_id
    local action_id = request.action_id
    local attempt_id = request.attempt_id
    local epoch = context.carrier_epoch
    local agent_ref = request.agent_ref
    local brief = request.brief or ""
    local workspace_id = request.workspace_id or "default"
    local idempotency_key = request.idempotency_key or (attempt_id .. "-run")
    local messages: {types.Message} = {}

    local function checkpoint(terminal: {[string]: unknown}?): {[string]: unknown}
        local value: {[string]: unknown} = {schema_revision = M.CHECKPOINT_REVISION,
            normalizer_state = {messages = messages}}
        if terminal then value.terminal = terminal end
        return value
    end

    local function fail_run(message: string): types.ExecutionResult
        return {outcome = "failed", error = message, answer = nil, checkpoint = nil}
    end

    local restored, checkpoint_error = decode_checkpoint(context.checkpoint)
    if not restored then return fail_run("decode Wippy checkpoint: " .. tostring(checkpoint_error)) end
    messages = restored.messages
    if restored.terminal then
        local terminal = restored.terminal
        local saved = checkpoint({outcome = terminal.outcome, answer = terminal.answer})
        if terminal.outcome == "succeeded" then
            return {outcome = "succeeded", answer = terminal.answer, error = nil, checkpoint = saved}
        elseif terminal.outcome == "cancelled" then
            return {outcome = "cancelled", answer = terminal.answer, error = nil, checkpoint = saved}
        elseif terminal.outcome == "uncertain" then
            return {outcome = "uncertain", answer = terminal.answer, error = "resumed terminal checkpoint records an uncertain outcome", checkpoint = saved}
        end
        return {outcome = "failed", answer = terminal.answer, error = "resumed terminal checkpoint records a failed outcome", checkpoint = saved}
    end

    local raw_config: unknown = request.host_config
    if raw_config == nil then
        local conf_entry = registry.get("bee.driver.wippy:host_config")
        if conf_entry and type(conf_entry.data) == "table" then
            raw_config = conf_entry.data
        else
            raw_config = {}
        end
    end
    local host_config, config_error = M.decode_host_config(raw_config)
    if not host_config then
        return fail_run("decode host configuration: " .. tostring(config_error))
    end

    local function commit(idem: string, records: {{[string]: unknown}}, terminal: {[string]: unknown}?): (boolean, string?)
        return context.commit(idem, records, checkpoint(terminal))
    end

    local function settle(outcome: types.Outcome, answer: string?, error: string?): types.ExecutionResult
        local saved = checkpoint({outcome = outcome, answer = answer})
        if outcome == "succeeded" then
            return {outcome = "succeeded", answer = answer, error = nil, checkpoint = saved}
        elseif outcome == "cancelled" then
            return {outcome = "cancelled", answer = answer, error = nil, checkpoint = saved}
        elseif outcome == "uncertain" then
            return {outcome = "uncertain", answer = answer, error = error or "outcome is uncertain", checkpoint = saved}
        end
        return {outcome = "failed", answer = answer, error = error or "execution failed", checkpoint = saved}
    end

    -- 4. Resolve agent closure if agent_ref provided
    local closure: {[string]: unknown}? = nil
    local instructions = "You are a helpful assistant."
    local tool_schemas: {{[string]: unknown}} = {}
    local tool_map: {[string]: {[string]: unknown}} = {}

    if agent_ref and agent_ref ~= "" then
        local pinned = registry.snapshot()
        local resolved, res_err = M.resolve_agent(pinned, agent_ref, host_config)
        if not resolved then
            return fail_run("resolve agent closure: " .. tostring(res_err))
        end
        closure = resolved
        instructions = tostring(closure.instructions or instructions)

        local mem_list = closure.memory
        if mem_list and #mem_list > 0 and #messages == 0 then
            for _, mem_ref in ipairs(mem_list) do
                local mem_record = {
                    source = "bee",
                    body = {
                        type = "extension",
                        event_key = "memory:" .. mem_ref .. ":" .. attempt_id,
                        data = {
                            type = "extension",
                            event_name = "bee.carrier.memory",
                            event_revision = "1",
                            payload_json = json.encode({memory_ref = mem_ref, attempt_id = attempt_id}),
                        },
                    },
                }
                local committed, commit_err = commit(idempotency_key .. "-mem-" .. mem_ref, {mem_record}, nil)
                if not committed then
                    return fail_run("commit memory record: " .. tostring(commit_err))
                end
            end
        end

        local tools = closure.tools or {}
        for _, t in ipairs(tools) do
            local alias = tostring(t.alias)
            tool_map[alias] = t
            tool_schemas[#tool_schemas + 1] = {
                type = "function",
                ["function"] = {
                    name = alias,
                    description = t.description,
                    parameters = t.input_schema,
                },
            }
        end
    end

    if #messages == 0 then
        messages[#messages + 1] = {role = "system", content = instructions}
        if brief and #brief > 0 then
            messages[#messages + 1] = {role = "user", content = truncate_text(brief, M.MAX_TEXT_BYTES)}
        end
    end

    if not checkpoint_fits(messages) then
        return fail_run("initial checkpoint exceeds " .. tostring(M.MAX_CHECKPOINT_BYTES) .. " bytes")
    end

    local final_answer: string? = nil
    local turn_sequence = 0

    while true do
        turn_sequence = turn_sequence + 1

        if context.cancelled() then
            return settle("cancelled", final_answer)
        end

        local payload: types.ChatPayload = {
            model = (host_config.model or (closure and type(closure.model) == "string" and closure.model) or "default"),
            messages = wire_messages(messages),
            tools = #tool_schemas > 0 and tool_schemas or nil,
            stream = host_config.stream == true,
        }

        local resp, chat_err = client.chat_completions(host_config, payload, workspace_id, function()
            return context.cancelled()
        end)

        if chat_err == "cancelled" or context.cancelled() then
            return settle("cancelled", final_answer)
        end

        if chat_err or not resp then
            return settle("failed", final_answer, "chat completions: " .. tostring(chat_err))
        end

        if resp.tool_calls and #resp.tool_calls > 0 then
            if #resp.tool_calls > M.MAX_TOOL_CALLS_PER_TURN then
                return settle("failed", final_answer,
                    "turn requests " .. tostring(#resp.tool_calls) .. " tool calls, above the limit of " .. tostring(M.MAX_TOOL_CALLS_PER_TURN))
            end
            local calls: {types.ToolCall} = resp.tool_calls
            local decoded_arguments: {{[string]: unknown}} = {}
            local seen_call_ids: {[string]: boolean} = {}
            for index, tc in ipairs(calls) do
                local call, call_error = decode_tool_call(tc, index)
                if not call then return settle("failed", final_answer, "decode tool call: " .. tostring(call_error)) end
                if seen_call_ids[call.id] then return settle("failed", final_answer, "tool call IDs must be unique") end
                seen_call_ids[call.id] = true
                local arguments, arguments_error = decode_tool_arguments(call.arguments)
                if not arguments then return settle("failed", final_answer, "decode tool arguments: " .. tostring(arguments_error)) end
                decoded_arguments[index] = arguments
            end

            local assistant_msg: types.Message = {
                role = "assistant",
                content = resp.content and truncate_text(resp.content, M.MAX_TEXT_BYTES) or nil,
                tool_calls = calls,
            }
            local prospective_messages: {types.Message} = copy_messages(messages)
            prospective_messages[#prospective_messages + 1] = assistant_msg
            for _, tc in ipairs(calls) do
                local reserved_result: types.Message = {role = "tool", tool_call_id = tc.id,
                    content = string.rep("x", M.MAX_TOOL_EVENT_OUTPUT_BYTES)}
                prospective_messages[#prospective_messages + 1] = reserved_result
            end
            if not checkpoint_fits(prospective_messages) then
                return settle("failed", final_answer, "prospective tool checkpoint exceeds " .. tostring(M.MAX_CHECKPOINT_BYTES) .. " bytes")
            end

            local tool_records: {{[string]: unknown}} = {}
            local result_record_indices: {integer} = {}
            for index, tc in ipairs(calls) do
                local call_record, call_error = output_record("tool_call:" .. attempt_id .. ":" .. tostring(turn_sequence) .. ":" .. tc.id,
                    {type = "tool_call", id = tc.id, tool = tc.name, input = decoded_arguments[index]})
                if not call_record then return settle("failed", final_answer, tostring(call_error)) end
                tool_records[#tool_records + 1] = call_record
                local result_record, result_error = output_record("tool_result:" .. attempt_id .. ":" .. tostring(turn_sequence) .. ":" .. tc.id,
                    {type = "tool_result", id = tc.id, tool = tc.name, outcome = "failed",
                        output = string.rep("x", M.MAX_TOOL_EVENT_OUTPUT_BYTES)})
                if not result_record then return settle("failed", final_answer, tostring(result_error)) end
                tool_records[#tool_records + 1] = result_record
                result_record_indices[index] = #tool_records
            end
            local prospective_events, events_error = canonical.encode(tool_records)
            if not prospective_events or #prospective_events > M.MAX_TOOL_EVENT_BATCH_BYTES then
                return settle("failed", final_answer, "prospective tool events exceed " .. tostring(M.MAX_TOOL_EVENT_BATCH_BYTES)
                    .. " bytes: " .. tostring(events_error or ""))
            end

            messages = prospective_messages
            local first_result_message = #messages - #calls + 1
            for index, tc in ipairs(calls) do
                local decoded_args = decoded_arguments[index]
                local fn_name = tc.name
                local matched_tool = tool_map[fn_name]
                local ok_exec, tool_output
                if matched_tool then
                    ok_exec, tool_output = M.execute_tool(matched_tool, decoded_args, attempt_id, workspace_id)
                else
                    ok_exec = false
                    tool_output = {code = "NOT_FOUND", message = "tool " .. fn_name .. " is not admitted in the agent capability grant"}
                end
                local output_encoded, output_error = canonical.encode(tool_output)
                if not output_encoded or #output_encoded > M.MAX_TOOL_EVENT_OUTPUT_BYTES then
                    ok_exec = false
                    tool_output = {code = "OUTPUT_TOO_LARGE", message = "tool result exceeds " .. tostring(M.MAX_TOOL_EVENT_OUTPUT_BYTES) .. " bytes"}
                end

                local result_record, result_error = output_record("tool_result:" .. attempt_id .. ":" .. tostring(turn_sequence) .. ":" .. tc.id,
                    {type = "tool_result", id = tc.id, tool = fn_name, outcome = ok_exec and "succeeded" or "failed", output = tool_output})
                if not result_record then
                    return settle("failed", final_answer, "encode tool result: " .. tostring(result_error))
                end
                tool_records[result_record_indices[index]] = result_record
                messages[first_result_message + index - 1] = {role = "tool", tool_call_id = tc.id,
                    content = encode_tool_output(tool_output)}
            end

            local committed, commit_err = commit(idempotency_key .. "-turn-" .. tostring(turn_sequence), tool_records, nil)
            if not committed then
                return settle("failed", final_answer, "commit turn records: " .. tostring(commit_err))
            end
        else
            if resp.content then
                final_answer = truncate_text(tostring(resp.content), M.MAX_TEXT_BYTES)
                messages[#messages + 1] = {role = "assistant", content = final_answer}

                local answer_record = {
                    source = "bee",
                    body = {
                        type = "extension",
                        event_key = "answer:" .. attempt_id .. ":" .. tostring(turn_sequence),
                        data = {
                            type = "extension",
                            event_name = "bee.carrier.output",
                            event_revision = "1",
                            payload_json = json.encode({
                                type = "text",
                                text = final_answer,
                                channel = "answer",
                            }),
                        },
                    },
                }

                if not checkpoint_fits(messages) then
                    return settle("failed", final_answer, "checkpoint exceeds " .. tostring(M.MAX_CHECKPOINT_BYTES) .. " bytes")
                end

                local committed, commit_err = commit(idempotency_key .. "-ans-" .. tostring(turn_sequence), {answer_record}, {outcome = "succeeded", answer = final_answer})
                if not committed then
                    return settle("failed", final_answer, "commit answer record: " .. tostring(commit_err))
                end
            end

            local inbox = M.process_inbox(thread_id, action_id, attempt_id, epoch, idempotency_key,
                function(operation: string, value: {[string]: unknown}): (unknown, string?)
                    return call_func(THREADS .. ":" .. operation, value)
                end)
            if inbox.kind == "failed" then return settle(inbox.outcome, final_answer, inbox.message) end
            if inbox.kind == "empty" then return settle("succeeded", final_answer) end
            local user_text: string
            if inbox.content.text then
                user_text = truncate_text(inbox.content.text, M.MAX_TEXT_BYTES)
            else
                user_text = "Delivered artifact " .. truncate_text(inbox.content.artifact_ref or "", 512) .. "."
            end
            messages[#messages + 1] = {role = "user", content = user_text}
        end
    end

    return settle("failed", final_answer, "execution loop ended without a terminal response")

end

return M
