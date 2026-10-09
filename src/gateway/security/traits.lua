local registry = require("registry")
local bounds = require("bounds")
local agent_trait = require("agent_trait")
local descriptor = require("descriptor")
local canonical = require("canonical")
local M = {}
type Declaration = agent_trait.Declaration
function M.load(ref: string): (Declaration?, string?)
    local pinned, err = registry.snapshot()
    if not pinned then return nil, tostring(err) end
    local entry, entry_error = pinned:get(ref)
    if not entry then return nil, "trait unavailable: " .. ref end
    local trait, trait_error = agent_trait.registry(ref, entry)
    if not trait then return nil, trait_error end
    local app = trait.application_ref
    if not app then return nil, "trait has no application_ref: " .. ref end
    local application, app_error = pinned:get(app)
    local meta = application and bounds.object(application.meta)
    local declared = meta and descriptor.decode(app, meta.application)
    if not application or application.kind ~= "process.lua" or not meta or meta.type ~= descriptor.TYPE or not declared then
        return nil, "installed application unavailable: " .. app .. ": " .. tostring(app_error)
    end
    return {id = ref, title = trait.title, prompt = trait.prompt, tools = trait.tool_refs, listens = trait.listens, hooks = trait.hooks,
        application_ref = app, application_revision = declared.definition_revision, digest = trait.digest}, nil
end
function M.review(declared: Declaration): (Declaration?, string?)
    local live, err = M.load(declared.id)
    if not live then return nil, err end
    if live.application_ref ~= declared.application_ref or live.application_revision ~= declared.application_revision
        or live.digest ~= declared.digest or canonical.encode(live.listens) ~= canonical.encode(declared.listens)
        or canonical.encode(live.hooks) ~= canonical.encode(declared.hooks) then
        return nil, "application or trait declarations changed; person re-approval required: " .. declared.id
    end
    return live, nil
end
return M
