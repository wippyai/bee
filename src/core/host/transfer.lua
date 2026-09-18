-- MIT. Checked display-transfer requests. Admission and storage belong to the host.
local contract = require("contract")
type Request = {version: integer, workspace_id: string, connection_id: string,
    renderer_generation: string, request_id: string, view_id: string,
    instance_id: string, target_display_id: string, expected_revision: integer}
type Assignment = {view_id: string, instance_id: string, display_id: string, revision: integer, pending: boolean}
type Display = {display_id: string, available: boolean, control: boolean}
type Snapshot = {version: integer, workspace_id: string, connection_id: string, display_id: string, revision: integer, items: {Assignment}, displays: {Display}}
type Result = {version: integer, workspace_id: string, connection_id: string, request_id: string, view_id: string, instance_id: string, target_display_id: string, assignment_revision: integer, error_code: string, error: string}
local M = {}

local function identity(value: unknown, maximum: integer): string?
    local checked = contract.text(value, maximum)
    if not checked or checked == "" then return nil end
    return checked
end
local function revision(value: unknown, minimum: integer): integer?
    if type(value) ~= "number" or value ~= math.floor(value) or value < minimum or value > 9007199254740990 then return nil end
    return math.floor(value)
end
local function array_size(value: unknown, maximum: integer): integer?
    if type(value) ~= "table" then return nil end
    local count = 0
    for key in pairs(value) do if type(key) ~= "number" or key ~= math.floor(key) or key < 1 or key > maximum then return nil else count = count + 1 end end
    return count
end
local function assignment(value: unknown): Assignment?
    if type(value) ~= "table" then return nil end
    for key in pairs(value) do if key ~= "view_id" and key ~= "instance_id" and key ~= "display_id" and key ~= "revision" and key ~= "pending" then return nil end end
    local view_id, instance_id, display_id, current = identity(value.view_id, 80), identity(value.instance_id, 80), contract.workspace_id(value.display_id), revision(value.revision, 1)
    if not view_id or not instance_id or not display_id or not current or type(value.pending) ~= "boolean" then return nil end
    return {view_id = view_id, instance_id = instance_id, display_id = display_id, revision = current, pending = value.pending}
end
local function display(value: unknown): Display?
    if type(value) ~= "table" then return nil end
    for key in pairs(value) do if key ~= "display_id" and key ~= "available" and key ~= "control" then return nil end end
    local display_id = contract.workspace_id(value.display_id)
    if not display_id or type(value.available) ~= "boolean" or type(value.control) ~= "boolean" then return nil end
    return {display_id = display_id, available = value.available, control = value.control}
end
function M.snapshot(value: unknown): Snapshot?
    if type(value) ~= "table" or value.version ~= 1 then return nil end
    for key in pairs(value) do if key ~= "version" and key ~= "workspace_id" and key ~= "connection_id" and key ~= "display_id" and key ~= "revision" and key ~= "items" and key ~= "displays" then return nil end end
    local workspace_id, connection_id, display_id, current = contract.workspace_id(value.workspace_id), identity(value.connection_id, 80), contract.workspace_id(value.display_id), revision(value.revision, 0)
    local item_count, display_count = array_size(value.items, 16), array_size(value.displays, 8)
    if not workspace_id or not connection_id or not display_id or not current or not item_count or not display_count then return nil end
    local items: {Assignment}, displays: {Display} = {}, {}; local known_items: {[string]: boolean}, known_displays: {[string]: boolean} = {}, {}
    for index = 1, item_count do local item = assignment(value.items[index]); local key = item and item.view_id or ""; if not item or known_items[key] then return nil end; known_items[key] = true; items[#items + 1] = item end
    for index = 1, display_count do local item = display(value.displays[index]); if not item or known_displays[item.display_id] then return nil end; known_displays[item.display_id] = true; displays[#displays + 1] = item end
    return {version = 1, workspace_id = workspace_id, connection_id = connection_id, display_id = display_id, revision = current, items = items, displays = displays}
end
function M.result(value: unknown): Result?
    if type(value) ~= "table" or value.version ~= 1 then return nil end
    for key in pairs(value) do if key ~= "version" and key ~= "workspace_id" and key ~= "connection_id" and key ~= "request_id" and key ~= "view_id" and key ~= "instance_id" and key ~= "target_display_id" and key ~= "assignment_revision" and key ~= "error_code" and key ~= "error" then return nil end end
    local workspace_id = contract.workspace_id(value.workspace_id)
    local connection_id = identity(value.connection_id, 80)
    local request_id, view_id, instance_id = identity(value.request_id, 80), identity(value.view_id, 80), identity(value.instance_id, 80)
    local target_display_id = contract.workspace_id(value.target_display_id)
    local current = revision(value.assignment_revision, 0)
    local error_code = contract.text(value.error_code, 80)
    local raw_error: unknown = value.error
    if not workspace_id or not connection_id or not request_id or not view_id or not instance_id or not target_display_id or not current or not error_code or type(raw_error) ~= "string" or #raw_error > 4096 or (error_code == "" and (current < 1 or raw_error ~= "")) then return nil end
    local error_text: string = raw_error
    return {version = 1, workspace_id = workspace_id, connection_id = connection_id, request_id = request_id, view_id = view_id, instance_id = instance_id, target_display_id = target_display_id, assignment_revision = current, error_code = error_code, error = error_text} :: Result
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
