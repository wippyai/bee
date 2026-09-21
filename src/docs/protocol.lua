local bounds = require("bounds")
local M = {}
M.SCHEMA = "bee.docs-request@1"
-- One list page, one search page, one read window. The read window matches the
-- record text bound the other agent-facing tools already use.
M.MAX_LIST = 64
M.MAX_RESULTS = 16
M.MAX_READ_BYTES = 16384
M.MAX_QUERY_BYTES = 256
M.MAX_ID_BYTES = 160
type Operation = "list" | "search" | "read"
type Request = {operation: Operation, topic: string?, query: string?, id: string?, section: string?,
    offset: integer?, limit: integer?}
local function reference(value: unknown): string?
    local id = bounds.id(value)
    if not id or #id > M.MAX_ID_BYTES or not id:match("^[%w_./:-]+$") or id:find("..", 1, true) then return nil end
    return id
end
function M.decode(raw: unknown): (Request?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "request must be an object" end
    local op = value.operation
    if op ~= "list" and op ~= "search" and op ~= "read" then return nil, "unknown docs operation" end
    local allowed: {string} = {"operation"}
    if op == "list" then
        allowed[#allowed + 1] = "topic"
        allowed[#allowed + 1] = "offset"
        allowed[#allowed + 1] = "limit"
    elseif op == "search" then
        allowed[#allowed + 1] = "query"
        allowed[#allowed + 1] = "topic"
        allowed[#allowed + 1] = "offset"
        allowed[#allowed + 1] = "limit"
    else
        allowed[#allowed + 1] = "id"
        allowed[#allowed + 1] = "section"
        allowed[#allowed + 1] = "offset"
        allowed[#allowed + 1] = "limit"
    end
    local extra = bounds.fields(value, allowed)
    if extra then return nil, extra end
    local request: Request = {operation = op}
    if value.topic ~= nil then
        local topic = bounds.line(value.topic, 64)
        if not topic or not topic:match("^[a-z0-9_%-]+$") then return nil, "topic must be a lowercase topic name" end
        request.topic = topic
    end
    if op == "search" then
        if type(value.query) ~= "string" or #value.query == 0 or #value.query > M.MAX_QUERY_BYTES then
            return nil, "query must be nonempty text of at most " .. tostring(M.MAX_QUERY_BYTES) .. " bytes"
        end
        if value.query:find("%c") then return nil, "query must be one line" end
        request.query = value.query
    end
    if op == "read" then
        local id = reference(value.id)
        if not id then return nil, "id must be a corpus document id" end
        request.id = id
        if value.section ~= nil then
            local section = bounds.line(value.section, 120)
            if not section or not section:match("^[a-z0-9_%-]+$") then return nil, "section must be a heading anchor" end
            request.section = section
        end
        local offset = 0
        if value.offset ~= nil then
            local declared = bounds.count(value.offset)
            if not declared then return nil, "offset must be a nonnegative integer" end
            offset = declared
        end
        request.offset = offset
        local limit = M.MAX_READ_BYTES
        if value.limit ~= nil then
            local declared = bounds.integer(value.limit)
            if not declared or declared < 1 or declared > M.MAX_READ_BYTES then
                return nil, "limit must be between 1 and " .. tostring(M.MAX_READ_BYTES)
            end
            limit = declared
        end
        request.limit = limit
    elseif op == "list" or op == "search" then
        local offset = 0
        if value.offset ~= nil then
            local declared = bounds.count(value.offset)
            if not declared then return nil, "offset must be a nonnegative integer" end
            offset = declared
        end
        request.offset = offset
        if value.limit ~= nil then
            local declared = bounds.integer(value.limit)
        local maximum = op == "list" and M.MAX_LIST or M.MAX_RESULTS
            if not declared or declared < 1 or declared > maximum then
                return nil, "limit must be between 1 and " .. tostring(maximum)
            end
            request.limit = declared
        end
    end
    return request, nil
end
return M
