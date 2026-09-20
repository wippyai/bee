-- Fixture application that exposes its authentic broker checkpoint receipts to
-- its fixture workspace owner. It has no production authority or behavior.
local process = require("process")
local channel = require("channel")
local tty = require("tty")
local client = require("client")

local function main(value: unknown)
    local launch = client.launch(value)
    if not launch then error("Invalid checkpoint fixture launch") end
    local receipts = assert(process.listen("bee.application.checkpoint_result", {message = true}))
    local commands = assert(process.listen("bee.fixture.checkpoint.command", {message = true}))
    local closes = assert(process.listen("bee.application.close", {message = true}))
    local surface = assert(tty.surface())
    assert(surface:present({"CHECKPOINT APP " .. launch.definition_revision, "STATE " .. launch.resume_state}))
    client.ready(launch)
    assert(process.send(launch.workspace_pid, "bee.fixture.checkpoint.ready", {pid = tostring(process.pid()),
        definition_revision = launch.definition_revision, resume_state = launch.resume_state}))
    local initial = assert(client.checkpoint(launch, "acknowledged-initial"))
    assert(process.send(launch.workspace_pid, "bee.fixture.checkpoint.sent", {request_id = initial, state = "acknowledged-initial"}))
    while true do
        local selected = channel.select({receipts:case_receive(), commands:case_receive(), closes:case_receive()})
        if not selected.ok then break end
        if selected.channel == closes and selected.value:from() == launch.broker_pid then break end
        if selected.channel == receipts then
            local data: unknown = selected.value:payload():data()
            if selected.value:from() == launch.broker_pid and type(data) == "table" then
                assert(process.send(launch.workspace_pid, "bee.fixture.checkpoint.receipt", {request_id = data.request_id,
                    error_code = data.error_code, error = data.error}))
            end
        elseif selected.value:from() == launch.workspace_pid then
            local command: unknown = selected.value:payload():data()
            local request_id: string?
            local state: string?
            if command == "refuse" then state = "refused-newer"; request_id = assert(client.checkpoint(launch, state))
            elseif command == "accept" then state = "acknowledged-newer"; request_id = assert(client.checkpoint(launch, state))
            elseif command == "lose" then state = "lost-newer"; request_id = assert(client.checkpoint(launch, state))
            elseif command == "initial" then assert(initial ~= "")
            else error("Unknown checkpoint fixture command") end
            if request_id and state then assert(process.send(launch.workspace_pid, "bee.fixture.checkpoint.sent", {request_id = request_id, state = state})) end
        end
    end
    surface:close()
    for _, subscription in ipairs({receipts, commands, closes}) do process.unlisten(subscription) end
end

return {main = main}
