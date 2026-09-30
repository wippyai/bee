-- SPDX-License-Identifier: MIT
local process = require("process")
local bounds = require("bounds")
local image = require("image")
local channel = require("channel")
local M = {}
function M.main()
    local requests = assert(process.listen(image.REQUEST, {message = true}))
    assert(process.registry.register(image.OWNER))
    local events = assert(process.events())
    local stopping = false
    while true do
        local selected = channel.select({requests:case_receive(), events:case_receive()})
        if not selected.ok then break end
        if selected.channel == events then
            if selected.value.kind == process.event.CANCEL then break end
        else
            local message = selected.value
            local value = bounds.object(message:payload():data())
            local id = value and bounds.id(value.request_id) or nil
            if value and value.version == 1 and id and id:match("^[0-9a-f-]+$")
                and not bounds.fields(value, {"version", "request_id"}) then
                local sender = tostring(message:from())
                local profile, reason, recipient = image.authorized_request(id, sender)
                local digest, route, failure = nil, nil, reason
                if profile then
                    local completed = channel.new(1)
                    local cancel = channel.new(1)
                    coroutine.spawn(function()
                        local built, interactive, problem = image.build(profile, recipient, cancel)
                        completed:send({image = built, route = interactive, error = problem})
                    end)
                    while true do
                        local event = channel.select({completed:case_receive(), events:case_receive()})
                        if not event.ok then stopping = true; cancel:send(true); break end
                        if event.channel == completed then
                            local result = event.value :: {image: string?, route: string?, error: string?}
                            digest, route, failure = result.image, result.route, result.error
                            break
                        elseif event.value.kind == process.event.CANCEL then
                            stopping = true
                            cancel:send(true)
                        end
                    end
                end
                process.send(sender, image.REPLY, {version = 1, request_id = id, image = digest, route = route, error = failure})
            end
        end
        if stopping then break end
    end
    process.registry.unregister(image.OWNER)
    process.unlisten(requests)
end
return M
