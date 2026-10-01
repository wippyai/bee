-- MIT. Test producer for the shared singleton navigation contract.
local tty = require("tty")
local process = require("process")
local channel = require("channel")
local client = require("client")
local function main(raw: unknown)
    local launch = assert(client.launch(raw))
    local navigation = assert(process.listen("bee.app.navigate", {message = true}))
    local events = assert(process.events())
    assert(tty.start())
    local surface = assert(tty.surface())
    local function show(args: {string})
        local canvas = tty.canvas(60, 16)
        canvas:put(1, 1, args[1] or "empty", 60)
        assert(surface:present(canvas:rows()))
    end
    show(launch.arguments)
    client.ready(launch)
    while true do
        local selected = channel.select({navigation:case_receive(), events:case_receive()})
        if not selected.ok or selected.channel == events then break end
        local sender = tostring(selected.value:from())
        local value: unknown = selected.value:payload():data()
        local args = client.navigation(launch, sender, value)
        if args then show(args) end
    end
    process.unlisten(navigation)
    tty.stop()
end
return {main = main}
