-- MIT. Antigravity CLI stream-json protocol normalization into thread observations.
-- The only terminal report is the result envelope; a stream that ends without
-- one is uncertain, whatever the process exit says.
local json = require("json")
local events = require("events")
local types = require("types")
local bounds = require("bounds")

local M = {}
M.PROTOCOL_REVISION = "agy-stream-json-1"
-- Agy's stream transport rejects frames larger than this bound. Keeping the
-- same ceiling here lets direct callers receive every bounded text frame while
-- refusing an envelope that bypassed transport framing.
M.MAX_FRAME_BYTES = 1048576
M.MAX_ANSWER_BYTES = events.MAX_TEXT_BYTES

type Observation = {[string]: unknown}
type State = {
    session_id: string?,
    started: boolean,
    resumed: boolean,
    terminal: types.Terminal?,
    answer: string?,
    answer_truncated: boolean,
}
type Step = {observations: {Observation}, terminal: types.Terminal?}

local function decode_fault(value: unknown, field: string): ({code: string, message: string, retryable: boolean}?, string?)
    if value == nil then return nil, nil end
    local object = bounds.object(value)
    if not object then return nil, field .. " must be an object" end
    local unknown_field = bounds.fields(object, {"code", "message", "retryable"})
    if unknown_field then return nil, field .. ": " .. unknown_field end
    local code = bounds.id(object.code)
    if not code then return nil, field .. ".code is not an identifier" end
    local message = bounds.text(object.message, bounds.MAX_FAULT_MESSAGE_BYTES)
    if not message then return nil, field .. ".message exceeds maximum fault message bytes" end
    if type(object.retryable) ~= "boolean" then return nil, field .. ".retryable must be a boolean" end
    return {code = code, message = message, retryable = object.retryable :: boolean}, nil
end

