-- SPDX-License-Identifier: MIT
local funcs = require("funcs")
local security = require("security")
local bounds = require("bounds")
local admission = require("admission")
local folder_consent = require("folder_consent")
local M = {}
function M.run(plan: admission.Plan, workspace: string, workdir: unknown): {[string]: unknown}
    if not security.can("bee.harness.setup", workspace) then return {ok = false, error = "setup is not authorized"} end
    -- A folder under an admitted root becomes the working directory only
    -- where the definition and its launch policy both allow the override: the
    -- request's folder, otherwise the saved profile's.
    local backend_request: {[string]: unknown} = {workspace_id = workspace, definition_ref = plan.definition_ref, expected_definition_digest = plan.definition_digest, placement_kind = plan.placement_kind}
    local selected_placement = plan.effective_profile and plan.effective_profile.placement
    backend_request.private_home = selected_placement ~= nil and selected_placement.kind == "native" and selected_placement.home == "private"
    local folder: unknown = workdir
    if folder == nil and plan.effective_profile then folder = plan.effective_profile.workdir end
    if folder ~= nil then
        if not admission.overrides(plan, "workdir") then return {ok = false, error = "the launch does not allow a workdir override"} end
        backend_request.workdir = folder
    end
    local scope, scope_error = security.named_scope("bee.harness.launch:harness_setup_execution_scope")
    if not scope then return {ok = false, error = tostring(scope_error or "setup scope unavailable")} end
    local executor, executor_error = funcs.new():with_scope(scope)
    if not executor then return {ok = false, error = tostring(executor_error or "setup scope denied")} end
    local result, call_error = executor:call("bee.harness.binding:setup_backend", backend_request)
    if call_error or type(result) ~= "table" then return {ok = false, error = tostring(call_error or "setup reply")} end
    if result.ok == true then
        local consent_error = folder_consent.run(plan, workspace, bounds.id(result.workdir), executor)
        if consent_error then return {ok = false, error = consent_error} end
    end
    return result
end
return M
