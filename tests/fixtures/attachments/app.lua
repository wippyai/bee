local tty = require("tty")
local process = require("process")
local channel = require("channel")
local uuid = require("uuid")
local client = require("client")
local function main(value: unknown)
    local launch = client.launch(value)
    if not launch then error("Invalid launch") end
    local input = assert(tty.events())
    local closes = assert(process.listen("bee.application.close", {message = true}))
    local receipts = assert(process.listen("bee.application.checkpoint_result", {message = true}))
    assert(tty.start())
    local surface = assert(tty.surface())
    local nonce = uuid.v7()
    assert(surface:present({"READY " .. nonce}))
    client.ready(launch)
    local checkpoint = assert(client.checkpoint(launch, '{"saved":true}'))
    while true do
        local selected = channel.select({input:case_receive(), closes:case_receive(), receipts:case_receive()})
        if not selected.ok then break end
        if selected.channel == closes and selected.value:from() == launch.broker_pid then break end
        if selected.channel == receipts then
            local data: unknown = selected.value:payload():data()
            if selected.value:from() == launch.broker_pid and type(data) == "table" and data.request_id == checkpoint then
                assert(data.error_code == "", "Checkpoint failed")
                assert(surface:present({"SAVED " .. nonce}))
                if launch.arguments[1] == "inventory" then assert(client.title(launch, "Inventory probe")) end
            end
        end
    end
    process.unlisten(closes)
    process.unlisten(receipts)
    tty.stop()
end
return {main = main}
