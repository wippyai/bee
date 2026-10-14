-- SPDX-License-Identifier: MIT
local registry = require("registry")
local security = require("security")
local hash = require("hash")
local bounds = require("bounds")
local canonical = require("canonical")
local agent_trait = require("agent_trait")
local app_identity = require("app_identity")
local application = require("application")
local app_tools = require("app_tools")
local capability_access = require("capability_access")
local capability_grants = require("capability_grants")
local governed_admission = require("governed_admission")
local M = {}
type Catalog = {traits: {agent_trait.Declaration}, tools: {app_tools.Tool}}
function M.workspace(): string?
    local actor = security.actor()
    local meta = actor and bounds.object(actor:meta())
    return meta and bounds.id(meta.workspace_id) or nil
end
function M.catalog(workspace: string): (Catalog?, string?)
    local records, record_error = registry.find({[".kind"] = "registry.entry", ["meta.type"] = capability_grants.SCHEMA})
    if not records then return nil, tostring(record_error) end
    local offers_tools = false
    for _, entry in ipairs(records) do
        local data = bounds.object(entry.data)
        if data and data.workspace_id == workspace then
            for _, raw in ipairs(bounds.array(data.capabilities, 64) or {}) do
                local grant = bounds.object(raw)
                if grant and grant.capability == "agent.tools" then offers_tools = true end
            end
        end
    end
    if not offers_tools then return {traits = {}, tools = {}}, nil end
    local discovery, err = app_tools.discover(workspace)
    if not discovery then return nil, err end
    local definitions, invalid = application.definitions(workspace)
    if not definitions then return nil, invalid end
    local traits: {agent_trait.Declaration} = {}
    for _, definition in ipairs(definitions) do
        local record, refusal = capability_access.record(workspace, definition)
        if refusal then return nil, refusal.error and refusal.error.message or "application grants unavailable" end
        local offered = false
        for _, grant in ipairs(record and record.capabilities or {}) do
            if grant.capability == "agent.tools" then offered = true end
        end
        local app = offered and application.definition(definition) or nil
        if app and record then
            local origin, origin_error = application.origin(definition, workspace)
            if origin_error then return nil, origin_error end
            local id = app_identity.trait(workspace, definition, origin and origin.overlay_owner or nil)
            if not id then return nil, "application trait identity unavailable" end
            local names: {string} = {}
            local tools: {app_tools.Tool} = {}
            for _, tool in ipairs(discovery.tools) do
                if tool.definition_id == definition then
                    names[#names + 1] = tool.alias
                    tools[#tools + 1] = tool
                end
            end
            local entry = registry.get(definition)
            local meta = entry and bounds.object(entry.meta)
            local description = meta and bounds.text(meta.description, 4096) or nil
            if not description and origin then
                local overlay, err = registry.overlay(origin.overlay_owner)
                if not overlay then return nil, tostring(err) end
                local metadata, err = overlay:find({[".kind"] = "ns.definition", ["meta.title"] = app.title})
                if not metadata then return nil, tostring(err) end
                if #metadata == 1 then
                    local meta = bounds.object(metadata[1].meta)
                    description = meta and bounds.text(meta.description, 4096) or nil
                end
            end
            if not description then
                for _, binding in ipairs(record.bindings) do
                    local requirement = bounds.id(binding.requirement_id)
                    local entry = requirement and registry.get(requirement)
                    local meta = entry and bounds.object(entry.meta)
                    if meta and meta.capability == "agent.tools" then description = bounds.text(meta.reason, 4096) end
                end
            end
            local prompt = (description or ("Use " .. app.title .. ".")) .. "\nTools: " .. table.concat(names, ", ")
            local declared, trait_error = agent_trait.declaration({id = id, title = app.title, prompt = prompt,
                tools = names, application_ref = definition, application_revision = app.revision})
            if not declared then return nil, trait_error end
            declared.digest = hash.sha256(assert(canonical.encode({declaration = declared, tools = tools, grants = record})))
            traits[#traits + 1] = declared
        end
    end
    return {traits = traits, tools = discovery.tools}, nil
end
function M.load(ref: string, workspace: string?): (agent_trait.Declaration?, string?, string?)
    local home = workspace or M.workspace()
    local records, err = registry.find({[".kind"] = "registry.entry", ["meta.type"] = capability_grants.SCHEMA})
    if not records then return nil, tostring(err) end
    local admissions, err = registry.find({[".kind"] = "registry.entry", ["meta.type"] = governed_admission.SCHEMA})
    if not admissions then return nil, tostring(err) end
    for _, entry in ipairs(records) do
        local data = bounds.object(entry.data)
        local workspace = data and bounds.id(data.workspace_id)
        local definition = data and bounds.id(data.application)
        if workspace and definition and (not home or home == workspace) then
            local owner: string? = nil
            for _, entry in ipairs(admissions) do
                local record = bounds.object(entry.data)
                if record and record.workspace_id == workspace then
                    for _, raw in ipairs(bounds.array(record.bindings, 64) or {}) do
                        local binding = bounds.object(raw)
                        if binding and binding.definition_id == definition then owner = bounds.id(record.overlay_owner) end
                    end
                end
            end
            if app_identity.trait(workspace, definition, owner) == ref then
                local catalog, err = M.catalog(workspace)
                if not catalog then return nil, err end
                for _, trait in ipairs(catalog.traits) do if trait.id == ref then return trait, nil, workspace end end
            end
        end
    end
    return nil, "trait unavailable: " .. ref
end
return M
