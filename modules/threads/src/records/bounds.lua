-- Thread-specific capacities and sequence validators.
local shared_bounds = require("shared_bounds")
local M = {}
M.SCHEMA_REVISION = "bee.thread-record@1"
M.MAX_RECORD_BYTES = 16384
M.MAX_PAGE_RECORDS = 64
M.MAX_THREAD_RECORDS = 10000
M.MAX_THREAD_MEMBERS = 128
M.MAX_THREAD_ACTIONS = 128
M.MAX_THREAD_ATTEMPTS = 128
M.MAX_THREAD_TURNS = 128
M.MAX_THREAD_OBLIGATIONS = 2048
M.MAX_JSON_DEPTH = 16
M.MAX_TITLE_BYTES = 512
M.MAX_FAULT_MESSAGE_BYTES = 4096
M.KINDS = {"observation", "message", "action.admitted", "attempt.prepared", "attempt.started", "turn.request", "turn.end", "receipt", "delivery.mark", "request.answered", "approval.request", "approval.transition"}
M.SOURCES = {"stream", "hook", "transcript", "mcp", "bee"}
M.OUTCOMES = {"succeeded", "failed", "cancelled", "uncertain"}

function M.sequence(value: unknown): integer?
    local number = shared_bounds.integer(value)
    if not number or number < 1 or number > shared_bounds.MAX_SAFE_INTEGER then return nil end
    return number
end

function M.cursor(value: unknown): integer?
    local number = shared_bounds.integer(value)
    if not number or number < 0 or number > M.MAX_THREAD_RECORDS then return nil end
    return number
end

function M.page_limit(value: unknown): integer?
    if value == nil then return M.MAX_PAGE_RECORDS end
    local number = shared_bounds.integer(value)
    if not number or number < 1 or number > M.MAX_PAGE_RECORDS then return nil end
    return number
end

return M
