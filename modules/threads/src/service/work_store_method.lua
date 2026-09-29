-- MIT. Contract adapters keep the store's owner checks and transaction API
-- behind one callable method per journal operation.
local boundary = require("boundary")
local work_store = require("work_store")
local types = require("types")
local M = {}
function M.session_create(request: unknown): types.Reply
    return boundary.run(work_store.session_create, request, true)
end
function M.session_describe(request: unknown): types.Reply
    return boundary.run(work_store.session_describe, request, false)
end
function M.session_scan(request: unknown): types.Reply
    return boundary.run(work_store.session_scan, request, false)
end
function M.session_transition(request: unknown): types.Reply
    return boundary.run(work_store.session_transition, request, true)
end
function M.work_send(request: unknown): types.Reply
    return boundary.run(work_store.work_send, request, true)
end
function M.work_describe(request: unknown): types.Reply
    return boundary.run(work_store.work_describe, request, false)
end
function M.work_scan(request: unknown): types.Reply
    return boundary.run(work_store.work_scan, request, false)
end
function M.turn_reserve(request: unknown): types.Reply
    return boundary.run(work_store.turn_reserve, request, true)
end
function M.turn_recover(request: unknown): types.Reply
    return boundary.run(work_store.turn_recover, request, true)
end
function M.turn_pull(request: unknown): types.Reply
    return boundary.run(work_store.turn_pull, request, false)
end
function M.turn_accept(request: unknown): types.Reply
    return boundary.run(work_store.turn_accept, request, true)
end
function M.work_settle(request: unknown): types.Reply
    return boundary.run(work_store.work_settle, request, true)
end
function M.work_uncertain(request: unknown): types.Reply
    return boundary.run(work_store.work_uncertain, request, true)
end
function M.work_cancel(request: unknown): types.Reply
    return boundary.run(work_store.work_cancel, request, true)
end
function M.operation_lookup(request: unknown): types.Reply
    return boundary.run(work_store.operation_lookup, request, false)
end
function M.operation_describe(request: unknown): types.Reply
    return boundary.run(work_store.operation_describe, request, false)
end
function M.feed_read(request: unknown): types.Reply
    return boundary.run(work_store.feed_read, request, false)
end
return M
