-- SPDX-License-Identifier: MIT
local placement_types = require("placement_types")
local record_types = require("record_types")
local M = {}
type ProfileGrant = {workspace_id: string, name: string, subpath: string, access: "read" | "write", grant_ref: string}
type Request = {
    profile_grants: {ProfileGrant}?,
    preferences: placement_types.Preferences?,
    thread_id: string,
    action_id: string,
    attempt_id: string,
    owner_id: string,
    owner_incarnation: integer,
    binding_ref: string,
    profile_id: string,
    brief: string,
    policy_ref: string,
    placement_profile_ref: string?,
    placement_profile_digest: string?,
    placement_binding_ref: string?,
    placement_binding_digest: string?,
    resources: {placement_types.ResourceGrant},
    environment: {[string]: string},
    session_ref: string?,
    previous_attempt_id: string?,
    reauthorize: boolean?,
    working_directory: string?,
    projections: {string}?,
    workspace_id: string?,
    parent_action_id: string?,
    origin_view: {view_id: string, instance_id: string}?,
    options: placement_types.WorkdirOptions?,
}

function M.admitted_action(request: Request, binding_ref: string, binding_digest: string, budget_ref: string,
    grant_refs: {string}, input_text: string): record_types.Admitted
    local admitted: record_types.Admitted = {request_id = "launch:" .. request.attempt_id,
        principal_id = request.owner_id, binding_ref = binding_ref, binding_digest = binding_digest,
        grant_refs = grant_refs, budget_ref = budget_ref, input = {text = input_text}}
    if request.parent_action_id then admitted.parent_action_id = request.parent_action_id end
    return admitted
end
return M
