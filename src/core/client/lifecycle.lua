-- MIT. Supervisor-selected client lifetime, separate from workspace authority.
local contract = require("contract")
local interaction = require("interaction")
local arguments = require("arguments")
type Bootstrap = {quit_mode: "detach" | "supervisor", legacy_desktop: unknown, arguments: {string}, fullscreen: boolean,
    secondary_application: string?, workspace_appearance: boolean, desktop_id: string?}
type Control = {op: "state" | "save" | "exit" | "pause", request_id: string, shutdown: interaction.Wire?, error: string?}
local M = {}
function M.bootstrap(value: unknown): Bootstrap?
    if value == nil then return {quit_mode = "detach", legacy_desktop = nil, arguments = {}, fullscreen = false,
        secondary_application = nil, workspace_appearance = false, desktop_id = nil} end
    if type(value) ~= "table" or value.version ~= 1 then return nil end
    local desktop_id: string? = nil
    if value.desktop_id ~= nil then
        desktop_id = contract.workspace_id(value.desktop_id)
        if not desktop_id then return nil end
    end
    local mode = value.quit_mode
    if mode == nil then mode = "detach" end
    if mode ~= "detach" and mode ~= "supervisor" then return nil end
    local args = arguments.decode(value.arguments)
    if not args or (value.fullscreen ~= nil and type(value.fullscreen) ~= "boolean") then return nil end
    if value.workspace_appearance ~= nil and type(value.workspace_appearance) ~= "boolean" then return nil end
    local secondary: string? = nil
    if value.secondary_application ~= nil then
        secondary = contract.text(value.secondary_application, 160)
        if not secondary or secondary == "" then return nil end
    end
    return {quit_mode = mode, legacy_desktop = value.legacy_desktop, arguments = args,
        fullscreen = value.fullscreen == true, secondary_application = secondary,
        workspace_appearance = value.workspace_appearance == true, desktop_id = desktop_id}
end
function M.control(value: unknown, workspace_id: string): Control?
    if type(value) ~= "table" or value.version ~= 1 or value.workspace_id ~= workspace_id then return nil end
    local request_id = contract.text(value.request_id, 80)
    if not request_id or request_id == "" then return nil end
    if value.op ~= "state" and value.error ~= nil then return nil end
    if value.op == "exit" then
        if value.shutdown ~= nil then return nil end
        return {op = "exit", request_id = request_id, shutdown = nil, error = nil}
    end
    if value.op == "save" then
        if value.shutdown ~= nil then return nil end
        return {op = "save", request_id = request_id, shutdown = nil, error = nil}
    end
    if value.op == "pause" then
        if value.shutdown ~= nil then return nil end
        return {op = "pause", request_id = request_id, shutdown = nil, error = nil}
    end
    if value.op ~= "state" then return nil end
    local failure: string? = nil
    if value.error ~= nil then
        -- Match the host reply boundary: diagnostic text can include line
        -- breaks and must not disappear while forwarding an accepted refusal.
        if type(value.error) ~= "string" or #value.error > 4096 then return nil end
        failure = value.error
    end
    local question = interaction.shutdown(value)
    if value.shutdown ~= nil and not question then return nil end
    if question and failure then return nil end
    return {op = "state", request_id = request_id, shutdown = question and interaction.wire(question) or nil, error = failure}
end
return M
