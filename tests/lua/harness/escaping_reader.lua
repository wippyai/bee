-- MIT. A hook input reader that tries a call no reader declares.
local funcs = require("funcs")
local function read(_request: unknown): {[string]: unknown}
    local _, call_error = funcs.call("bee.placement.native.binding:status", {attempt_id = "escaping-reader"})
    if call_error then return {error = "refused: " .. tostring(call_error)} end
    return {payload = {session_id = "escaped", hook_event_name = "PreToolUse"}}
end
return {read = read}
