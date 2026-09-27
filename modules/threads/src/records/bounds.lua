-- Thread-specific capacities and sequence validators on shared protocol bounds.
local shared = require("shared")
local M = {}
M.SCHEMA_REVISION = "bee.thread-record@1"
M.MAX_SAFE_INTEGER = shared.MAX_SAFE_INTEGER
M.MAX_ID_BYTES = shared.MAX_ID_BYTES
M.MAX_RECORD_BYTES = 16384
M.MAX_PAGE_RECORDS = 64
M.MAX_THREAD_RECORDS = 10000
M.MAX_THREAD_MEMBERS = 128
M.MAX_THREAD_ACTIONS = 128
M.MAX_THREAD_ATTEMPTS = 128
M.MAX_THREAD_TURNS = 128
M.MAX_THREAD_OBLIGATIONS = 2048
M.MAX_ARRAY_ITEMS = shared.MAX_ARRAY_ITEMS
M.MAX_TEXT_BYTES = shared.MAX_TEXT_BYTES
M.MAX_JSON_DEPTH = 16
M.MAX_TITLE_BYTES = 512
M.MAX_FAULT_MESSAGE_BYTES = 4096
M.KINDS = {"observation", "message", "action.admitted", "attempt.prepared", "attempt.started", "turn.request", "turn.end", "receipt", "delivery.mark", "request.answered", "approval.request", "approval.transition"}
M.SOURCES = {"stream", "hook", "transcript", "mcp", "bee"}
M.OUTCOMES = {"succeeded", "failed", "cancelled", "uncertain"}

M.id = shared.id
M.text = shared.text
M.line = shared.line
function M.integer(value: unknown): integer?
    return shared.integer(value)
end
M.count = shared.count
M.timestamp = shared.timestamp
M.array = shared.array
M.ids = shared.ids
M.fields = shared.fields
M.object = shared.object
M.optional_id = shared.optional_id
M.subpath = shared.subpath
M.dense_list = shared.dense_list
M.MAX_SUBPATH_BYTES = shared.MAX_SUBPATH_BYTES

function M.sequence(value: unknown): integer?
    local number = shared.integer(value)
    if not number or number < 1 or number > M.MAX_THREAD_RECORDS then return nil end
    return number
end

function M.cursor(value: unknown): integer?
    local number = shared.integer(value)
    if not number or number < 0 or number > M.MAX_THREAD_RECORDS then return nil end
    return number
end

function M.page_limit(value: unknown): integer?
    if value == nil then return M.MAX_PAGE_RECORDS end
    local number = shared.integer(value)
    if not number or number < 1 or number > M.MAX_PAGE_RECORDS then return nil end
    return number
end

function M.member(value: unknown, variants: {string}): string?
    if type(value) ~= "string" then return nil end
    for _, variant in ipairs(variants) do if variant == value then return value end end
    return nil
end
return M
