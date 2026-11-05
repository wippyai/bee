-- MIT. Destination store handles for one node and workspace.
local plans = require("plan_store")
local activations = require("activation_store")
local leases = require("lease_store")
local resources = require("resources")
local M = {}

local function stores(node_id: string, workspace_id: string): (plans.Store?, activations.Store?, leases.Store?, string?)
    local resource, resource_error = resources.database()
    if not resource then return nil, nil, nil, resource_error end
    local plan_store, plan_error = plans.open(resource, node_id, workspace_id)
    if not plan_store then return nil, nil, nil, plan_error end
    local activation_store, activation_error = activations.open(resource, node_id, workspace_id)
    if not activation_store then plans.close(plan_store); return nil, nil, nil, activation_error end
    local lease_handle, lease_error = leases.open(resource, node_id, workspace_id)
    if not lease_handle then
        activations.close(activation_store)
        plans.close(plan_store)
        return nil, nil, nil, lease_error
    end
    return plan_store, activation_store, lease_handle, nil
end

local function close(plan_store: plans.Store?, activation_store: activations.Store?, lease_handle: leases.Store?)
    if lease_handle then leases.close(lease_handle) end
    if activation_store then activations.close(activation_store) end
    if plan_store then plans.close(plan_store) end
end

M.stores = stores
M.close = close
return M
