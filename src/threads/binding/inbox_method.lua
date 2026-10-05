-- MIT. Authenticated action inbox operations at the Threads owner boundary.
local boundary = require("boundary")
local inbox = require("inbox")
local types = require("types")
local M = {}
function M.accept(request: unknown): types.Reply return boundary.run(inbox.accept, request) end
function M.describe(request: unknown): types.Reply return boundary.run(inbox.describe, request) end
function M.resolve(request: unknown): types.Reply return boundary.run(inbox.resolve, request) end
function M.send(request: unknown): types.Reply return boundary.run(inbox.send, request) end
function M.reply(request: unknown): types.Reply return boundary.run(inbox.reply, request) end
function M.list(request: unknown): types.Reply return boundary.run(inbox.list, request) end
function M.ack(request: unknown): types.Reply return boundary.run(inbox.ack, request) end
function M.offer(request: unknown): types.Reply return boundary.run(inbox.offer, request) end
function M.transport(request: unknown): types.Reply return boundary.run(inbox.transport, request) end
return M
