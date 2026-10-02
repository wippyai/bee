-- MIT. The fixture owner verifies retention and its running worker's definition.
local process = require("process")
local registry = require("registry")
local time = require("time")
local channel = require("channel")
local uuid = require("uuid")
local fs = require("fs")
local logger = require("logger")
local bounds = require("bounds")
local function handle(raw: unknown): unknown
    local request = bounds.object(raw)
    assert(request and request.version == 1 and request.service == "bee.files.service:worker_service")
    local digest = bounds.line(request.digest, 64)
    assert(digest)
    local intent = assert(registry.snapshot()):get("bee.hub.operations:" .. digest)
    assert(intent, "owner was called before durable intent")
    local worker = process.registry.lookup("bee.files.fixture.worker")
    if request.phase == "ready" then
        local deadline = time.after("5s")
        while not worker do
            local poll = time.after("25ms")
            local selected = channel.select({poll:case_receive(), deadline:case_receive()})
            assert(selected.ok and selected.channel == poll, "new service registration is not ready")
            worker = process.registry.lookup("bee.files.fixture.worker")
        end
    end
    if worker then
        local topic = "bee.files.fixture.reply." .. tostring(assert(uuid.v4()))
        local inbox = assert(process.listen(topic, {message = true}))
        assert(process.send(worker, "bee.files.fixture", {request = request, topic = topic}))
        local deadline = time.after("5s")
        local selected = channel.select({inbox:case_receive(), deadline:case_receive()})
        assert(selected.ok and selected.channel == inbox and selected.value:from() == worker, "owner drain or readiness is uncertain")
        local reply = bounds.object(selected.value:payload():data())
        process.unlisten(inbox)
        assert(reply and reply.ok == true)
        request = reply
    else
        assert(request.phase == "quiesce", "new service worker is absent")
        request.ok = true
    end
    local volume = assert(fs.get("bee.files.service:retained"))
    local accepted = volume:readfile("accepted.txt")
    if request.phase == "quiesce" and accepted then assert(volume:readfile("work.txt") == accepted, "owner lost accepted work") end
    if request.phase == "quiesce" and volume:stat("crash.once") then
        assert(volume:writefile("crash.drained", digest, {atomic = true}))
        logger:info("COMPONENT_LIFECYCLE_CRASH_POINT", {digest = digest})
        channel.select({time.after("60s"):case_receive()})
    end
    return request
end
return {handle = handle}
