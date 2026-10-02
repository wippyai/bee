-- MIT. Disposable service with accepted work and a retained owner file.
local process = require("process")
local registry = require("registry")
local channel = require("channel")
local time = require("time")
local fs = require("fs")
local logger = require("logger")
local bounds = require("bounds")
local hash = require("hash")
local canonical = require("canonical")
local VERSION = "__SERVICE_VERSION__"
local function main()
    local entry = assert(registry.snapshot()):get("bee.files.service:worker")
    assert(entry)
    local encoded = assert(canonical.encode({id = entry.id, kind = entry.kind, meta = entry.meta or {}, data = entry.data}, 1048576))
    local definition = assert(hash.sha256(encoded))
    local inbox = assert(process.listen("bee.files.fixture", {message = true}))
    local events = assert(process.events())
    local volume = assert(fs.get("bee.files.service:retained"))
    local pending: {recipient: string, topic: string, value: string, due: Channel<time.Time>}? = nil
    local waiting: {recipient: string, topic: string, request: {[string]: unknown}}? = nil
    local function fenced(): boolean
        local state = assert(assert(registry.snapshot()):state())
        for _, entry in ipairs(state.entries) do
            local receipt = entry.id:sub(1, 19) == "bee.hub.operations:" and bounds.object(entry.data)
            local work = receipt and bounds.object(receipt.lifecycle_work)
            local services = work and bounds.array(work.services, 128)
            if services and work and work.phase ~= "ready" then
                for _, raw in ipairs(services) do local service = bounds.object(raw); if service and service.owner == "bee/files" then return true end end
            end
        end
        return false
    end
    assert(process.registry.register("bee.files.fixture.worker"))
    logger:info("COMPONENT_SERVICE_READY", {version = VERSION, pid = tostring(process.pid())})
    while true do
        local cases = {inbox:case_receive(), events:case_receive()}
        if pending then cases[#cases + 1] = pending.due:case_receive() end
        local selected = channel.select(cases)
        if selected.channel == events then
            assert(not pending, "accepted work was canceled")
            return
        elseif pending and selected.channel == pending.due then
            assert(volume:writefile("work.txt", pending.value, {atomic = true}))
            process.send(pending.recipient, pending.topic, {ok = true, value = pending.value})
            pending = nil
        elseif selected.ok then
            local message = selected.value
            local input = bounds.object(message:payload():data())
            local topic = input and bounds.line(input.topic, 128)
            if input and topic then
                if input.operation == "accept" then
                    local value = bounds.line(input.value, 128)
                    if value and not pending and not fenced() then
                        assert(volume:writefile("accepted.txt", value, {atomic = true}))
                        pending = {recipient = tostring(message:from()), topic = topic, value = value, due = time.after("250ms")}
                        process.send(message:from(), topic, {accepted = true})
                    else process.send(message:from(), topic, {ok = false}) end
                else
                    local request = bounds.object(input.request)
                    if request and request.definition == definition then
                        if request.phase == "quiesce" then waiting = {recipient = tostring(message:from()), topic = topic, request = request}
                        elseif request.phase == "ready" then
                            request.ok = true
                            process.send(message:from(), topic, request)
                        end
                    end
                end
            end
        end
        if waiting and not pending then
            local request = waiting.request
            request.ok = true
            process.send(waiting.recipient, waiting.topic, request)
            waiting = nil
        end
    end
end
return {main = main}
