-- MIT. Make direct Threads calls in an isolated application actor context.
local funcs = require("funcs")

local function main(thread_id: string, message: unknown, payload_digest: string, send_key: string,
    record_key: string, caller_node_id: string): {[string]: unknown}
    local sent, send_error = funcs.call("bee.threads.service:send", {thread_id = thread_id,
        idempotency_key = send_key, caller_node_id = caller_node_id, payload_digest = payload_digest, message = message})
    if type(sent) == "table" and type(sent.ok) == "boolean" and sent.ok == false then
        return {send_transport_error = send_error, send_reply = sent, record_transport_error = nil, record_reply = nil}
    end
    local recorded, record_error = funcs.call("bee.threads.service:record", {thread_id = thread_id,
        idempotency_key = record_key, kind = "message", body = message})
    return {send_transport_error = send_error, send_reply = sent,
        record_transport_error = record_error and tostring(record_error) or nil, record_reply = recorded}
end

return {main = main}