local function decode_usage(value: unknown, field: string, provider_wire: boolean?): ({[string]: unknown}?, string?)
    if value == nil then return nil, nil end
    local object = bounds.object(value)
    if not object then return nil, field .. " must be an object" end
    local allowed_fields = {"input_tokens", "output_tokens", "cached_tokens", "cost_decimal", "currency"}
    if provider_wire then
        -- These counters occur in Agy's captured result frames but are not
        -- part of Bee's portable usage record. Validate them before dropping.
        allowed_fields[#allowed_fields + 1] = "cache_read_tokens"
        allowed_fields[#allowed_fields + 1] = "thinking_tokens"
        allowed_fields[#allowed_fields + 1] = "total_tokens"
    end
    local unknown_field = bounds.fields(object, allowed_fields)
    if unknown_field then return nil, field .. ": " .. unknown_field end
    local usage: {[string]: unknown} = {}
    for _, name in ipairs({"input_tokens", "output_tokens", "cached_tokens"}) do
        local raw: unknown = object[name]
        if raw ~= nil then
            local count = bounds.count(raw)
            if not count then return nil, field .. "." .. name .. " must be a nonnegative integer" end
            usage[name] = count
        end
    end
    if provider_wire then
        local cache_read: unknown = object.cache_read_tokens
        if cache_read ~= nil then
            local count = bounds.count(cache_read)
            if not count then return nil, field .. ".cache_read_tokens must be a nonnegative integer" end
            if object.cached_tokens ~= nil and usage.cached_tokens ~= count then
                return nil, field .. ".cached_tokens conflicts with cache_read_tokens"
            end
            if usage.cached_tokens == nil then usage.cached_tokens = count end
        end
        for _, name in ipairs({"thinking_tokens", "total_tokens"}) do
            local raw: unknown = object[name]
            if raw ~= nil and not bounds.count(raw) then
                return nil, field .. "." .. name .. " must be a nonnegative integer"
            end
        end
    end
    local cost: unknown, currency: unknown = object.cost_decimal, object.currency
    if (cost == nil) ~= (currency == nil) then
        return nil, field .. ".cost_decimal and currency come together"
    end
    if cost ~= nil then
        if type(cost) ~= "string" or not cost:match("^%d+%.?%d*$") or #cost > 40 then
            return nil, field .. ".cost_decimal must be a decimal string"
        end
        if type(currency) ~= "string" or not currency:match("^%u%u%u$") then
            return nil, field .. ".currency must be a three-letter code"
        end
        usage.cost_decimal = cost
        usage.currency = currency
    end
    return usage, nil
end

local function decode_terminal(value: unknown): (types.Terminal?, string?)
    local object = bounds.object(value)
    if not object then return nil, "state.terminal must be an object" end
    local unknown_field = bounds.fields(object, {"outcome", "answer", "resume_ref", "usage", "error"})
    if unknown_field then return nil, "state.terminal: " .. unknown_field end
    local declared_outcome = bounds.member(object.outcome, {"succeeded", "failed", "cancelled", "uncertain"})
    if not declared_outcome then return nil, "state.terminal.outcome is not one outcome Bee admits" end
    local outcome: types.Outcome = declared_outcome :: types.Outcome

    local answer: string? = nil
    if object.answer ~= nil then
        answer = bounds.text(object.answer, bounds.MAX_RECORD_BYTES)
        if not answer then return nil, "state.terminal.answer exceeds maximum record bytes" end
    end
    local resume_ref: string? = nil
    if object.resume_ref ~= nil then
        resume_ref = bounds.id(object.resume_ref)
        if not resume_ref then return nil, "state.terminal.resume_ref is not an identifier" end
    end
    local usage, usage_error = decode_usage(object.usage, "state.terminal.usage")
    if usage_error then return nil, usage_error end
    local fault, fault_error = decode_fault(object.error, "state.terminal.error")
    if fault_error then return nil, fault_error end
    local terminal: types.Terminal = {
        outcome = outcome,
        answer = answer,
        resume_ref = resume_ref,
        usage = usage,
        error = fault,
    }
    return terminal, nil
end

function M.new(resumed: boolean): State
    return {
        started = false,
        resumed = resumed,
        answer_truncated = false,
    }
end

function M.validate_state(value: unknown): (State?, string?)
    local object = bounds.object(value)
    if not object then return nil, "state must be an object" end
    local unknown_field = bounds.fields(object, {"session_id", "started", "resumed", "terminal", "answer", "answer_truncated"})
    if unknown_field then return nil, "state: " .. unknown_field end

    local session_id: string? = nil
    if object.session_id ~= nil then
        session_id = bounds.id(object.session_id)
        if not session_id then return nil, "state.session_id is not an identifier" end
    end

    if type(object.started) ~= "boolean" then
        return nil, "state.started must be a boolean"
    end

    if type(object.resumed) ~= "boolean" then
        return nil, "state.resumed must be a boolean"
    end

    if type(object.answer_truncated) ~= "boolean" then
        return nil, "state.answer_truncated must be a boolean"
    end

    local terminal: types.Terminal? = nil
    if object.terminal ~= nil then
        local decoded, terminal_error = decode_terminal(object.terminal)
        if not decoded then return nil, terminal_error end
        terminal = decoded
    end

    local answer: string? = nil
    if object.answer ~= nil then
        answer = bounds.text(object.answer, M.MAX_ANSWER_BYTES)
        if not answer then return nil, "state.answer exceeds maximum record bytes" end
    end
    if object.answer_truncated == true and answer ~= nil then
        return nil, "state.answer must be absent after truncation"
    end

    return {
        session_id = session_id,
        started = object.started :: boolean,
        resumed = object.resumed :: boolean,
        terminal = terminal,
        answer = answer,
        answer_truncated = object.answer_truncated :: boolean,
    }, nil
end

local function key(index: integer, suffix: string): string
    return "agy:" .. tostring(index) .. ":" .. suffix
end

local function text_of(value: unknown): string
    if type(value) == "string" then return value end
    if type(value) == "table" then
        local encoded, err = json.encode(value)
        if not err and encoded then return encoded end
    end
    return tostring(value)
end

local function event_body(envelope: {[string]: unknown}, event_name: string): {[string]: unknown}
    local nested = envelope[event_name]
    if type(nested) == "table" then return nested :: {[string]: unknown} end
    return envelope
end

local function extract_cid(envelope: {[string]: unknown}, body: {[string]: unknown}): (string?, string?)
    local envelope_raw: unknown = envelope.conversation_id
    local body_raw: unknown = nil
    if body ~= envelope then body_raw = body.conversation_id end
    local envelope_cid: string? = nil
    if envelope_raw ~= nil then
        envelope_cid = bounds.id(envelope_raw)
        if not envelope_cid then return nil, "envelope conversation_id is not an identifier" end
    end
    local body_cid: string? = nil
    if body_raw ~= nil then
        body_cid = bounds.id(body_raw)
        if not body_cid then return nil, "body conversation_id is not an identifier" end
    end
    if envelope_cid and body_cid and envelope_cid ~= body_cid then
        return nil, "envelope and body conversation_id conflict"
    end
    return envelope_cid or body_cid, nil
end

function M.normalize(state: State, index: integer, envelope: {[string]: unknown}): Step
    local out: {Observation} = {}
    local raw_kind: unknown = envelope.event
    local kind = tostring(raw_kind or "")

    if state.terminal then
        out[#out + 1] = events.notice(key(index, "after-result"), "warning", "after_result", "envelope after the result: " .. kind)
        return {observations = out}
    end

    local body = event_body(envelope, kind)
    local envelope_cid, identity_error = extract_cid(envelope, body)
    if identity_error then
        if kind == "result" then
            local code = "malformed_identity"
            if identity_error == "envelope and body conversation_id conflict" then code = "conflicting_conversation_id" end
            local fault = events.fault(code, identity_error, false)
            state.terminal = {outcome = "failed", resume_ref = state.session_id, error = fault}
            out[#out + 1] = events.turn(key(index, "turn"), "ended", "failed", nil)
            return {observations = out, terminal = state.terminal}
        end
        local code = "malformed_identity"
        if kind == "init" then code = "malformed_init" end
        out[#out + 1] = events.notice(key(index, "identity"), "warning", code, identity_error)
        return {observations = out}
    end

    -- Pin conversation identity on init; refuse conflicting later IDs.
    if kind == "init" then
        if not envelope_cid then
            -- Malformed init: missing valid conversation identity. Must not claim readiness.
            out[#out + 1] = events.notice(key(index, "init"), "warning", "malformed_init", "init envelope missing valid conversation_id")
            return {observations = out}
        end
        if state.session_id ~= nil and state.session_id ~= envelope_cid then
            out[#out + 1] = events.notice(key(index, "conflict"), "warning", "conflicting_conversation_id", "init conversation_id " .. envelope_cid .. " does not match pinned " .. state.session_id)
            return {observations = out}
        end
        state.session_id = envelope_cid
        state.started = true
        local phase = state.resumed and "resumed" or "started"
        out[#out + 1] = events.session(key(index, "init"), phase, state.session_id)
        out[#out + 1] = events.turn(key(index, "turn"), "started", nil, nil)
        return {observations = out}
    end

    -- Refuse conflicting later conversation IDs
    if envelope_cid and state.session_id and envelope_cid ~= state.session_id then
        out[#out + 1] = events.notice(key(index, "conflict"), "warning", "conflicting_conversation_id", "envelope conversation_id " .. envelope_cid .. " does not match pinned " .. state.session_id)
        if kind == "result" then
            local fault = events.fault("conflicting_conversation_id", "result conversation_id " .. envelope_cid .. " does not match pinned " .. state.session_id, false)
            state.terminal = {
                outcome = "failed",
                resume_ref = state.session_id,
                error = fault,
            }
            out[#out + 1] = events.turn(key(index, "turn"), "ended", "failed", nil)
            return {observations = out, terminal = state.terminal}
        end
        return {observations = out}
    end

    if kind == "step_update" then
        local step_type = tostring(body.step_type or "")
        local step_index = body.step_index
        local seg_suffix = type(step_index) == "number" and tostring(step_index) or tostring(index)

        if step_type == "agent_response" then
            if type(body.text_delta) == "string" and #body.text_delta > 0 then
                local delta = body.text_delta
                if #delta > M.MAX_FRAME_BYTES then
                    out[#out + 1] = events.notice(key(index, "answer-bound"), "warning", "oversized_text_delta", "Agy text_delta exceeds the stream frame bound and was refused")
                else
                    local segment = "assistant:" .. seg_suffix
                    for _, piece in ipairs(events.text(key(index, "delta"), segment, "append", delta, "answer")) do
                        out[#out + 1] = piece
                    end
                    if not state.answer_truncated then
                        local current = state.answer or ""
                        local answer = current .. delta
                        if #answer <= M.MAX_ANSWER_BYTES then
                            state.answer = answer
                        else
                            state.answer = nil
                            state.answer_truncated = true
                            out[#out + 1] = events.notice(key(index, "answer-bound"), "warning", "answer_truncated", "Agy answer exceeded the retained answer bound; text observations remain complete")
                        end
                    end
                end
            end
            if body.thinking ~= nil then
                local summary = text_of(body.thinking)
                if #summary > 0 then
                    if #summary > M.MAX_FRAME_BYTES then
                        out[#out + 1] = events.notice(key(index, "summary-bound"), "warning", "oversized_thinking", "Agy thinking summary exceeds the stream frame bound and was refused")
                    else
                        local segment = "thinking:" .. seg_suffix
                        for _, piece in ipairs(events.text(key(index, "thinking"), segment, "complete", summary, "reasoning_summary")) do
                            out[#out + 1] = piece
                        end
                    end
                end
            end
        elseif step_type == "system_message" then
            local msg = text_of(body.message or "")
            if #msg > 0 then
                out[#out + 1] = events.notice(key(index, "system"), "info", "system_message", msg)
            end
        elseif step_type == "tool_call" or body.tool_name ~= nil then
            local tool_name = tostring(body.tool_name or "tool")
            local call_id = tostring(body.call_id or ("call-" .. seg_suffix))

            local item_state = tostring(body.state or "")
            if item_state == "ACTIVE" then
                local params = "{}"
                if body.parameters ~= nil then
                    local encoded, err = json.encode(body.parameters)
                    if not err and encoded then params = encoded end
                elseif type(body.args) == "string" then
                    params = body.args
                elseif type(body.command) == "string" then
                    params = body.command
                end
                out[#out + 1] = events.tool_call(key(index, "tool_call"), call_id, tool_name, params)
            elseif item_state == "DONE" then
                local outcome = "succeeded"
                local fault: {code: string, message: string, retryable: boolean}? = nil
                local err_obj = body.error
                if err_obj ~= nil or body.is_error == true then
                    outcome = "failed"
                    local msg = type(err_obj) == "table" and tostring((err_obj :: {[string]: unknown}).message or (err_obj :: {[string]: unknown}).type or "tool error") or tostring(err_obj or "tool error")
                    fault = events.fault("tool_error", msg, false)
                end
                local output_text = ""
                if body.output ~= nil then
                    output_text = text_of(body.output)
                end
                out[#out + 1] = events.tool_result(key(index, "tool_result"), call_id, outcome, output_text, fault)
            end
        end

        if body.permission_denials ~= nil then
            out[#out + 1] = events.notice(key(index, "denied"), "warning", "permission_denied", text_of(body.permission_denials))
        end
    elseif kind == "result" then
        local raw_status = string.upper(tostring(body.status or envelope.status or ""))
        local outcome = "succeeded"
        local fault: {code: string, message: string, retryable: boolean}? = nil
        local decoded_usage, usage_error = decode_usage(body.usage or envelope.usage, "result.usage", true)

        local is_malformed = false
        if not state.started then
            is_malformed = true
            fault = events.fault("unstarted_session", "result received before session was started", false)
        elseif type(envelope.result) ~= "table" and envelope.result ~= nil then
            is_malformed = true
            fault = events.fault("malformed_result", "result body must be an object", false)
        elseif type(envelope.result) ~= "table" then
            is_malformed = true
            fault = events.fault("malformed_result", "result envelope is missing its body", false)
        elseif envelope_cid == nil and state.session_id == nil then
            is_malformed = true
            fault = events.fault("missing_conversation_id", "result missing conversation identity", false)
        elseif usage_error then
            is_malformed = true
            fault = events.fault("malformed_usage", usage_error, false)
        elseif body.status == nil or type(body.status) ~= "string" then
            is_malformed = true
            fault = events.fault("malformed_result", "result status must be a string", false)
        elseif body.response ~= nil and type(body.response) ~= "string" then
            is_malformed = true
            fault = events.fault("malformed_result", "result response must be text", false)
        elseif body.error ~= nil and type(body.error) ~= "string" and type(body.error) ~= "table" then
            is_malformed = true
            fault = events.fault("malformed_result", "result error must be text or an object", false)
        elseif body.error ~= nil and raw_status == "SUCCESS" then
            is_malformed = true
            fault = events.fault("status_error_mismatch", text_of(body.error), false)
        elseif raw_status == "SUCCESS" and type(body.response) ~= "string" then
            is_malformed = true
            fault = events.fault("malformed_result", "successful result is missing response text", false)
        end

        if is_malformed then
            outcome = "failed"
        elseif raw_status == "SUCCESS" then
            outcome = "succeeded"
        elseif raw_status == "ERROR" or raw_status == "FAILED" then
            outcome = "failed"
            local reason = tostring(body.terminal_reason or raw_status:lower())
            fault = events.fault(reason, text_of(body.error or body.response or "turn failed"), false)
        elseif raw_status == "CANCELED" or raw_status == "CANCELLED" or raw_status == "INTERRUPTED" then
            outcome = "cancelled"
            fault = events.fault("cancelled", text_of(body.error or "turn cancelled"), false)
        else
            outcome = "uncertain"
            fault = events.fault("unknown_status", "unexpected terminal status: " .. raw_status, false)
        end

        local usage = decoded_usage
        out[#out + 1] = events.turn(key(index, "turn"), "ended", outcome, usage)

        local answer: string? = nil
        if outcome == "succeeded" then
            if type(body.response) == "string" then
                if #body.response <= M.MAX_ANSWER_BYTES then
                    answer = body.response
                else
                    state.answer = nil
                    state.answer_truncated = true
                    out[#out + 1] = events.notice(key(index, "answer-bound"), "warning", "answer_truncated", "Agy result response exceeded the retained answer bound; text observations remain complete")
                end
            elseif not state.answer_truncated and state.answer and #state.answer > 0 then
                answer = state.answer
            end
        end

        state.terminal = {
            outcome = outcome :: types.Outcome,
            answer = answer,
            resume_ref = state.session_id,
            usage = usage,
            error = fault,
        }
        return {observations = out, terminal = state.terminal}
    else
        local encoded, err = json.encode(envelope)
        out[#out + 1] = events.extension(key(index, "event"), "agy." .. kind, M.PROTOCOL_REVISION, (not err and encoded) or "{}")
    end

    return {observations = out}
end

function M.finish(state: State, index: integer): Step
    if state.terminal then
        local none: {Observation} = {}
        local quiet: Step = {observations = none}
        return quiet
    end
    local out: {Observation} = {events.turn(key(index, "eof"), "ended", "uncertain", nil)}
    local terminal: types.Terminal = {
        outcome = "uncertain",
        resume_ref = state.session_id,
        error = events.fault("stream_ended", "the stream ended without a result envelope", false),
    }
    state.terminal = terminal
    return {observations = out, terminal = terminal}
end

return M
