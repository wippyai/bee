local bounds = require("bounds")
local M = {}
-- One list page, one search page, one read window. The read window matches the
-- record text bound the other agent-facing tools already use.
M.MAX_LIST = 64
M.MAX_RESULTS = 16
M.MAX_READ_BYTES = 16384
M.MAX_QUERY_BYTES = 256
M.MAX_ID_BYTES = 160
type Operation = "list" | "search" | "read"
type ListRequest = {operation: "list", topic: string?, offset: integer, limit: integer?}
type SearchRequest = {operation: "search", query: string, topic: string?, offset: integer, limit: integer?}
type ReadRequest = {operation: "read", id: string, section: string?, offset: integer, limit: integer}
type Request = ListRequest | SearchRequest | ReadRequest
function M.document_id(value: unknown): string?
    local id = bounds.id(value)
    if not id or #id > M.MAX_ID_BYTES or not id:match("^[%w_./:-]+$") or id:find("..", 1, true) then return nil end
    return id
end
function M.decode(raw: unknown): (Request?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "request must be an object" end
    local op: Operation? = value.operation == "list" and "list" or (value.operation == "search" and "search" or (value.operation == "read" and "read" or nil))
    if not op then return nil, "unknown docs operation" end
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
    local topic: string? = nil
    if value.topic ~= nil then
        local decoded_topic = bounds.line(value.topic, 64)
        if not decoded_topic or not decoded_topic:match("^[a-z0-9_%-]+$") then return nil, "topic must be a lowercase topic name" end
        topic = decoded_topic
    end
    local offset = 0
    if value.offset ~= nil then
        local decoded_offset = bounds.count(value.offset)
        if not decoded_offset then return nil, "offset must be a nonnegative integer" end
        offset = decoded_offset
    end
    if op == "list" then
        local limit: integer? = nil
        if value.limit ~= nil then
            local declared = bounds.integer(value.limit)
            if not declared or declared < 1 or declared > M.MAX_LIST then
                return nil, "limit must be between 1 and " .. tostring(M.MAX_LIST)
            end
            limit = declared
        end
        local request: ListRequest = {operation = "list", topic = topic, offset = offset, limit = limit}
        return request, nil
    end
    if op == "search" then
        if type(value.query) ~= "string" then
            return nil, "query must be nonempty text of at most " .. tostring(M.MAX_QUERY_BYTES) .. " bytes"
        end
        local query: string = value.query
        if #query == 0 or #query > M.MAX_QUERY_BYTES then
            return nil, "query must be nonempty text of at most " .. tostring(M.MAX_QUERY_BYTES) .. " bytes"
        end
        if query:find("%c") then return nil, "query must be one line" end
        local limit: integer? = nil
        if value.limit ~= nil then
            local declared = bounds.integer(value.limit)
            if not declared or declared < 1 or declared > M.MAX_RESULTS then
                return nil, "limit must be between 1 and " .. tostring(M.MAX_RESULTS)
            end
            limit = declared
        end
        local request: SearchRequest = {operation = "search", query = query, topic = topic, offset = offset, limit = limit}
        return request, nil
    end
    local id = M.document_id(value.id)
    if not id then return nil, "id must be a corpus document id" end
    local section: string? = nil
    if value.section ~= nil then
        local decoded_section = bounds.line(value.section, 120)
        if not decoded_section or not decoded_section:match("^[a-z0-9_%-]+$") then return nil, "section must be a heading anchor" end
        section = decoded_section
    end
    local limit = M.MAX_READ_BYTES
    if value.limit ~= nil then
        local declared = bounds.integer(value.limit)
        if not declared or declared < 1 or declared > M.MAX_READ_BYTES then
            return nil, "limit must be between 1 and " .. tostring(M.MAX_READ_BYTES)
        end
        limit = declared
    end
    local request: ReadRequest = {operation = "read", id = id, section = section, offset = offset, limit = limit}
    return request, nil
end
-- The MCP input schema, generated from the same bounds the decoder enforces
-- so the advertised contract cannot drift from what read accepts.
function M.schema(): {[string]: unknown}
    local id = {type = "string", minLength = 1, maxLength = M.MAX_ID_BYTES}
    local topic = {type = "string", pattern = "^[a-z0-9_-]+$", maxLength = 64}
    return {type = "object", additionalProperties = false, required = {"operation"},
        properties = {
            operation = {type = "string", enum = {"list", "search", "read"}},
            topic = topic,
            query = {type = "string", minLength = 1, maxLength = M.MAX_QUERY_BYTES},
            id = id,
            section = {type = "string", pattern = "^[a-z0-9_-]+$", maxLength = 120},
            offset = {type = "integer", minimum = 0},
            limit = {type = "integer", minimum = 1, maximum = M.MAX_READ_BYTES,
                description = "list accepts at most " .. tostring(M.MAX_LIST) .. ", search at most "
                    .. tostring(M.MAX_RESULTS) .. ", read at most " .. tostring(M.MAX_READ_BYTES)},
        },
        examples = {
            {operation = "list", topic = "terminal", offset = 0, limit = M.MAX_LIST},
            {operation = "search", query = "tty.canvas", limit = M.MAX_RESULTS},
            {operation = "read", id = "toolkit", section = "lifecycle", offset = 0, limit = 4000},
        }}
end
return M
