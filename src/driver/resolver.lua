-- MIT. The lower binding resolver shared by carrier-adjacent placement and
-- the harness catalog. It reads one pinned registry generation and answers
-- only activation plus a driver's contract target; profile presentation and
-- permission adapters remain owned by the harness catalog.
local registry = require("registry")
local bounds = require("bounds")
local M = {}
M.ACTIVATION = "bee:harness_activation"
M.ACTIVATION_TYPE = "bee.harness_activation"
M.ACTIVATION_SCHEMA = "bee.harness-activation@1"
M.MAX_BINDINGS = 64
M.MAX_CONTRACTS = 16
type Entry = {[string]: unknown}
type Activation = {bindings: {[string]: boolean}}
-- Decode the host declaration independently of any registry access.  The
-- catalog and placement both use this exact boundary after they have pinned
-- their own snapshot, so malformed activation can never silently select a
-- binding in one path but not the other.
function M.decode_activation(ref: string, entry: Entry): (Activation?, string?)
    local meta = bounds.object(entry.meta) or {}
    if meta.type ~= M.ACTIVATION_TYPE then return nil, ref .. " is not a harness activation declaration" end
    local data = bounds.object(entry.data)
    if not data then return nil, ref .. " has no data" end
    local unknown_field = bounds.fields(data, {"schema_revision", "bindings"})
    if unknown_field then return nil, ref .. ": " .. unknown_field end
    if data.schema_revision ~= M.ACTIVATION_SCHEMA then return nil, ref .. ": schema_revision must be " .. M.ACTIVATION_SCHEMA end
    local list, list_error = bounds.ids(data.bindings, true)
    if not list then return nil, ref .. ": bindings: " .. tostring(list_error) end
    if #list > M.MAX_BINDINGS then return nil, ref .. ": bindings exceeds " .. tostring(M.MAX_BINDINGS) .. " items" end
    local bindings: {[string]: boolean} = {}
    for _, binding_ref in ipairs(list) do bindings[binding_ref] = true end
    return {bindings = bindings}, nil
end
function M.pin(): (registry.Snapshot?, string?)
    local pinned, err = registry.snapshot()
    if err or not pinned then return nil, "pin registry" end
    return pinned, nil
end
function M.entry(pinned: registry.Snapshot, ref: string): {[string]: unknown}?
    local entry, err = pinned:get(ref)
    if err or not entry then return nil end
    return bounds.object(entry)
end
function M.active(pinned: registry.Snapshot): ({[string]: boolean}?, string?)
    local activation = M.entry(pinned, M.ACTIVATION)
    if not activation then return {}, nil end
    local decoded, decode_error = M.decode_activation(M.ACTIVATION, activation)
    if not decoded then return nil, decode_error end
    return decoded.bindings, nil
end
local function array(value: unknown, maximum: integer, label: string): ({unknown}?, string?)
    if type(value) ~= "table" then return nil, label .. " must be a list" end
    local list = value :: {unknown}
    local count = 0
    for key in pairs(list) do
        if type(key) ~= "number" or key < 1 or math.floor(key) ~= key then return nil, label .. " must be a list" end
        count = count + 1
    end
    if count > maximum then return nil, label .. " exceeds " .. tostring(maximum) .. " items" end
    for index = 1, count do
        if list[index] == nil then return nil, label .. " must be a list" end
    end
    return list, nil
end
function M.configure(pinned: registry.Snapshot, binding_ref: string): (string?, string?, string?)
    local active, active_error = M.active(pinned)
    if not active or not active[binding_ref] then return nil, active_error or "binding " .. binding_ref .. " is not activated", nil end
    local binding = M.entry(pinned, binding_ref)
    local meta = binding and bounds.object(binding.meta) or nil
    if not binding or binding.kind ~= "contract.binding" or not meta or meta.type ~= "harness.driver" then return nil, "binding " .. binding_ref .. " is not an activated driver", nil end
    local driver_id = bounds.id(meta.driver_id)
    if not driver_id then return nil, "binding " .. binding_ref .. " has no driver_id", nil end
    local data = bounds.object(binding.data)
    if not data then return nil, "binding " .. binding_ref .. " has malformed data", nil end
    local data_extra = bounds.fields(data, {"contracts"})
    if data_extra then return nil, "binding " .. binding_ref .. " data: " .. data_extra, nil end
    local contracts, contracts_error = array(data.contracts, M.MAX_CONTRACTS, "binding " .. binding_ref .. " contracts")
    if not contracts then return nil, contracts_error, nil end
    local target: string? = nil
    for _, raw in ipairs(contracts) do
        local contract = bounds.object(raw)
        if not contract then return nil, "binding " .. binding_ref .. " contract must be an object", nil end
        local contract_extra = bounds.fields(contract, {"contract", "methods"})
        if contract_extra then return nil, "binding " .. binding_ref .. " contract: " .. contract_extra, nil end
        if contract.contract == "bee.driver:driver" then
            if target then return nil, "binding " .. binding_ref .. " declares the driver contract twice", nil end
            local methods = bounds.object(contract.methods)
            if not methods then return nil, "binding " .. binding_ref .. " driver methods must be an object", nil end
            local method_extra = bounds.fields(methods, {"prepare", "dispatch", "normalize", "configure"})
            if method_extra then return nil, "binding " .. binding_ref .. " driver methods: " .. method_extra, nil end
            for _, name in ipairs({"prepare", "dispatch", "normalize", "configure"}) do
                local method = bounds.id(methods[name])
                if not method then return nil, "binding " .. binding_ref .. " binds no " .. name, nil end
                local entry = M.entry(pinned, method)
                if not entry or entry.kind ~= "function.lua" then return nil, "binding " .. binding_ref .. " method " .. name .. " is not a function", nil end
                if name == "configure" then target = method end
            end
        end
    end
    if not target then return nil, "binding " .. binding_ref .. " binds no configure", nil end
    return target, nil, driver_id
end
return M
