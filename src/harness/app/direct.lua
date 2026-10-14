-- SPDX-License-Identifier: MIT
local admission = require("admission")
local funcs = require("funcs")
local bounds = require("bounds")
local uuid = require("uuid")
local M = {}
local function fault(reply: admission.Reply?): string
    local value = reply and reply.error
    if not value then return "Agent launch was not admitted" end
    return value.code .. ": " .. value.message
end

function M.run(workspace_id: string, definition_ref: string, thread_id: string?,
    origin_view: {view_id: string, instance_id: string}?, phase: ((string) -> ())?, brief: string?): (admission.Admitted?, string?)
    if phase then phase("Checking installed driver") end
    local plan, refused = admission.resolve(definition_ref, nil, workspace_id)
    if not plan then return nil, fault(refused) end
    if phase then phase("Preparing agent resources") end
    local setup, setup_error = funcs.call("bee.harness.binding:setup", {
        workspace_id = workspace_id, definition_ref = definition_ref,
        expected_plan_digest = plan.plan_digest})
    local prepared = bounds.object(setup)
    if setup_error or not prepared or prepared.ok ~= true then
        return nil, setup_error and tostring(setup_error) or
            (prepared and type(prepared.error) == "string" and prepared.error or "Agent resource setup failed")
    end
    local request_id, request_error = uuid.v7()
    if not request_id then return nil, "Agent request identity: " .. tostring(request_error) end
    if phase then phase("Creating session and thread") end
    local admitted, admission_error = admission.admit_request({request_id = request_id,
        definition_ref = definition_ref, expected_plan_digest = plan.plan_digest,
        workspace_id = workspace_id, thread_id = thread_id, brief = brief or "", mode = plan.mode, workdir = prepared.workdir, origin_view = origin_view})
    if not admitted then return nil, fault(admission_error) end
    return admitted, nil
end

return M
