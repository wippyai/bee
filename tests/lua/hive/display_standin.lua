-- MIT. Test-only stand-in for a native display client: it runs on the display
-- client host, so its own PID is what the desktop bridge admits, and it relays
-- the calls the test hands it and the bridge's replies.
local process = require("process")
local channel = require("channel")
local function main(test: string)
    local calls = assert(process.listen("bee.test.standin.call", {message = true}))
    local replies = assert(process.listen("bee.hive.reply", {message = true}))
    local events = assert(process.events())
    while true do
        local selected = channel.select({calls:case_receive(), replies:case_receive(), events:case_receive()})
        if not selected.ok then break end
        if selected.channel == events then
            if selected.value.kind == process.event.CANCEL then break end
        elseif selected.channel == calls then
            process.send(test, "bee.test.standin.request", selected.value:payload():data())
        else
            process.send(test, "bee.test.standin.reply", selected.value:payload():data())
        end
    end
    process.unlisten(calls); process.unlisten(replies)
end
return {main = main}
