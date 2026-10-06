-- MIT. What the node authorizes an app to be: the definition its process entry
-- declares, the admission that names the policies it may hold, the actor each
-- of its instances runs as and the scope that actor runs in. The owner starts
-- apps with these; the test runner runs an app's tests with the same ones.
local registry = require("registry")
local security = require("security")
local system = require("system")
local principal = require("principal")
local descriptor = require("descriptor")
local governed_admission = require("governed_admission")
local application_admissions = require("application_admissions")

local M = {}

-- Every app runs inside one of these policy groups; its process entry and
-- its admission add what the app may do. An admission marked
-- scope_management selects the group that lets the app build call scopes.
M.SCOPE = "bee.node.security:application"
M.MANAGING_SCOPE = "bee.node.security:scope_managing_application"
M.ADMISSION_TYPE = "bee.node.application_admission"

type Definition = {process: string, title: string, terminal: boolean, revision: string, resume_schema: string, singleton: boolean}
M.Definition = Definition

-- definition is the app process entry id declares, from its meta.application
-- descriptor.
function M.definition(id: string): (Definition?, string?)
    local entry, err = registry.get(id)
    if not entry then return nil, "unknown app " .. id .. ": " .. tostring(err) end
    if entry.kind ~= "process.lua" or entry.meta.type ~= descriptor.TYPE then return nil, id .. " is not an app" end
    local declared = descriptor.decode(id, entry.meta.application)
    if not declared then return nil, id .. " declares no valid application" end
    return {process = id, title = declared.title, terminal = declared.terminal, revision = declared.definition_revision,
        resume_schema = declared.resume_schema, singleton = declared.singleton}, nil
end

-- admission is the binding that admits definition_id in workspace_id: the
-- host's own admissions first, then the overlays governance admitted for the
-- workspace, then the packages it composes. The record is the governed
-- admission the binding came from; a host admission has none.
function M.admission(definition_id: string, workspace_id: string): (governed_admission.Binding?, governed_admission.Record?, string?)
    for _, entry in ipairs(registry.find({[".kind"] = "registry.entry", ["meta.type"] = M.ADMISSION_TYPE}) or {}) do
        local data: unknown = entry.data
        local bindings, bindings_error = governed_admission.bindings(type(data) == "table" and data.bindings or nil)
        if not bindings then return nil, nil, "admission " .. entry.id .. ": " .. tostring(bindings_error) end
        for _, binding in ipairs(bindings) do
            if binding.definition_id == definition_id then return binding, nil, nil end
        end
    end
    local pinned = assert(registry.snapshot())
    local selection, selection_error = application_admissions.read(pinned, pinned:version():string(), workspace_id,
        assert(system.node.id()))
    if not selection then return nil, nil, selection_error end
    for _, source in ipairs({selection.governed, selection.packages}) do
        for _, measured in ipairs(source) do
            for _, binding in ipairs(measured.record.bindings) do
                if binding.definition_id == definition_id then return binding, measured.record, nil end
            end
        end
    end
    return nil, nil, nil
end

-- actor is the actor an app instance runs as; owners such as Threads and the
-- approval owner authorize by the workspace and definition it carries.
function M.actor(workspace_id: string, instance_id: string, definition: Definition, generation: integer): (security.Actor?, string?)
    local value = principal.value(workspace_id, instance_id, definition.process, definition.revision, generation)
    if not value then return nil, "application principal is invalid" end
    local actor, err = security.new_actor(value.id, value.metadata)
    if not actor then return nil, "application principal: " .. tostring(err) end
    return actor, nil
end

-- scope is the scope an app instance runs in: its boundary group and the
-- policies its admission names.
function M.scope(definition: Definition, workspace_id: string): (security.Scope?, string?)
    local binding, _, admission_error = M.admission(definition.process, workspace_id)
    if admission_error then return nil, "admission: " .. admission_error end
    local scope, scope_error = security.named_scope(M.SCOPE)
    if not scope then return nil, "application scope: " .. tostring(scope_error) end
    if not binding then return scope, nil end
    if binding.scope_management then
        local managing, managing_error = security.named_scope(M.MANAGING_SCOPE)
        if not managing then return nil, "scope-managing application scope: " .. tostring(managing_error) end
        scope = managing
    end
    for _, id in ipairs(binding.policies) do
        local policy, policy_error = security.policy(id)
        if not policy then return nil, "admitted policy " .. id .. ": " .. tostring(policy_error) end
        scope = scope:with(policy)
    end
    return scope, nil
end

return M
