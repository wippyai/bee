-- MIT. Strict public delivery boundary. It admits only the operations an
-- authoring agent may invoke and bounds every field; host profiles and owner
-- facades remain the authority for what any operation may touch.
local bounds = require("bounds")
local M = {}
type Operation = "request" | "status" | "publish" | "preflight"
local OPERATIONS: {[string]: boolean} = {request = true, status = true, publish = true, preflight = true}
M.OPERATIONS = OPERATIONS
type Request = {operation: Operation, workspace_id: string, source_workspace: string, version: string,
    snapshot_digest: string?, source_node: string?, intent_id: string?}
function M.decode(raw: unknown): (Request?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "delivery request must be an object" end
    local extra = bounds.fields(value, {"operation", "workspace_id", "source_overlay_id", "version",
        "snapshot_digest", "source_node", "intent_id"})
    if extra then return nil, extra end
    local operation = value.operation
    if type(operation) ~= "string" or not OPERATIONS[operation] then return nil, "unknown delivery operation" end
    local selected_operation: Operation = operation :: Operation
    local workspace_id = bounds.id(value.workspace_id)
    local source_workspace = bounds.id(value.source_overlay_id)
    local version = bounds.id(value.version)
    if not workspace_id or not source_workspace or not version then
        return nil, "delivery needs operation, workspace_id, source_overlay_id and version"
    end
    local request: Request = {operation = selected_operation, workspace_id = workspace_id,
        source_workspace = source_workspace, version = version}
    if value.snapshot_digest ~= nil then
        local digest = value.snapshot_digest
        if (selected_operation ~= "request" and selected_operation ~= "preflight")
            or type(digest) ~= "string" or #digest ~= 64 or not digest:match("^[0-9a-f]+$") then
            return nil, "snapshot_digest is only valid on request and preflight and must be a lowercase SHA-256 measurement"
        end
        request.snapshot_digest = digest
    end
    if (selected_operation == "request" or selected_operation == "preflight") and request.snapshot_digest == nil then
        return nil, selected_operation .. " needs the frozen snapshot_digest"
    end
    if value.source_node ~= nil or value.intent_id ~= nil then
        if selected_operation ~= "status" then return nil, "source_node and intent_id are only valid on status; preflight stages nothing, request stages a version" end
        local node = bounds.id(value.source_node)
        local intent = bounds.id(value.intent_id)
        if value.source_node ~= nil and not node then return nil, "source_node is not an identifier" end
        if value.intent_id ~= nil and not intent then return nil, "intent_id is not an identifier" end
        request.source_node, request.intent_id = node, intent
    end
    return request, nil
end
-- The MCP input schema, generated from the same operations the decoder
-- enforces. request stages a version, preflight checks a frozen digest
-- without staging, status reads a staged version, publish releases one.
function M.schema(): {[string]: unknown}
    local digest = {type = "string", pattern = "^[0-9a-f]{64}$",
        description = "lowercase SHA-256 of the frozen overlay snapshot"}
    local identity = {type = "string", minLength = 1, maxLength = 160}
    return {type = "object", additionalProperties = false, required = {"operation", "source_overlay_id", "version"},
        properties = {
            operation = {type = "string", enum = {"request", "status", "preflight"},
                description = "request stages the version and reads its preflight verdict; "
                    .. "preflight checks the frozen digest without staging; status reads a staged version"},
            workspace_id = {type = "string", minLength = 1, maxLength = 160,
                description = "This session's own workspace, the default; any other is refused"},
            source_overlay_id = identity,
            version = identity,
            snapshot_digest = digest,
            source_node = identity,
            intent_id = identity,
        },
        examples = {
            {operation = "preflight", source_overlay_id = "counter", version = "1.0.0",
                snapshot_digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"},
            {operation = "request", source_overlay_id = "counter", version = "1.0.0",
                snapshot_digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"},
            {operation = "status", source_overlay_id = "counter", version = "1.0.0"},
        }}
end
return M
