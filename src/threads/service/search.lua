local sql = require("sql")
local json = require("json")
local hash = require("hash")
local bounds = require("bounds")
local canonical = require("canonical")
local record = require("record")
local record_types = require("record_types")
local values = require("values")
local reader = require("reader")
local transaction = require("transaction")
local record_bounds = require("record_bounds")
local M = {}
type Membership = (sql.Transaction, string, string) -> (reader.Head?, reader.Member?, transaction.Result?)
type Window = {thread_id: string, through: integer, head_revision: integer, member_revision: integer}
type Cursor = {fingerprint: string, windows: {Window}, thread_id: string, sequence: integer, score: integer}
local function fail(code: string, message: string): transaction.Result return transaction.failure(code, message) end
local function decode_cursor(raw: unknown, fingerprint: string): (Cursor?, transaction.Result?)
    if type(raw) ~= "string" or #raw > 16384 then return nil, fail("INVALID_ARGUMENT", "invalid continuation") end
    local object = bounds.object(json.decode(raw))
    if not object or object.fingerprint ~= fingerprint then return nil, fail("DENIED", "continuation belongs to another caller or query") end
    local rows = bounds.array(object.windows, 16)
    local thread, sequence, score = bounds.id(object.thread_id), bounds.count(object.sequence), bounds.count(object.score)
    if not rows or not thread or not sequence or not score then return nil, fail("INVALID_ARGUMENT", "invalid continuation extent") end
    local windows: {Window} = {}
    for _, raw_window in ipairs(rows) do
        local window = bounds.object(raw_window)
        local id = window and bounds.id(window.thread_id)
        local through = window and record_bounds.cursor(window.through)
        local head = window and bounds.count(window.head_revision)
        local member = window and bounds.count(window.member_revision)
        if not id or not through or not head or not member then return nil, fail("INVALID_ARGUMENT", "invalid continuation window") end
        windows[#windows + 1] = {thread_id = id, through = through, head_revision = head, member_revision = member}
    end
    return {fingerprint = fingerprint, windows = windows, thread_id = thread, sequence = sequence, score = score}, nil
end
local function fingerprint(actor: string, request: unknown): string
    return assert(hash.sha256(assert(canonical.encode({actor = actor, request = request}))))
end
local function windows(tx: sql.Transaction, actor: string, ids: {string}, previous: Cursor?, membership: Membership): ({Window}?, transaction.Result?)
    local result: {Window} = {}
    if previous then
        for _, window in ipairs(previous.windows) do
            if not bounds.member(window.thread_id, ids) then return nil, fail("DENIED", "continuation is outside its scope") end
            local head, member, denied = membership(tx, window.thread_id, actor)
            if not head or not member then return nil, denied or fail("DENIED", "thread authority has ended") end
            if window.through > head.head_sequence or window.head_revision ~= head.revision or window.member_revision ~= member.revision then
                return nil, fail("CONFLICT", "thread authority changed; start a new page")
            end
            result[#result + 1] = window
        end
    else
        for _, id in ipairs(ids) do
            local head, member, denied = membership(tx, id, actor)
            if head and member then
                result[#result + 1] = {thread_id = id, through = head.head_sequence, head_revision = head.revision, member_revision = member.revision}
            elseif denied and denied.code ~= "DENIED" and denied.code ~= "NOT_FOUND" then return nil, denied end
        end
    end
    return result, nil
end
local function kinds(raw: unknown): ({string}?, string?)
    if raw == nil then return {}, nil end
    local ids, err = bounds.ids(raw, true)
    if not ids then return nil, err end
    for _, id in ipairs(ids) do if not values.kind(id) then return nil, "unknown record kind: " .. id end end
    table.sort(ids)
    return ids, nil
end
local function continuation(fingerprint: string, windows: {Window}, thread: string, sequence: integer, score: integer): string
    return assert(canonical.encode({fingerprint = fingerprint, windows = windows, thread_id = thread, sequence = sequence, score = score}))
end
function M.search(db: sql.DB, actor: string, request: unknown, membership: Membership): transaction.Result
    local object = bounds.object(request)
    if not object or bounds.fields(object, {"scope", "query", "kinds", "cursor", "limit"}) then return fail("INVALID_ARGUMENT", "search needs scope, query, kinds, cursor and limit") end
    local scope = bounds.object(object.scope)
    local ids = scope and not bounds.fields(scope, {"thread_ids"}) and bounds.ids(scope.thread_ids, true) or nil
    local query = bounds.line(object.query, 512)
    local filter, kind_error = kinds(object.kinds)
    local limit = record_bounds.page_limit(object.limit)
    if not ids or #ids == 0 or #ids > 16 or not query or #query == 0 or not filter or not limit then return fail("INVALID_ARGUMENT", kind_error or "search needs 1 to 16 thread_ids, a nonempty query and a bounded limit") end
    table.sort(ids)
    query = query:lower()
    local digest = fingerprint(actor, {scope = ids, query = query, kinds = filter})
    local cursor: Cursor? = nil
    if object.cursor ~= nil then
        local denied: transaction.Result?
        cursor, denied = decode_cursor(object.cursor, digest)
        if not cursor then return denied or fail("INVALID_ARGUMENT", "invalid continuation") end
    end
    return transaction.read(db, function(tx: sql.Transaction): transaction.Result
        local admitted, denied = windows(tx, actor, ids, cursor, membership)
        if not admitted then return denied or fail("DENIED", "scope is unavailable") end
        if #admitted == 0 then return transaction.success({items = {}, total = 0}, false) end
        local clauses: {string}, parameters: {unknown} = {}, {}
        for _, window in ipairs(admitted) do
            clauses[#clauses + 1] = "(thread_id=? AND sequence<=?)"
            parameters[#parameters + 1] = window.thread_id; parameters[#parameters + 1] = window.through
        end
        local kind_sql = ""
        if #filter > 0 then
            local slots: {string} = {}
            for _, kind in ipairs(filter) do slots[#slots + 1] = "?"; parameters[#parameters + 1] = kind end
            kind_sql = " AND kind IN (" .. table.concat(slots, ",") .. ")"
        end
        parameters[#parameters + 1] = query; parameters[#parameters + 1] = query; parameters[#parameters + 1] = query
        local common = "WITH authorized AS (SELECT *, COALESCE(json_extract(record_json,'$.body.content.text'),json_extract(record_json,'$.body.data.text'),json_extract(record_json,'$.body.data.payload_json'),'') AS text FROM bee_thread_records WHERE (" .. table.concat(clauses, " OR ") .. ")" .. kind_sql .. "), matched AS (SELECT *, (length(lower(text))-length(replace(lower(text),?,'')))/length(?) AS score FROM authorized WHERE instr(lower(text),?)>0) "
        local totals, count_error = tx:query(common .. "SELECT COUNT(*) AS count FROM matched", parameters)
        if not totals or count_error then return fail("INTERNAL", "count authorized matches") end
        local total = bounds.count(totals[1].count)
        if not total then return fail("INTERNAL", "invalid match count") end
        local after = ""
        if cursor then
            after = " WHERE score<? OR (score=? AND (thread_id>? OR (thread_id=? AND sequence>?)))"
            for _, value in ipairs({cursor.score, cursor.score, cursor.thread_id, cursor.thread_id, cursor.sequence}) do parameters[#parameters + 1] = value end
        end
        parameters[#parameters + 1] = limit + 1
        local rows, query_error = tx:query(common .. "SELECT thread_id,record_id,sequence,record_json,score,text FROM matched" .. after .. " ORDER BY score DESC,thread_id,sequence LIMIT ?", parameters)
        if not rows or query_error then return fail("INTERNAL", "search authorized records") end
        local items: {{[string]: unknown}} = {}
        local next_cursor: string? = nil
        for index = 1, math.min(limit, #rows) do
            local row = rows[index]
            local decoded, err = record.decode_json(row.record_json)
            if not decoded then return fail("INTERNAL", err or "corrupt search record") end
            local text = bounds.text(row.text, 16384) or ""
            local start = math.max(1, (text:lower():find(query, 1, true) or 1) - 80)
            items[#items + 1] = {thread_id = decoded.thread_id, record_id = decoded.record_id, sequence = decoded.sequence, kind = decoded.kind,
                record_ref = {thread_id = decoded.thread_id, record_id = decoded.record_id}, snippet = text:sub(start, start + 511), score = row.score}
            if index == limit and #rows > limit then next_cursor = continuation(digest, admitted, decoded.thread_id, decoded.sequence, assert(bounds.count(row.score))) end
        end
        return transaction.success({items = items, total = total, next_cursor = next_cursor}, false)
    end)
end
function M.timeline(db: sql.DB, actor: string, request: unknown, membership: Membership): transaction.Result
    local object = bounds.object(request)
    if not object or bounds.fields(object, {"thread_id", "after", "cursor", "limit"}) then return fail("INVALID_ARGUMENT", "timeline needs thread_id, after, cursor and limit") end
    local thread, limit = bounds.id(object.thread_id), record_bounds.page_limit(object.limit)
    local after = record_bounds.cursor(object.after == nil and 0 or object.after)
    if not thread or not limit or not after or (object.cursor ~= nil and object.after ~= nil) then return fail("INVALID_ARGUMENT", "invalid timeline range") end
    local digest = fingerprint(actor, {thread_id = thread, method = "timeline"})
    local cursor: Cursor? = nil
    if object.cursor ~= nil then
        local denied: transaction.Result?
        cursor, denied = decode_cursor(object.cursor, digest)
        if not cursor then return denied or fail("INVALID_ARGUMENT", "invalid continuation") end
        after = cursor.sequence
    end
    return transaction.read(db, function(tx: sql.Transaction): transaction.Result
        local head, member, denied = membership(tx, thread, actor)
        if not head or not member then return denied or fail("DENIED", "thread is not readable") end
        local admitted, invalid = windows(tx, actor, {thread}, cursor, membership)
        if not admitted or #admitted ~= 1 then return invalid or fail("INVALID_ARGUMENT", "invalid timeline window") end
        local rows, err = reader.page(tx, thread, after, admitted[1].through, limit, nil, nil)
        if not rows then return fail("INTERNAL", err or "read timeline") end
        local items: {record_types.Record} = {}
        for index = 1, math.min(limit, #rows) do
            local decoded, invalid = record.decode_json(rows[index].record_json)
            if not decoded then return fail("INTERNAL", invalid or "corrupt timeline record") end
            items[#items + 1] = decoded
        end
        local last = items[#items]
        local next_cursor = #rows > limit and last and continuation(digest, admitted, thread, last.sequence, 0) or nil
        return transaction.success({items = items, next_cursor = next_cursor}, false)
    end)
end
return M
