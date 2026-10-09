-- SPDX-License-Identifier: MIT
local process = require("process")
local bounds = require("bounds")
local image = require("image")
local channel = require("channel")
local environment = require("environment")
local service = require("service")
local demand = require("demand")
local task = require("task")
local M = {}
type Request = {sender: string, id: string}
function M.main()
    local requests = assert(process.listen(image.REQUEST, {message = true}))
    local demanded = assert(process.listen(demand.WAKE, {message = true}))
    assert(process.registry.register(image.OWNER))
    local events = assert(process.events())
    local generation = 0
    local queue: {Request} = {}
    local stopping = false
    local cancel = channel.new(1)
    local build: task.Task = task.new("Docker operation", function(): boolean
        local request = table.remove(queue, 1)
        if not request then return true end
        local profile, reason, recipient, operation, workspace = image.authorized_request(request.id, request.sender)
        local digest, route, failure = nil, nil, reason
        if profile then
            local called, built, interactive, problem = pcall(function(): (string?, string?, string?)
                if operation and workspace then
                    local address, cause = environment.run(profile.ref, profile.digest, profile.profile.network or "none", workspace, recipient, cancel, operation == "revoke")
                    return address, nil, cause
                end
                return image.build(profile, recipient, cancel)
            end)
            if called then digest, route, failure = built, interactive, problem
            else failure = tostring(built) end
        end
        assert(process.send(request.sender, image.REPLY, {version = 1, request_id = request.id, image = digest, route = route, error = failure}))
        return true
    end)
    build.pending = false
    local sweep = task.new("Docker supervision", function(): boolean return service.sweep().ok end)
    assert(demand.ready(image.OWNER))
    local function enqueue(sender: string, raw: unknown)
        local value = bounds.object(raw)
        local id = value and bounds.id(value.request_id)
        if value and value.version == 1 and id and id:match("^[0-9a-f-]+$")
            and not bounds.fields(value, {"version", "request_id"}) then
            queue[#queue + 1] = {sender = sender, id = id}
            task.wake(build)
        end
    end
    while true do
        if not stopping then task.advance(build); task.advance(sweep) end
        if stopping and not build.active then break end
        if not stopping and generation > 0 and #queue == 0 and task.quiet(build) and task.quiet(sweep) then
            assert(demand.quiet(image.OWNER, generation))
        end
        local cases = {requests:case_receive(), demanded:case_receive(), events:case_receive(),
            build.completed:case_receive(), sweep.completed:case_receive()}
        local build_retry, sweep_retry = task.deadline(build), task.deadline(sweep)
        if build_retry then cases[#cases + 1] = build_retry:case_receive() end
        if sweep_retry then cases[#cases + 1] = sweep_retry:case_receive() end
        local selected = channel.select(cases)
        if not selected.ok then stopping = true; cancel:send(true)
        elseif selected.channel == events then
            if selected.value.kind == process.event.CANCEL then stopping = true; cancel:send(true) end
        elseif selected.channel == build.completed then
            task.finish(build, selected.value == true)
            if #queue > 0 then task.wake(build) end
        elseif selected.channel == sweep.completed then
            task.finish(sweep, selected.value == true)
            if selected.value == true and not sweep.pending and service.pending() then task.defer(sweep, service.SWEEP_INTERVAL_MS) end
        elseif selected.channel == requests then
            enqueue(tostring(selected.value:from()), selected.value:payload():data())
        elseif selected.channel == demanded then
            local supervisor = process.registry.lookup(demand.SUPERVISOR, process.registry.LOCAL)
            local message = selected.value
            local value = bounds.object(message:payload():data())
            if supervisor and tostring(message:from()) == tostring(supervisor) and value and type(value.generation) == "number" then
                generation = math.floor(value.generation)
                task.wake(sweep)
                for _, raw in ipairs(bounds.array(value.requests, 64) or {}) do
                    local request = bounds.object(raw)
                    if request and type(request.caller) == "string" then enqueue(request.caller, request.data) end
                end
            end
        end
    end
    process.registry.unregister(image.OWNER)
    process.unlisten(requests)
    process.unlisten(demanded)
end
return M
