-- MIT. Registry-owned Hub inventory snapshot reader.
local registry = require("registry")
local inventory = require("inventory")
local M = {}

function M.read(): (inventory.Result?, string?)
    local snapshot, snapshot_error = registry.snapshot()
    if not snapshot then return nil, tostring(snapshot_error) end
    local state, state_error = snapshot:state()
    if not state then return nil, tostring(state_error) end
    return inventory.decode(state, snapshot:version():id())
end

function M.sources(request: unknown): ({[string]: unknown}?, string?)
    local snapshot, snapshot_error = registry.snapshot()
    if not snapshot then return nil, tostring(snapshot_error) end
    local state, state_error = snapshot:state()
    if not state then return nil, tostring(state_error) end
    return inventory.sources(state, snapshot:version():id(), request)
end

return M
