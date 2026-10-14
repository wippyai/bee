-- MIT. Contract adapters keep the store's owner checks and transaction API
-- behind one callable method per journal operation.
local boundary = require("boundary")
local work_store = require("work_store")
local types = require("types")
local M = {}
function M.session_create(request: unknown): types.Reply
    return boundary.run(work_store.session_create, request)
end
function M.session_attach(request: unknown): types.Reply
    return boundary.run(work_store.session_attach, request)
end
function M.session_describe(request: unknown): types.Reply
    return boundary.run(work_store.session_describe, request)
end
function M.session_scan(request: unknown): types.Reply
    return boundary.run(work_store.session_scan, request)
end
function M.node_summary(request: unknown): types.Reply
    return boundary.run(work_store.node_summary, request)
end
function M.session_transition(request: unknown): types.Reply
    return boundary.run(work_store.session_transition, request)
end
function M.work_send(request: unknown): types.Reply
    return boundary.run(work_store.work_send, request)
end
function M.work_describe(request: unknown): types.Reply
    return boundary.run(work_store.work_describe, request)
end
function M.work_await(request: unknown): types.Reply
    return boundary.run(work_store.work_await, request)
end
function M.work_scan(request: unknown): types.Reply
    return boundary.run(work_store.work_scan, request)
end
function M.turn_reserve(request: unknown): types.Reply
    return boundary.run(work_store.turn_reserve, request)
end
function M.turn_recover(request: unknown): types.Reply
    return boundary.run(work_store.turn_recover, request)
end
function M.turn_pull(request: unknown): types.Reply
    return boundary.run(work_store.turn_pull, request)
end
function M.turn_accept(request: unknown): types.Reply
    return boundary.run(work_store.turn_accept, request)
end
function M.turn_observation(request: unknown): types.Reply
    return boundary.run(work_store.turn_observation, request)
end
function M.work_settle(request: unknown): types.Reply
    return boundary.run(work_store.work_settle, request)
end
function M.work_uncertain(request: unknown): types.Reply
    return boundary.run(work_store.work_uncertain, request)
end
function M.work_cancel(request: unknown): types.Reply
    return boundary.run(work_store.work_cancel, request)
end
function M.operation_lookup(request: unknown): types.Reply
    return boundary.run(work_store.operation_lookup, request)
end
function M.operation_describe(request: unknown): types.Reply
    return boundary.run(work_store.operation_describe, request)
end
function M.feed_read(request: unknown): types.Reply
    return boundary.run(work_store.feed_read, request)
end
function M.work_history(request: unknown): types.Reply
    return boundary.run(work_store.work_history, request)
end
return M
