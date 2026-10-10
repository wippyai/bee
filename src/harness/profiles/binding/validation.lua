-- SPDX-License-Identifier: MIT
local registry = require("registry")
local bounds = require("bounds")
local descriptors = require("descriptors")
local agent_trait = require("agent_trait")
local protocol = require("protocol")
local preferences = require("preferences")
local mcp = require("mcp")
local M = {}
function M.check(pinned: registry.Snapshot, profile: protocol.Profile): string?
    local requested: {string} = {}
    for _, ref in ipairs(profile.active_traits or {}) do requested[#requested + 1] = ref end
    for _, ref in ipairs(profile.requestable or {}) do requested[#requested + 1] = ref end
    for _, ref in ipairs(requested) do
        local builtin = ref == mcp.APPLICATION_RUNTIME_TRAIT.id
        for _, trait in ipairs(mcp.CONSENT_TRAITS) do if trait.id == ref then builtin = true end end
        local entry = pinned:get(ref)
        if not builtin then
            if not entry then return "Trait unavailable: " .. ref end
            local trait, err = agent_trait.registry(ref, entry)
            if not trait then return err end
        end
    end
    local definition = pinned:get(profile.definition_ref)
    local definition_data = definition and bounds.object(definition.data)
    if not definition_data or definition_data.binding_ref ~= profile.driver_binding_ref then return "Definition has no matching admitted driver binding" end
    local binding = pinned:get(profile.driver_binding_ref)
    local meta = binding and bounds.object(binding.meta)
    local ref = meta and bounds.id(meta.descriptor_ref)
    if not ref then return "Driver has no CLI descriptor" end
    local descriptor, err = descriptors.load_from(pinned, ref)
    if not descriptor then return err or "CLI descriptor is unavailable" end
    local fields = bounds.object(descriptor.options.fields) or {}
    local declared: {[string]: {[string]: unknown}} = {}
    for _, raw in pairs(fields) do
        local item = bounds.object(raw)
        local path = item and bounds.id(item.path)
        if item and path then declared[path] = item end
    end
    for name, value in pairs(profile.provider) do
        if name == "options" then
            for key, option in pairs(profile.provider.options or {}) do
                local field = declared["provider.options." .. key]
                if not field then return "Unsupported provider option " .. key end
                local _, invalid = descriptors.decode_option(key, field, option)
                if invalid then return invalid end
            end
        else
            local field = declared["provider." .. name]
            if not field then return "Unsupported provider field " .. name end
            local _, invalid = descriptors.decode_option(name, field, value)
            if invalid then return invalid end
        end
    end
    return nil
end
function M.ceiling(pinned: registry.Snapshot, profile: protocol.Profile, parent: {string}?): string?
    local definition = pinned:get(profile.definition_ref)
    local definition_data = definition and bounds.object(definition.data)
    local ref = definition_data and bounds.id(definition_data.policy_ref)
    local entry = ref and pinned:get(ref)
    local policy = entry and bounds.object(entry.data)
    if not policy then return "Driver launch ceiling is unavailable" end
    local selected, selection_error = protocol.preferences(profile)
    if not selected then return selection_error end
    local _, err = preferences.apply(policy, selected)
    if err then return err end
    local surface = bounds.object(policy.gateway_surface) or {}
    local access = bounds.object(surface.access) or {}
    local allowed: {[string]: boolean} = {}
    for _, id in ipairs(bounds.ids(access.traits, true) or {}) do allowed[id] = true end
    for _, raw in ipairs(bounds.array(surface.traits, 64) or {}) do
        local trait = bounds.object(raw)
        if trait and type(trait.id) == "string" then allowed[trait.id] = true end
    end
    for _, list in ipairs({profile.active_traits or {}, profile.requestable or {}}) do
        for _, id in ipairs(list) do
            if not allowed[id] then return "trait outside launch ceiling: " .. id end
            if parent and not bounds.member(id, parent) then return "trait outside parent ceiling: " .. id end
        end
    end
    return nil
end
return M
