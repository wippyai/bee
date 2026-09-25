-- MIT. Local supervisor messages describe identities, never confer authority.
local contract = require("contract")
local decode = require("decode")
type Host = {workspace_id: string, desktop: decode.Desktop, fresh: boolean}
type Ready = {client_id: string, import_receipt: string}
type Quit = {request_id: string, emergency: boolean}
type ClientResult = {request_id: string, op: string, recipient: string, error_code: string, error: string}
local M = {}
function M.host(value: unknown): Host?
    if type(value) ~= "table" or value.version ~= 1 or type(value.saved) ~= "table" then return nil end
    if value.fresh ~= nil and type(value.fresh) ~= "boolean" then return nil end
    local workspace_id = contract.workspace_id(value.workspace_id)
    local desktop = decode.desktop(value.saved.desktop)
    if not workspace_id or not desktop then return nil end
    return {workspace_id = workspace_id, desktop = desktop, fresh = value.fresh == true}
end
function M.request(value: unknown, workspace_id: string): string?
    if type(value) ~= "table" or value.version ~= 1 or value.workspace_id ~= workspace_id then return nil end
    local id = contract.text(value.request_id, 80)
    if not id or id == "" then return nil end
    return id
end
-- A host client result names the operation and recipient it settles. A release
-- the host started for a client it saw exit carries no request id, so an owner
-- that announced the same departure correlates on recipient and operation.
function M.client_result(value: unknown, workspace_id: string): ClientResult?
    if type(value) ~= "table" or value.version ~= 1 or value.workspace_id ~= workspace_id then return nil end
    local request_id = contract.text(value.request_id, 80)
    local op = contract.text(value.op, 40)
    local recipient = contract.text(value.recipient, 160)
    local code = contract.text(value.error_code, 80)
    local message = value.error
    if not request_id or not op or op == "" or not recipient or recipient == "" or not code then return nil end
    if type(message) ~= "string" or #message > 4096 then return nil end
    return {request_id = request_id, op = op, recipient = recipient, error_code = code, error = message}
end
function M.ready(value: unknown, workspace_id: string, require_import: boolean): Ready?
    if type(value) ~= "table" or value.version ~= 1 or value.workspace_id ~= workspace_id then return nil end
    local client_id = contract.workspace_id(value.client_id)
    local receipt: string? = nil
    if value.import_receipt == "" and not require_import then receipt = ""
    else receipt = contract.workspace_id(value.import_receipt) end
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
