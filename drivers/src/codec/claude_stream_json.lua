-- MIT. Claude Code stream-json (protocol revision stream-json-2) into thread
-- observations. The only terminal report is the result envelope; a stream
-- that ends without one is uncertain, whatever the process exit says.
local events_types = require("events_types")
local json = require("json")
local events = require("events")
local types = require("types")
local bounds = require("bounds")
local path_reader = require("paths")
local M = {}
M.PROTOCOL_REVISION = "stream-json-2"
M.MAX_ANSWER_BYTES = events.MAX_TEXT_BYTES
type Observation = {[string]: unknown}
-- api_error: the error kind of the last assistant message Claude Code
-- synthesized from a failed API call, such as authentication_failed.
type State = {
    session_id: string?,
    started: boolean,
    resumed: boolean,
    api_error: string?,
    message_id: string?,
    rate_limits: types.RateLimits?,
    usage: types.Usage?,
    terminal: types.Terminal?,
}
type Step = {observations: {Observation}, terminal: types.Terminal?}
function M.new(resumed: boolean): State
    return {started = false, resumed = resumed}
end
function M.decode_state(value: unknown): (State?, string?)
    local object = bounds.object(value)
    if not object then return nil, "state must be an object" end
    local unknown = bounds.fields(object, {"session_id", "started", "resumed", "api_error", "terminal", "message_id", "rate_limits", "usage"})
    if unknown then return nil, "state: " .. unknown end
    if type(object.started) ~= "boolean" or type(object.resumed) ~= "boolean" then return nil, "state flags must be booleans" end
    local session_id: string? = nil
    if object.session_id ~= nil then
        session_id = bounds.id(object.session_id)
        if not session_id then return nil, "state.session_id is not an identifier" end
    end
    local api_error: string? = nil
    if object.api_error ~= nil then
        api_error = bounds.id(object.api_error)
        if not api_error then return nil, "state.api_error is not an identifier" end
    end
    local message_id: string? = nil
    if object.message_id ~= nil then
        message_id = bounds.id(object.message_id)
        if not message_id then return nil, "state.message_id is invalid" end
    end
    local usage, usage_error = events.decode_usage(object.usage)
    if usage_error then return nil, usage_error end
    local rate_limits, limits_error = events.decode_limits(object.rate_limits)
    if limits_error then return nil, limits_error end
    local terminal: types.Terminal? = nil
    if object.terminal ~= nil then
        local decoded, terminal_error = types.decode_terminal(object.terminal)
        if not decoded then return nil, terminal_error end
        terminal = decoded
    end
    return {session_id = session_id, started = object.started, resumed = object.resumed, api_error = api_error, terminal = terminal, message_id = message_id, rate_limits = rate_limits, usage = usage}, nil
end
-- retryable reports whether a failed turn may succeed when repeated: the
-- HTTP status of the failed API call decides when Claude Code reports one -
-- a rate limit or a server fault, never a refused credential or request.
local function retryable(reason: string, status: unknown): boolean
    local code = tonumber(status)
    if code then return code == 429 or code >= 500 end
    return reason == "api_error" or reason == "rate_limit"
end
local function key(index: integer, suffix: string): string
    return "claude:" .. tostring(index) .. ":" .. suffix
