-- MIT. Resolve a measured definition or an authorized saved profile without effects.
local admission = require("admission")
local bounds = require("bounds")
local function invalid(message: string): admission.Reply
    return {ok = false, error = {code = "INVALID", message = message}, value = nil}
end
local function handle(request: unknown): admission.Reply
    local object = bounds.object(request)
    if not object then return invalid("request must be an object") end
    local extra = bounds.fields(object, {"definition_ref", "mode", "workspace_id", "saved_profile_id", "saved_profile_revision"})
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
    local plan, refused = admission.resolve(definition_ref, mode, workspace, saved_id, revision)
    if not plan then return refused or invalid("launch plan unavailable") end
    return {ok = true, error = nil, value = plan}
end
return {handle = handle}
