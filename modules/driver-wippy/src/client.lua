-- MIT. OpenAI-compatible chat completions HTTP client for native Wippy driver.
local http_client = require("http_client")
local json = require("json")
local env = require("env")
local registry = require("registry")
local types = require("types")

local M = {}

M.MAX_URL_BYTES = 512

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
            local data = entry.data :: {[string]: unknown}
            if type(data.variable) == "string" and data.variable ~= "" then
                local name = data.variable :: string
                local val, err = env.get(name)
                if not err and val and #val > 0 then return val, nil end
                return nil, "credential source " .. name .. " yields no value"
            end
            return nil, "credential entry " .. credential_ref .. " names no variable"
        elseif type(entry.data) == "table" then
            local d = entry.data :: {[string]: unknown}
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

local function parse_sse_line(line: string): (string?, {[string]: unknown}?)
    local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed == "" or trimmed:sub(1, 1) == ":" then return nil, nil end
    if not trimmed:find("^data:") then return nil, nil end
    local payload = trimmed:sub(6):gsub("^%s+", "")
    if payload == "[DONE]" then return "DONE", nil end
    local decoded, err = json.decode(payload)
    if err or type(decoded) ~= "table" then return nil, nil end
    return "DATA", decoded :: {[string]: unknown}
end

local function tool_arguments(value: unknown): string
    if type(value) == "string" then return value end
    if type(value) == "table" then
        local encoded, _ = json.encode(value)
        if encoded then return encoded end
    end
    return "{}"
end

local function decode_tool_call(item: unknown): types.ToolCall?
    if type(item) ~= "table" then return nil end
    local raw = item :: {[string]: unknown}
    if type(raw.id) ~= "string" or raw.id == "" then return nil end
    local fn = type(raw["function"]) == "table" and (raw["function"] :: {[string]: unknown}) or {}
    if type(fn.name) ~= "string" or fn.name == "" then return nil end
    return {
        id = raw.id :: string,
        kind = "function",
        name = fn.name :: string,
        arguments = tool_arguments(fn.arguments),
    }
end

local function decode_message(message: unknown): (string?, {types.ToolCall}?)
    if type(message) ~= "table" then return nil, nil end
    local msg = message :: {[string]: unknown}
    local content: string? = nil
    if type(msg.content) == "string" then content = msg.content :: string end
    local tools_list: {types.ToolCall}? = nil
    if type(msg.tool_calls) == "table" then
        for _, item in ipairs(msg.tool_calls :: {unknown}) do
            local call = decode_tool_call(item)
            if call then
                if not tools_list then tools_list = {} end
                tools_list[#tools_list + 1] = call
            end
        end
    end
    return content, tools_list
end

local function decode_choice(choice: unknown): ({[string]: unknown}?, string?)
    if type(choice) ~= "table" then return nil, "choice is not an object" end
    return choice :: {[string]: unknown}, nil
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

    local body_data, dec_err = json.decode(resp.body or "{}")
    if dec_err or type(body_data) ~= "table" then return nil, "decode response: " .. tostring(dec_err) end
    local obj = body_data :: {[string]: unknown}
    local choices = obj.choices
    if type(choices) ~= "table" or #(choices :: {unknown}) == 0 then return nil, "no choices in response" end

    local first, choice_err = decode_choice((choices :: {unknown})[1])
    if not first then return nil, tostring(choice_err) end
    local content, tools_list = decode_message(first.message)
    if content == nil and tools_list == nil then return nil, "no message in choice" end

    return {
        content = content,
        tool_calls = tools_list,
        finish_reason = type(first.finish_reason) == "string" and (first.finish_reason :: string) or "stop",
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

    local content_parts: {string} = {}
    local tool_map: {[integer]: types.ToolCall} = {}
    local finish_reason: string? = nil
    local buffer = ""
    local done = false

    local function handle_line(line: string)
        local kind, event = parse_sse_line(line)
        if kind == "DONE" then
            done = true
            return
        end
        if kind ~= "DATA" or not event then return end
        local choices = event.choices
        if type(choices) ~= "table" or #(choices :: {unknown}) == 0 then return end
        local first = (choices :: {unknown})[1]
        if type(first) ~= "table" then return end
        local choice = first :: {[string]: unknown}
        if type(choice.finish_reason) == "string" then
            finish_reason = choice.finish_reason :: string
        end
        local delta = type(choice.delta) == "table" and (choice.delta :: {[string]: unknown}) or nil
        if not delta then return end
        if type(delta.content) == "string" then
            content_parts[#content_parts + 1] = delta.content :: string
        end
        if type(delta.tool_calls) == "table" then
            for _, item in ipairs(delta.tool_calls :: {unknown}) do
                if type(item) ~= "table" then break end
                local dt = item :: {[string]: unknown}
                local idx = math.floor(tonumber(dt.index) or 0)
                if not tool_map[idx] then
                    tool_map[idx] = {
                        id = (type(dt.id) == "string" and dt.id or "") :: string,
                        kind = "function",
                        name = "",
                        arguments = "",
                    }
                end
                local target = tool_map[idx]
                if type(dt.id) == "string" and #dt.id > 0 then target.id = dt.id :: string end
                local fn = type(dt["function"]) == "table" and (dt["function"] :: {[string]: unknown}) or nil
                if fn then
                    if type(fn.name) == "string" then
                        target.name = target.name .. (fn.name :: string)
                    end
                    if type(fn.arguments) == "string" then
                        target.arguments = target.arguments .. (fn.arguments :: string)
                    end
                end
            end
        end
    end

    while not done do
        if cancel_check and cancel_check() then
            stream:close()
            return nil, "cancelled"
        end

        local chunk, read_err = stream:read(4096)
        if read_err then break end
        if not chunk or #chunk == 0 then break end
        buffer = buffer .. chunk

        while not done do
            local newline_pos = buffer:find("\n", 1, true)
            if not newline_pos then break end
            local line = buffer:sub(1, newline_pos - 1)
            buffer = buffer:sub(newline_pos + 1)
            handle_line(line)
        end
    end
    if #buffer > 0 and not done then
        handle_line(buffer)
    end

    stream:close()

    local final_tools: {types.ToolCall}? = nil
    local count = 0
    for _ in pairs(tool_map) do count = count + 1 end
    if count > 0 then
        final_tools = {}
        local indices: {integer} = {}
        for k in pairs(tool_map) do indices[#indices + 1] = k end
        table.sort(indices)
        for _, k in ipairs(indices) do
            local call = tool_map[k]
            if call.id ~= "" and call.name ~= "" then
                final_tools[#final_tools + 1] = call
            end
        end
        if #final_tools == 0 then final_tools = nil end
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
