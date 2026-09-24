-- MIT. Test-only stand-in for a retained desktop supervisor: it relays what the
-- bridge asks of it to the test and sends the test's answers as itself.
local process = require("process")
local channel = require("channel")
local function main(test: string)
    local topics = {"bee.retained.activate", "bee.retained.request", "bee.retained.launch", "bee.retained.switched"}
    local subscriptions = {}
    for _, topic in ipairs(topics) do subscriptions[#subscriptions + 1] = assert(process.listen(topic, {message = true})) end
    local commands = assert(process.listen("bee.test.retained.send", {message = true}))
    local events = assert(process.events())
    while true do
        local cases = {commands:case_receive(), events:case_receive()}
        for _, subscription in ipairs(subscriptions) do cases[#cases + 1] = subscription:case_receive() end
        local selected = channel.select(cases)
        if not selected.ok then break end
        if selected.channel == events then
            if selected.value.kind == process.event.CANCEL then break end
        elseif selected.channel == commands then
            local command: unknown = selected.value:payload():data()
            if type(command) == "table" and type(command.topic) == "string" then process.send(test, command.topic, command.value) end
        else
            for index, subscription in ipairs(subscriptions) do
                if selected.channel == subscription then
                    process.send(test, "bee.test.retained.received", {topic = topics[index], value = selected.value:payload():data()})
                end
            end
        end
    end
    for _, subscription in ipairs(subscriptions) do process.unlisten(subscription) end
    process.unlisten(commands)
end
return {main = main}
