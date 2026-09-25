-- MIT. Authenticated action inbox operations at the Threads owner boundary.
local boundary = require("boundary")
local inbox = require("inbox")
local types = require("types")
local M = {}
function M.accept(request: unknown): types.Reply return boundary.run(inbox.accept, request, true) end
function M.describe(request: unknown): types.Reply return boundary.run(inbox.describe, request, false) end
function M.send(request: unknown): types.Reply return boundary.run(inbox.send, request, true) end
function M.reply(request: unknown): types.Reply return boundary.run(inbox.reply, request, true) end
function M.list(request: unknown): types.Reply return boundary.run(inbox.list, request, false) end
function M.ack(request: unknown): types.Reply return boundary.run(inbox.ack, request, false) end
return M