end
local function text_of(value: unknown): string
    if type(value) == "string" then return value end
    if type(value) == "table" then
        local parts: {string} = {}
        for _, block in ipairs(value) do
            if type(block) == "table" then
                local piece: unknown = (block).text
                if type(piece) == "string" then parts[#parts + 1] = piece end
            end
        end
        if #parts > 0 then return table.concat(parts, "\n") end
        local encoded, err = json.encode(value)
        if not err and encoded then return encoded end
    end
    return tostring(value)
end
local function usage_of(value: unknown, cost: unknown, model_usage: unknown): events_types.Usage?
    local usage = bounds.object(value) or {}
    local details = bounds.object(usage.output_tokens_details) or {}
    local total = events.usage(usage.input_tokens, usage.output_tokens, usage.cache_read_input_tokens,
        usage.cache_creation_input_tokens, details.thinking_tokens, cost)
    local models = bounds.object(model_usage)
    if models then
        local decoded: {[string]: events_types.ModelUsage} = {}
        for model, raw in pairs(models) do
            local item = bounds.object(raw)
            if item and bounds.model(model) then
                local mapped = events.usage(item.inputTokens, item.outputTokens, item.cacheReadInputTokens,
                    item.cacheCreationInputTokens, item.thinkingTokens, item.costUSD)
                if mapped then decoded[model] = mapped end
            end
        end
        if next(decoded) then total = total or {}; total.models = decoded end
    end
    return total
end
local function rate_limits_of(value: unknown): types.RateLimits?
    local info = bounds.object(value)
    if not info then return nil end
    local limits: types.RateLimits = {windows = {}}
    local windows = bounds.object(info.unifiedWindows)
    if windows then
        local names: {string} = {}
        for name in pairs(windows) do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do
            local item = bounds.object(windows[name])
            if item then
                local window = events.limit_window(name, item.utilization, item.status or (name == info.rateLimitType and info.status or nil), item.resetsAt, nil)
                if window then limits.windows[#limits.windows + 1] = window end
            end
        end
    elseif type(info.rateLimitType) == "string" then
        local window = events.limit_window(info.rateLimitType, info.utilization, info.status, info.resetsAt, nil)
        if window then limits.windows[1] = window end
    end
    limits.overage_status = events.limit_status(info.overageStatus)
    limits.overage_disabled_reason = bounds.id(info.overageDisabledReason)
    if type(info.isUsingOverage) == "boolean" then limits.is_using_overage = info.isUsingOverage end
    return limits
end
local function content_blocks(state: State, index: integer, message: unknown, assistant: boolean, out: {Observation})
    if type(message) ~= "table" then return end
    local content: unknown = (message).content
    if type(content) ~= "table" then return end
    for position, block in ipairs(content) do
        if type(block) == "table" then
            local item = block
            local suffix = "block" .. tostring(position)
            if item.type == "text" and type(item.text) == "string" then
                local segment = "assistant:" .. tostring(index) .. ":" .. tostring(position)
                if assistant then
                    local id = bounds.id(message.id) or state.message_id
                    if id then segment = events.segment_id(id, tostring(position - 1)) end
                end
                for _, piece in ipairs(events.text(key(index, suffix), segment, "complete", item.text, "answer")) do out[#out + 1] = piece end
            elseif item.type == "tool_use" and type(item.id) == "string" and type(item.name) == "string" then
                local input_text = "{}"
                local encoded, err = json.encode(item.input)
                if not err and encoded then input_text = encoded end
                out[#out + 1] = events.tool_call(key(index, suffix), item.id, item.name, input_text)
            elseif item.type == "tool_result" and type(item.tool_use_id) == "string" then
                local outcome = "succeeded"
                local fault: {code: string, message: string, retryable: boolean}? = nil
                if item.is_error == true then
                    outcome = "failed"
                    fault = events.fault("tool_error", text_of(item.content), false)
                end
                out[#out + 1] = events.tool_result(key(index, suffix), item.tool_use_id, outcome, text_of(item.content), fault)
            elseif item.type == "thinking" then
                local summary: unknown = item.thinking
                if type(summary) == "string" and #summary > 0 then
                    for _, piece in ipairs(events.text(key(index, suffix), events.segment_id(bounds.id(message.id) or state.message_id or ("thinking:" .. tostring(index)), tostring(position - 1)), "complete", summary, "reasoning_summary")) do out[#out + 1] = piece end
                end
            end
        end
    end
end
-- One envelope in, observations out; the terminal report only from result.
function M.normalize(state: State, index: integer, envelope: {[string]: unknown}, paths: {[string]: unknown}?): Step
    local out: {Observation} = {}
    local kind: unknown = envelope.type
    if state.terminal then
        out[#out + 1] = events.notice(key(index, "after-result"), "warning", "after_result", "envelope after the result: " .. tostring(kind))
        return {observations = out}
    end
    if kind == "system" then
        local subtype: unknown = envelope.subtype
        if subtype == "init" then
            local session: unknown = path_reader.read(envelope, paths, "resume_id")
            if type(session) == "string" then state.session_id = session end
            state.started = true
            local phase = "started"
            if state.resumed then phase = "resumed" end
            out[#out + 1] = events.session(key(index, "init"), phase, state.session_id)
            out[#out + 1] = events.turn(key(index, "turn"), "started", nil, nil)
        elseif subtype == "permission_denied" then
            out[#out + 1] = events.notice(key(index, "denied"), "warning", "permission_denied", tostring(envelope.tool_name) .. ": " .. tostring(envelope.message))
        elseif subtype == "api_retry" then
            out[#out + 1] = events.notice(key(index, "retry"), "warning", "api_retry", tostring(envelope.error) .. " attempt " .. tostring(envelope.attempt))
        elseif subtype == "informational" then
            local level = "info"
            if envelope.level == "warning" then level = "warning" end
            out[#out + 1] = events.notice(key(index, "info"), level, "informational", text_of(envelope.content))
        elseif subtype == "compact_boundary" then
            out[#out + 1] = events.notice(key(index, "compact"), "info", "compact_boundary", "context compacted")
        else
            local encoded, err = json.encode(envelope)
            out[#out + 1] = events.extension(key(index, "system"), "claude.system." .. tostring(subtype), M.PROTOCOL_REVISION, (not err and encoded) or "{}")
        end
    elseif kind == "assistant" or kind == "user" then
        if kind == "assistant" and envelope.is_api_error_message == true and type(envelope.error) == "string" then
            state.api_error = bounds.id(envelope.error)
        end
        content_blocks(state, index, envelope.message, kind == "assistant", out)
        if kind == "assistant" then
            local message = bounds.object(envelope.message)
            if message then state.usage = events.add_usage(state.usage, events.model_usage(usage_of(message.usage, nil, nil), message.model)) end
            state.message_id = nil
        end
    elseif kind == "stream_event" then
        local event: unknown = envelope.event
        if type(event) == "table" then
            local inner = event
            if inner.type == "message_start" then
                local message = bounds.object(inner.message)
                state.message_id = (message and bounds.id(message.id)) or ("message:" .. tostring(index))
            elseif inner.type == "content_block_delta" and type(inner.delta) == "table" then
                local delta = inner.delta
                local text = delta.type == "text_delta" and delta.text or delta.type == "thinking_delta" and delta.thinking or nil
                if type(text) == "string" then
                    state.message_id = state.message_id or ("message:" .. tostring(index))
                    local segment = events.segment_id(state.message_id, tostring(inner.index))
                    local channel = delta.type == "text_delta" and "answer" or "reasoning_summary"
                    for _, piece in ipairs(events.text(key(index, "delta"), segment, "append", text, channel)) do out[#out + 1] = piece end
                end
            end
        end
    elseif kind == "rate_limit_event" then
        local limits = rate_limits_of(envelope.rate_limit_info)
        if limits then
            state.rate_limits = limits
            out[#out + 1] = events.rate_limit(key(index, "limits"), limits)
        end
    elseif kind == "result" then
        local session: unknown = path_reader.read(envelope, paths, "resume_id")
        if type(session) == "string" then state.session_id = session end
        local is_error = envelope.is_error == true
        local subtype: unknown = envelope.subtype
        local outcome = "succeeded"
        local fault: {code: string, message: string, retryable: boolean}? = nil
        if is_error or subtype ~= "success" then
            outcome = "failed"
            local raw_reason = path_reader.read(envelope, paths, "errors")
            local reason = tostring(raw_reason or subtype or "error")
            fault = events.fault(state.api_error or reason, text_of(path_reader.read(envelope, paths, "result_text")),
                retryable(reason, envelope.api_error_status))
            local status = tonumber(envelope.api_error_status)
            if events.rejected(state.rate_limits) and (status == nil or status == 429) and (not state.api_error or state.api_error == "rate_limit") then fault = events.fault("rate_limit", text_of(path_reader.read(envelope, paths, "result_text")), true) end
        end
        local denials: unknown = envelope.permission_denials
        if type(denials) == "table" then
            for position, denial in ipairs(denials) do
                if type(denial) == "table" then
                    local item = denial
                    out[#out + 1] = events.notice(key(index, "denial" .. tostring(position)), "warning", "permission_denied", tostring(item.tool_name) .. " " .. tostring(item.tool_use_id))
                end
            end
        end
        local usage = events.merge_usage(state.usage, usage_of(path_reader.read(envelope, paths, "usage"), envelope.total_cost_usd, envelope.modelUsage))
        out[#out + 1] = events.turn(key(index, "turn"), "ended", outcome, usage)
        local answer: string? = nil
        local result = path_reader.read(envelope, paths, "result_text")
        if outcome == "succeeded" and type(result) == "string" and #result <= M.MAX_ANSWER_BYTES then answer = result end
        state.terminal = {outcome = outcome, answer = answer, resume_ref = state.session_id, usage = usage, error = fault, rate_limits = state.rate_limits}
        return {observations = out, terminal = state.terminal}
    else
        local encoded, err = json.encode(envelope)
        out[#out + 1] = events.extension(key(index, "event"), "claude." .. tostring(kind), M.PROTOCOL_REVISION, (not err and encoded) or "{}")
    end
    return {observations = out}
end
-- The stream ended: without a result the turn is uncertain; the process
-- exit never turns that into success.
function M.finish(state: State, index: integer): Step
    if state.terminal then
        local none: {Observation} = {}
        local quiet: Step = {observations = none}
        return quiet
    end
    local out: {Observation} = {events.turn(key(index, "eof"), "ended", "uncertain", state.usage)}
    local terminal: types.Terminal = {outcome = "uncertain", resume_ref = state.session_id, rate_limits = state.rate_limits, usage = state.usage, error = events.fault("stream_ended", "the stream ended without a result envelope", false)}
    state.terminal = terminal
    return {observations = out, terminal = terminal}
end
return M
