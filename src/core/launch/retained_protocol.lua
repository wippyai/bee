-- MIT. Retained supervisor protocol; sender authentication remains caller responsibility before decoding.
local contract = require("contract")
local clipboard = require("clipboard")
type Request = {op: "attach" | "detach" | "copy", request_id: string, recipient: string, mode: "control" | "observe"}
type Ready = {workspace_id: string, desktop_id: string}
type Result = {request_id: string, mount: string, error_code: string, error: string}
local M = {}

-- Decodes an attach/detach request. Sender authentication remains caller responsibility.
function M.request(value: unknown, workspace_id: string, desktop_id: string): Request?
    if type(value) ~= "table" or value.version ~= 1 or value.workspace_id ~= workspace_id
        or value.desktop_id ~= desktop_id then return nil end
    for key in pairs(value) do
        if key ~= "version" and key ~= "workspace_id" and key ~= "desktop_id" and key ~= "op"
            and key ~= "request_id" and key ~= "recipient" and key ~= "mode" then return nil end
    end
    local id = contract.text(value.request_id, 80)
    local recipient = contract.text(value.recipient, 160)
    if not id or id == "" or not recipient or recipient == "" then return nil end
    if value.op == "detach" or value.op == "copy" then
        if value.mode ~= nil then return nil end
        return {op = value.op == "copy" and "copy" or "detach", request_id = id, recipient = recipient, mode = "observe"}
    end
    if value.op ~= "attach" or (value.mode ~= "control" and value.mode ~= "observe") then return nil end
    return {op = "attach", request_id = id, recipient = recipient,
        mode = value.mode == "control" and "control" or "observe"}
end

-- Decodes ready announcement. Sender authentication remains caller responsibility.
function M.ready(value: unknown): Ready?
    if type(value) ~= "table" or value.version ~= 1 then return nil end
    for key in pairs(value) do
        if key ~= "version" and key ~= "workspace_id" and key ~= "desktop_id" then return nil end
    end
    local wid = contract.workspace_id(value.workspace_id)
    local did = contract.workspace_id(value.desktop_id)
    if not wid or not did then return nil end
    return {workspace_id = wid, desktop_id = did}
end

-- Decodes attach/detach result. Sender authentication remains caller responsibility.
function M.result(value: unknown, workspace_id: string, desktop_id: string): Result?
    if type(value) ~= "table" or value.version ~= 1 then return nil end
    if not contract.workspace_id(workspace_id) or not contract.workspace_id(desktop_id) then return nil end
    if value.workspace_id ~= workspace_id or value.desktop_id ~= desktop_id then return nil end
    for key in pairs(value) do
        if key ~= "version" and key ~= "workspace_id" and key ~= "desktop_id"
            and key ~= "request_id" and key ~= "mount" and key ~= "error_code"
            and key ~= "error" then
            return nil
        end
    end
    local request_id = contract.text(value.request_id, 80)
    if not request_id or request_id == "" then return nil end
    local mount = contract.text(value.mount, 4096)
    if not mount then return nil end
    local error_code = contract.text(value.error_code, 80)
    if not error_code then return nil end
    local err = value.error
    if type(err) ~= "string" or #err > 4096 then return nil end
    if error_code == "" then
        if err ~= "" then return nil end
    else
        if mount ~= "" or err == "" then return nil end
    end
    return {request_id = request_id, mount = mount, error_code = error_code, error = err}
end

type CopyResult = {request_id: string, selected: boolean, text: string, error: string}
function M.copy_result(value: unknown): CopyResult? return clipboard.copy_result(value) end
return M
