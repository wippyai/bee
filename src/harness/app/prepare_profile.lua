-- SPDX-License-Identifier: MIT
local funcs = require("funcs")
local bounds = require("bounds")
local admission = require("admission")
local profiles = require("profiles")
return {handle = function(value: unknown): {[string]: unknown}
    local request = bounds.object(value)
    if not request or bounds.fields(request, {"definition_ref", "workspace_id", "profile_id", "profile_revision", "overrides"}) then
        return {ok = false, error = "Invalid profile setup request"}
    end
    local definition, workspace = bounds.id(request.definition_ref), bounds.id(request.workspace_id)
    local id, revision = bounds.id(request.profile_id), bounds.count(request.profile_revision)
    local options, options_error = profiles.overrides(request.overrides)
    if not definition or not workspace or not id or not revision or revision < 1 or options_error then
        return {ok = false, error = options_error or "Invalid profile setup identity"}
    end
    local plan, plan_error = admission.resolve(definition, "window", workspace, id, revision,
        nil, nil, nil, nil, options)
    if not plan then
        return {ok = false, error = plan_error and plan_error.error and plan_error.error.message or "Folder approval is unavailable"}
    end
    local prepared, prepare_error = funcs.call("bee.harness.binding:setup", {workspace_id = workspace,
        definition_ref = definition, expected_plan_digest = plan.plan_digest, saved_profile_id = id,
        saved_profile_revision = revision, workdir = options and options.workdir, overrides = options})
    return bounds.object(prepared) or {ok = false, error = tostring(prepare_error or "Folder approval is unavailable")}
end}
