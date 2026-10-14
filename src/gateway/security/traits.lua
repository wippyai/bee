local registry = require("registry")
local bounds = require("bounds")
local agent_trait = require("agent_trait")
local descriptor = require("descriptor")
local canonical = require("canonical")
local database = require("database")
local json = require("json")
local hook_capabilities = require("hook_capabilities")
local M = {}
type Declaration = agent_trait.Declaration
function M.session(binding: {subject: string, action_id: string}): string
    return binding.subject:match("^bs:") and binding.subject or binding.action_id
end
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
function M.supported(declared: Declaration, session: string, workspace: string, admitted_hooks: {string}?): string?
    if #(declared.hooks or {}) == 0 then return nil end
    local db, err = database.open()
    if not db then return err end
    local rows, failure = db:query("SELECT route_json FROM bee_sessions WHERE session_ref=? AND workspace_id=?", {session, workspace})
    db:release()
    if not rows or failure or #rows ~= 1 then return "extension session is unavailable" end
    local route = type(rows[1].route_json) == "string" and bounds.object(json.decode(rows[1].route_json)) or nil
    local driver = route and bounds.id(route.provider) or "unknown"
    for _, point in ipairs(declared.hooks or {}) do
        local capability = hook_capabilities.at(driver, point)
        if not capability or not capability.supported then return point .. ": " .. (capability and capability.reason or "unknown hook point") end
        if driver ~= "wippy" then
            local delivered = false
            for _, event in ipairs(admitted_hooks or {}) do
                if hook_capabilities.EVENTS[event] == point then delivered = true end
            end
            if not delivered then return point .. ": the hook response transport is not admitted by this binding" end
        end
    end
    return nil
end

return M
