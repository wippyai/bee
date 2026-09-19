-- MIT. Strict public delivery boundary. It admits only the operations an
-- authoring agent may invoke and bounds every field; host profiles and owner
-- facades remain the authority for what any operation may touch.
local bounds = require("bounds")
local M = {}
type Operation = "request" | "status" | "publish"
local OPERATIONS: {[string]: boolean} = {request = true, status = true, publish = true}
M.OPERATIONS = OPERATIONS
type Request = {operation: Operation, workspace_id: string, source_workspace: string, version: string,
    snapshot_digest: string?, source_node: string?, intent_id: string?}
function M.decode(raw: unknown): (Request?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "delivery request must be an object" end
    local extra = bounds.fields(value, {"operation", "workspace_id", "source_workspace", "version",
        "snapshot_digest", "source_node", "intent_id"})
    if extra then return nil, extra end
    local operation = value.operation
    if type(operation) ~= "string" or not OPERATIONS[operation] then return nil, "unknown delivery operation" end
    local selected_operation: Operation = operation :: Operation
    local workspace_id = bounds.id(value.workspace_id)
    local source_workspace = bounds.id(value.source_workspace)
    local version = bounds.id(value.version)
    if not workspace_id or not source_workspace or not version then
        return nil, "delivery needs operation, workspace_id, source_workspace and version"
    end
    local request: Request = {operation = selected_operation, workspace_id = workspace_id,
        source_workspace = source_workspace, version = version}
    if value.snapshot_digest ~= nil then
        local digest = value.snapshot_digest
        if selected_operation ~= "request" or type(digest) ~= "string" or #digest ~= 64 or not digest:match("^[0-9a-f]+$") then
            return nil, "snapshot_digest is only valid on request and must be a lowercase SHA-256 measurement"
        end
        request.snapshot_digest = digest
    end
    if selected_operation == "request" and request.snapshot_digest == nil then
        return nil, "request needs the frozen snapshot_digest"
    end
    if value.source_node ~= nil or value.intent_id ~= nil then
        if selected_operation ~= "status" then return nil, "source_node and intent_id are only valid on status" end
        local node = bounds.id(value.source_node)
        local intent = bounds.id(value.intent_id)
        if value.source_node ~= nil and not node then return nil, "source_node is not an identifier" end
        if value.intent_id ~= nil and not intent then return nil, "intent_id is not an identifier" end
        request.source_node, request.intent_id = node, intent
    end
    return request, nil
end
return M
