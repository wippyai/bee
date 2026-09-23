-- MIT. Retained supervisor protocol; sender authentication remains caller responsibility before decoding.
local contract = require("contract")
local clipboard = require("clipboard")
local arguments = require("arguments")
type Request = {op: "attach" | "detach" | "copy", request_id: string, recipient: string, mode: "control" | "observe"}
type CatalogReaders = {workspace_id: string, readers: {string}}
local MAX_CATALOG_READERS = 16
type Ready = {workspace_id: string, desktop_id: string}
type Result = {request_id: string, mount: string, error_code: string, error: string}
local M = {}
-- Local names and topic of the readiness handshake between the desktop bridge
-- that composes the retained workspace and the owner route that reports it.
M.BRIDGE_NAME = "bee.retained.bridge"
M.OWNER_NAME = "bee.retained.owner"
M.TOPIC_OBSERVE = "bee.retained.observe"

-- Decodes an attach/detach request. Sender authentication remains caller responsibility.
-- A complete, host-selected snapshot of live application executions allowed to
-- read the retained desktop catalog. The PID values identify only this current
-- execution: receiver-side sender authentication remains mandatory.
function M.catalog_readers(value: unknown, expected_workspace_id: string?): CatalogReaders?
    if type(value) ~= "table" or value.version ~= 1 then return nil end
    for key in pairs(value) do
        if key ~= "version" and key ~= "workspace_id" and key ~= "readers" then return nil end
    end
    local workspace_id = contract.workspace_id(value.workspace_id)
    if not workspace_id or (expected_workspace_id and workspace_id ~= expected_workspace_id)
        or type(value.readers) ~= "table" then return nil end
    local count = 0
    for key in pairs(value.readers) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 or key > #value.readers then return nil end
        count = count + 1
        if count > MAX_CATALOG_READERS then return nil end
    end
    if count ~= #value.readers then return nil end
    local readers: {string} = {}
    local seen: {[string]: boolean} = {}
    for i = 1, count do
        local reader = contract.text(value.readers[i], 160)
        if not reader or reader == "" or seen[reader] then return nil end
        seen[reader] = true
        readers[#readers + 1] = reader
    end
    return {workspace_id = workspace_id, readers = readers}
end

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

-- Internal launch messages are accepted only after the receiver authenticates
-- its owner and checks the recipient's current controller attachment.
type Launch = {request_id: string, recipient: string, name: string, arguments: {string}}
function M.launch(value: unknown, workspace_id: string, desktop_id: string): Launch?
    if not contract.workspace_id(workspace_id) or not contract.workspace_id(desktop_id) then return nil end
    if type(value) ~= "table" or value.version ~= 1 or value.workspace_id ~= workspace_id
        or value.desktop_id ~= desktop_id then return nil end
    for key in pairs(value) do
        if key ~= "version" and key ~= "workspace_id" and key ~= "desktop_id"
            and key ~= "request_id" and key ~= "recipient" and key ~= "name" and key ~= "arguments" then return nil end
    end
    local request_id = contract.text(value.request_id, 80)
    local recipient = contract.text(value.recipient, 160)
    local name = contract.text(value.name, 40)
    if not request_id or request_id == "" or not recipient or recipient == "" or not name
        or not name:match("^[a-z][a-z0-9_-]*$") then return nil end
    -- The internal envelope requires an explicit vector; decode supplies the
    -- same count, item, total-size and control-character bounds as local launch.
    if value.arguments == nil then return nil end
    local values = arguments.decode(value.arguments)
    if not values then return nil end
    return {request_id = request_id, recipient = recipient, name = name, arguments = values}
end

type LaunchResult = {request_id: string, id: string, instance_id: string, error_code: string, error: string}
function M.launch_result(value: unknown, workspace_id: string, desktop_id: string): LaunchResult?
    if not contract.workspace_id(workspace_id) or not contract.workspace_id(desktop_id) then return nil end
    if type(value) ~= "table" or value.version ~= 1 or value.workspace_id ~= workspace_id
        or value.desktop_id ~= desktop_id then return nil end
    for key in pairs(value) do
        if key ~= "version" and key ~= "workspace_id" and key ~= "desktop_id" and key ~= "request_id"
            and key ~= "id" and key ~= "instance_id" and key ~= "error_code" and key ~= "error" then return nil end
    end
    local request_id = contract.text(value.request_id, 80)
    local id = contract.text(value.id, 80)
    local instance = contract.text(value.instance_id, 80)
    local code = contract.text(value.error_code, 80)
    if not request_id or request_id == "" or not id or not instance or not code
        or type(value.error) ~= "string" or #value.error > 4096 then return nil end
    if code == "" then
        if id == "" or instance == "" or value.error ~= "" then return nil end
    elseif id ~= "" or instance ~= "" or value.error == "" then return nil end
    return {request_id = request_id, id = id, instance_id = instance, error_code = code, error = value.error}
end

type CopyResult = {request_id: string, selected: boolean, text: string, error: string}
function M.copy_result(value: unknown): CopyResult? return clipboard.copy_result(value) end
type ActivationResult = {request_id: string, error_code: string, error: string}
function M.activation_result(value: unknown, workspace_id: string, desktop_id: string): ActivationResult?
    if type(value) ~= "table" or value.version ~= 1 or value.workspace_id ~= workspace_id or value.desktop_id ~= desktop_id then return nil end
    for key in pairs(value) do
        if key ~= "version" and key ~= "workspace_id" and key ~= "desktop_id" and key ~= "request_id"
            and key ~= "error_code" and key ~= "error" then return nil end
    end
    local id = contract.text(value.request_id, 80)
    if not id or id == "" or type(value.error) ~= "string" or #value.error > 400 then return nil end
    local code = value.error_code
    if code ~= "" and code ~= "BUSY" and code ~= "UNAVAILABLE" then return nil end
    if (code == "") ~= (value.error == "") then return nil end
    return {request_id = id, error_code = code, error = value.error}
end
return M
