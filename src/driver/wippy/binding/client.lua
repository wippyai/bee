-- MIT. OpenAI-compatible chat completions HTTP client for native Wippy driver.
local http_client = require("http_client")
local json = require("json")
local env = require("env")
local registry = require("registry")
local types = require("types")
local bounds = require("bounds")
local framing = require("framing")

local M = {}

M.MAX_URL_BYTES = 512
M.MAX_SSE_FRAME_BYTES = 65536
M.MAX_STREAM_BYTES = 4194304
M.MAX_TOOL_ARGUMENT_BYTES = 8192
M.MAX_TOOL_CALLS_PER_TURN = 16

type Object = {[string]: unknown}
type ParsedLine = {kind: "ignore"} | {kind: "done"} | {kind: "data", event: Object}
type StreamTool = {id: string, name: string, arguments: string}

-- A credential reference names host configuration, never a secret value: an
-- env.variable entry resolving to its declared variable, or a registry entry
-- carrying the token in its data. Anything else is unresolvable: the
-- reference string itself is never sent as a bearer key, and the key is
-- never logged or returned in an error.
function M.resolve_key(credential_ref: string?, workspace_id: string?): (string?, string?)
    if not credential_ref or credential_ref == "" then return nil, nil end

    local entry = registry.get(credential_ref)
    if entry then
        if entry.kind == "env.variable" and type(entry.data) == "table" then
            local data = entry.data
            if type(data.variable) == "string" and data.variable ~= "" then
                local name = data.variable
                local val, err = env.get(name)
                if not err and val and #val > 0 then return val, nil end
                return nil, "credential source " .. name .. " yields no value"
            end
            return nil, "credential entry " .. credential_ref .. " names no variable"
        elseif type(entry.data) == "table" then
            local d = entry.data
            local token = d.api_key or d.key or d.token or d.value
            if type(token) == "string" and #token > 0 then return token, nil end
            return nil, "credential entry " .. credential_ref .. " carries no key"
        end
        return nil, "credential entry " .. credential_ref .. " is not a key source"
    end

    return nil, "credential reference " .. credential_ref .. " is not in the registry"
end

function M.normalize_url(endpoint: string): string
    local url = endpoint
    if url:sub(-1) == "/" then url = url:sub(1, -2) end
    if not url:find("/chat/completions$", 1, false) then
        url = url .. "/chat/completions"
    end
    return url
end

local function parse_sse_line(line: string): (ParsedLine?, string?)
    if line == "" or line:sub(1, 1) == ":" then return {kind = "ignore"}, nil end
    local field, payload = line:match("^([^:]+):?(.*)$")
    if not field then return nil, "SSE line has no field" end
    if field ~= "data" then return {kind = "ignore"}, nil end
    if not payload then return nil, "SSE data field has no value" end
    if payload:sub(1, 1) == " " then payload = payload:sub(2) end
    if payload == "[DONE]" then return {kind = "done"}, nil end
    local decoded, err = json.decode(payload)
    local event = bounds.object(decoded)
    if err or not event then return nil, "decode SSE data: " .. tostring(err or "event must be an object") end
    return {kind = "data", event = event}, nil
end

type StreamRead = (integer) -> (string?, string?)
type StreamClose = () -> ()

local function decode_arguments(value: unknown): (string?, string?)
    local text = bounds.text(value, M.MAX_TOOL_ARGUMENT_BYTES)
    if not text then return nil, "tool arguments exceed their byte bound" end
    local first = text:match("^%s*(.)")
    if first ~= "{" then return nil, "tool arguments must be a JSON object" end
    local decoded, err = json.decode(text)
    if err or not bounds.object(decoded) then return nil, "tool arguments must be a JSON object: " .. tostring(err or "invalid object") end
    return text, nil
end

local function decode_tool_call(item: unknown): (types.ToolCall?, string?)
    local raw = bounds.object(item)
    if not raw then return nil, "tool call must be an object" end
    if bounds.fields(raw, {"id", "type", "function"}) then return nil, "tool call has unknown fields" end
    local id = bounds.id(raw.id)
    local fn = bounds.object(raw["function"])
    if not id or raw.type ~= "function" or not fn or bounds.fields(fn, {"name", "arguments"}) then
        return nil, "tool call identity or function is malformed"
    end
    local name = bounds.id(fn.name)
    local arguments, argument_error = decode_arguments(fn.arguments)
    if not name or not arguments then return nil, argument_error or "tool call name is invalid" end
    return {id = id, kind = "function", name = name, arguments = arguments}, nil
