local process = require("process")
local sql = require("sql")
local client = require("client")
local contract = require("contract")
local security = require("security")
local reader = require("reader")
local function main(owner: string, thread: string, after: integer, read_capability: string)
    local binding = assert(contract.open("bee.thread.demo:reader_binding"))
    local framing: unknown = binding:inspect()
    assert(type(framing) == "table", "Invalid native contract result")
    local actor = assert(security.actor())
    assert(type(framing.pid) == "string" and framing.pid ~= tostring(process.pid()), "Contract function must have its own execution identity")
    assert(framing.actor == actor:id() and framing.storage_denied == true, "Contract lost caller actor or scope")
    local owned: unknown = binding:inspect_owned_storage()
    assert(type(owned) == "table" and owned.actor == actor:id() and owned.storage_denied == false,
        "Function-owned storage policy did not preserve caller actor")
    local journal = assert(reader.open(owner, thread, read_capability))
    local initial, initial_error = journal:read_after(after)
    assert(initial and not initial_error, "Native contract read failed")
    local foreign: unknown = binding:read_after(owner, thread .. "/foreign", read_capability, after)
    assert(type(foreign) == "table" and foreign.error == "denied", "Read capability escaped its thread")
    local malformed: unknown = binding:read_after(owner, thread, read_capability, 0.5)
    assert(type(malformed) == "table" and malformed.error == "invalid", "Contract accepted fractional cursor")
    assert(client.call(owner, "append", thread, "spoof", "test.run.finished", "{}", 0, read_capability).error == "denied")
    assert(not client.decode({seq = 0, rows = {[2] = {seq = 1, source = "s", key = "k", kind = "e", body = "{}"}}, error = ""}), "Sparse event page accepted")
    assert(not client.decode({seq = 0, rows = {{seq = 1, source = "s", key = "k", kind = "e", body = "{}"},
        {seq = 1, source = "s", key = "k", kind = "e", body = "{}"}}, error = ""}), "Duplicate event sequence accepted")
    local database, denied = sql.get("bee.thread.demo:db")
    assert(not database and denied, "Subscriber accessed owner storage")
    assert(client.call(owner, "read", thread .. "/foreign", "", "", "", 0).error == "denied")
    assert(client.call(owner, "append", thread, "spoof", "test.run.finished", "{}", 0).error == "denied")
    local cursor = after
    while true do
        local wake = client.call(owner, "wait", thread, "", "", "", cursor)
        assert(wake.error == "", wake.error)
        -- Wakeups only prompt catch-up; the native reader returns durable rows.
        local reply, read_error = journal:read_after(cursor)
        if not reply then error(read_error or "Read failed") end
        for _, value in ipairs(reply.rows) do
            if type(value) ~= "table" or type(value.seq) ~= "number" or type(value.kind) ~= "string" or type(value.body) ~= "string" then error("Invalid event") end
            local seq = math.floor(value.seq)
            assert(seq > cursor, "Cursor moved backwards")
            cursor = seq
            assert(process.send(owner, "bee.thread.demo.request", {version = 1, op = "status", thread = thread,
                text = tostring(seq) .. "  " .. value.kind .. "  " .. value.body}))
        end
        local done = client.call(owner, "caught_up", thread, "", "", "", cursor)
        if done.error == "" then break end
        assert(done.error == "pending", done.error)
    end
    assert(process.send(owner, "bee.thread.demo.request", {version = 1, op = "subscriber_done", thread = thread}))
end
return {main = main}
