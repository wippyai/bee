-- MIT. Local startup owns physical resources until the desktop takes them.
local process = require("process")
local channel = require("channel")
local tty = require("tty")
local security = require("security")
local time = require("time")
local physical = require("physical")
local input_decode = require("input_decode")
local contract = require("contract")
local decode = require("decode")
local workspaces = require("workspaces")
type Terminal = {display: physical.Display, input: tty.EventChannel}
type Started = {supervisor: string, host: string, workspace_id: string, desktop: decode.Desktop, terminal: Terminal}
local M = {}
function M.open(): Started?
    local boot, boot_error = process.listen("bee.launch.host", {message = true})
    if not boot then error(tostring(boot_error)) end
    local supervisor = ""
    local display: physical.Display? = nil
    local started: Started? = nil
    local function run()
        display = physical.open()
        local events = assert(process.events())
        local input, input_error = tty.events()
        if not input then error(tostring(input_error)) end
        local policies: {security.Policy} = {}
        for _, name in ipairs({"bee:host_policy", "bee:local_supervisor_spawn_policy"}) do
            local policy, err = security.policy(name)
            if not policy then error(tostring(err)) end
            policies[#policies + 1] = policy
        end
        local self = tostring(process.pid())
        supervisor = tostring(assert(process.with_options({}):with_context({["bee.launch_owner"] = self})
            :with_scope(security.new_scope(policies)):spawn_monitored("bee.launch:supervisor", "bee:workers", self, workspaces.classic())))
        local deadline = time.after("10s")
        while true do
            local selected = channel.select({boot:case_receive(), events:case_receive(), input:case_receive(), deadline:case_receive()})
            if not selected.ok or selected.channel == deadline then error("Local host startup timed out") end
            if selected.channel == input then
                local event = input_decode.decode(selected.value)
                if event then
                    if event.type == "close" or (event.type == "key" and event.ctrl and event.key == "q" and event.action ~= "release") then return end
                    if event.type == "resize" and display then physical.resize(display, event.width, event.height) end
                end
            elseif selected.channel == events then
                local event = selected.value
                if event.kind == process.event.CANCEL then return end
                if event.kind == process.event.EXIT and tostring(event.from) == supervisor then
                    error("Local supervisor exited before host readiness: " .. (decode.exit_error(event.result) or "without publishing a host"))
                end
            else
                local message = selected.value
                if tostring(message:from()) == supervisor then
                    local data: unknown = message:payload():data()
                    if type(data) ~= "table" or data.version ~= 1 then error("Invalid local host bootstrap") end
                    local workspace_id = contract.workspace_id(data.workspace_id)
                    local host = contract.text(data.host, 160)
                    local desktop = decode.desktop(data.desktop)
                    if not workspace_id or not host or host == "" or not desktop then error("Invalid local host bootstrap") end
                    if not display then error("Local terminal ownership lost") end
                    started = {supervisor = supervisor, host = host, workspace_id = workspace_id,
                        desktop = desktop, terminal = {display = display, input = input}}
                    display = nil
                    return
                end
            end
        end
    end
    local ok, err = pcall(run)
    process.unlisten(boot)
    if not started and supervisor ~= "" then process.terminate(supervisor) end
    if display then physical.close(display) end
    if not ok then error(err) end
    return started
end
return M
