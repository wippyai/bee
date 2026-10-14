local bounds = require("bounds")
local M = {}
-- One list page, one search page, one read window. The read window matches the
-- record text bound the other agent-facing tools already use.
M.MAX_LIST = 64
M.MAX_RESULTS = 16
M.MAX_READ_BYTES = 16384
M.MAX_QUERY_BYTES = 256
M.MAX_ID_BYTES = 160
M.MAX_PATH_BYTES = 240
type Operation = "list" | "search" | "read"
type WebOperation = "web_search" | "web_read" | "web_toc" | "web_index"
type ListRequest = {operation: "list", topic: string?, offset: integer, limit: integer?}
type SearchRequest = {operation: "search", query: string, topic: string?, offset: integer, limit: integer?}
type ReadRequest = {operation: "read", id: string, section: string?, offset: integer, limit: integer}
-- The live operations read the documentation site the corpus is selected
-- from; each answers one window of the fetched page.
type WebRequest = {operation: WebOperation, query: string?, path: string?, offset: integer, limit: integer}
type Request = ListRequest | SearchRequest | ReadRequest
local WEB_FIELDS: {[string]: {string}} = {web_search = {"query"}, web_read = {"path"}, web_toc = {}, web_index = {}}
local function web_operation(value: unknown): WebOperation?
    if value == "web_search" then return "web_search" end
    if value == "web_read" then return "web_read" end
    if value == "web_toc" then return "web_toc" end
    if value == "web_index" then return "web_index" end
    return nil
end
function M.document_id(value: unknown): string?
    local id = bounds.id(value)
    if not id or #id > M.MAX_ID_BYTES or not id:match("^[%w_./:-]+$") or id:find("..", 1, true) then return nil end
    return id
end
local function query_text(value: unknown): (string?, string?)
    if type(value) ~= "string" or #value == 0 or #value > M.MAX_QUERY_BYTES then
        return nil, "query must be nonempty text of at most " .. tostring(M.MAX_QUERY_BYTES) .. " bytes"
    end
    if value:find("%c") then return nil, "query must be one line" end
    return value, nil
end
local function window_bounds(value: {[string]: unknown}): (integer?, integer?, string?)
    local offset = 0
    if value.offset ~= nil then
        local decoded = bounds.count(value.offset)
        if not decoded then return nil, nil, "offset must be a nonnegative integer" end
        offset = decoded
    end
    local limit = M.MAX_READ_BYTES
    if value.limit ~= nil then
        local declared = bounds.integer(value.limit)
        if not declared or declared < 1 or declared > M.MAX_READ_BYTES then
            return nil, nil, "limit must be between 1 and " .. tostring(M.MAX_READ_BYTES)
        end
        limit = declared
    end
    return offset, limit, nil
end
-- web decodes a live documentation request, or returns nil without an error
-- when raw names an offline operation for decode.
function M.web(raw: unknown): (WebRequest?, string?)
    local value = bounds.object(raw)
    local op = value and web_operation(value.operation)
    if not value or not op then return nil, nil end
    local allowed: {string} = {"operation", "offset", "limit"}
    for _, field in ipairs(WEB_FIELDS[op]) do allowed[#allowed + 1] = field end
    local extra = bounds.fields(value, allowed)
    if extra then return nil, extra end
    local offset, limit, window_error = window_bounds(value)
    if not offset or not limit then return nil, window_error end
    local request: WebRequest = {operation = op, offset = offset, limit = limit}
    if op == "web_search" then
        local query, query_error = query_text(value.query)
        if not query then return nil, query_error end
        request.query = query
    elseif op == "web_read" then
        local path = bounds.line(value.path, M.MAX_PATH_BYTES)
        if not path or not path:match("^[a-z0-9][a-z0-9_./-]*$") or path:find("..", 1, true) or path:find("//", 1, true) then
            return nil, "path must be a documentation page path"
        end
        request.path = path
    end
    return request, nil
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
            operation = {type = "string", enum = {"list", "search", "read", "web_search", "web_read", "web_toc", "web_index"}},
            topic = topic,
            query = {type = "string", minLength = 1, maxLength = M.MAX_QUERY_BYTES},
            id = id,
            section = {type = "string", pattern = "^[a-z0-9_-]+$", maxLength = 120},
            path = {type = "string", pattern = "^[a-z0-9][a-z0-9_./-]*$", maxLength = M.MAX_PATH_BYTES,
                description = "web_read: a page path from web_toc or web_search, such as lua/core/process"},
            offset = {type = "integer", minimum = 0},
            limit = {type = "integer", minimum = 1, maximum = M.MAX_READ_BYTES,
                description = "list accepts at most " .. tostring(M.MAX_LIST) .. ", search at most "
                    .. tostring(M.MAX_RESULTS) .. ", read and the web operations at most " .. tostring(M.MAX_READ_BYTES) .. " bytes"},
        },
        examples = {
            {operation = "list", topic = "terminal", offset = 0, limit = M.MAX_LIST},
            {operation = "search", query = "tty.canvas", limit = M.MAX_RESULTS},
            {operation = "read", id = "toolkit", section = "lifecycle", offset = 0, limit = 4000},
            {operation = "web_search", query = "process.spawn"},
            {operation = "web_read", path = "lua/core/process", offset = 0, limit = 16384},
        }}
end
return M
