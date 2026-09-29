-- MIT. Resolve the exact bee.driver methods admitted for a session route.
local registry = require("registry")
local M = {}

M.CONTRACT = "bee.driver:driver"
M.METHODS = {"prepare", "dispatch", "normalize", "configure"}

type Object = {[string]: unknown}
type Snapshot = {get: (string) -> (unknown?, string?)}
type Lookup = (string) -> (unknown?, string?)
type Methods = {prepare: string, dispatch: string, normalize: string}

local function object(value: unknown): Object?
    if type(value) ~= "table" then return nil end
    return value :: Object
end

local function method_id(value: unknown, prefix: string, method: string): string?
    if type(value) ~= "string" or #value > 256 then return nil end
    if value:sub(1, #prefix) ~= prefix or value:sub(#prefix + 1) ~= method then return nil end
    return value
end

function M.decode(binding_ref: string, raw_binding: unknown, lookup: Lookup): (Methods?, string?)
    local binding = object(raw_binding)
    local data = binding and object(binding.data)
    local contracts = data and data.contracts
    if not binding or binding.kind ~= "contract.binding" or type(contracts) ~= "table" then
        return nil, "selected driver binding is malformed"
    end
    local prefix = binding_ref:gsub(":", ".") .. ":"
    local selected: Object? = nil
    for _, raw_contract in ipairs(contracts :: {unknown}) do
        local contract = object(raw_contract)
        if contract and contract.contract == M.CONTRACT then
            if selected then return nil, "selected driver binding declares its contract twice" end
            selected = object(contract.methods)
        end
    end
    if not selected then return nil, "selected binding does not implement " .. M.CONTRACT end
    local resolved: {[string]: string} = {}
    for _, name in ipairs(M.METHODS) do
        local target = method_id((selected :: Object)[name], prefix, name)
        if not target then return nil, "selected driver binding omits its " .. name .. " method" end
        local entry, entry_error = lookup(target)
        local target_entry = object(entry)
        if entry_error or not target_entry or target_entry.kind ~= "function.lua" then
            return nil, "selected driver target " .. name .. " is unavailable"
        end
        resolved[name] = target
    end
    return {prepare = resolved.prepare :: string, dispatch = resolved.dispatch :: string,
        normalize = resolved.normalize :: string}, nil
end

function M.resolve(binding_ref: string): (Methods?, string?)
    local pinned, pin_error = registry.snapshot()
    if pin_error or not pinned then return nil, "driver registry snapshot is unavailable" end
    local snapshot = pinned :: Snapshot
    local binding, binding_error = snapshot:get(binding_ref)
    if binding_error or not binding then return nil, "selected driver binding is unavailable" end
    return M.decode(binding_ref, binding, function(target: string): (unknown?, string?)
        return snapshot:get(target)
    end)
end

return M
