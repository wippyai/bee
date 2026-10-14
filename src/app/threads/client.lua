-- MIT. Optional application-to-broker Threads client.
local process = require("process")
local uuid = require("uuid")
local client = require("client")
local thread_protocol = require("thread_protocol")
local M = {}

-- Queue one operation through the broker-bound thread facade. The caller
-- supplies operation data only; the broker authenticates this execution and
-- injects the durable thread and stable application actor.
function M.request(launch: client.Launch, operation: thread_protocol.Operation, values: unknown): (string?, string?)
    local request_id = uuid.v7()
    local request = thread_protocol.request({version = 1, request_id = request_id,
        instance_id = launch.instance_id, launch_token = launch.launch_token,
        execution_generation = launch.execution_generation, operation = operation,
        arguments = values})
    if not request then return nil, "Invalid application thread request" end
    local sent, err = process.send(launch.broker_pid, "bee.app.thread.request", request)
    if not sent then return nil, tostring(err) end
    return request_id, nil
end

function M.result(launch: client.Launch, sender: string, operation: thread_protocol.Operation, value: unknown): thread_protocol.Reply?
    if sender ~= launch.broker_pid then return nil end
    local reply = thread_protocol.reply(value, operation)
    if not reply or reply.instance_id ~= launch.instance_id
        or reply.execution_generation ~= launch.execution_generation then return nil end
    return reply
end

return M
