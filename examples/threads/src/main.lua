-- MIT. One fixed-thread owner for an isolated, bounded communication proof.
local process = require("process")
local channel = require("channel")
local security = require("security")
local time = require("time")
local io = require("io")
local store = require("store")
local uuid = require("uuid")
local function main(thread: string?, run: string?, after_text: string?)
    thread, run = thread or "local-tests", run or "first-run"
    if #thread == 0 or #thread > 80 or thread:find("%c") or #run == 0 or #run > 80 or run:find("%c") then error("Invalid thread or run ID") end
    local after = tonumber(after_text or "0")
    if not after or after < 0 or after > 10000 or after ~= math.floor(after) then error("Invalid cursor") end
    local requests = assert(process.listen("bee.thread_demo.request", {message = true}))
    local lifecycle = assert(process.events())
    local database, open_error = store.open()
    if not database then error(tostring(open_error)) end
    local participant, policy_error = security.policy("bee.thread_demo:participant")
    if not participant then error(tostring(policy_error)) end
    local binding_policy = security.policy("bee.thread_demo:binding_policy")
    local method_policy = security.policy("bee.thread_demo:method_policy")
    local function_policy = security.policy("bee.thread_demo:function_policy")
    if not binding_policy or not method_policy or not function_policy then error("Missing contract probe policy") end
    local scope = security.new_scope({participant, binding_policy, method_policy, function_policy})
    local owner = tostring(process.pid())
    local read_capability = uuid.v7()
    local reader = tostring(assert(process.with_options({}):with_scope(scope):spawn_monitored("bee.thread_demo:subscriber", "bee.thread_demo:workers", owner, thread, math.floor(after), read_capability)))
    local writer = tostring(assert(process.with_options({}):with_scope(scope):spawn_monitored("bee.thread_demo:producer", "bee.thread_demo:workers", owner, thread, run)))
    local ticker = assert(time.ticker("100ms"))
    local ticks = ticker:channel()
    local tick, waiter, waiter_deadline = 0, -1, 0
    local producer_done, subscriber_done = false, false
    local function reply(pid: string, seq: integer, rows: {unknown}, err: string)
        assert(process.send(pid, "bee.thread_demo.reply", {version = 1, seq = seq, rows = rows, error = err}))
    end
    local function read(cursor: integer): ({unknown}, string?)
        local rows, err = database:read(thread, cursor)
        if not rows then return {}, err or "read failed" end
        return rows, nil
    end
    assert(io.print("BEE THREAD / " .. thread .. " / run " .. run))
    local failure = ""
    while not (producer_done and subscriber_done) do
        local selected = channel.select({requests:case_receive(), ticks:case_receive(), lifecycle:case_receive()})
        if not selected.ok then failure = "Owner channel closed"; break end
        if selected.channel == lifecycle then
            local event = selected.value
            if event.kind == process.event.EXIT and event.result and event.result.error then
                failure = "Participant failed: " .. tostring(event.result.error); break
            end
        elseif selected.channel == ticks then
            tick = tick + 1
            if tick >= 150 then failure = "Participant did not complete within 15s"; break end
            if waiter >= 0 and tick >= waiter_deadline then
                reply(reader, 0, {}, ""); waiter = -1
            end
        else
            local sender = tostring(selected.value:from())
            local data: unknown = selected.value:payload():data()
            if type(data) == "table" and data.version == 1 and data.capability == read_capability then
                if data.op ~= "read" or data.thread ~= thread then reply(sender, 0, {}, "denied")
                elseif type(data.after) ~= "number" or data.after ~= math.floor(data.after) or data.after < 0 or data.after > 10000 then reply(sender, 0, {}, "invalid")
                else
                    local rows, err = read(math.floor(data.after))
                    reply(sender, 0, rows, err or "")
                end
            elseif sender ~= reader and sender ~= writer then
                -- Unknown senders cannot cause reflection traffic or mutate state.
            elseif type(data) ~= "table" or data.version ~= 1 or data.thread ~= thread then
                reply(sender, 0, {}, "denied")
            elseif data.op == "append" and sender == writer then
                if type(data.key) ~= "string" or type(data.kind) ~= "string" or type(data.body) ~= "string" then reply(sender, 0, {}, "invalid")
                else
                    local seq, err = database:append(thread, "test-runner", data.key, data.kind, data.body)
                    reply(sender, seq or 0, {}, err or "")
                    if not err and waiter >= 0 then
                        local rows, read_error = read(waiter)
                        reply(reader, 0, rows, read_error or ""); waiter = -1
                    end
                end
            elseif (data.op == "read" or data.op == "wait" or data.op == "caught_up") and sender == reader then
                if type(data.after) ~= "number" or data.after < 0 or data.after > 10000 or data.after ~= math.floor(data.after) then reply(sender, 0, {}, "invalid")
                elseif waiter >= 0 then reply(sender, 0, {}, "busy")
                else
                    local cursor = math.floor(data.after)
                    local rows, err = read(cursor)
                    if data.op == "caught_up" then reply(sender, 0, {}, producer_done and #rows == 0 and not err and "" or "pending")
                    elseif data.op == "wait" and not err and #rows == 0 and not producer_done then waiter, waiter_deadline = cursor, tick + 10
                    else reply(sender, 0, rows, err or "") end
                end
            elseif data.op == "producer_done" and sender == writer then
                producer_done = true
                if waiter >= 0 then local rows, err = read(waiter); reply(reader, 0, rows, err or ""); waiter = -1 end
            elseif data.op == "subscriber_done" and sender == reader then subscriber_done = true
            elseif data.op == "status" and sender == reader and type(data.text) == "string" and #data.text <= 20000 then
                local line = data.text:gsub("%c", " ")
                assert(io.print(line))
            else reply(sender, 0, {}, "denied") end
        end
    end
    process.terminate(reader); process.terminate(writer)
    ticker:stop(); process.unlisten(requests); database:close()
    if failure ~= "" then error(failure) end
    assert(io.print("Thread caught up; journal retained."))
end
return {main = main}
