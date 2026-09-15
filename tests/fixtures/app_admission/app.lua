-- MIT. The displayed result comes from the actual launched scope.
local client = require("client")
local tty = require("tty")
local process = require("process")
local security = require("security")
local function main(value: unknown)
    local launch = assert(client.launch(value))
    local closes = assert(process.listen("bee.application.close", {message = true}))
    assert(tty.start())
    local surface = assert(tty.surface())
    assert(surface:present({security.can("bee.admission.probe", "fixture") and "GRANTED" or "DENIED"}))
    client.ready(launch)
    while true do
        local message = assert(closes:receive())
        if message:from() == launch.broker_pid then break end
    end
    process.unlisten(closes)
    tty.stop()
end
return {main = main}
