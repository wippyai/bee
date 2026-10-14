-- SPDX-License-Identifier: MIT
local mapper = require("mapper")
local delivery = require("delivery")
local bounds = require("bounds")
local M = {}
function M.capture(fixture: {[string]: unknown}): {[string]: unknown}
    local state = mapper.new()
    local rows: {{[string]: unknown}} = {}
    local logs: {{[string]: unknown}} = {}
    local refused = false
    local function emit(event: {[string]: unknown})
        for _, row in ipairs(mapper.event(state, event)) do
            delivery.send({submit = function(payload: {[string]: unknown}): {[string]: unknown}?
                if fixture.deliveryFailure and not refused and payload.hook_event_name == "UserPromptSubmit" then refused = true; error("fixture hook endpoint refused delivery") end
                rows[#rows + 1] = payload
                return {hookSpecificOutput = {additionalContext = fixture.context}}
            end, permission = function(_: string, _: {[string]: unknown}) end,
            record = function(_: string) logs[#logs + 1] = {level = "error", service = "bee-hooks"} end}, row)
        end
        if state.failure then logs[#logs + 1] = {message = "Bee OpenCode callback: " .. state.failure}; state.failure = nil end
    end
    emit({type = "session.created", properties = {info = {id = "ses_root"}}})
    emit({type = "session.updated", properties = {info = {id = "ses_root"}}})
    emit({type = "session.created", properties = {info = {id = "ses_child", parentID = "ses_root"}}})
    emit({type = "message.updated", properties = {info = {id = "msg_prompt", sessionID = "ses_root", role = "user"}}})
    emit({type = "message.part.updated", properties = {part = {id = "prt_prompt", messageID = "msg_prompt", sessionID = "ses_root", type = "text", text = fixture.prompt}}})
    emit({type = "session.idle", properties = {sessionID = "ses_child"}})
    if fixture.tools then
        for _, status in ipairs({"running", "completed"}) do
            emit({type = "message.part.updated", properties = {part = {id = "prt_tool", messageID = "msg_tool", sessionID = "ses_root", type = "tool", tool = "bash", callID = "call_1", state = {status = status, input = {command = "echo fixture"}, output = "fixture"}}}})
        end
        emit({type = "message.part.updated", properties = {part = {id = "prt_error", messageID = "msg_tool", sessionID = "ses_root", type = "tool", tool = "read", callID = "call_2", state = {status = "error", error = "fixture error"}}}})
        for i = 3, 4 do emit({type = "permission.asked", properties = {sessionID = "ses_root", id = "per_" .. tostring(i), permission = "bash", tool = {callID = "call_" .. tostring(i)}, metadata = {command = "echo permission"}}}) end
    end
    emit({type = "message.updated", properties = {info = {id = "msg_tool", sessionID = "ses_root", role = "assistant", parentID = "msg_prompt", finish = "tool-calls", time = {completed = 1}}}})
    local time: {[string]: unknown} = {}
    if fixture.incomplete ~= true then time.completed = 2 end
    local info: {[string]: unknown} = {id = "msg_reply", sessionID = "ses_root", role = "assistant", parentID = "msg_prompt", finish = "stop", time = time}
    if fixture.failed then info.error = {name = "APIError"} end
    emit({type = "message.updated", properties = {info = info}})
    for i, part in ipairs({{type = "reasoning", text = "Private reasoning"}, {type = "text", text = "Synthetic", synthetic = true}, {type = "text", text = "Ignored", ignored = true}, {type = "text", text = fixture.answer}}) do
        part.id = "prt_" .. tostring(i); part.messageID = "msg_reply"; part.sessionID = "ses_root"
        emit({type = "message.part.updated", properties = {part = part}})
    end
    if fixture.errorEvent then emit({type = "session.error", properties = {sessionID = "ses_root", error = {name = "APIError"}}}) end
    emit({type = "session.idle", properties = {sessionID = "ses_root"}})
    emit({type = "session.idle", properties = {sessionID = "ses_root"}})
    if fixture.dispose ~= true then emit({type = "session.deleted", properties = {info = {id = "ses_root"}}}) end
    for _, row in ipairs(mapper.finish(state)) do rows[#rows + 1] = row end
    return {rows = rows, logs = logs}
end
return M
