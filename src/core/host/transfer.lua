-- MIT. Checked display-transfer requests. Admission and storage belong to the host.
local contract = require("contract")
type Request = {version: integer, workspace_id: string, connection_id: string,
    renderer_generation: string, request_id: string, view_id: string,
    instance_id: string, target_display_id: string, expected_revision: integer}
local M = {}

local function identity(value: unknown, maximum: integer): string?
    local checked = contract.text(value, maximum)
    if not checked or checked == "" then return nil end
    return checked
end

function M.request(value: unknown): Request?
    if type(value) ~= "table" or value.version ~= 1 then return nil end
    -- The sender's admitted display determines the source. Payload metadata
    -- cannot supply a source identity, permission, renderer PID or mount.
    for key in pairs(value) do
        if key ~= "version" and key ~= "workspace_id" and key ~= "connection_id"
            and key ~= "renderer_generation" and key ~= "request_id" and key ~= "view_id"
            and key ~= "instance_id" and key ~= "target_display_id" and key ~= "expected_revision" then return nil end
    end
    local workspace = contract.workspace_id(value.workspace_id)
    local target = contract.workspace_id(value.target_display_id)
    local connection = identity(value.connection_id, 80)
    local generation = identity(value.renderer_generation, 80)
    local request = identity(value.request_id, 80)
    local view = identity(value.view_id, 80)
    local instance = identity(value.instance_id, 80)
    local revision = value.expected_revision
    if not workspace or not target or not connection or not generation or not request or not view or not instance then return nil end
    if type(revision) ~= "number" or revision < 1 or revision >= 9007199254740990
        or revision ~= math.floor(revision) then return nil end
    return {version = 1, workspace_id = workspace, connection_id = connection,
        renderer_generation = generation, request_id = request, view_id = view,
        instance_id = instance, target_display_id = target, expected_revision = math.floor(revision)}
end

return M
