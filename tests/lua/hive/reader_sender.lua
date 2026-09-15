-- MIT. Test-only actor that sends its own authenticated PID in a snapshot.
local process = require("process")
local channel = require("channel")
local function main(recipient: string, workspace: string, actions: {string})
    local commands = assert(process.listen("bee.test.catalog_reader.command", {message = true}))
    for _, action in ipairs(actions) do
        local readers: {string} = {}
        if action == "grant_self" then readers[1] = tostring(process.pid()) end
        if action == "grant_recipient" then readers[1] = recipient end
        if action == "forward" then
            local selected = channel.select({commands:case_receive()})
            if not selected.ok or selected.channel ~= commands then error("catalog reader control closed") end
            local sent, err = process.send(recipient, "bee.test.catalog_reader", selected.value:payload():data())
            if not sent then error(tostring(err)) end
        else
            local value: unknown = {version = 1, workspace_id = workspace, readers = readers}
            local sent, err = process.send(recipient, "bee.test.catalog_reader", value)
            if not sent then error(tostring(err)) end
        end
    end
    process.unlisten(commands)
end
return {main = main}
