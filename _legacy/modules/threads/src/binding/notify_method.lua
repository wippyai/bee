-- MIT. Authority method notify: the caller's actor, the linked store, one
-- mutation that registers a one-shot notice on the caller's own thread.
local boundary = require("boundary")
local notices = require("notices")
local types = require("types")
local function handle(request: unknown): types.Reply
    return boundary.run(notices.notify, request, true)
end
return {handle = handle}
