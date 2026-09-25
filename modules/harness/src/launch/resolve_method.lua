-- MIT. Resolve a measured definition or an authorized saved profile without effects.
local admission = require("admission")
local bounds = require("bounds")
local function invalid(message: string): admission.Reply
    return {ok = false, error = {code = "INVALID", message = message}, value = nil}
end
local function handle(request: unknown): admission.Reply
    local object = bounds.object(request)
    if not object then return invalid("request must be an object") end
    local extra = bounds.fields(object, {"definition_ref", "mode", "workspace_id", "saved_profile_id", "saved_profile_revision", "agent_ref", "owner_component_revision", "owner_revision", "spec_digest"})
    if extra then return invalid(extra) end
    local definition_ref = bounds.id(object.definition_ref)
    if not definition_ref then return invalid("definition_ref must be an identifier") end
    local mode: string? = nil
    if object.mode ~= nil then
        mode = bounds.member(object.mode, {"window", "session", "batch"})
        if not mode then return invalid("invalid launch mode") end
    end
    local workspace, saved_id, revision = bounds.id(object.workspace_id), bounds.id(object.saved_profile_id), bounds.count(object.saved_profile_revision)
    if object.saved_profile_id ~= nil or object.saved_profile_revision ~= nil then
        if not workspace or not saved_id or not revision or revision < 1 then return invalid("saved profile needs workspace, identity and positive revision") end
    elseif object.workspace_id ~= nil and not workspace then return invalid("workspace_id must be an identifier") end
    local agent_ref: string? = nil
    if object.agent_ref ~= nil then
        agent_ref = bounds.id(object.agent_ref)
        if not agent_ref then return invalid("agent_ref must be an identifier") end
    end
    local owner_component_revision: integer? = nil
    local rev_raw = object.owner_component_revision ~= nil and object.owner_component_revision or object.owner_revision
    if rev_raw ~= nil then
        local count = bounds.count(rev_raw)
        if not count or count < 1 then return invalid("owner_component_revision must be a positive integer") end
        owner_component_revision = count
    end
    local spec_digest: string? = nil
    if object.spec_digest ~= nil then
        local digest = bounds.text(object.spec_digest, 64)
        if not digest or #digest ~= 64 or not digest:match("^[0-9a-f]+$") then
            return invalid("spec_digest must be a lowercase SHA-256 hex digest")
        end
        spec_digest = digest
    end
    local plan, refused = admission.resolve(definition_ref, mode, workspace, saved_id, revision, agent_ref, owner_component_revision, spec_digest)
    if not plan then return refused or invalid("launch plan unavailable") end
    return {ok = true, error = nil, value = plan}
end
return {handle = handle}
