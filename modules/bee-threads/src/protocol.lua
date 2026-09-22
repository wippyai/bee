-- MIT. Values shared by journal functions and their typed Lua client.
local M = {}
type Event = {seq: integer, run: string, key: string, kind: string, body: string}
type Reply = {ok: boolean, error: string, created: boolean, seq: integer, events: {Event}}
function M.id(value: unknown): string?
    if type(value) ~= "string" or #value == 0 or #value > 160 or value:find("%c") then return nil end
    return value
end
function M.cursor(value: unknown): integer?
    if type(value) ~= "number" or value < 0 or value > 10000 or value ~= math.floor(value) then return nil end
    return math.floor(value)
end
function M.reply(error_text: string?): Reply
    return {ok = error_text == nil, error = error_text or "", created = false, seq = 0, events = {}}
end
function M.decode(value: unknown): Reply?
    if type(value) ~= "table" then return nil end
    local ok, err, created = value.ok, value.error, value.created
    local seq, rows = M.cursor(value.seq), value.events
    if type(ok) ~= "boolean" then return nil end
    if type(err) ~= "string" or #err > 4096 then return nil end
    if type(created) ~= "boolean" then return nil end
    if not seq then return nil end
    if type(rows) ~= "table" then return nil end
    if ok ~= (err == "") then return nil end
    local count = 0
    for key in pairs(rows) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 or key > 64 then return nil end
        count = count + 1
    end
    local events: {Event} = {}
    local previous = 0
    for index = 1, count do
        local row: unknown = rows[index]
        if type(row) ~= "table" then return nil end
        local number = M.cursor(row.seq)
        local run, key, kind = M.id(row.run), M.id(row.key), M.id(row.kind)
        local body = row.body
        if not number or number <= previous or not run or not key or not kind or type(body) ~= "string" or #body > 16384 then return nil end
        previous = number
        events[index] = {seq = number, run = run, key = key, kind = kind, body = body}
    end
    return {ok = ok, error = err, created = created, seq = seq, events = events}
end
return M
