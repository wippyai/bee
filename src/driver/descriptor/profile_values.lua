local registry = require("registry")
local json = require("json")
local bounds = require("bounds")
local descriptors = require("descriptors")
local effective = require("effective")
local M = {}
type Object = {[string]: unknown}
type Stored = {schema_ref: string, schema_revision: string, values: Object}
function M.schema(binding_ref: string): (descriptors.Descriptor?, string?, string?)
    local pinned, err = registry.snapshot()
    if not pinned then return nil, nil, tostring(err) end
    local binding = pinned:get(binding_ref)
    local meta = binding and bounds.object(binding.meta)
    local ref = meta and bounds.id(meta.descriptor_ref)
    if not ref then return nil, nil, "Driver has no option schema" end
    local descriptor, invalid = descriptors.load_from(pinned, ref)
    return descriptor, ref, invalid
end
function M.flatten(provider: Object): (Object?, string?)
    local result: Object = assert(bounds.object(json.decode("{}")))
    for name, value in pairs(provider) do
        if name == "options" then
            local options = bounds.object(value)
            if not options then return nil, "Provider options must be an object" end
            for id, item in pairs(options) do
                if provider[id] ~= nil then return nil, "Conflicting provider option " .. id end
                result[id] = item
            end
        else result[name] = value end
    end
    return result, nil
end
function M.encode(binding_ref: string, provider: Object, placement_ref: string?): (Stored?, string?)
    local descriptor, ref, err = M.schema(binding_ref)
    if not descriptor or not ref then return nil, err end
    local values, invalid = M.flatten(provider)
    if not values then return nil, invalid end
    local fields = bounds.object(descriptor.options.fields) or {}
    for id in pairs(values) do
        local field = bounds.object(fields[id])
        if not field or not field.path then return nil, "Undeclared profile option " .. id end
    end
    local _, compile_error = effective.compile(descriptor, nil, nil, values, nil, nil, nil, placement_ref)
    if compile_error then return nil, compile_error end
    return {schema_ref = ref, schema_revision = descriptor.schema_revision, values = values}, nil
end
function M.decode(binding_ref: string, stored: Object, placement_ref: string?): (Object?, string?)
    if bounds.fields(stored, {"schema_ref", "schema_revision", "values"}) then return nil, "Invalid option schema selection" end
    local descriptor, ref, err = M.schema(binding_ref)
    if not descriptor then return nil, err end
    if stored.schema_ref ~= ref or stored.schema_revision ~= descriptor.schema_revision then return nil, "Driver option schema changed; repair is required" end
    local values = bounds.object(stored.values)
    if not values then return nil, "Option values must be an object" end
    local result: Object = assert(bounds.object(json.decode("{}")))
    local options: Object = {}
    local fields = bounds.object(descriptor.options.fields) or {}
    for id, value in pairs(values) do
        local field = bounds.object(fields[id])
        if not field or not field.path then return nil, "Undeclared profile option " .. id end
        if field.path == "provider." .. id then result[id] = value else options[id] = value end
    end
    if next(options) then result.options = options end
    local _, invalid = effective.compile(descriptor, nil, nil, values, nil, nil, nil, placement_ref)
    if invalid then return nil, invalid end
    return result, nil
end
function M.person_only(binding_ref: string, provider: Object): string?
    local descriptor, _, err = M.schema(binding_ref)
    if not descriptor then return err or "Driver option schema is unavailable" end
    local values = provider.schema_ref and bounds.object(provider.values) or M.flatten(provider)
    if not values then return "Invalid driver options" end
    local fields = bounds.object(descriptor.options.fields) or {}
    for name, value in pairs(values) do
        local field = bounds.object(fields[name])
        if field and field.security_class == "person-only" then return name .. " requires a person write with consent provenance" end
        for _, selected in ipairs(field and bounds.array(field.person_values, 64) or {}) do
            if value == selected then return name .. " requires a person write with consent provenance" end
        end
    end
    return nil
end
return M
