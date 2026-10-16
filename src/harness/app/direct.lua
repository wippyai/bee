-- SPDX-License-Identifier: MIT
local admission = require("admission")
local funcs = require("funcs")
local bounds = require("bounds")
local uuid = require("uuid")
local M = {}
type Call = (string, unknown) -> (unknown, string?)
type Admit = (admission.Request, string?) -> (admission.Admitted?, admission.Reply?)
local function fault(reply: admission.Reply?): string
    local value = reply and reply.error
    if not value then return "Agent launch was not admitted" end
    return value.code .. ": " .. value.message
end
local function call_function(target: string, input: unknown): (unknown, string?)
    local raw, err = funcs.call(target, input)
    if err then return nil, tostring(err) end
    return raw, nil
end
-- The host setup a launch of the definition needs: host-selected roots are
-- associated, and a root whose location changed is associated again, before
-- admission grants from them.
local function setup(call: Call, request: {[string]: unknown}): ({[string]: unknown}?, string?)
    local raw, setup_error = call("bee.harness.binding:setup", request)
    local prepared = bounds.object(raw)
    if setup_error or not prepared or prepared.ok ~= true then
        return nil, setup_error and tostring(setup_error) or
            (prepared and type(prepared.error) == "string" and prepared.error or "Agent resource setup failed")
    end
    return prepared, nil
end

function M.run(workspace_id: string, definition_ref: string, thread_id: string?,
    origin_view: {view_id: string, instance_id: string}?, phase: ((string) -> ())?, brief: string?): (admission.Admitted?, string?)
    if phase then phase("Checking installed driver") end
    local plan, refused = admission.resolve(definition_ref, nil, workspace_id)
    if not plan then return nil, fault(refused) end
    if phase then phase("Preparing agent resources") end
    local prepared, setup_error = setup(call_function, {workspace_id = workspace_id, definition_ref = definition_ref,
        expected_plan_digest = plan.plan_digest})
    if not prepared then return nil, setup_error end
    local request_id, request_error = uuid.v7()
    if not request_id then return nil, "Agent request identity: " .. tostring(request_error) end
    if phase then phase("Creating session and thread") end
    local admitted, admission_error = admission.admit_request({request_id = request_id,
        definition_ref = definition_ref, expected_plan_digest = plan.plan_digest,
        workspace_id = workspace_id, thread_id = thread_id, brief = brief or "", mode = plan.mode, workdir = prepared.workdir, origin_view = origin_view})
    if not admitted then return nil, fault(admission_error) end
    return admitted, nil
end

-- restore admits a saved window's continuation after the same host setup a
-- new launch of its definition runs.
function M.restore(request: admission.Request, operation_key: string?, call: Call?, admit: Admit?): (admission.Admitted?, admission.Reply?)
    local prepared, setup_error = setup(call or call_function, {workspace_id = request.workspace_id, definition_ref = request.definition_ref,
        expected_plan_digest = request.expected_plan_digest, saved_profile_id = request.saved_profile_id,
        saved_profile_revision = request.saved_profile_revision, overrides = request.overrides})
    if not prepared then return nil, {ok = false, error = {code = "UNAVAILABLE", message = tostring(setup_error)}, value = nil} end
    return (admit or admission.admit_request)(request, operation_key)
end

return M
