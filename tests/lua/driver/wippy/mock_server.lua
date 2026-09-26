-- MIT. Mock OpenAI-compatible chat completions server for native Wippy driver testing.
local http = require("http")
local json = require("json")

local function handle(): nil
    local request = http.request()
    local response = http.response()
    if not request or not response then return nil end

    local body_str = request:body() or "{}"
    local body, err = json.decode(body_str)
    if err or type(body) ~= "table" then
        response:set_status(400)
        response:set_content_type(http.CONTENT.JSON)
        response:write_json({error = {message = "invalid request body"}})
        return nil
    end

    local payload = body :: {[string]: unknown}
    local messages = (type(payload.messages) == "table" and payload.messages or {}) :: {{[string]: unknown}}
    local is_stream = payload.stream == true

    -- Check if the latest message is a tool result
    local last_msg = #messages > 0 and messages[#messages] or nil
    if last_msg and last_msg.role == "tool" then
        local tool_res = tostring(last_msg.content or "")
        local final_text = "I have completed the task. Result: " .. tool_res

        if is_stream then
            response:set_status(200)
            response:set_content_type("text/event-stream")
            response:set_header("Cache-Control", "no-cache")
            response:write("data: " .. json.encode({
                id = "chatcmpl-stream-2",
                object = "chat.completion.chunk",
                created = 1234567,
                model = "test-model",
                choices = {{index = 0, delta = {content = final_text}}}
            }) .. "\n\n")
            response:write("data: " .. json.encode({
                id = "chatcmpl-stream-2",
                object = "chat.completion.chunk",
                created = 1234567,
                model = "test-model",
                choices = {{index = 0, finish_reason = "stop"}}
            }) .. "\n\n")
            response:write("data: [DONE]\n\n")
            return nil
        else
            response:set_status(200)
            response:set_content_type(http.CONTENT.JSON)
            response:write_json({
                id = "chatcmpl-2",
                object = "chat.completion",
                created = 1234567,
                model = "test-model",
                choices = {{
                    index = 0,
                    message = {role = "assistant", content = final_text},
                    finish_reason = "stop"
                }}
            })
            return nil
        end
    end

    -- Inspect user prompt
    local user_prompt = ""
    for _, msg in ipairs(messages) do
        if msg.role == "user" and type(msg.content) == "string" then
            user_prompt = msg.content :: string
        end
    end

    -- Mode A: Tool call request
    if user_prompt:find("call_tool", 1, true) then
        if is_stream then
            response:set_status(200)
            response:set_content_type("text/event-stream")
            response:set_header("Cache-Control", "no-cache")
            response:write("data: " .. json.encode({
                id = "chatcmpl-stream-tc",
                choices = {{
                    index = 0,
                    delta = {
                        role = "assistant",
                        tool_calls = {{
                            index = 0,
                            id = "call_stream_1",
                            type = "function",
                            ["function"] = {
                                name = "FileReport",
                                arguments = "{\"summary\":"
                            }
                        }}
                    }
                }}
            }) .. "\n\n")
            response:write("data: " .. json.encode({
                id = "chatcmpl-stream-tc",
                choices = {{
                    index = 0,
                    delta = {
                        tool_calls = {{
                            index = 0,
                            ["function"] = {
                                arguments = "\"streamed-review-done\"}"
                            }
                        }}
                    }
                }}
            }) .. "\n\n")
            response:write("data: " .. json.encode({
                id = "chatcmpl-stream-tc",
                choices = {{index = 0, finish_reason = "tool_calls"}}
            }) .. "\n\n")
            response:write("data: [DONE]\n\n")
            return nil
        else
            response:set_status(200)
            response:set_content_type(http.CONTENT.JSON)
            response:write_json({
                id = "chatcmpl-tc-1",
                object = "chat.completion",
                created = 1234567,
                model = "test-model",
                choices = {{
                    index = 0,
                    message = {
                        role = "assistant",
                        content = nil,
                        tool_calls = {{
                            id = "call_tc_1",
                            type = "function",
                            ["function"] = {
                                name = "FileReport",
                                arguments = json.encode({summary = "nonstream-review-done"})
                            }
                        }}
                    },
                    finish_reason = "tool_calls"
                }}
            })
            return nil
        end
    end

    -- Mode B: Unadmitted tool call
    if user_prompt:find("call_unadmitted_tool", 1, true) then
        response:set_status(200)
        response:set_content_type(http.CONTENT.JSON)
        response:write_json({
            id = "chatcmpl-unadmitted",
            object = "chat.completion",
            choices = {{
                index = 0,
                message = {
                    role = "assistant",
                    content = nil,
                    tool_calls = {{
                        id = "call_forbidden",
                        type = "function",
                        ["function"] = {
                            name = "ForbiddenDangerousTool",
                            arguments = "{}"
                        }
                    }}
                },
                finish_reason = "tool_calls"
            }}
        })
        return nil
    end

    -- Mode C: Plain streaming response
    if is_stream then
        response:set_status(200)
        response:set_content_type("text/event-stream")
        response:set_header("Cache-Control", "no-cache")
        response:write("data: " .. json.encode({
            id = "chatcmpl-stream-plain",
            choices = {{index = 0, delta = {role = "assistant", content = "Streamed "}}}
        }) .. "\n\n")
        response:write("data: " .. json.encode({
            id = "chatcmpl-stream-plain",
            choices = {{index = 0, delta = {content = "answer "}}}
        }) .. "\n\n")
        response:write("data: " .. json.encode({
            id = "chatcmpl-stream-plain",
            choices = {{index = 0, delta = {content = "success!"}}}
        }) .. "\n\n")
        response:write("data: " .. json.encode({
            id = "chatcmpl-stream-plain",
            choices = {{index = 0, finish_reason = "stop"}}
        }) .. "\n\n")
        response:write("data: [DONE]\n\n")
        return nil
    end

    -- Mode D: Default standard response
    response:set_status(200)
    response:set_content_type(http.CONTENT.JSON)
    response:write_json({
        id = "chatcmpl-plain-1",
        object = "chat.completion",
        created = 1234567,
        model = "test-model",
        choices = {{
            index = 0,
            message = {role = "assistant", content = "Standard answer: " .. user_prompt},
            finish_reason = "stop"
        }}
    })
    return nil
end

return {handle = handle}
