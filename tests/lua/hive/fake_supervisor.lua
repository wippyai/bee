-- MIT. A stand-in supervisor for client tests: registers the local name and
-- answers calls according to the mode named in their input.
local process = require("process")
local channel = require("channel")
local time = require("time")
local types = require("types")
local function main()
    local registered, register_error = process.registry.register(types.SUPERVISOR_NAME)
    if not registered then error("register: " .. tostring(register_error)) end
    local requests = assert(process.listen(types.TOPIC_REQUEST, {message = true}))
    local events = assert(process.events())
    while true do
        local selected = channel.select({requests:case_receive(), events:case_receive()})
        if not selected.ok then return end
        if selected.channel == events then
            local event = selected.value
            if event.kind == process.event.CANCEL then return end
        else
            local message = selected.value
            local sender = tostring(message:from())
            local data: unknown = message:payload():data()
            local call, call_error = types.decode_call(data)
            if not call then
                process.send(sender, types.TOPIC_REPLY, types.reply_error("", types.fault("INVALID_ARGUMENT", call_error or "invalid call")))
            else
                local mode = call.input.mode
                if mode == "echo" then
                    process.send(sender, types.TOPIC_REPLY, types.reply_ok(call.request_id, {echo = call.input, owner = call.owner_ref.service_id}))
                elseif mode == "delayed" then
                    time.sleep("150ms")
                    process.send(sender, types.TOPIC_REPLY, types.reply_ok(call.request_id, {late = true}))
                elseif mode == "malformed" then
                    process.send(sender, types.TOPIC_REPLY, {protocol_revision = types.REVISION, request_id = call.request_id, ok = true, value = 1, error = {code = "DENIED", message = "x", retryable = false}})
                elseif mode == "impostor" then
                    local impostor, spawn_error = process.spawn("bee.hive:fake_impostor", "bee:workers", sender, call.request_id)
                    if not impostor then error("spawn impostor: " .. tostring(spawn_error)) end
                elseif mode == "stale" then
                    process.send(sender, types.TOPIC_REPLY, types.reply_ok("some-other-request", {stale = true}))
                    process.send(sender, types.TOPIC_REPLY, types.reply_ok(call.request_id, {fresh = true}))
                elseif mode == nil then
                    process.send(sender, types.TOPIC_REPLY, types.reply_ok(call.request_id,
                        {input_digest = assert(types.digest(call.input))}))
                end
            end
        end
    end
end
return {main = main}