end

local function decode_message(message: unknown): (string?, {types.ToolCall}?, string?)
    local msg = bounds.object(message)
    if not msg then return nil, nil, "message is not an object" end
    if bounds.fields(msg, {"role", "content", "tool_calls", "refusal", "annotations"}) then return nil, nil, "message has unknown fields" end
    if msg.role ~= nil and msg.role ~= "assistant" then return nil, nil, "message role is not assistant" end
    local content: string? = nil
    if msg.content ~= nil then
        content = bounds.text(msg.content, M.MAX_STREAM_BYTES)
        if not content then return nil, nil, "message content is malformed or too large" end
    end
    local tools_list: {types.ToolCall}? = nil
    if msg.tool_calls ~= nil then
        local list, list_error = bounds.array(msg.tool_calls, M.MAX_TOOL_CALLS_PER_TURN)
        if not list then return nil, nil, "tool_calls: " .. tostring(list_error) end
        if #list > 0 then tools_list = {} end
        local seen: {[string]: boolean} = {}
        for index, item in ipairs(list) do
            local call, call_error = decode_tool_call(item)
            if not call then return nil, nil, "tool_calls[" .. tostring(index) .. "]: " .. tostring(call_error) end
            if seen[call.id] then return nil, nil, "tool call IDs must be unique" end
            seen[call.id] = true
            tools_list[#tools_list + 1] = call
        end
    end
    if content == nil and tools_list == nil then return nil, nil, "message has no content or tool calls" end
    return content, tools_list, nil
end

local function decode_choice(choice: unknown): ({[string]: unknown}?, string?)
    local object = bounds.object(choice)
    if not object then return nil, "choice is not an object" end
    return object, nil
end

function M.chat_completions(config: types.HostConfig, payload: types.ChatPayload, workspace_id: string?, cancel_check: (() -> boolean)?): (types.ChatResponse?, string?)
    local url = M.normalize_url(config.endpoint)
    local key: string? = nil
    if config.credential_ref and config.credential_ref ~= "" then
        local resolved, key_error = M.resolve_key(config.credential_ref, workspace_id)
        if not resolved then
            return nil, "resolve credential: " .. tostring(key_error)
        end
        key = resolved
    end

    local headers: {[string]: string} = {
        ["Content-Type"] = "application/json",
        ["Accept"] = payload.stream and "text/event-stream" or "application/json",
    }
    if key and #key > 0 then
        headers["Authorization"] = "Bearer " .. key
    end

    local encoded_body, encode_err = json.encode(payload)
    if not encoded_body then return nil, "encode request body: " .. tostring(encode_err) end

    local timeout = (config.timeout_ms and math.floor(config.timeout_ms / 1000) or 30)
    if timeout < 1 then timeout = 1 end
    if timeout > 120 then timeout = 120 end

    if payload.stream == true then
        return M.stream_completions(url, headers, encoded_body, timeout, cancel_check)
    end

    local resp, req_err = http_client.post(url, {
        headers = headers,
        body = encoded_body,
        timeout = timeout,
    })
    if req_err or not resp then return nil, tostring(req_err or "request failed") end
    if resp.status_code and resp.status_code >= 400 then
        return nil, "HTTP " .. tostring(resp.status_code)
    end

    local body = bounds.text(resp.body or "", M.MAX_STREAM_BYTES)
    if not body then return nil, "response exceeds " .. tostring(M.MAX_STREAM_BYTES) .. " bytes" end
    local body_data, dec_err = json.decode(body)
    local obj = bounds.object(body_data)
    if dec_err or not obj then return nil, "decode response: " .. tostring(dec_err or "response must be an object") end
    local choices = bounds.array(obj.choices, 16)
    if not choices or #choices == 0 then return nil, "response choices are malformed or missing" end

    local first, choice_err = decode_choice(choices[1])
    if not first then return nil, tostring(choice_err) end
    local content, tools_list, message_error = decode_message(first.message)
    if message_error then return nil, "decode response message: " .. message_error end
    local finish_reason: string? = nil
    if first.finish_reason ~= nil then
        finish_reason = bounds.text(first.finish_reason, 80)
        if not finish_reason then return nil, "response finish_reason is malformed" end
    end

    return {
        content = content,
        tool_calls = tools_list,
        finish_reason = finish_reason or "stop",
    }, nil
end

function M.stream_completions(url: string, headers: {[string]: string}, encoded_body: string, timeout: integer, cancel_check: (() -> boolean)?): (types.ChatResponse?, string?)
    local resp, req_err = http_client.post(url, {
        headers = headers,
        body = encoded_body,
        stream = true,
        timeout = timeout,
    })
    if req_err or not resp then return nil, tostring(req_err or "streaming request failed") end
    if resp.status_code and resp.status_code >= 400 then
        if resp.stream then resp.stream:close() end
        return nil, "HTTP " .. tostring(resp.status_code)
    end

    local stream = resp.stream
    if not stream then return nil, "no stream available on response" end

    return M.consume_stream(function(size: integer): (string?, string?)
        return stream:read(size)
    end, function()
        stream:close()
    end, cancel_check)
end

function M.consume_stream(read: StreamRead, close: StreamClose, cancel_check: (() -> boolean)?): (types.ChatResponse?, string?)
    local content_parts: {string} = {}
    local tool_map: {[integer]: StreamTool} = {}
    local finish_reason: string? = nil
    local framer = framing.new(M.MAX_SSE_FRAME_BYTES)
    local total_bytes = 0
    local done = false
    local closed = false

    local function close_stream()
        if closed then return end
        closed = true
        close()
    end

    local function consume_event(event: Object): string?
        local choices, choices_error = bounds.array(event.choices, 16)
        if not choices then
            if event.choices == nil and event.usage ~= nil then return nil end
            return "SSE choices: " .. tostring(choices_error or "missing choices")
        end
        if #choices == 0 then return nil end
        local choice = bounds.object(choices[1])
        if not choice then return "SSE choice must be an object" end
        local choice_extra = bounds.fields(choice, {"index", "delta", "finish_reason", "logprobs"})
        if choice_extra then return "SSE choice: " .. choice_extra end
        if choice.index ~= nil then
            local selected = bounds.integer(choice.index)
            if selected ~= 0 then return "SSE choice index is unsupported" end
        end
        if choice.finish_reason ~= nil then
            finish_reason = bounds.text(choice.finish_reason, 80)
            if not finish_reason then return "SSE finish_reason is malformed" end
        end
        local delta = bounds.object(choice.delta)
        if not delta then return "SSE delta must be an object" end
        local delta_extra = bounds.fields(delta, {"role", "content", "tool_calls", "refusal"})
        if delta_extra then return "SSE delta: " .. delta_extra end
        if delta.content ~= nil then
            local content = bounds.text(delta.content, M.MAX_STREAM_BYTES)
            if not content then return "SSE content fragment is malformed" end
            local size = #content
            for _, part in ipairs(content_parts) do size = size + #part end
            if size > M.MAX_STREAM_BYTES then return "SSE content exceeds " .. tostring(M.MAX_STREAM_BYTES) .. " bytes" end
            content_parts[#content_parts + 1] = content
        end
        if delta.tool_calls == nil then return nil end
        local deltas, delta_error = bounds.array(delta.tool_calls, M.MAX_TOOL_CALLS_PER_TURN)
        if not deltas then return "SSE tool_calls: " .. tostring(delta_error) end
        for _, item in ipairs(deltas) do
            local tool_delta = bounds.object(item)
            if not tool_delta then return "SSE tool call fragment must be an object" end
            local extra = bounds.fields(tool_delta, {"index", "id", "type", "function"})
            if extra then return "SSE tool call fragment: " .. extra end
            local index = bounds.integer(tool_delta.index)
            if not index or index < 0 or index >= M.MAX_TOOL_CALLS_PER_TURN then
                return "SSE tool call index is out of range"
            end
            local target = tool_map[index]
            if not target then
                target = {id = "", name = "", arguments = ""}
                tool_map[index] = target
            end
            if tool_delta.id ~= nil then
                local fragment = bounds.text(tool_delta.id, 160)
                if not fragment or #target.id + #fragment > 160 then return "SSE tool call ID is malformed" end
                target.id = target.id .. fragment
            end
            if tool_delta.type ~= nil and tool_delta.type ~= "function" then return "SSE tool call type is unsupported" end
            if tool_delta["function"] ~= nil then
                local fn = bounds.object(tool_delta["function"])
                if not fn then return "SSE tool function fragment must be an object" end
                local fn_extra = bounds.fields(fn, {"name", "arguments"})
                if fn_extra then return "SSE tool function: " .. fn_extra end
                if fn.name ~= nil then
                    local name = bounds.text(fn.name, 160)
                    if not name or #target.name + #name > 160 then return "SSE tool name is malformed" end
                    target.name = target.name .. name
                end
                if fn.arguments ~= nil then
                    local arguments = bounds.text(fn.arguments, M.MAX_TOOL_ARGUMENT_BYTES)
                    if not arguments or #target.arguments + #arguments > M.MAX_TOOL_ARGUMENT_BYTES then
                        return "SSE tool arguments exceed their byte bound"
                    end
                    target.arguments = target.arguments .. arguments
                end
            end
        end
        return nil
    end

    local function consume_line(line: string): string?
        if done and line ~= "" then return "SSE data followed the terminal marker" end
        local parsed, parse_error = parse_sse_line(line)
        if not parsed then return parse_error or "SSE line is malformed" end
        if parsed.kind == "done" then
            done = true
            return nil
        end
        if parsed.kind == "ignore" then return nil end
        return consume_event(parsed.event)
    end

    while true do
        if cancel_check and cancel_check() then
            close_stream()
            return nil, "cancelled"
        end

        local chunk, read_err = read(4096)
        if read_err then
            close_stream()
            return nil, "read SSE stream: " .. tostring(read_err)
        end
        if not chunk or #chunk == 0 then break end
        total_bytes = total_bytes + #chunk
        if total_bytes > M.MAX_STREAM_BYTES then
            close_stream()
            return nil, "SSE stream exceeds " .. tostring(M.MAX_STREAM_BYTES) .. " bytes"
        end
        local lines, frame_error = framing.feed(framer, chunk)
        if not lines then
            close_stream()
            return nil, "frame SSE stream: " .. tostring(frame_error)
        end
        for _, line in ipairs(lines) do
            local line_error = consume_line(line)
            if line_error then
                close_stream()
                return nil, line_error
            end
        end
        if done then break end
    end
    local partial, frame_error = framing.finish(framer)
    if frame_error then
        close_stream()
        return nil, "finish SSE stream: " .. frame_error
    end
    if partial then
        close_stream()
        return nil, "SSE stream ended with an incomplete frame"
    end
    if not done then
        close_stream()
        return nil, "SSE stream ended before [DONE]"
    end

    close_stream()

    local final_tools: {types.ToolCall}? = nil
    local indices: {integer} = {}
    for index in pairs(tool_map) do indices[#indices + 1] = index end
    table.sort(indices)
    if #indices > 0 then
        final_tools = {}
        local seen: {[string]: boolean} = {}
        for position, index in ipairs(indices) do
            if index ~= position - 1 then return nil, "SSE tool call indices are not dense" end
            local fragments = tool_map[index]
            local id, name = bounds.id(fragments.id), bounds.id(fragments.name)
            local arguments, argument_error = decode_arguments(fragments.arguments)
            if not id or not name or not arguments then
                return nil, "SSE tool call is incomplete: " .. tostring(argument_error or "missing ID or name")
            end
            if seen[id] then return nil, "SSE tool call IDs must be unique" end
            seen[id] = true
            final_tools[#final_tools + 1] = {id = id, kind = "function", name = name, arguments = arguments}
        end
    end

    local text: string? = nil
    if #content_parts > 0 then
        text = table.concat(content_parts, "")
    end
    if text == nil and final_tools == nil then
        return nil, "stream carried no content or tool calls"
    end

    return {
        content = text,
        tool_calls = final_tools,
        finish_reason = finish_reason or "stop",
    }, nil
end

return M
