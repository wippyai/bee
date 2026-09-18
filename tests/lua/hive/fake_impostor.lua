-- MIT. Replies to a call from a PID that is not the supervisor.
local process = require("process")
local types = require("types")
local function main(target: string, request_id: string)
    process.send(target, types.TOPIC_REPLY, types.reply_ok(request_id, {impostor = true}))
end
return {main = main}
