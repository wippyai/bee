-- MIT. Native fan-out gate before exposing observers through Bee's owner protocol.
local tty = require("tty")
local process = require("process")
local channel = require("channel")
local time = require("time")
local M = {}

function M.producer(owner: string)
    local commands = assert(process.listen("bee.observation.paint", {message = true}))
    assert(tty.start())
    local output = assert(tty.surface())
    assert(process.send(owner, "bee.observation.ready", {}))
    while true do
        local message = commands:receive()
        if not message then break end
        if message:from() == owner then
            local data: unknown = message:payload():data()
            if type(data) == "string" then
                if data == "stop" then break end
                assert(output:present({data}))
            end
        end
    end
    output:close()
    tty.stop()
    process.unlisten(commands)
end

function M.main()
    local owner = tostring(process.pid())
    local ready = assert(process.listen("bee.observation.ready", {message = true}))
    local view, view_error = tty.viewport({width = 80, height = 24})
    if not view then error(tostring(view_error)) end
    local grant = assert(view:grant())
    local producer = tostring(assert(process.with_options({terminal = grant}):spawn_monitored(
        "bee.attachment_probe:observer_producer", "bee:workers", owner)))
    assert(ready:receive():from() == producer)
    local control_ref, control_mount_error = view:mount(owner, {observe = true, input = true, resize = true})
    if not control_ref then error(tostring(control_mount_error)) end
    local observer_ref, observer_mount_error = view:mount(owner, {observe = true})
    if not observer_ref then error(tostring(observer_mount_error)) end
    local controller, control_error = tty.attach(control_ref)
    if not controller then error(tostring(control_error)) end
    local observer, observer_error = tty.attach(observer_ref)
    if not observer then error(tostring(observer_error)) end
    local control_updates = assert(controller:updates())
    local observer_updates = assert(observer:updates())
    local timer = assert(time.ticker("2s"))
    local deadline = timer:channel()
    assert(process.send(producer, "bee.observation.paint", "BEE_FANOUT"))
    local saw_control, saw_observer = false, false
    while not saw_control or not saw_observer do
        local selected = channel.select({control_updates:case_receive(), observer_updates:case_receive(), deadline:case_receive()})
        assert(selected.ok and selected.channel ~= deadline, "Independent update stream did not receive a frame")
        if selected.channel == control_updates then
            saw_control = table.concat(assert(controller:snapshot()).rows):find("BEE_FANOUT", 1, true) ~= nil
        elseif selected.channel == observer_updates then
            saw_observer = table.concat(assert(observer:snapshot()).rows):find("BEE_FANOUT", 1, true) ~= nil
        end
    end
    local sent, input_error = observer:send({type = "key", key = "x", key_type = "runes", action = "press"})
    assert(not sent and input_error, "Observer received input authority")
    local resized, resize_error = observer:resize(30, 10)
    assert(not resized and resize_error, "Observer received resize authority")
    local delegated, delegation_error = observer:mount(owner, {observe = true})
    assert(not delegated and delegation_error, "Observer redelegated its grant")
    assert(view:revoke(observer_ref))
    local snapshot, snapshot_error = observer:snapshot()
    assert(not snapshot and snapshot_error, "Revoked observer retained snapshot access")
    while true do
        local selected = channel.select({observer_updates:case_receive(), deadline:case_receive()})
        assert(selected.channel ~= deadline, "Revoked observer update stream did not close")
        if not selected.ok then break end
    end
    assert(controller:resize(90, 32))
    assert(controller:send({type = "key", key = "x", key_type = "runes", action = "press"}))
    assert(process.send(producer, "bee.observation.paint", "BEE_CONTROLLER_REMAINS"))
    local continued = false
    while not continued do
        local selected = channel.select({control_updates:case_receive(), deadline:case_receive()})
        assert(selected.ok and selected.channel ~= deadline, "Observer revoke interrupted the controller")
        local frame = assert(controller:snapshot())
        continued = table.concat(frame.rows):find("BEE_CONTROLLER_REMAINS", 1, true) ~= nil
        if continued then assert(frame.width == 90 and frame.height == 32) end
    end
    timer:stop()
    observer:close(); controller:close(); view:close()
    process.terminate(producer)
    process.unlisten(ready)
end

return M
