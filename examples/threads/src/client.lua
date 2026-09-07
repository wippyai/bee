-- MIT. Private fixture RPC; not a public Bee API.
local process = require("process")
local channel = require("channel")
local time = require("time")
type Event = {seq: integer, source: string, key: string, kind: string, body: string}
type Reply = {seq: integer, rows: {Event}, error: string}
local M = {}
function M.decode(value: unknown): Reply?
    if type(value) ~= "table" then return nil end
    local raw_seq, raw_rows, error_text = value.seq, value.rows, value.error
    if type(raw_seq) ~= "number" or raw_seq < 0 or raw_seq > 10000 or raw_seq ~= math.floor(raw_seq) then return nil end
    if type(raw_rows) ~= "table" then return nil end
    if type(error_text) ~= "string" or #error_text > 4096 then return nil end
    local receipt = math.floor(raw_seq)
    local count = 0
    for index in pairs(raw_rows) do
        if type(index) ~= "number" or index < 1 or index > 64 or index ~= math.floor(index) then return nil end
        count = count + 1
    end
    local rows: {Event} = {}
    local previous = 0
    for index = 1, count do
        local row: unknown = raw_rows[index]
        if type(row) ~= "table" then return nil end
        local seq, source, key, kind, body = row.seq, row.source, row.key, row.kind, row.body
        if type(seq) ~= "number" or seq <= previous or seq > 10000 or seq ~= math.floor(seq) then return nil end
        if type(source) ~= "string" or #source == 0 or #source > 256 then return nil end
        if type(key) ~= "string" or #key == 0 or #key > 256 then return nil end
        if type(kind) ~= "string" or #kind == 0 or #kind > 256 then return nil end
        if type(body) ~= "string" or #body > 16384 then return nil end
        previous = math.floor(seq)
        rows[index] = {seq = previous, source = source, key = key, kind = kind, body = body}
    end
    return {seq = receipt, rows = rows, error = error_text}
end
function M.call(owner: string, op: string, thread: string, key: string, kind: string, body: string, after: integer, capability: string?): Reply
    local replies = assert(process.listen("bee.thread_demo.reply", {message = true}))
    local timeout = assert(time.timer("3s"))
    assert(process.send(owner, "bee.thread_demo.request", {version = 1, op = op, thread = thread, key = key, kind = kind, body = body, after = after, capability = capability or ""}))
    local result: Reply = {seq = 0, rows = {}, error = "timeout"}
    while true do
        local selected = channel.select({replies:case_receive(), timeout:channel():case_receive()})
        if not selected.ok or selected.channel ~= replies then break end
        if selected.value:from() == owner then
            local data: unknown = selected.value:payload():data()
            if type(data) == "table" and data.version == 1 then
                local decoded = M.decode(data)
                if decoded then result = decoded
                else result = {seq = 0, rows = {}, error = "invalid reply"} end
                break
            end
        end
    end
    timeout:stop(); process.unlisten(replies)
    return result
end
return M
