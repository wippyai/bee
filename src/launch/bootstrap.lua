-- MIT. Local startup owns physical resources until the desktop takes them.
local process = require("process")
local channel = require("channel")
local tty = require("tty")
local security = require("security")
local time = require("time")
local funcs = require("funcs")
local physical = require("physical")
local input_decode = require("input_decode")
local contract = require("contract")
local decode = require("decode")
local workspaces = require("workspaces")
local edit_mode_recovery = require("edit_mode_recovery")
local boot_fallback = require("boot_fallback")
type Terminal = {display: physical.Display, input: tty.EventChannel}
type Started = {supervisor: string, host: string, workspace_id: string, desktop: decode.Desktop, terminal: Terminal}
local M = {}

function M.open(): Started?
    local boot, boot_error = process.listen("bee.launch.host", {message = true})
    if not boot then error(tostring(boot_error)) end
    local events = assert(process.events())
    local input, input_error = tty.events()
    if not input then process.unlisten(boot); error(tostring(input_error)) end
    local supervisor = ""
    local display: physical.Display? = nil

    local function readiness(): (Started?, string?, boolean)
        display = display or physical.open()
        local policies: {security.Policy} = {}
        for _, name in ipairs({"bee.security.desktop:host_policy", "bee.security.desktop:local_supervisor_spawn_policy"}) do
            local policy, err = security.policy(name)
            if not policy then error(tostring(err)) end
            policies[#policies + 1] = policy
        end
        local self = tostring(process.pid())
        local pid, spawn_error = process.with_options({}):with_context({["bee.launch_owner"] = self})
            :with_scope(security.new_scope(policies)):spawn_monitored("bee.launch:supervisor", "bee:workers", self, workspaces.classic())
        if not pid then error(tostring(spawn_error)) end
        supervisor = tostring(pid)
        local deadline = time.after("10s")
        while true do
            local selected = channel.select({boot:case_receive(), events:case_receive(), input:case_receive(), deadline:case_receive()})
            if not selected.ok then
                process.terminate(supervisor); supervisor = ""
                return nil, "Local host startup channel closed", true
            end
            if selected.channel == deadline then
                process.terminate(supervisor); supervisor = ""
                return nil, "Local host startup timed out", true
            elseif selected.channel == input then
                local event = input_decode.decode(selected.value)
                if event then
                    if event.type == "close" or (event.type == "key" and event.ctrl and event.key == "q" and event.action ~= "release") then
                        return nil, nil, false
                    end
                    if event.type == "resize" and display then physical.resize(display, event.width, event.height) end
                end
            elseif selected.channel == events then
                local event = selected.value
                if event.kind == process.event.CANCEL then return nil, nil, false end
                if event.kind == process.event.EXIT and tostring(event.from) == supervisor then
                    local failure = decode.exit_error(event.result) or "without publishing a host"
                    supervisor = ""
                    return nil, "Local supervisor exited before host readiness: " .. failure, true
                end
            else
                local message = selected.value
                if tostring(message:from()) == supervisor then
                    local data: unknown = message:payload():data()
                    if type(data) ~= "table" or data.version ~= 1 then
                        process.terminate(supervisor); supervisor = ""
                        return nil, "Invalid local host bootstrap", true
                    end
                    local workspace_id = contract.workspace_id(data.workspace_id)
                    local host_value: string? = contract.text(data.host, 160)
                    local host_name = ""
                    if host_value ~= nil then host_name = host_value end
                    local checked_workspace_id = ""
                    if workspace_id ~= nil then checked_workspace_id = workspace_id end
                    local desktop = decode.desktop(data.desktop)
                    if checked_workspace_id == "" or host_name == "" or not desktop then
                        process.terminate(supervisor); supervisor = ""
                        return nil, "Invalid local host bootstrap", true
                    end
                    local terminal_display: physical.Display = assert(display, "Local terminal ownership lost")
                    local ready: Started = {supervisor = supervisor, host = host_name, workspace_id = checked_workspace_id,
                        desktop = desktop, terminal = {display = terminal_display, input = input}}
                    display = nil
                    return ready, nil, false
                end
            end
        end
        return nil, "Local host readiness ended", false
    end

    local function cleanup_readiness_failure()
        if supervisor ~= "" then process.terminate(supervisor); supervisor = "" end
    end

    local function disable_super_edit(): (boolean?, string?)
        local ok, reply, call_error = pcall(function()
            return funcs.new():call("bee.gov.binding:super_edit_recovery_call", {operation = "disable_all"})
        end)
        if not ok then return nil, tostring(reply) end
        if call_error then return nil, tostring(call_error) end
        local result = type(reply) == "table" and reply :: {[string]: unknown} or nil
        if not result or result.ok ~= true then
            return nil, tostring(result and (result.message or result.code) or "edit-mode recovery returned an invalid reply")
        end
        local value = type(result.value) == "table" and result.value :: {[string]: unknown} or nil
        if not value or type(value.changed) ~= "boolean" then return nil, "edit-mode recovery returned an invalid result" end
        return value.changed :: boolean, nil
    end

    local result, startup_error = boot_fallback.run(readiness, disable_super_edit, cleanup_readiness_failure)
    process.unlisten(boot)
    if result then return result end
    if supervisor ~= "" then process.terminate(supervisor) end
    if display then physical.close(display) end
    if startup_error then error(startup_error) end
    return nil
end

return M
