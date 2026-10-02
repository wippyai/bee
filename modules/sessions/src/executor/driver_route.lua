-- MIT. Resolve the exact bee.driver methods admitted for a session route.
local registry = require("registry")
local bounds = require("bounds")
local resolver = require("resolver")
local M = {}

M.CONTRACT = "bee.driver:driver"
M.METHODS = {"prepare", "dispatch", "normalize", "configure"}

type Object = {[string]: unknown}
type Lookup = (string) -> (unknown?, string?)
type Methods = {prepare: string, dispatch: string, normalize: string, configure: string}

function M.decode(binding_ref: string, raw_binding: unknown, lookup: Lookup): (Methods?, string?)
    local binding = bounds.object(raw_binding)
    local data = binding and bounds.object(binding.data)
    local contracts = data and bounds.dense_list(data.contracts, resolver.MAX_CONTRACTS, "driver contracts")
    if not binding or binding.kind ~= "contract.binding" or not contracts then
        return nil, "selected driver binding is malformed"
    end
    local meta = bounds.object(binding.meta)
    if not bounds.id(binding_ref) or not meta or meta.type ~= "harness.driver" or not bounds.id(meta.driver_id) then
        return nil, "selected binding is not an agent driver"
    end
    local selected: Object? = nil
    for _, raw_contract in ipairs(contracts) do
        local contract = bounds.object(raw_contract)
        if not contract or bounds.fields(contract, {"contract", "methods"}) then
            return nil, "selected driver binding has a malformed contract"
        end
        if contract.contract == M.CONTRACT then
            if selected then return nil, "selected driver binding declares its contract twice" end
            selected = bounds.object(contract.methods)
            if not selected or bounds.fields(selected, M.METHODS) then
                return nil, "selected driver binding has malformed methods"
            end
        end
    end
    if not selected then return nil, "selected binding does not implement " .. M.CONTRACT end
    local resolved: {[string]: string} = {}
    for _, name in ipairs(M.METHODS) do
        local target = bounds.id(selected[name])
        if not target then return nil, "selected driver binding omits its " .. name .. " method" end
        local entry, entry_error = lookup(target)
        local target_entry = bounds.object(entry)
        if entry_error or not target_entry or target_entry.kind ~= "function.lua" then
            return nil, "selected driver target " .. name .. " is unavailable"
        end
        resolved[name] = target
    end
    return {prepare = assert(resolved.prepare), dispatch = assert(resolved.dispatch),
        normalize = assert(resolved.normalize), configure = assert(resolved.configure)}, nil
end

function M.resolve(binding_ref: string): (Methods?, string?)
    local pinned, pin_error = registry.snapshot()
    if pin_error or not pinned then return nil, "driver registry snapshot is unavailable" end
    local snapshot = pinned
    local active, activation_error = resolver.active(snapshot)
    if not active then return nil, activation_error end
    if not active[binding_ref] then return nil, "binding " .. binding_ref .. " is not activated" end
    local binding, binding_error = snapshot:get(binding_ref)
    if binding_error or not binding then return nil, "selected driver binding is unavailable" end
    return M.decode(binding_ref, binding, function(target: string): (unknown?, string?)
        return snapshot:get(target)
    end)
end

return M
