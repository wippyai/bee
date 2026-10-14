local process = require("process")
local tty = require("tty")
local client = require("client")
local function run(value: unknown, route: string)
    local launch = assert(client.launch(value))
    local release = assert(process.listen("bee.test.route.release", {message = true}))
    assert(tty.start())
    local output = assert(tty.surface())
    assert(output:present({"routed " .. route}))
    assert(process.send(launch.broker_pid, "bee.test.route.ready", {pid = tostring(process.pid()), route = route}))
    release:receive()
    output:close()
    tty.stop()
    process.unlisten(release)
end
return {
    selection = function(value: unknown) return run(value, "selection") end,
    execution = function(value: unknown) return run(value, "execution") end,
}
