-- MIT. Authority method send: the caller's actor, the linked store, one operation.
local boundary = require("boundary")
local send = require("send")
local types = require("types")
local function handle(request: unknown): types.Reply
    return boundary.run(send.send, request, true)
end
return {handle = handle}
