-- MIT. The lower binding resolver shared by carrier-adjacent placement and
-- the harness catalog. It reads one pinned registry generation and answers
-- only activation plus a driver's contract target; profile presentation and
-- permission adapters remain owned by the harness catalog.
local registry = require("registry")
local bounds = require("bounds")
local profile_codec = require("profile")
local descriptor = require("descriptor")
local driver_types = require("types")
local M = {}
M.ACTIVATION = "bee.harness:harness_activation"
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
    local list = value
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
            local method_extra = bounds.fields(methods, {"prepare", "dispatch", "normalize", "configure", "locate"})
            if method_extra then return nil, "binding " .. binding_ref .. " driver methods: " .. method_extra, nil end
            for _, name in ipairs({"prepare", "dispatch", "normalize", "configure"}) do
                local method = bounds.id(methods[name])
                if not method then return nil, "binding " .. binding_ref .. " binds no " .. name, nil end
                local entry = M.entry(pinned, method)
                if not entry or entry.kind ~= "function.lua" then return nil, "binding " .. binding_ref .. " method " .. name .. " is not a function", nil end
                if name == "configure" then target = method end
            end
            if methods.locate ~= nil then
                local method = bounds.id(methods.locate)
                if not method then return nil, "binding " .. binding_ref .. " binds no locate", nil end
                local entry = M.entry(pinned, method)
                if not entry or entry.kind ~= "function.lua" then return nil, "binding " .. binding_ref .. " method locate is not a function", nil end
            end
        end
    end
    if not target then return nil, "binding " .. binding_ref .. " binds no configure", nil end
    return target, nil, driver_id
end

function M.configure_renderer(pinned: registry.Snapshot, binding_ref: string, target: string?): (string?, string?)
    local namespace = binding_ref:match("^(.*):binding$")
    if not namespace or (target ~= nil and target ~= namespace .. ".binding:configure") then return nil, nil end
    local binding = M.entry(pinned, binding_ref)
    local meta = binding and bounds.object(binding.meta) or nil
    local provider = meta and bounds.id(meta.driver_id) or nil
    if not provider then return nil, nil end
    local descriptor_ref = meta and bounds.id(meta.descriptor_ref) or nil
    if not descriptor_ref then
        if meta and meta.descriptor_ref ~= nil then return nil, "driver binding has an invalid descriptor_ref" end
        return nil, nil
    end
    local selected, descriptor_error = descriptor.load_from(pinned, descriptor_ref)
    if descriptor_error then return nil, descriptor_error end
    if selected and selected.provider ~= provider then return nil, "driver binding descriptor provider does not match driver_id" end
    return selected and selected.configure or nil, nil
end

function M.configure_renderer_for_target(pinned: registry.Snapshot, target: string): (string?, string?)
    local namespace = target:match("^(.*)%.binding:configure$")
    if not namespace then return nil, nil end
    return M.configure_renderer(pinned, namespace .. ":binding", target)
end

-- The selected immutable driver profile may name a typed CLI adapter for
-- Git's additional metadata roots. The caller cannot supply this choice;
-- placement reads it from the activated binding's profile record.
function M.profile(pinned: registry.Snapshot, binding_ref: string, profile_id: string): (driver_types.Profile?, string?)
    local active, active_error = M.active(pinned)
    if not active or not active[binding_ref] then return nil, active_error or "binding " .. binding_ref .. " is not activated" end
    local binding = M.entry(pinned, binding_ref)
    local meta = binding and bounds.object(binding.meta) or nil
    if not binding or binding.kind ~= "contract.binding" or not meta or meta.type ~= "harness.driver" then
        return nil, "binding " .. binding_ref .. " is not an activated driver"
    end
    local profiles_ref = bounds.id(meta.profiles_ref)
    -- Legacy and fixture drivers without declarative profiles cannot opt into
    -- additional sandbox roots; they retain their existing configure path.
    if not profiles_ref then return nil, nil end
    local profiles_entry = M.entry(pinned, profiles_ref)
    local profiles_meta = profiles_entry and bounds.object(profiles_entry.meta) or nil
    local profiles_data = profiles_entry and bounds.object(profiles_entry.data) or nil
    if not profiles_entry or not profiles_meta or profiles_meta.type ~= "harness.profile" or profiles_meta.driver_ref ~= binding_ref or not profiles_data then
        return nil, "binding " .. binding_ref .. " profile entry is invalid"
    end
    local decoded, decode_error = profile_codec.decode(profiles_data.driver)
    if not decoded then return nil, "binding " .. binding_ref .. " profile entry: " .. tostring(decode_error) end
    local selected = profile_codec.find(decoded, profile_id)
    if not selected then return nil, "binding " .. binding_ref .. " has no profile " .. profile_id end
    return selected, nil
end
function M.select_hooks(profile: driver_types.Profile?, requested: {string}): {string}
    local supported: {[string]: boolean} = {}
    if profile and profile.hooks then
        for _, event in ipairs(profile.hooks.events) do supported[event] = true end
    end
    local selected: {string} = {}
    for _, event in ipairs(requested) do
        if supported[event] then selected[#selected + 1] = event end
    end
    table.sort(selected)
    return selected
end

return M
