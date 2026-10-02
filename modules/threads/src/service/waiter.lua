-- MIT. The waiter: a bounded registry of live waits, woken by commit
-- notifications. Registrations are keyed by the authenticated sender; a
-- wakeup is a hint, never an outcome. Nothing here is durable.
local process = require("process")
local channel = require("channel")
local time = require("time")
local waits = require("waits")
type Registration = {waiter_id: string, pid: string, topic: string, thread_id: string, after_sequence: integer, deadline_at: integer}
local function main()
    local registered, register_error = process.registry.register(waits.WAITER_NAME)
    if not registered then error("register waiter: " .. tostring(register_error)) end
    local registrations: {[string]: Registration} = {}
    local per_thread: {[string]: integer} = {}
    local total = 0
    local function remove(waiter_id: string)
        local registration = registrations[waiter_id]
        if not registration then return end
        registrations[waiter_id] = nil
        per_thread[registration.thread_id] = (per_thread[registration.thread_id] or 1) - 1
        total = total - 1
    end
    local function sweep(now: integer)
        for waiter_id, registration in pairs(registrations) do
            if registration.deadline_at <= now then remove(waiter_id) end
        end
    end
    local registers = assert(process.listen(waits.TOPIC_REGISTER, {message = true}))
    local unregisters = assert(process.listen(waits.TOPIC_UNREGISTER, {message = true}))
    local commits = assert(process.listen(waits.TOPIC_COMMITTED, {message = true}))
    local events = assert(process.events())
    local ticker = time.ticker("1s")
    while true do
        local selected = channel.select({registers:case_receive(), unregisters:case_receive(), commits:case_receive(), ticker:channel():case_receive(), events:case_receive()})
        if not selected.ok then return end
        if selected.channel == events then
            if selected.value.kind == process.event.CANCEL then return end
        elseif selected.channel == ticker:channel() then
            sweep(math.floor(time.now():unix_nano() / 1000000))
        elseif selected.channel == registers then
            local message = selected.value
            local sender = tostring(message:from())
            local data: unknown = message:payload():data()
            if type(data) == "table" and type(data.waiter_id) == "string" and type(data.topic) == "string" and type(data.thread_id) == "string"
                and type(data.after_sequence) == "number" and type(data.deadline_at) == "number" then
                sweep(math.floor(time.now():unix_nano() / 1000000))
                local count = per_thread[data.thread_id] or 0
                if total >= waits.MAX_WAITERS or count >= waits.MAX_WAITERS_PER_THREAD then
                    process.send(sender, data.topic, {registered = false, reason = "BUSY"})
                else
                    registrations[data.waiter_id] = {waiter_id = data.waiter_id, pid = sender, topic = data.topic, thread_id = data.thread_id,
                        after_sequence = math.floor(data.after_sequence), deadline_at = math.floor(data.deadline_at)}
                    per_thread[data.thread_id] = count + 1
                    total = total + 1
                    process.send(sender, data.topic, {registered = true})
                end
            end
        elseif selected.channel == unregisters then
            local message = selected.value
            local data: unknown = message:payload():data()
            if type(data) == "table" and type(data.waiter_id) == "string" then
                local registration = registrations[data.waiter_id]
                if registration and registration.pid == tostring(message:from()) then remove(data.waiter_id) end
            end
        else
            local message = selected.value
            local data: unknown = message:payload():data()
            if type(data) == "table" and type(data.thread_id) == "string" then
                for waiter_id, registration in pairs(registrations) do
                    if registration.thread_id == data.thread_id then
                        process.send(registration.pid, registration.topic, {woke = true, thread_id = data.thread_id})
                        remove(waiter_id)
                    end
                end
            end
        end
    end
end
return {main = main}
