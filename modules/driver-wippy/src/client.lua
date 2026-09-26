-- MIT. OpenAI-compatible chat completions HTTP client for native Wippy driver.
local http_client = require("http_client")
local json = require("json")
local env = require("env")
local registry = require("registry")
local funcs = require("funcs")
local types = require("types")

local M = {}

function M.resolve_key(credential_ref: string?, workspace_id: string?): (string?, string?)
    if not credential_ref or credential_ref == "" then return nil, nil end

    -- 1. Try registry entry
    local entry = registry.get(credential_ref)
    if entry then
        if entry.kind == "env.variable" then
            local val, err = env.get(credential_ref)
            if not err and val and #val > 0 then return val, nil end
        elseif type(entry.data) == "table" then
            local d = entry.data :: {[string]: unknown}
            local token = d.api_key or d.key or d.token or d.value
            if type(token) == "string" and #token > 0 then return token, nil end
        end
    end

    -- 2. Try direct env variable
    local env_val, env_err = env.get(credential_ref)
    if not env_err and env_val and #env_val > 0 then return env_val, nil end

    -- 3. Try credentials broker materialize
    if workspace_id and credential_ref:match("^[%w_.-]+$") then
        local ok_mat, mat_res = pcall(function()
            return funcs.call("bee.credentials.binding:materialize", {workspace_id = workspace_id, projection_id = credential_ref})
        end)
        if ok_mat and type(mat_res) == "table" and (mat_res :: {[string]: unknown}).ok == true then
            local val_obj = (mat_res :: {[string]: unknown}).value :: {[string]: unknown}
            if val_obj and type(val_obj.secret) == "string" then
                return val_obj.secret :: string, nil
            end
        end
    end

    -- 4. Fallback: literal string if not a reference
    return credential_ref, nil
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

function M.chat_completions(config: types.HostConfig, payload: types.ChatPayload, cancel_check: (() -> boolean)?): (types.ChatResponse?, string?)
    local url = M.normalize_url(config.endpoint)
    local key = M.resolve_key(config.credential_ref, nil)

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

    if payload.stream == true then
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

        local content_parts: {string} = {}
        local tool_map: {[integer]: types.ToolCall} = {}
        local finish_reason: string? = nil
        local buffer = ""

        local stream = resp.stream
        if not stream then return nil, "no stream available on response" end

        while true do
            if cancel_check and cancel_check() then
                stream:close()
                return nil, "cancelled"
            end

            local chunk, read_err = stream:read(4096)
            if read_err or not chunk or #chunk == 0 then break end
            buffer = buffer .. chunk

            while true do
                local newline_pos = buffer:find("\n", 1, true)
                if not newline_pos then break end
                local line = buffer:sub(1, newline_pos - 1)
                buffer = buffer:sub(newline_pos + 1)

                local kind, event = parse_sse_line(line)
                if kind == "DONE" then
                    break
                elseif kind == "DATA" and event then
                    local choices = event.choices
                    if type(choices) == "table" and #choices > 0 then
                        local first = choices[1] :: {[string]: unknown}
                        if first.finish_reason and type(first.finish_reason) == "string" then
                            finish_reason = first.finish_reason :: string
                        end
                        local delta = first.delta :: {[string]: unknown}?
                        if delta then
                            if type(delta.content) == "string" then
                                content_parts[#content_parts + 1] = delta.content :: string
                            end
                            local delta_tools = delta.tool_calls :: {unknown}?
                            if type(delta_tools) == "table" then
                                for _, item in ipairs(delta_tools) do
                                    local dt = item :: {[string]: unknown}
                                    local idx = math.floor(tonumber(dt.index) or 0)
                                    if not tool_map[idx] then
                                        tool_map[idx] = {
                                            id = (type(dt.id) == "string" and dt.id or "") :: string,
                                            type = "function",
                                            ["function"] = {
                                                name = "",
                                                arguments = "",
                                            },
                                        }
                                    end
                                    local target = tool_map[idx]
                                    if type(dt.id) == "string" and #dt.id > 0 then target.id = dt.id :: string end
                                    local fn = dt["function"] :: {[string]: unknown}?
                                    if fn then
                                        if type(fn.name) == "string" then
                                            target["function"].name = target["function"].name .. (fn.name :: string)
                                        end
                                        if type(fn.arguments) == "string" then
                                            target["function"].arguments = target["function"].arguments .. (fn.arguments :: string)
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end

        if resp.stream then resp.stream:close() end

        local final_tools: {types.ToolCall}? = nil
        local count = 0
        for _ in pairs(tool_map) do count = count + 1 end
        if count > 0 then
            final_tools = {}
            local indices: {integer} = {}
            for k in pairs(tool_map) do indices[#indices + 1] = k end
            table.sort(indices)
            for _, k in ipairs(indices) do
                final_tools[#final_tools + 1] = tool_map[k]
            end
        end

        local text: string? = nil
        if #content_parts > 0 then
            text = table.concat(content_parts, "")
        end

        return {
            content = text,
            tool_calls = final_tools,
            finish_reason = finish_reason or "stop",
        }, nil
    else
        local resp, req_err = http_client.post(url, {
            headers = headers,
            body = encoded_body,
            timeout = timeout,
        })
        if req_err or not resp then return nil, tostring(req_err or "request failed") end
        if resp.status_code and resp.status_code >= 400 then
            return nil, "HTTP " .. tostring(resp.status_code) .. ": " .. tostring(resp.body)
        end

        local body_data, dec_err = json.decode(resp.body or "{}")
        if dec_err or type(body_data) ~= "table" then return nil, "decode response: " .. tostring(dec_err) end
        local obj = body_data :: {[string]: unknown}
        local choices = obj.choices :: {unknown}?
        if not choices or #choices == 0 then return nil, "no choices in response" end

        local first = choices[1] :: {[string]: unknown}
        local message = first.message :: {[string]: unknown}?
        if not message then return nil, "no message in choice" end

        local content: string? = nil
        if type(message.content) == "string" then content = message.content :: string end

        local tools_list: {types.ToolCall}? = nil
        local raw_tools = message.tool_calls :: {unknown}?
        if type(raw_tools) == "table" and #raw_tools > 0 then
            tools_list = {}
            for _, item in ipairs(raw_tools) do
                local t = item :: {[string]: unknown}
                local fn = (t["function"] or {}) :: {[string]: unknown}
                tools_list[#tools_list + 1] = {
                    id = tostring(t.id or "call_unknown"),
                    type = "function",
                    ["function"] = {
                        name = tostring(fn.name or ""),
                        arguments = tostring(fn.arguments or "{}"),
                    },
                }
            end
        end

        return {
            content = content,
            tool_calls = tools_list,
            finish_reason = type(first.finish_reason) == "string" and (first.finish_reason :: string) or "stop",
        }, nil
    end
end

return M
