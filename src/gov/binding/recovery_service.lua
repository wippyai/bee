-- MIT. Headless native recovery of one host activation slot: the slot goes back
-- to the version before the one it runs, through the same revert the Library asks for.
local system = require("system")
local uuid = require("uuid")
local bounds = require("bounds")
local resources = require("resources")
local activations = require("activation_store")
local destination = require("destination_service")

local M = {}
type Object = {[string]: unknown}
function M.revert(owner_raw: unknown): (string?, string?)
    local overlay_owner = bounds.id(owner_raw)
    if not overlay_owner then return nil, "usage: bee gov revert OWNER (OWNER is the exact activation overlay owner)" end
    local node, node_error = system.node.id()
    local resource, resource_error = resources.database()
    if not node or node_error or not resource then
        return nil, tostring(node_error or resource_error or "recovery identity is unavailable")
    end
    local listed = activations.desired_slots(resource, node)
    local listing = listed.ok and bounds.object(listed.value) or nil
    local slots = listing and listing.slots
    if not listed.ok then return nil, listed.message or "list activation slots" end
    if type(slots) ~= "table" then return nil, "activation slot list is malformed" end
    local workspace_id: string? = nil
    for _, raw in ipairs(slots) do
        local slot = bounds.object(raw)
        if not slot then return nil, "activation slot is malformed" end
        if slot.overlay_owner == overlay_owner then
            if workspace_id then return nil, "activation owner is ambiguous across workspaces" end
            workspace_id = bounds.id(slot.workspace_id)
        end
    end
    if not workspace_id then return nil, "no desired activation slot matches OWNER" end

    local store, open_error = activations.open(resource, node, workspace_id)
    if not store then return nil, tostring(open_error or "open activation store") end
    local desired = activations.desired(store, overlay_owner)
    local current: Object? = desired.ok and bounds.object(desired.value) or nil
    if not current then
        activations.close(store)
        return nil, desired.message or "read desired activation"
    end
    local key, key_error = uuid.v7()
    if not key or key_error then
        activations.close(store)
        return nil, "allocate recovery receipt identity"
    end
    local source_workspace = bounds.id(current.source_workspace)
    activations.close(store)
    if not source_workspace then return nil, "desired activation names no source overlay" end
    local reverted = destination.revert(workspace_id, source_workspace, key)
    if not reverted.ok then return nil, reverted.message or reverted.code or "activation revert failed" end
    return "Reverted " .. overlay_owner .. " to its retained baseline", nil
end

return M
