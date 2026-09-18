-- MIT. Limits shared by decoders, the encoder and storage. A bound lives here
-- once; a decoder enforces it and a table CHECK repeats it for the file.
local M = {}
M.SCHEMA_REVISION = "bee.thread-record@1"
M.MAX_ID_BYTES = 160
M.MAX_RECORD_BYTES = 16384
M.MAX_PAGE_RECORDS = 64
M.MAX_THREAD_RECORDS = 10000
M.MAX_THREAD_MEMBERS = 128
M.MAX_THREAD_ACTIONS = 128
M.MAX_THREAD_ATTEMPTS = 128
M.MAX_THREAD_TURNS = 128
M.MAX_THREAD_OBLIGATIONS = 2048
M.MAX_ARRAY_ITEMS = 64
M.MAX_JSON_DEPTH = 16
M.MAX_TITLE_BYTES = 512
M.MAX_FAULT_MESSAGE_BYTES = 4096
M.KINDS = {"observation", "message", "action.admitted", "attempt.prepared", "attempt.started", "turn.request", "turn.end", "receipt", "delivery.mark", "request.answered", "approval.request", "approval.transition"}
M.SOURCES = {"stream", "hook", "transcript", "mcp", "bee"}
M.OUTCOMES = {"succeeded", "failed", "cancelled", "uncertain"}
-- Identifiers: short, printable, and never empty.
function M.id(value: unknown): string?
    if type(value) ~= "string" or #value == 0 or #value > M.MAX_ID_BYTES or value:find("%c") then return nil end
    return value
end
-- Text carries content; it may span lines but stays within one record.
function M.text(value: unknown, limit: integer?): string?
    if type(value) ~= "string" or #value > (limit or M.MAX_RECORD_BYTES) then return nil end
    return value
end
-- One line of bounded text: nonempty, no control characters.
function M.line(value: unknown, limit: integer): string?
    if type(value) ~= "string" or #value == 0 or #value > limit or value:find("%c") then return nil end
    return value
end
function M.integer(value: unknown): integer?
    if type(value) ~= "number" or value ~= math.floor(value) or value ~= value then return nil end
    if value > 9007199254740991 or value < -9007199254740991 then return nil end
    return math.floor(value)
end
function M.count(value: unknown): integer?
    local number = M.integer(value)
    if not number or number < 0 then return nil end
    return number
end
function M.sequence(value: unknown): integer?
    local number = M.integer(value)
    if not number or number < 1 or number > M.MAX_THREAD_RECORDS then return nil end
    return number
end
function M.cursor(value: unknown): integer?
    local number = M.integer(value)
    if not number or number < 0 or number > M.MAX_THREAD_RECORDS then return nil end
    return number
end
-- Canonical UTC instants with millisecond precision, the only form recorded.
function M.timestamp(value: unknown): string?
    if type(value) ~= "string" or #value ~= 24 then return nil end
    if not value:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d%.%d%d%dZ$") then return nil end
    local month, day, hour, minute, second = tonumber(value:sub(6, 7)), tonumber(value:sub(9, 10)),
        tonumber(value:sub(12, 13)), tonumber(value:sub(15, 16)), tonumber(value:sub(18, 19))
    if not month or not day or not hour or not minute or not second then return nil end
    if month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or minute > 59 or second > 59 then return nil end
    return value
end
function M.member(value: unknown, variants: {string}): string?
    if type(value) ~= "string" then return nil end
    for _, variant in ipairs(variants) do
        if variant == value then return value end
    end
    return nil
end
-- A JSON array of identifiers: dense from one, bounded, each item an id.
function M.ids(value: unknown, distinct: boolean): ({string}?, string?)
    if type(value) ~= "table" then return nil, "expected a list" end
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 then return nil, "list keys must be dense" end
        count = count + 1
    end
    if count > M.MAX_ARRAY_ITEMS then return nil, "list exceeds " .. tostring(M.MAX_ARRAY_ITEMS) .. " items" end
    local result: {string} = {}
    local seen: {[string]: boolean} = {}
    for index = 1, count do
        local item = M.id(value[index])
        if not item then return nil, "list item " .. tostring(index) .. " is not an identifier" end
        if distinct and seen[item] then return nil, "list item " .. tostring(index) .. " repeats" end
        seen[item] = true
        result[index] = item
    end
    return result, nil
end
-- Every decoder rejects fields it does not name; a typo never silently drops.
function M.fields(value: {[string]: unknown}, allowed: {string}): string?
    local permitted: {[string]: boolean} = {}
    for _, name in ipairs(allowed) do permitted[name] = true end
    for key in pairs(value) do
        if type(key) ~= "string" or not permitted[key] then return "unknown field " .. tostring(key) end
    end
    return nil
end
M.MAX_SUBPATH_BYTES = 512
-- A subpath is relative, has no empty, dot or dot-dot segments and no
-- backslashes; the empty subpath is the root itself.
function M.subpath(value: unknown): (string?, string?)
    if type(value) ~= "string" then return nil, "subpath must be a string" end
    if #value > M.MAX_SUBPATH_BYTES then return nil, "subpath is too long" end
    if value == "" then return "", nil end
    if value:sub(1, 1) == "/" or value:find("\\", 1, true) or value:find("\0", 1, true) then return nil, "subpath must be relative" end
    for segment in (value .. "/"):gmatch("([^/]*)/") do
        if segment == "" or segment == "." or segment == ".." then return nil, "subpath has an invalid segment" end
    end
    return value, nil
end
function M.object(value: unknown): {[string]: unknown}?
    if type(value) ~= "table" then return nil end
    for key in pairs(value) do
        if type(key) ~= "string" then return nil end
    end
    return value :: {[string]: unknown}
end
return M
