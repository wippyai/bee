-- MIT. Local supervisor messages describe identities, never confer authority.
local contract = require("contract")
local decode = require("decode")
type Host = {workspace_id: string, desktop: decode.Desktop}
type Ready = {client_id: string, import_receipt: string}
type Quit = {request_id: string, emergency: boolean}
local M = {}
function M.host(value: unknown): Host?
    if type(value) ~= "table" or value.version ~= 1 or type(value.saved) ~= "table" then return nil end
    local workspace_id = contract.workspace_id(value.workspace_id)
    local desktop = decode.desktop(value.saved.desktop)
    if not workspace_id or not desktop then return nil end
    return {workspace_id = workspace_id, desktop = desktop}
end
function M.request(value: unknown, workspace_id: string): string?
    if type(value) ~= "table" or value.version ~= 1 or value.workspace_id ~= workspace_id then return nil end
    local id = contract.text(value.request_id, 80)
    if not id or id == "" then return nil end
    return id
end
function M.ready(value: unknown, workspace_id: string): Ready?
    if type(value) ~= "table" or value.version ~= 1 or value.workspace_id ~= workspace_id then return nil end
    local client_id = contract.workspace_id(value.client_id)
    local receipt = contract.workspace_id(value.import_receipt)
    if not client_id or not receipt then return nil end
    return {client_id = client_id, import_receipt = receipt}
end
function M.quit(value: unknown, workspace_id: string): Quit?
    local request_id = M.request(value, workspace_id)
    if not request_id or type(value) ~= "table" then return nil end
    if value.emergency ~= nil and type(value.emergency) ~= "boolean" then return nil end
    return {request_id = request_id, emergency = value.emergency == true}
end
return M
