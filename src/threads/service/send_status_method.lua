-- MIT. Authority method send_status: the caller's actor, the linked store, one operation.
local boundary = require("boundary")
local send = require("send")
local types = require("types")
local function handle(request: unknown): types.Reply
    return boundary.run(send.send_status, request, false)
end
return {handle = handle}
